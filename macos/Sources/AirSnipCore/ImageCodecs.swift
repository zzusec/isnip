import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum ExportImageFormat: String, Codable, CaseIterable, Sendable {
    case png
    case jpeg
    case webp

    public var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .webp: return "webp"
        }
    }

    public var displayName: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .webp: return "WebP"
        }
    }
}

public struct PixelRect: Equatable, Hashable, Codable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = max(0, width)
        self.height = max(0, height)
    }

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func clamped(toWidth maxW: Int, height maxH: Int) -> PixelRect {
        let x0 = max(0, min(maxW, x))
        let y0 = max(0, min(maxH, y))
        let x1 = max(x0, min(maxW, x + width))
        let y1 = max(y0, min(maxH, y + height))
        return PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

public struct RGBAColor: Equatable, Hashable, Codable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public init(hex: UInt32, alpha: UInt8 = 255) {
        self.r = UInt8((hex >> 16) & 0xFF)
        self.g = UInt8((hex >> 8) & 0xFF)
        self.b = UInt8(hex & 0xFF)
        self.a = alpha
    }

    public var hexString: String {
        String(format: "#%02X%02X%02X", r, g, b)
    }

    public var rgbString: String {
        "\(r), \(g), \(b)"
    }

    public var cgColor: CGColor {
        CGColor(
            srgbRed: CGFloat(r) / 255.0,
            green: CGFloat(g) / 255.0,
            blue: CGFloat(b) / 255.0,
            alpha: CGFloat(a) / 255.0
        )
    }
}

