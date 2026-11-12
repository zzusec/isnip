import Foundation
import CoreGraphics

public struct LongshotParams: Equatable, Sendable {
    public var minRatio: Double
    public var minFixedRows: Int

    public init(minRatio: Double = 0.88, minFixedRows: Int = 8) {
        self.minRatio = minRatio
        self.minFixedRows = minFixedRows
    }
}

public struct LongshotMatch: Equatable, Sendable {
    /// >0 scrolled down (content moved up); <0 scrolled up (content moved down); 0 still
    public var offset: Int
    /// Inclusive start, exclusive end row in `new` frame to append/prepend
    public var startRow: Int
    public var endRow: Int
    public var confident: Bool

    public init(offset: Int, startRow: Int, endRow: Int, confident: Bool) {
        self.offset = offset
        self.startRow = startRow
        self.endRow = endRow
        self.confident = confident
    }
}

public enum LongshotStitcher {
    public static func rowHash(_ bytes: UnsafePointer<UInt8>, count: Int) -> UInt64 {
        let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        var h = offsetBasis
        let chunks = count / 8
        for c in 0..<chunks {
            var v: UInt64 = 0
            let base = c * 8
            for b in 0..<8 {
                // Quantize minor 1-bit compression/compositor noise by masking LSB (& 0xFE) for resilient matching
                v |= UInt64(bytes[base + b] & 0xFE) << (b * 8)
            }
            h = (h ^ v) &* prime
        }
        for i in (chunks * 8)..<count {
            h = (h ^ UInt64(bytes[i] & 0xFE)) &* prime
        }
        return h
    }

    public static func rowHashes(rgba: [UInt8], width: Int, height: Int) -> [UInt64] {
        let stride = width * 4
        var result = [UInt64](repeating: 0, count: height)
        rgba.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            for y in 0..<height {
                result[y] = rowHash(base.advanced(by: y * stride), count: stride)
            }
        }
        return result
    }

    public static func fixedRegions(
        prev: [UInt8],
        next: [UInt8],
        width: Int,
        height: Int,
        params: LongshotParams
    ) -> (top: Int, bottom: Int) {
        let ph = rowHashes(rgba: prev, width: width, height: height)
        let nh = rowHashes(rgba: next, width: width, height: height)

        var top = 0
        while top < height && ph[top] == nh[top] {
            top += 1
        }
        if top < params.minFixedRows {
            top = 0
        }

        var bottom = 0
        while bottom < height && ph[height - 1 - bottom] == nh[height - 1 - bottom] {
            bottom += 1
        }
        if top + bottom > height {
            bottom = height - top
        }
        if bottom < params.minFixedRows {
            bottom = 0
        }
        return (top, bottom)
    }

    public static func locate(
        prev: [UInt8],
        next: [UInt8],
        width: Int,
        height: Int,
        fixedTop: Int,
        fixedBottom: Int,
        params: LongshotParams
    ) -> LongshotMatch {
        let ph = rowHashes(rgba: prev, width: width, height: height)
        let nh = rowHashes(rgba: next, width: width, height: height)
        let ct = fixedTop
        let contentH = max(0, height - fixedTop - fixedBottom)
        if contentH < 8 {
            return LongshotMatch(offset: 0, startRow: height, endRow: height, confident: false)
        }
        let maxShift = max(1, (contentH * 2) / 3)

        var same = 0
        for i in 0..<contentH where ph[ct + i] == nh[ct + i] {
            same += 1
        }
        if Double(same) / Double(contentH) >= params.minRatio {
            return LongshotMatch(offset: 0, startRow: height, endRow: height, confident: true)
        }

        let down = minConsistentShift(ph: ph, nh: nh, ct: ct, ch: contentH, maxShift: maxShift, minRatio: params.minRatio, up: false)
        let up = minConsistentShift(ph: ph, nh: nh, ct: ct, ch: contentH, maxShift: maxShift, minRatio: params.minRatio, up: true)

        switch (down, up) {
        case (nil, nil):
            return LongshotMatch(offset: 0, startRow: height, endRow: height, confident: false)
        case (let s?, nil):
            return LongshotMatch(offset: s, startRow: ct + contentH - s, endRow: ct + contentH, confident: true)
        case (nil, let s?):
            return LongshotMatch(offset: -s, startRow: ct, endRow: ct + s, confident: true)
        case (let sd?, let su?):
            if sd <= su {
                return LongshotMatch(offset: sd, startRow: ct + contentH - sd, endRow: ct + contentH, confident: true)
            } else {
                return LongshotMatch(offset: -su, startRow: ct, endRow: ct + su, confident: true)
            }
        }
    }

    private static func minConsistentShift(
        ph: [UInt64],
        nh: [UInt64],
        ct: Int,
        ch: Int,
        maxShift: Int,
        minRatio: Double,
        up: Bool
    ) -> Int? {
        for s in 1...maxShift {
            let overlap = ch - s
            if overlap < 6 { continue }
            var matches = 0
            for i in 0..<overlap {
                let equal = up
                    ? (ph[ct + i] == nh[ct + i + s])
                    : (ph[ct + i + s] == nh[ct + i])
                if equal { matches += 1 }
            }
            if Double(matches) / Double(overlap) >= minRatio {
                return s
            }
        }
        return nil
    }
}

