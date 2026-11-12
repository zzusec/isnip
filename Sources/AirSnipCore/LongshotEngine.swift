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
                // Quantize minor 2-bit compositor/color-management noise (& 0xFC) for resilient matching
                v |= UInt64(bytes[base + b] & 0xFC) << (b * 8)
            }
            h = (h ^ v) &* prime
        }
        for i in (chunks * 8)..<count {
            h = (h ^ UInt64(bytes[i] & 0xFC)) &* prime
        }
        return h
    }

    public static func defaultHorizontalMargin(forWidth width: Int) -> Int {
        width >= 96 ? min(64, width / 12) : 0
    }

    public static func rowHashes(
        rgba: [UInt8],
        width: Int,
        height: Int,
        startX: Int? = nil,
        endX: Int? = nil
    ) -> [UInt64] {
        guard width > 0, height > 0 else { return [] }
        let stride = width * 4
        let margin = defaultHorizontalMargin(forWidth: width)
        let x0 = max(0, min(width - 1, startX ?? margin))
        let x1 = max(x0 + 1, min(width, endX ?? (width - margin)))
        let byteOffset = x0 * 4
        let byteCount = (x1 - x0) * 4

        var result = [UInt64](repeating: 0, count: height)
        rgba.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            for y in 0..<height {
                result[y] = rowHash(base.advanced(by: y * stride + byteOffset), count: byteCount)
            }
        }
        return result
    }

    private static func hasVisualStructure(
        rgba: [UInt8],
        width: Int,
        startRow: Int,
        rowCount: Int,
        startX: Int,
        endX: Int
    ) -> Bool {
        guard rowCount > 0, endX > startX else { return false }
        let stride = width * 4
        let firstIdx = startRow * stride + startX * 4
        guard firstIdx + 2 < rgba.count else { return false }
        let r0 = Int(rgba[firstIdx])
        let g0 = Int(rgba[firstIdx + 1])
        let b0 = Int(rgba[firstIdx + 2])

        let xStep = max(1, (endX - startX) / 24)
        let yStep = max(1, rowCount / 12)
        for y in Swift.stride(from: startRow, to: startRow + rowCount, by: yStep) {
            let rowBase = y * stride
            for x in Swift.stride(from: startX, to: endX, by: xStep) {
                let o = rowBase + x * 4
                if abs(Int(rgba[o]) - r0) > 6
                    || abs(Int(rgba[o + 1]) - g0) > 6
                    || abs(Int(rgba[o + 2]) - b0) > 6 {
                    return true
                }
            }
        }
        return false
    }

    public static func fixedRegions(
        prev: [UInt8],
        next: [UInt8],
        width: Int,
        height: Int,
        params: LongshotParams
    ) -> (top: Int, bottom: Int) {
        let margin = defaultHorizontalMargin(forWidth: width)
        let x0 = max(0, min(width - 1, margin))
        let x1 = max(x0 + 1, min(width, width - margin))
        let ph = rowHashes(rgba: prev, width: width, height: height, startX: x0, endX: x1)
        let nh = rowHashes(rgba: next, width: width, height: height, startX: x0, endX: x1)

        let maxTop = max(params.minFixedRows, (height * 40) / 100)
        var top = 0
        while top < min(height, maxTop) && ph[top] == nh[top] {
            top += 1
        }
        if top < params.minFixedRows
            || !hasVisualStructure(rgba: prev, width: width, startRow: 0, rowCount: top, startX: x0, endX: x1) {
            top = 0
        }

        let maxBottom = max(params.minFixedRows, (height * 35) / 100)
        var bottom = 0
        while bottom < min(height, maxBottom) && ph[height - 1 - bottom] == nh[height - 1 - bottom] {
            bottom += 1
        }
        if top + bottom > height {
            bottom = height - top
        }
        if bottom < params.minFixedRows
            || !hasVisualStructure(rgba: prev, width: width, startRow: height - bottom, rowCount: bottom, startX: x0, endX: x1) {
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
        let primary = locateWithHashes(
            ph: ph,
            nh: nh,
            height: height,
            fixedTop: fixedTop,
            fixedBottom: fixedBottom,
            params: params
        )
        if primary.confident || width < 160 {
            return primary
        }

        // Fallback for pages with fixed left/right navigation sidebars: match center 50% content column
        let cx0 = width / 4
        let cx1 = (width * 3) / 4
        let cph = rowHashes(rgba: prev, width: width, height: height, startX: cx0, endX: cx1)
        let cnh = rowHashes(rgba: next, width: width, height: height, startX: cx0, endX: cx1)
        let centerMatch = locateWithHashes(
            ph: cph,
            nh: cnh,
            height: height,
            fixedTop: fixedTop,
            fixedBottom: fixedBottom,
            params: params
        )
        return centerMatch.confident ? centerMatch : primary
    }

    private static func locateWithHashes(
        ph: [UInt64],
        nh: [UInt64],
        height: Int,
        fixedTop: Int,
        fixedBottom: Int,
        params: LongshotParams
    ) -> LongshotMatch {
        let ct = fixedTop
        let contentH = max(0, height - fixedTop - fixedBottom)
        if contentH < 8 || ph.count < height || nh.count < height {
            return LongshotMatch(offset: 0, startRow: height, endRow: height, confident: false)
        }
        let maxShift = max(1, (contentH * 2) / 3)

        var sameTotal = 0
        var featureCount = 0
        var featureSame = 0
        for i in 0..<contentH {
            let idx = ct + i
            let eq = (ph[idx] == nh[idx])
            if eq { sameTotal += 1 }
            if i > 0 && (ph[idx] != ph[idx - 1] || nh[idx] != nh[idx - 1]) {
                featureCount += 1
                if eq { featureSame += 1 }
            }
        }
        let totalZeroRatio = Double(sameTotal) / Double(contentH)
        let minZeroFeatureRatio = max(0.75, params.minRatio - 0.08)
        let zeroFeaturesAgree = (featureCount == 0) || (Double(featureSame) / Double(featureCount) >= minZeroFeatureRatio)
        if totalZeroRatio >= params.minRatio && zeroFeaturesAgree {
            return LongshotMatch(offset: 0, startRow: height, endRow: height, confident: true)
        }

        let down = bestConsistentShift(
            ph: ph,
            nh: nh,
            ct: ct,
            ch: contentH,
            maxShift: maxShift,
            minRatio: params.minRatio,
            frameHasFeatures: featureCount > 0,
            up: false
        )
        let up = bestConsistentShift(
            ph: ph,
            nh: nh,
            ct: ct,
            ch: contentH,
            maxShift: maxShift,
            minRatio: params.minRatio,
            frameHasFeatures: featureCount > 0,
            up: true
        )

        switch (down, up) {
        case (nil, nil):
            return LongshotMatch(offset: 0, startRow: height, endRow: height, confident: false)
        case (let d?, nil):
            return LongshotMatch(offset: d.shift, startRow: ct + contentH - d.shift, endRow: ct + contentH, confident: true)
        case (nil, let u?):
            return LongshotMatch(offset: -u.shift, startRow: ct, endRow: ct + u.shift, confident: true)
        case (let d?, let u?):
            if d.score > u.score + 0.02 || (abs(d.score - u.score) <= 0.02 && d.shift <= u.shift) {
                return LongshotMatch(offset: d.shift, startRow: ct + contentH - d.shift, endRow: ct + contentH, confident: true)
            } else {
                return LongshotMatch(offset: -u.shift, startRow: ct, endRow: ct + u.shift, confident: true)
            }
        }
    }

    private static func bestConsistentShift(
        ph: [UInt64],
        nh: [UInt64],
        ct: Int,
        ch: Int,
        maxShift: Int,
        minRatio: Double,
        frameHasFeatures: Bool,
        up: Bool
    ) -> (shift: Int, score: Double)? {
        let minFeatureRatio = max(0.70, minRatio - 0.14)
        var best: (shift: Int, score: Double)?

        for s in 1...maxShift {
            let overlap = ch - s
            if overlap < 6 { continue }
            var matches = 0
            var featTotal = 0
            var featMatches = 0
            for i in 0..<overlap {
                let pIdx = up ? (ct + i) : (ct + i + s)
                let nIdx = up ? (ct + i + s) : (ct + i)
                let equal = (ph[pIdx] == nh[nIdx])
                if equal { matches += 1 }
                if i > 0 && (ph[pIdx] != ph[pIdx - 1] || nh[nIdx] != nh[nIdx - 1]) {
                    featTotal += 1
                    if equal { featMatches += 1 }
                }
            }
            let totalRatio = Double(matches) / Double(overlap)
            if totalRatio < minRatio { continue }

            let score: Double
            if featTotal > 0 {
                let featRatio = Double(featMatches) / Double(featTotal)
                if featRatio < minFeatureRatio { continue }
                score = featRatio * 0.72 + totalRatio * 0.28
            } else {
                if frameHasFeatures { continue }
                score = totalRatio
            }

            if let current = best {
                if score > current.score + 0.008 {
                    best = (s, score)
                }
            } else {
                best = (s, score)
            }
        }
        return best
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