public struct PixelBufferRGBA: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var rgba: [UInt8] // Top-down, non-premultiplied RGBA, 4 bytes per pixel

    public init(width: Int, height: Int, rgba: [UInt8]) {
        precondition(width > 0 && height > 0 && rgba.count == width * height * 4)
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    public init?(cgImage: CGImage) {
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &buf,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Unpremultiply partially transparent pixels so lossless codecs preserve exact straight RGBA
        let total = w * h
        for i in 0..<total {
            let a = buf[i * 4 + 3]
            if a > 0 && a < 255 {
                let af = Int(a)
                buf[i * 4] = UInt8(min(255, (Int(buf[i * 4]) * 255 + af / 2) / af))
                buf[i * 4 + 1] = UInt8(min(255, (Int(buf[i * 4 + 1]) * 255 + af / 2) / af))
                buf[i * 4 + 2] = UInt8(min(255, (Int(buf[i * 4 + 2]) * 255 + af / 2) / af))
            }
        }
        self.width = w
        self.height = h
        self.rgba = buf
    }

    public func pixel(x: Int, y: Int) -> RGBAColor {
        let cx = max(0, min(width - 1, x))
        let cy = max(0, min(height - 1, y))
        let idx = (cy * width + cx) * 4
        return RGBAColor(r: rgba[idx], g: rgba[idx + 1], b: rgba[idx + 2], a: rgba[idx + 3])
    }

    public func cropped(to rect: PixelRect) -> PixelBufferRGBA? {
        let r = rect.clamped(toWidth: width, height: height)
        guard !r.isEmpty else { return nil }
        var out = [UInt8](repeating: 0, count: r.width * r.height * 4)
        let rowBytes = r.width * 4
        for row in 0..<r.height {
            let srcStart = ((r.y + row) * width + r.x) * 4
            let dstStart = row * rowBytes
            out[dstStart..<(dstStart + rowBytes)] = rgba[srcStart..<(srcStart + rowBytes)]
        }
        return PixelBufferRGBA(width: r.width, height: r.height, rgba: out)
    }

    public func makeCGImage() -> CGImage? {
        var premul = rgba
        let total = width * height
        for i in 0..<total {
            let a = Int(premul[i * 4 + 3])
            if a < 255 {
                if a == 0 {
                    premul[i * 4] = 0
                    premul[i * 4 + 1] = 0
                    premul[i * 4 + 2] = 0
                } else {
                    premul[i * 4] = UInt8((Int(premul[i * 4]) * a + 127) / 255)
                    premul[i * 4 + 1] = UInt8((Int(premul[i * 4 + 1]) * a + 127) / 255)
                    premul[i * 4 + 2] = UInt8((Int(premul[i * 4 + 2]) * a + 127) / 255)
                }
            }
        }
        let data = Data(premul) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

/// Three-pass O(1)-per-pixel separable box blur approximating a true Gaussian kernel on CPU.
public enum BoxBlurEngine {
    public static func blur(_ source: PixelBufferRGBA, radius: Int) -> PixelBufferRGBA {
        let r = max(1, min(96, radius))
        var src = source.rgba
        var dst = [UInt8](repeating: 0, count: src.count)
        let w = source.width
        let h = source.height

        for _ in 0..<3 {
            horizontalPass(src: src, dst: &dst, width: w, height: h, radius: r)
            verticalPass(src: dst, dst: &src, width: w, height: h, radius: r)
        }
        return PixelBufferRGBA(width: w, height: h, rgba: src)
    }

    private static func horizontalPass(src: [UInt8], dst: inout [UInt8], width: Int, height: Int, radius: Int) {
        let kernel = radius * 2 + 1
        src.withUnsafeBufferPointer { sPtr in
            dst.withUnsafeMutableBufferPointer { dPtr in
                guard let sb = sPtr.baseAddress, let db = dPtr.baseAddress else { return }
                for y in 0..<height {
                    let rowOffset = y * width * 4
                    var sumR = 0, sumG = 0, sumB = 0, sumA = 0
                    for k in -radius...radius {
                        let cx = max(0, min(width - 1, k)) * 4 + rowOffset
                        sumR += Int(sb[cx])
                        sumG += Int(sb[cx + 1])
                        sumB += Int(sb[cx + 2])
                        sumA += Int(sb[cx + 3])
                    }
                    for x in 0..<width {
                        let outIdx = rowOffset + x * 4
                        db[outIdx] = UInt8((sumR + radius) / kernel)
                        db[outIdx + 1] = UInt8((sumG + radius) / kernel)
                        db[outIdx + 2] = UInt8((sumB + radius) / kernel)
                        db[outIdx + 3] = UInt8((sumA + radius) / kernel)

                        let removeX = max(0, x - radius) * 4 + rowOffset
                        let addX = min(width - 1, x + radius + 1) * 4 + rowOffset
                        sumR += Int(sb[addX]) - Int(sb[removeX])
                        sumG += Int(sb[addX + 1]) - Int(sb[removeX + 1])
                        sumB += Int(sb[addX + 2]) - Int(sb[removeX + 2])
                        sumA += Int(sb[addX + 3]) - Int(sb[removeX + 3])
                    }
                }
            }
        }
    }

    private static func verticalPass(src: [UInt8], dst: inout [UInt8], width: Int, height: Int, radius: Int) {
        let kernel = radius * 2 + 1
        let stride = width * 4
        src.withUnsafeBufferPointer { sPtr in
            dst.withUnsafeMutableBufferPointer { dPtr in
                guard let sb = sPtr.baseAddress, let db = dPtr.baseAddress else { return }
                for x in 0..<width {
                    let colOffset = x * 4
                    var sumR = 0, sumG = 0, sumB = 0, sumA = 0
                    for k in -radius...radius {
                        let cy = max(0, min(height - 1, k)) * stride + colOffset
                        sumR += Int(sb[cy])
                        sumG += Int(sb[cy + 1])
                        sumB += Int(sb[cy + 2])
                        sumA += Int(sb[cy + 3])
                    }
                    for y in 0..<height {
                        let outIdx = y * stride + colOffset
                        db[outIdx] = UInt8((sumR + radius) / kernel)
                        db[outIdx + 1] = UInt8((sumG + radius) / kernel)
                        db[outIdx + 2] = UInt8((sumB + radius) / kernel)
                        db[outIdx + 3] = UInt8((sumA + radius) / kernel)

                        let removeY = max(0, y - radius) * stride + colOffset
                        let addY = min(height - 1, y + radius + 1) * stride + colOffset
                        sumR += Int(sb[addY]) - Int(sb[removeY])
                        sumG += Int(sb[addY + 1]) - Int(sb[removeY + 1])
                        sumB += Int(sb[addY + 2]) - Int(sb[removeY + 2])
                        sumA += Int(sb[addY + 3]) - Int(sb[removeY + 3])
                    }
                }
            }
        }
    }
}

public enum ImageEncodingError: LocalizedError {
    case invalidImage
    case destinationCreationFailed
    case finalizeFailed
    case webpDimensionsExceeded(width: Int, height: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "无效图像数据"
        case .destinationCreationFailed:
            return "无法创建编码器"
        case .finalizeFailed:
            return "写入图像失败"
        case .webpDimensionsExceeded(let w, let h):
            return "WebP 单边上限 16384 px（当前 \(w)×\(h)），请改存 PNG"
        }
    }
}

public struct PngCompressionResult: Sendable, Equatable {
    public let data: Data
    public let originalBytes: Int
    public let compressedBytes: Int
    public let usedPngquant: Bool
    public let usedOxipng: Bool

    public init(
        data: Data,
        originalBytes: Int,
        compressedBytes: Int,
        usedPngquant: Bool,
        usedOxipng: Bool
    ) {
        self.data = data
        self.originalBytes = originalBytes
        self.compressedBytes = compressedBytes
        self.usedPngquant = usedPngquant
        self.usedOxipng = usedOxipng
    }

    public var savedRatioPercent: Int {
        guard originalBytes > 0, compressedBytes < originalBytes else { return 0 }
        let pct = (Double(originalBytes - compressedBytes) / Double(originalBytes)) * 100.0
        return max(0, min(99, Int(pct.rounded())))
    }

    public var formattedSummary: String {
        let compStr = PngSmartCompressor.formatByteCount(compressedBytes)
        if savedRatioPercent >= 3 {
            let origStr = PngSmartCompressor.formatByteCount(originalBytes)
            return "\(origStr) → \(compStr) (-\(savedRatioPercent)%)"
        }
        return compStr
    }

    public var compactBadgeSummary: String {
        let compStr = PngSmartCompressor.formatByteCount(compressedBytes)
        if savedRatioPercent >= 3 {
            return "\(compStr) (-\(savedRatioPercent)%)"
        }
        return compStr
    }
}

/// Smart PNG compression pipeline matching:
/// `pngquant --speed 1 - <"$f" | oxipng -o max --out "[压缩后]$f" -`
public enum PngSmartCompressor {
    public enum Mode: Sendable, Equatable {
        case fastQuantizeOnly
        case fullPipeline(oxipngMax: Bool)
    }

    private static let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    public static func formatByteCount(_ bytes: Int) -> String {
        if bytes >= 1_000_000 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
        } else if bytes >= 1024 {
            return String(format: "%d KB", max(1, Int((Double(bytes) / 1024.0).rounded())))
        } else {
            return "\(bytes) B"
        }
    }

    public static func resolveHelperBinary(named name: String) -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []

        if let envDir = ProcessInfo.processInfo.environment["ISNIP_HELPERS_DIR"] ?? ProcessInfo.processInfo.environment["AIRSNIP_HELPERS_DIR"], !envDir.isEmpty {
            candidates.append(URL(fileURLWithPath: envDir, isDirectory: true).appendingPathComponent(name))
        }

        let bundleHelpers = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent(name)
        candidates.append(bundleHelpers)

        // Source-tree fallback (used during `swift test` and local CLI development):
        // #filePath = .../macos/Sources/AirSnipCore/ImageCodecs.swift -> .../macos/Vendor/Helpers/<name>
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(
            sourceRoot
                .appendingPathComponent("Vendor", isDirectory: true)
                .appendingPathComponent("Helpers", isDirectory: true)
                .appendingPathComponent(name)
        )

        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/\(name)"))

        for url in candidates {
            if fm.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    public static var hasBundledOrSystemTools: Bool {
        resolveHelperBinary(named: "pngquant") != nil || resolveHelperBinary(named: "oxipng") != nil
    }

    private static func isValidPNG(_ data: Data) -> Bool {
        guard data.count > pngMagic.count else { return false }
        return Array(data.prefix(pngMagic.count)) == pngMagic
    }

    @discardableResult
    private static func runTool(_ executable: URL, arguments: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        } catch {
            return -1
        }
    }

    public static func compress(
        _ rawPngData: Data,
        quality: PngCompressionQualityPreset = .visuallyLossless,
        mode: Mode = .fullPipeline(oxipngMax: true)
    ) -> PngCompressionResult {
        guard isValidPNG(rawPngData) else {
            return PngCompressionResult(
                data: rawPngData,
                originalBytes: rawPngData.count,
                compressedBytes: rawPngData.count,
                usedPngquant: false,
                usedOxipng: false
            )
        }

        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("isnip-png-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        } catch {
            return PngCompressionResult(
                data: rawPngData,
                originalBytes: rawPngData.count,
                compressedBytes: rawPngData.count,
                usedPngquant: false,
                usedOxipng: false
            )
        }
        defer {
            try? fm.removeItem(at: workDir)
        }

        let inputURL = workDir.appendingPathComponent("input.png")
        let quantURL = workDir.appendingPathComponent("quant.png")
        let oxiURL = workDir.appendingPathComponent("oxi.png")

        do {
            try rawPngData.write(to: inputURL, options: .atomic)
        } catch {
            return PngCompressionResult(
                data: rawPngData,
                originalBytes: rawPngData.count,
                compressedBytes: rawPngData.count,
                usedPngquant: false,
                usedOxipng: false
            )
        }

        var bestData = rawPngData
        var bestFileURL = inputURL
        var didPngquant = false
        var didOxipng = false

        if let pngquantURL = resolveHelperBinary(named: "pngquant") {
            var args = ["--speed", "1"]
            if let q = quality.qualityArgument {
                args += ["--quality", q]
            }
            args += ["--force", "--output", quantURL.path, "--", inputURL.path]
            let rc = runTool(pngquantURL, arguments: args)
            if rc == 0,
               let qData = try? Data(contentsOf: quantURL),
               isValidPNG(qData),
               qData.count < bestData.count {
                bestData = qData
                bestFileURL = quantURL
                didPngquant = true
            }
        }

        if case .fullPipeline(let oxipngMax) = mode,
           let oxipngURL = resolveHelperBinary(named: "oxipng") {
            let optLevel = oxipngMax ? "max" : "4"
            let args = ["-o", optLevel, "--strip", "safe", "--out", oxiURL.path, bestFileURL.path]
            let rc = runTool(oxipngURL, arguments: args)
            if rc == 0,
               let oData = try? Data(contentsOf: oxiURL),
               isValidPNG(oData),
               oData.count <= bestData.count {
                bestData = oData
                didOxipng = true
            }
        }

        return PngCompressionResult(
            data: bestData,
            originalBytes: rawPngData.count,
            compressedBytes: bestData.count,
            usedPngquant: didPngquant,
            usedOxipng: didOxipng
        )
    }

    /// Runs lossless `oxipng -o max --strip safe` on an already-quantized (or raw) PNG buffer.
    public static func optimizeWithOxipng(
        _ currentPngData: Data,
        originalBytes: Int,
        usedPngquant: Bool,
        oxipngMax: Bool = true
    ) -> PngCompressionResult {
        guard isValidPNG(currentPngData),
              let oxipngURL = resolveHelperBinary(named: "oxipng") else {
            return PngCompressionResult(
                data: currentPngData,
                originalBytes: originalBytes,
                compressedBytes: currentPngData.count,
                usedPngquant: usedPngquant,
                usedOxipng: false
            )
        }
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("isnip-oxi-\(UUID().uuidString)", isDirectory: true)
        guard (try? fm.createDirectory(at: workDir, withIntermediateDirectories: true)) != nil else {
            return PngCompressionResult(
                data: currentPngData,
                originalBytes: originalBytes,
                compressedBytes: currentPngData.count,
                usedPngquant: usedPngquant,
                usedOxipng: false
            )
        }
        defer { try? fm.removeItem(at: workDir) }

        let inURL = workDir.appendingPathComponent("in.png")
        let outURL = workDir.appendingPathComponent("out.png")
        guard (try? currentPngData.write(to: inURL, options: .atomic)) != nil else {
            return PngCompressionResult(
                data: currentPngData,
                originalBytes: originalBytes,
                compressedBytes: currentPngData.count,
                usedPngquant: usedPngquant,
                usedOxipng: false
            )
        }
        let optLevel = oxipngMax ? "max" : "4"
        let rc = runTool(oxipngURL, arguments: ["-o", optLevel, "--strip", "safe", "--out", outURL.path, inURL.path])
        if rc == 0,
           let outData = try? Data(contentsOf: outURL),
           isValidPNG(outData),
           outData.count <= currentPngData.count {
            return PngCompressionResult(
                data: outData,
                originalBytes: originalBytes,
                compressedBytes: outData.count,
                usedPngquant: usedPngquant,
                usedOxipng: true
            )
        }
        return PngCompressionResult(
            data: currentPngData,
            originalBytes: originalBytes,
            compressedBytes: currentPngData.count,
            usedPngquant: usedPngquant,
            usedOxipng: false
        )
    }
}