public enum LongshotStepResult: Equatable, Sendable {
    case appended(offset: Int, rows: Int)
    case still
    case failed
    case limitReached
}

public final class LongshotCanvas {
    public let width: Int
    public let frameHeight: Int
    public let params: LongshotParams
    public let maxHeight: Int

    private var firstFrame: [UInt8]?
    private var prevFrame: [UInt8] = []
    private var headerBytes: [UInt8] = []
    public private(set) var headerHeight: Int = 0
    private var footerBytes: [UInt8] = []
    public private(set) var footerHeight: Int = 0

    /// Deque-like row chunks: prepended rows in reverse order + appended rows in forward order
    private var topRowsData: [UInt8] = []
    private var topRowCount: Int = 0
    private var bottomRowsData: [UInt8] = []
    private var bottomRowCount: Int = 0

    private var segments: [(prepended: Bool, rows: Int)] = []

    public init(width: Int, frameHeight: Int, params: LongshotParams = LongshotParams(), maxHeight: Int = 30000) {
        self.width = width
        self.frameHeight = frameHeight
        self.params = params
        self.maxHeight = maxHeight
    }

    public var contentHeight: Int { topRowCount + bottomRowCount }

    public var totalHeight: Int {
        if let _ = firstFrame, contentHeight == 0 {
            return frameHeight
        }
        return headerHeight + contentHeight + footerHeight
    }

    public var canUndo: Bool { !segments.isEmpty }
    public var segmentCount: Int { segments.count }

    public func seed(_ frame: PixelBufferRGBA) {
        precondition(frame.width == width && frame.height == frameHeight)
        firstFrame = frame.rgba
        prevFrame = frame.rgba
    }

    public func push(_ frame: PixelBufferRGBA) -> LongshotStepResult {
        guard frame.width == width && frame.height == frameHeight else { return .failed }
        let rgba = frame.rgba
        let stride = width * 4

        if let first = firstFrame {
            // Check if completely identical to first frame -> keep buffering until first real movement!
            let initCheck = LongshotStitcher.locate(
                prev: first,
                next: rgba,
                width: width,
                height: frameHeight,
                fixedTop: 0,
                fixedBottom: 0,
                params: params
            )
            if initCheck.confident && initCheck.offset == 0 {
                return .still
            }

            firstFrame = nil
            var (t, b) = LongshotStitcher.fixedRegions(prev: first, next: rgba, width: width, height: frameHeight, params: params)
            if t >= frameHeight {
                t = 0
                b = 0
            }
            if t >= params.minFixedRows {
                headerBytes = Array(first[0..<(t * stride)])
                headerHeight = t
            }
            if b >= params.minFixedRows {
                footerBytes = Array(first[(first.count - b * stride)..<first.count])
                footerHeight = b
            }
            let bodyStart = headerHeight * stride
            let bodyEnd = (frameHeight - footerHeight) * stride
            if bodyEnd > bodyStart {
                bottomRowsData.append(contentsOf: first[bodyStart..<bodyEnd])
                bottomRowCount += (frameHeight - headerHeight - footerHeight)
            }
            prevFrame = first
            return pushInner(rgba)
        }

        return pushInner(rgba)
    }