public enum ImageEncoder {
    public static func encode(
        _ image: CGImage,
        format: ExportImageFormat,
        jpegQuality: Double = 0.92,
        smartPngCompression: Bool = false,
        pngQuality: PngCompressionQualityPreset = .visuallyLossless,
        oxipngMax: Bool = true
    ) throws -> Data {
        switch format {
        case .png:
            let raw = try encodeWithImageIO(image, utType: UTType.png.identifier, properties: nil)
            if smartPngCompression {
                return PngSmartCompressor.compress(raw, quality: pngQuality, mode: .fullPipeline(oxipngMax: oxipngMax)).data
            }
            return raw
        case .jpeg:
            let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: jpegQuality]
            return try encodeWithImageIO(image, utType: UTType.jpeg.identifier, properties: props)
        case .webp:
            guard image.width <= 16384 && image.height <= 16384 else {
                throw ImageEncodingError.webpDimensionsExceeded(width: image.width, height: image.height)
            }
            guard let buf = PixelBufferRGBA(cgImage: image) else {
                throw ImageEncodingError.invalidImage
            }
            return VP8LLosslessEncoder.encode(buf)
        }
    }

    public static func encodePNGWithReport(
        _ image: CGImage,
        smartCompression: Bool,
        quality: PngCompressionQualityPreset = .visuallyLossless,
        mode: PngSmartCompressor.Mode = .fullPipeline(oxipngMax: true)
    ) throws -> PngCompressionResult {
        let raw = try encodeWithImageIO(image, utType: UTType.png.identifier, properties: nil)
        guard smartCompression else {
            return PngCompressionResult(
                data: raw,
                originalBytes: raw.count,
                compressedBytes: raw.count,
                usedPngquant: false,
                usedOxipng: false
            )
        }
        return PngSmartCompressor.compress(raw, quality: quality, mode: mode)
    }

    private static func encodeWithImageIO(_ image: CGImage, utType: String, properties: [CFString: Any]?) throws -> Data {
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData, utType as CFString, 1, nil) else {
            throw ImageEncodingError.destinationCreationFailed
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary?)
        guard CGImageDestinationFinalize(dest) else {
            throw ImageEncodingError.finalizeFailed
        }
        return mutableData as Data
    }
}

/// Pure-Swift RFC 9649 compliant Lossless WebP (VP8L) encoder with Subtract-Green transform and LZ77 spatial back-references.
public enum VP8LLosslessEncoder {
    private static let clOrder = [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]

    private struct BitWriter {
        private(set) var bytes: [UInt8] = []
        private var buffer: UInt64 = 0
        private var bitCount: Int = 0

        mutating func writeBits(_ value: Int, count: Int) {
            guard count > 0 else { return }
            let mask: UInt64 = count == 64 ? ~0 : ((1 << count) - 1)
            buffer |= (UInt64(bitPattern: Int64(value)) & mask) << bitCount
            bitCount += count
            while bitCount >= 8 {
                bytes.append(UInt8(truncatingIfNeeded: buffer))
                buffer >>= 8
                bitCount -= 8
            }
        }

        mutating func finish() -> [UInt8] {
            if bitCount > 0 {
                bytes.append(UInt8(truncatingIfNeeded: buffer))
                buffer = 0
                bitCount = 0
            }
            return bytes
        }
    }

    private struct PrefixCode {
        let lengths: [Int]
        let codes: [Int]
        let singleSymbol: Int?
    }

    private static func reverseBits(_ code: Int, length: Int) -> Int {
        var c = code
        var r = 0
        for _ in 0..<length {
            r = (r << 1) | (c & 1)
            c >>= 1
        }
        return r
    }