    private func pushInner(_ rgba: [UInt8]) -> LongshotStepResult {
        let stride = width * 4
        let match = LongshotStitcher.locate(
            prev: prevFrame,
            next: rgba,
            width: width,
            height: frameHeight,
            fixedTop: headerHeight,
            fixedBottom: footerHeight,
            params: params
        )
        if !match.confident {
            prevFrame = rgba
            return .failed
        }
        if match.offset == 0 {
            prevFrame = rgba
            return .still
        }
        let rows = match.endRow - match.startRow
        if rows <= 0 {
            prevFrame = rgba
            return .still
        }
        if headerHeight + contentHeight + footerHeight + rows > maxHeight {
            prevFrame = rgba
            return .limitReached
        }

        let slice = rgba[(match.startRow * stride)..<(match.endRow * stride)]
        let prepended = match.offset < 0
        if prepended {
            // Store prepended slices at the front
            var updated = Array(slice)
            updated.append(contentsOf: topRowsData)
            topRowsData = updated
            topRowCount += rows
        } else {
            bottomRowsData.append(contentsOf: slice)
            bottomRowCount += rows
        }
        segments.append((prepended: prepended, rows: rows))
        prevFrame = rgba
        return .appended(offset: match.offset, rows: rows)
    }

    @discardableResult
    public func undoLast() -> Bool {
        guard let last = segments.popLast() else { return false }
        let byteCount = last.rows * width * 4
        if last.prepended {
            guard topRowsData.count >= byteCount else { return false }
            topRowsData.removeFirst(byteCount)
            topRowCount -= last.rows
        } else {
            guard bottomRowsData.count >= byteCount else { return false }
            bottomRowsData.removeLast(byteCount)
            bottomRowCount -= last.rows
        }
        return true
    }

    public func exportBuffer() -> PixelBufferRGBA? {
        if let first = firstFrame, contentHeight == 0 {
            return PixelBufferRGBA(width: width, height: frameHeight, rgba: first)
        }
        let totalH = headerHeight + contentHeight + footerHeight
        guard totalH > 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(totalH * width * 4)
        out.append(contentsOf: headerBytes)
        out.append(contentsOf: topRowsData)
        out.append(contentsOf: bottomRowsData)
        out.append(contentsOf: footerBytes)
        return PixelBufferRGBA(width: width, height: totalH, rgba: out)
    }

    public func makeThumbnail(maxWidth: Int, maxHeight: Int) -> CGImage? {
        guard width > 0, maxWidth > 0, maxHeight > 0 else { return nil }
        if let first = firstFrame, contentHeight == 0 {
            return PixelBufferRGBA(width: width, height: frameHeight, rgba: first).makeCGImage()
        }
        let totalH = headerHeight + contentHeight + footerHeight
        guard totalH > 0 else { return nil }

        let scale = min(Double(maxWidth) / Double(width), Double(maxHeight) / Double(totalH))
        let tw = max(1, min(maxWidth, Int((Double(width) * scale).rounded())))
        let th = max(1, min(maxHeight, Int((Double(totalH) * scale).rounded())))
        var thumb = [UInt8](repeating: 0, count: tw * th * 4)
        let stride = width * 4

        func rowSlice(_ y: Int) -> ArraySlice<UInt8>? {
            if y < headerHeight {
                let o = y * stride
                return headerBytes[o..<(o + stride)]
            }
            let cy = y - headerHeight
            if cy < topRowCount {
                let o = cy * stride
                return topRowsData[o..<(o + stride)]
            }
            let by = cy - topRowCount
            if by < bottomRowCount {
                let o = by * stride
                return bottomRowsData[o..<(o + stride)]
            }
            let fy = by - bottomRowCount
            if fy < footerHeight {
                let o = fy * stride
                return footerBytes[o..<(o + stride)]
            }
            return nil
        }

        for ty in 0..<th {
            let sy = (ty * totalH) / th
            guard let row = rowSlice(sy) else { continue }
            let rowStart = row.startIndex
            for tx in 0..<tw {
                let sx = ((tx * width) / tw) * 4
                let dst = (ty * tw + tx) * 4
                thumb[dst] = row[rowStart + sx]
                thumb[dst + 1] = row[rowStart + sx + 1]
                thumb[dst + 2] = row[rowStart + sx + 2]
                thumb[dst + 3] = row[rowStart + sx + 3]
            }
        }
        return PixelBufferRGBA(width: tw, height: th, rgba: thumb).makeCGImage()
    }
}