    private static func canonicalCodes(from lengths: [Int]) -> [Int] {
        let maxLen = lengths.max() ?? 0
        if maxLen == 0 { return Array(repeating: 0, count: lengths.count) }
        var blCount = Array(repeating: 0, count: maxLen + 1)
        for l in lengths where l > 0 { blCount[l] += 1 }
        var nextCode = Array(repeating: 0, count: maxLen + 1)
        var code = 0
        for bits in 1...maxLen {
            code = (code + blCount[bits - 1]) << 1
            nextCode[bits] = code
        }
        var codes = Array(repeating: 0, count: lengths.count)
        for i in 0..<lengths.count {
            let l = lengths[i]
            if l > 0 {
                codes[i] = reverseBits(nextCode[l], length: l)
                nextCode[l] += 1
            }
        }
        return codes
    }

    private static func buildLimitedLengths(freqs: [Int], maxBits: Int) -> [Int] {
        let n = freqs.count
        let active = freqs.enumerated().filter { $0.element > 0 }
        if active.isEmpty {
            var res = Array(repeating: 0, count: n)
            res[0] = 1
            return res
        }
        if active.count == 1 {
            var res = Array(repeating: 0, count: n)
            res[active[0].offset] = 1
            return res
        }

        var scale = 1
        while true {
            struct Node {
                let weight: Int
                let symbol: Int
                let left: Int
                let right: Int
            }
            var nodes: [Node] = active.map {
                Node(weight: max(1, ($0.element + scale - 1) / scale), symbol: $0.offset, left: -1, right: -1)
            }
            var available = Array(0..<nodes.count)
            while available.count > 1 {
                available.sort { nodes[$0].weight < nodes[$1].weight }
                let a = available.removeFirst()
                let b = available.removeFirst()
                let parent = Node(weight: nodes[a].weight + nodes[b].weight, symbol: -1, left: a, right: b)
                nodes.append(parent)
                available.append(nodes.count - 1)
            }
            var lengths = Array(repeating: 0, count: n)
            var maxDepth = 0
            func dfs(_ idx: Int, _ depth: Int) {
                let node = nodes[idx]
                if node.symbol >= 0 {
                    lengths[node.symbol] = depth
                    if depth > maxDepth { maxDepth = depth }
                } else {
                    dfs(node.left, depth + 1)
                    dfs(node.right, depth + 1)
                }
            }
            dfs(available[0], 0)
            if maxDepth <= maxBits {
                return lengths
            }
            scale *= 2
        }
    }

    private static func writePrefixTree(_ freqs: [Int], bw: inout BitWriter) -> PrefixCode {
        let n = freqs.count
        var active = freqs.enumerated().filter { $0.element > 0 }.map { $0.offset }
        if active.isEmpty { active = [0] }

        if active.count == 1 && active[0] < 256 {
            let s0 = active[0]
            bw.writeBits(1, count: 1)
            bw.writeBits(0, count: 1)
            bw.writeBits(1, count: 1)
            bw.writeBits(s0, count: 8)
            var lengths = Array(repeating: 0, count: n)
            lengths[s0] = 0
            return PrefixCode(lengths: lengths, codes: Array(repeating: 0, count: n), singleSymbol: s0)
        }
        if active.count == 2 && active[0] < 256 && active[1] < 256 {
            let s0 = active[0], s1 = active[1]
            bw.writeBits(1, count: 1)
            bw.writeBits(1, count: 1)
            bw.writeBits(1, count: 1)
            bw.writeBits(s0, count: 8)
            bw.writeBits(s1, count: 8)
            var lengths = Array(repeating: 0, count: n)
            var codes = Array(repeating: 0, count: n)
            lengths[s0] = 1; codes[s0] = 0
            lengths[s1] = 1; codes[s1] = 1
            return PrefixCode(lengths: lengths, codes: codes, singleSymbol: nil)
        }

        var modFreqs = freqs
        if active.count == 1 {
            let dummy = active[0] == 0 ? 1 : 0
            modFreqs[dummy] = 1
        }
        let lengths = buildLimitedLengths(freqs: modFreqs, maxBits: 15)
        let codes = canonicalCodes(from: lengths)

        struct Token { let sym: Int; let extra: Int; let extraBits: Int }
        var tokens: [Token] = []
        var i = 0
        while i < n {
            if lengths[i] == 0 {
                var run = 1
                while i + run < n && lengths[i + run] == 0 && run < 138 { run += 1 }
                if run >= 11 {
                    tokens.append(Token(sym: 18, extra: run - 11, extraBits: 7))
                    i += run
                } else if run >= 3 {
                    tokens.append(Token(sym: 17, extra: run - 3, extraBits: 3))
                    i += run
                } else {
                    tokens.append(Token(sym: 0, extra: 0, extraBits: 0))
                    i += 1
                }
            } else {
                tokens.append(Token(sym: lengths[i], extra: 0, extraBits: 0))
                i += 1
            }
        }

        var clFreqs = Array(repeating: 0, count: 19)
        for t in tokens { clFreqs[t.sym] += 1 }
        if clFreqs.filter({ $0 > 0 }).count == 1 {
            let only = clFreqs.firstIndex { $0 > 0 }!
            clFreqs[only == 0 ? 1 : 0] = 1
        }
        let clLengths = buildLimitedLengths(freqs: clFreqs, maxBits: 7)
        let clCodes = canonicalCodes(from: clLengths)

        bw.writeBits(0, count: 1)
        var numCL = 19
        while numCL > 4 && clLengths[clOrder[numCL - 1]] == 0 { numCL -= 1 }
        bw.writeBits(numCL - 4, count: 4)
        for k in 0..<numCL {
            bw.writeBits(clLengths[clOrder[k]], count: 3)
        }
        bw.writeBits(0, count: 1)

        for t in tokens {
            bw.writeBits(clCodes[t.sym], count: clLengths[t.sym])
            if t.extraBits > 0 {
                bw.writeBits(t.extra, count: t.extraBits)
            }
        }
        return PrefixCode(lengths: lengths, codes: codes, singleSymbol: nil)
    }

    private static func prefixEncodeValue(_ val: Int) -> (sym: Int, extraBits: Int, extraVal: Int) {
        let v = val - 1
        if v < 4 {
            return (v, 0, 0)
        }
        let highestBit = Int.bitWidth - 1 - v.leadingZeroBitCount
        let extraBits = highestBit - 1
        let secondBit = (v >> extraBits) & 1
        let sym = 2 + (2 * extraBits) + secondBit
        let extraVal = v & ((1 << extraBits) - 1)
        return (sym, extraBits, extraVal)
    }

    public static func encode(_ buffer: PixelBufferRGBA) -> Data {
        let width = buffer.width
        let height = buffer.height
        let rgba = buffer.rgba
        let count = width * height

        var argb = Array(repeating: UInt32(0), count: count)
        var hasAlpha = false
        rgba.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            for idx in 0..<count {
                let r = base[idx * 4]
                let g = base[idx * 4 + 1]
                let b = base[idx * 4 + 2]
                let a = base[idx * 4 + 3]
                if a != 255 { hasAlpha = true }
                let rSub = r &- g
                let bSub = b &- g
                argb[idx] = (UInt32(a) << 24) | (UInt32(rSub) << 16) | (UInt32(g) << 8) | UInt32(bSub)
            }
        }

        enum Op {
            case literal(UInt32)
            case copy(length: Int, distCode: Int)
        }
        var ops: [Op] = []
        ops.reserveCapacity(count / 2)

        let hashBits = 14
        var hashTable = Array(repeating: -1, count: 1 << hashBits)
        @inline(__always)
        func hashPixel(_ p: UInt32) -> Int {
            Int((p &* 0x1e35a7bd) >> (32 - hashBits))
        }

        var pos = 0
        while pos < count {
            let p = argb[pos]
            var bestLen = 0
            var bestDistCode = 0

            if pos >= 1 && argb[pos - 1] == p {
                var l = 1
                let limit = min(4096, count - pos)
                while l < limit && argb[pos + l] == argb[pos - 1 + l] { l += 1 }
                if l > bestLen { bestLen = l; bestDistCode = 2 }
            }
            if pos >= width && argb[pos - width] == p {
                var l = 1
                let limit = min(4096, count - pos)
                while l < limit && argb[pos + l] == argb[pos - width + l] { l += 1 }
                if l > bestLen { bestLen = l; bestDistCode = 1 }
            }

            let h = hashPixel(p)
            let prev = hashTable[h]
            hashTable[h] = pos
            if prev >= 0 && pos - prev <= 65536 && pos - prev != 1 && pos - prev != width && argb[prev] == p {
                var l = 1
                let limit = min(4096, count - pos)
                while l < limit && argb[pos + l] == argb[prev + l] { l += 1 }
                if l > bestLen && l >= 3 {
                    bestLen = l
                    bestDistCode = (pos - prev) + 120
                }
            }

            if bestLen >= 2 {
                ops.append(.copy(length: bestLen, distCode: bestDistCode))
                let recordSteps = min(bestLen, 32)
                for step in 1..<recordSteps {
                    hashTable[hashPixel(argb[pos + step])] = pos + step
                }
                pos += bestLen
            } else {
                ops.append(.literal(p))
                pos += 1
            }
        }

        var gFreq = Array(repeating: 0, count: 280)
        var rFreq = Array(repeating: 0, count: 256)
        var bFreq = Array(repeating: 0, count: 256)
        var aFreq = Array(repeating: 0, count: 256)
        var dFreq = Array(repeating: 0, count: 40)

        for op in ops {
            switch op {
            case .literal(let px):
                gFreq[Int((px >> 8) & 0xFF)] += 1
                rFreq[Int((px >> 16) & 0xFF)] += 1
                bFreq[Int(px & 0xFF)] += 1
                aFreq[Int((px >> 24) & 0xFF)] += 1
            case .copy(let length, let distCode):
                gFreq[256 + prefixEncodeValue(length).sym] += 1
                dFreq[prefixEncodeValue(distCode).sym] += 1
            }
        }

        var bw = BitWriter()
        bw.writeBits(0x2F, count: 8)
        bw.writeBits(width - 1, count: 14)
        bw.writeBits(height - 1, count: 14)
        bw.writeBits(hasAlpha ? 1 : 0, count: 1)
        bw.writeBits(0, count: 3)

        bw.writeBits(1, count: 1)
        bw.writeBits(2, count: 2)
        bw.writeBits(0, count: 1)

        bw.writeBits(0, count: 1)
        bw.writeBits(0, count: 1)

        let gTree = writePrefixTree(gFreq, bw: &bw)
        let rTree = writePrefixTree(rFreq, bw: &bw)
        let bTree = writePrefixTree(bFreq, bw: &bw)
        let aTree = writePrefixTree(aFreq, bw: &bw)
        let dTree = writePrefixTree(dFreq, bw: &bw)

        @inline(__always)
        func emit(_ sym: Int, _ tree: PrefixCode) {
            if tree.singleSymbol != nil { return }
            bw.writeBits(tree.codes[sym], count: tree.lengths[sym])
        }

        for op in ops {
            switch op {
            case .literal(let px):
                emit(Int((px >> 8) & 0xFF), gTree)
                emit(Int((px >> 16) & 0xFF), rTree)
                emit(Int(px & 0xFF), bTree)
                emit(Int((px >> 24) & 0xFF), aTree)
            case .copy(let length, let distCode):
                let lenEnc = prefixEncodeValue(length)
                emit(256 + lenEnc.sym, gTree)
                if lenEnc.extraBits > 0 { bw.writeBits(lenEnc.extraVal, count: lenEnc.extraBits) }
                let distEnc = prefixEncodeValue(distCode)
                emit(distEnc.sym, dTree)
                if distEnc.extraBits > 0 { bw.writeBits(distEnc.extraVal, count: distEnc.extraBits) }
            }
        }

        let vp8l = bw.finish()
        let vp8lLen = UInt32(vp8l.count)
        let paddedLen = vp8lLen + (vp8lLen & 1)
        let riffLen = 4 + 8 + paddedLen

        var out = Data()
        out.reserveCapacity(Int(8 + riffLen))
        out.append(contentsOf: [0x52, 0x49, 0x46, 0x46])
        withUnsafeBytes(of: riffLen.littleEndian) { out.append(contentsOf: $0) }
        out.append(contentsOf: [0x57, 0x45, 0x42, 0x50])
        out.append(contentsOf: [0x56, 0x50, 0x38, 0x4C])
        withUnsafeBytes(of: vp8lLen.littleEndian) { out.append(contentsOf: $0) }
        out.append(contentsOf: vp8l)
        if (vp8lLen & 1) == 1 { out.append(0) }
        return out
    }
}
