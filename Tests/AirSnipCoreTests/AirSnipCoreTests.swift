import XCTest
import AppKit
import Carbon
import CoreGraphics
import ImageIO
@testable import AirSnipCore

final class AirSnipCoreTests: XCTestCase {

    func testHSVColorRoundtripAndPrimaries() {
        XCTAssertEqual(ColorPalette.hsvToRGB(h: 0, s: 1, v: 1), RGBAColor(r: 255, g: 0, b: 0))
        XCTAssertEqual(ColorPalette.hsvToRGB(h: 120, s: 1, v: 1), RGBAColor(r: 0, g: 255, b: 0))
        XCTAssertEqual(ColorPalette.hsvToRGB(h: 240, s: 1, v: 1), RGBAColor(r: 0, g: 0, b: 255))
        XCTAssertEqual(ColorPalette.hsvToRGB(h: 0, s: 0, v: 1), RGBAColor(r: 255, g: 255, b: 255))
        XCTAssertEqual(ColorPalette.hsvToRGB(h: 0, s: 1, v: 0), RGBAColor(r: 0, g: 0, b: 0))

        for swatch in ColorPalette.defaultSwatches {
            let hsv = ColorPalette.rgbToHSV(swatch)
            let back = ColorPalette.hsvToRGB(h: hsv.h, s: hsv.s, v: hsv.v)
            XCTAssertLessThanOrEqual(abs(Int(back.r) - Int(swatch.r)), 1)
            XCTAssertLessThanOrEqual(abs(Int(back.g) - Int(swatch.g)), 1)
            XCTAssertLessThanOrEqual(abs(Int(back.b) - Int(swatch.b)), 1)
        }
    }

    func testToolbar24SlotsVisibilityAndSettleFallback() {
        let all = ToolbarSlot.allOrdered
        XCTAssertEqual(all.count, 24)
        XCTAssertEqual(Set(all.map(\.key)).count, 24)
        XCTAssertEqual(Set(all.map(\.label)).count, 24)

        var vis = ToolbarVisibilityConfig()
        for g in ToolbarGroup.allCases {
            XCTAssertEqual(vis.groupState(g), .all)
        }

        vis.setVisible(.ocr, false)
        vis.setVisible(.ocr, false)
        XCTAssertEqual(vis.hidden.count, 1)
        XCTAssertEqual(vis.groupState(.output), .partial)

        vis.setVisible(.tool(.rect), false)
        vis.setVisible(.tool(.arrow), false)
        XCTAssertEqual(vis.settleTool(.rect), .text)

        vis.setGroupVisible(.tools, false)
        XCTAssertEqual(vis.groupState(.tools), .none)
        // When all tools are hidden, settle preserves requested tool so keyboard shortcuts still work
        XCTAssertEqual(vis.settleTool(.rect), .rect)

        vis.setVisible(.color(1), false)
        XCTAssertEqual(vis.settleColorIndex(1), 0)
    }

    func testHotkeyConflictDetectionAndUnbound() {
        var cfg = AirSnipConfig()
        XCTAssertTrue(cfg.hotkeyConflicts().isEmpty)

        // Duplicate global hotkeys trigger conflict
        cfg.hotkeys.pin = cfg.hotkeys.screenshot
        XCTAssertEqual(cfg.hotkeyConflicts().count, 1)

        // Unbound never conflicts
        cfg.hotkeys.pin = .unbound
        cfg.hotkeys.screenshot = .unbound
        XCTAssertTrue(cfg.hotkeyConflicts().isEmpty)
    }

    func testAnnotationDocumentUndoRedoDeleteCurveAndCorner() {
        let doc = AnnotationDocument()
        let style = AnnotationStyle(color: ColorPalette.defaultSwatches[1], lineWidth: 4)

        let r1 = AnnotationObject(style: style, kind: .rect(a: ASPoint(10, 10), b: ASPoint(110, 90), cornerRadius: 0, filled: false))
        doc.add(r1)
        XCTAssertEqual(doc.objects.count, 1)
        XCTAssertEqual(doc.selectedID, r1.id)

        // Corner radius clamping
        doc.updateObject(id: r1.id, recordUndo: true) { obj in
            obj.setCornerRadius(999)
        }
        XCTAssertEqual(doc.selectedObject?.cornerRadius, 40.0) // min(100, 80) / 2 = 40

        // Arrow curve control point & double-click reset to straight
        let a1 = AnnotationObject(style: style, kind: .straightArrow(from: ASPoint(0, 0), to: ASPoint(90, 0)))
        doc.add(a1)
        doc.updateObject(id: a1.id, recordUndo: true) { obj in
            obj.setCurveControlPoint(index: 0, to: ASPoint(30, 45))
        }
        XCTAssertEqual(doc.selectedObject?.curveControlPoints?.c1, ASPoint(30, 45))
        doc.updateObject(id: a1.id, recordUndo: true) { obj in
            XCTAssertTrue(obj.resetCurveToStraight())
            XCTAssertFalse(obj.resetCurveToStraight())
        }

        // Delete selected only removes `a1`, keeping `r1`, and 1 undo restores `a1`!
        XCTAssertTrue(doc.deleteSelected())
        XCTAssertEqual(doc.objects.count, 1)
        XCTAssertEqual(doc.objects.first?.id, r1.id)

        XCTAssertTrue(doc.undo())
        XCTAssertEqual(doc.objects.count, 2)
        XCTAssertTrue(doc.redo())
        XCTAssertEqual(doc.objects.count, 1)

        // Number auto-increment uses max existing + 1
        doc.add(AnnotationObject(style: style, kind: .number(center: ASPoint(20, 20), tip: ASPoint(20, 20), number: 4, fontSize: 20)))
        XCTAssertEqual(doc.nextMarkerNumber(), 5)
    }

    func testLosslessWebPViaImageIORoundtripWithAlphaAndPatterns() throws {
        // Test 1: Solid color (1-symbol simple prefix code)
        let solid = PixelBufferRGBA(width: 48, height: 36, rgba: Array(repeating: 0, count: 48 * 36 * 4).enumerated().map { idx, _ in
            switch idx % 4 {
            case 0: return 30
            case 1: return 136
            case 2: return 229
            default: return 255
            }
        })
        try assertLosslessWebPRoundtrip(solid)

        // Test 2: Translucent gradient + sharp UI borders (Normal prefix codes + LZ77 + Alpha)
        let w = 180, h = 120
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                if y < 20 {
                    rgba[o] = 248; rgba[o+1] = 249; rgba[o+2] = 250; rgba[o+3] = 255
                } else {
                    rgba[o] = UInt8((x * 3 + y) & 0xFF)
                    rgba[o+1] = UInt8((y * 5) & 0xFF)
                    rgba[o+2] = UInt8(((x ^ y) * 7) & 0xFF)
                    rgba[o+3] = (x > 40 && x < 80) ? 180 : 255
                }
            }
        }
        try assertLosslessWebPRoundtrip(PixelBufferRGBA(width: w, height: h, rgba: rgba))
    }

    private func assertLosslessWebPRoundtrip(_ original: PixelBufferRGBA) throws {
        let webpData = VP8LLosslessEncoder.encode(original)
        guard let src = CGImageSourceCreateWithData(webpData as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let decoded = PixelBufferRGBA(cgImage: cg) else {
            XCTFail("ImageIO failed to decode VP8L output")
            return
        }
        XCTAssertEqual(decoded.width, original.width)
        XCTAssertEqual(decoded.height, original.height)
        for i in 0..<original.rgba.count {
            // Allow <=1 quantization on unpremultiply only when alpha < 255; exact 0 diff when opaque
            let alpha = original.rgba[(i / 4) * 4 + 3]
            let tol = alpha == 255 ? 0 : 1
            if abs(Int(decoded.rgba[i]) - Int(original.rgba[i])) > tol {
                XCTFail("Byte mismatch at \(i): expected \(original.rgba[i]), got \(decoded.rgba[i]) (alpha=\(alpha))")
                return
            }
        }
    }

    func testLongshotDownwardUpwardFixedHeaderFooterAndUndo() {
        let w = 64
        let totalContent = 200
        var content = [UInt8](repeating: 255, count: w * totalContent * 4)
        for y in 0..<totalContent {
            for x in 0..<w {
                let o = (y * w + x) * 4
                content[o] = UInt8((y * 3) & 0xFF)
                content[o+1] = UInt8((x * 7 + y) & 0xFF)
                content[o+2] = UInt8((y * 13) & 0xFF)
                content[o+3] = 255
            }
        }

        func frameAt(yOffset: Int) -> PixelBufferRGBA {
            let fh = 60
            var buf = [UInt8](repeating: 255, count: w * fh * 4)
            for y in 0..<fh {
                for x in 0..<w {
                    let d = (y * w + x) * 4
                    if y < 10 {
                        buf[d] = 12; buf[d+1] = 34; buf[d+2] = UInt8(x * 2); buf[d+3] = 255
                    } else if y >= 50 {
                        buf[d] = 56; buf[d+1] = 78; buf[d+2] = UInt8(x * 2); buf[d+3] = 255
                    } else {
                        let sy = yOffset + (y - 10)
                        let s = (sy * w + x) * 4
                        buf[d] = content[s]; buf[d+1] = content[s+1]; buf[d+2] = content[s+2]; buf[d+3] = 255
                    }
                }
            }
            return PixelBufferRGBA(width: w, height: fh, rgba: buf)
        }

        // Downward scroll with fixed header (10) & footer (10)
        let downCanvas = LongshotCanvas(width: w, frameHeight: 60)
        downCanvas.seed(frameAt(yOffset: 0))
        XCTAssertEqual(downCanvas.push(frameAt(yOffset: 0)), .still)
        XCTAssertEqual(downCanvas.push(frameAt(yOffset: 12)), .appended(offset: 12, rows: 12))
        XCTAssertEqual(downCanvas.push(frameAt(yOffset: 26)), .appended(offset: 14, rows: 14))
        XCTAssertEqual(downCanvas.headerHeight, 10)
        XCTAssertEqual(downCanvas.footerHeight, 10)
        XCTAssertEqual(downCanvas.totalHeight, 10 + (40 + 12 + 14) + 10)

        // Undo last segment removes 14 rows
        XCTAssertTrue(downCanvas.undoLast())
        XCTAssertEqual(downCanvas.totalHeight, 10 + (40 + 12) + 10)
        XCTAssertNotNil(downCanvas.makeThumbnail(maxWidth: 80, maxHeight: 200))

        // Upward scroll (e.g., scrolling chat history upwards)
        let upCanvas = LongshotCanvas(width: w, frameHeight: 60)
        upCanvas.seed(frameAt(yOffset: 50))
        XCTAssertEqual(upCanvas.push(frameAt(yOffset: 36)), .appended(offset: -14, rows: 14))
        XCTAssertEqual(upCanvas.totalHeight, 10 + (40 + 14) + 10)
    }

    func testOCRLinesJoinerCJKAndOutOfOrderSorting() {
        XCTAssertEqual(
            OCRLinesJoiner.joinSegments([OCRTextSegment(left: 0, top: 0, bottom: 16, words: ["你", "好", "世界"])]),
            "你好世界"
        )
        XCTAssertEqual(
            OCRLinesJoiner.joinSegments([OCRTextSegment(left: 0, top: 0, bottom: 16, words: ["Hello", "World"])]),
            "Hello World"
        )
        XCTAssertEqual(
            OCRLinesJoiner.joinSegments([OCRTextSegment(left: 0, top: 0, bottom: 16, words: ["使用", "macOS", "15", "系统"])]),
            "使用macOS 15系统"
        )
        // Out-of-order multi-segment visual row sorting
        let segs = [
            OCRTextSegment(left: 26, top: 58, bottom: 74, words: ["第一行"]),
            OCRTextSegment(left: 25, top: 82, bottom: 98, words: ["第二行"]),
            OCRTextSegment(left: 236, top: 58, bottom: 74, words: ["中段"]),
            OCRTextSegment(left: 640, top: 58, bottom: 74, words: ["尾段"]),
        ]
        XCTAssertEqual(OCRLinesJoiner.joinSegments(segs), "第一行中段尾段\n第二行")
        XCTAssertEqual(
            OCRLinesJoiner.joinSegments([OCRTextSegment(left: 0, top: 0, bottom: 16, words: ["讠 兑", "你 好"])]),
            "讠兑你好"
        )
    }

    func testOCRParagraphMergeAndLegacyConfigCompat() throws {
        let wrappedCJK = "这是一段被PDF强制\n折行的中文说明文字\n\n• 第一条特性\n• 第二条特性"
        XCTAssertEqual(
            OCRLinesJoiner.mergeWrappedParagraphs(wrappedCJK),
            "这是一段被PDF强制折行的中文说明文字\n\n• 第一条特性\n\n• 第二条特性"
        )

        let wrappedEnglish = "Offline Vision recog-\nnition runs locally on\nmacOS without cloud."
        XCTAssertEqual(
            OCRLinesJoiner.mergeWrappedParagraphs(wrappedEnglish),
            "Offline Vision recognition runs locally on macOS without cloud."
        )

        // Legacy v0.1.0 OcrConfig & HotkeyConfig without v0.2.0 keys must decode seamlessly
        let legacyOcrJSON = #"{"autoCopy":true,"language":"zh-Hans"}"#.data(using: .utf8)!
        let decodedOcr = try JSONDecoder().decode(OcrConfig.self, from: legacyOcrJSON)
        XCTAssertTrue(decodedOcr.autoCopy)
        XCTAssertEqual(decodedOcr.language, "zh-Hans")
        XCTAssertFalse(decodedOcr.mergeLineBreaks)
        XCTAssertTrue(decodedOcr.detectBarcodes)

        let legacyHotkeyJSON = #"{"screenshot":{"keyCode":122,"modifiers":0}}"#.data(using: .utf8)!
        let decodedHK = try JSONDecoder().decode(HotkeyConfig.self, from: legacyHotkeyJSON)
        XCTAssertEqual(decodedHK.ocrCapture.displayString, "F2")

        // Legacy v0.2.x AirSnipConfig JSON without smartPngCompression must upgrade with smartPngCompression == true!
        let legacyConfigJSON = #"{"autoStart":false,"theme":"follow","windowSnap":true}"#.data(using: .utf8)!
        let decodedCfg = try JSONDecoder().decode(AirSnipConfig.self, from: legacyConfigJSON)
        XCTAssertTrue(decodedCfg.smartPngCompression)
        XCTAssertTrue(decodedCfg.compressClipboardPng)
        XCTAssertEqual(decodedCfg.pngCompressionQuality, .visuallyLossless)
        XCTAssertTrue(decodedCfg.nameStyle.formatBaseName().hasPrefix("isnip-"))
    }

    func testPngSmartCompressorPipelineShrinksAndPreservesValidImage() throws {
        XCTAssertTrue(PngSmartCompressor.hasBundledOrSystemTools)
        let w = 520
        let h = 340
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("Failed to create CGContext")
            return
        }

        // Render a realistic multi-stop macOS wallpaper + anti-aliased translucent UI cards
        let bgColors = [
            CGColor(srgbRed: 0.07, green: 0.19, blue: 0.48, alpha: 1.0),
            CGColor(srgbRed: 0.16, green: 0.48, blue: 0.84, alpha: 1.0),
            CGColor(srgbRed: 0.92, green: 0.56, blue: 0.34, alpha: 1.0),
        ] as CFArray
        if let grad = CGGradient(colorsSpace: cs, colors: bgColors, locations: [0.0, 0.55, 1.0]) {
            ctx.drawLinearGradient(
                grad,
                start: CGPoint(x: 0, y: CGFloat(h)),
                end: CGPoint(x: CGFloat(w), y: 0),
                options: []
            )
        }
        for i in 0..<6 {
            let fi = CGFloat(i)
            ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.99, blue: 1.0, alpha: 0.82 - fi * 0.08))
            let card = CGPath(
                roundedRect: CGRect(x: 36 + fi * 22, y: 28 + fi * 18, width: 260, height: 140),
                cornerWidth: 14,
                cornerHeight: 14,
                transform: nil
            )
            ctx.addPath(card)
            ctx.fillPath()
        }
        guard let cg = ctx.makeImage() else {
            XCTFail("Failed to build realistic screenshot CGImage")
            return
        }

        let report = try ImageEncoder.encodePNGWithReport(
            cg,
            smartCompression: true,
            quality: .visuallyLossless,
            mode: .fullPipeline(oxipngMax: true)
        )
        XCTAssertTrue(report.usedPngquant)
        XCTAssertTrue(report.usedOxipng)
        XCTAssertLessThan(report.compressedBytes, (report.originalBytes * 65) / 100)

        // Two-stage flow (fastQuantizeOnly -> optimizeWithOxipng) used for 0ms clipboard & atomic save
        let rawPng = try ImageEncoder.encode(cg, format: .png, smartPngCompression: false)
        let stage1 = PngSmartCompressor.compress(rawPng, quality: .balanced, mode: .fastQuantizeOnly)
        XCTAssertTrue(stage1.usedPngquant)
        XCTAssertFalse(stage1.usedOxipng)
        let stage2 = PngSmartCompressor.optimizeWithOxipng(
            stage1.data,
            originalBytes: rawPng.count,
            usedPngquant: stage1.usedPngquant,
            oxipngMax: true
        )
        XCTAssertTrue(stage2.usedOxipng)
        XCTAssertLessThanOrEqual(stage2.compressedBytes, stage1.compressedBytes)

        guard let src = CGImageSourceCreateWithData(stage2.data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            XCTFail("Compressed PNG failed ImageIO decode")
            return
        }
        XCTAssertEqual(decoded.width, w)
        XCTAssertEqual(decoded.height, h)
    }

    func testDefaultSilentSaveConfigAndBackwardCompatibility() throws {
        var cfg = AirSnipConfig()
        XCTAssertFalse(cfg.askBeforeSave)
        XCTAssertNil(cfg.lastSaveDirectory)

        // Legacy JSON without askBeforeSave decodes to false (silent save by default)
        let legacyJSON = Data(#"{"lastSaveFormat":"png","smartPngCompression":true}"#.utf8)
        let fromLegacy = try JSONDecoder().decode(AirSnipConfig.self, from: legacyJSON)
        XCTAssertFalse(fromLegacy.askBeforeSave)

        // Explicit toggle persists cleanly
        cfg.askBeforeSave = true
        cfg.lastSaveDirectory = "/tmp/isnip-custom"
        let encoded = try JSONEncoder().encode(cfg)
        let roundtrip = try JSONDecoder().decode(AirSnipConfig.self, from: encoded)
        XCTAssertTrue(roundtrip.askBeforeSave)
        XCTAssertEqual(roundtrip.lastSaveDirectory, "/tmp/isnip-custom")
    }

    func testPureRedThinDefaultMigrationAndFullOptionPersistence() throws {
        let fresh = AirSnipConfig()
        XCTAssertEqual(fresh.swatchColors[1], RGBAColor(r: 255, g: 0, b: 0))
        XCTAssertEqual(fresh.activeColorIndex, 1)
        XCTAssertEqual(fresh.defaultLineWidth, 2.0)
        XCTAssertFalse(fresh.defaultFillEnabled)
        XCTAssertFalse(fresh.defaultFontBold)
        XCTAssertFalse(fresh.defaultFontItalic)
        XCTAssertEqual(fresh.defaultNumberFontSize, 20.0)

        // Legacy v0.3.4 config with old #E53935 (229,57,53) and 4px migrates once to #FF0000 and 2px
        let legacyJSON = Data(#"""
        {
          "defaultLineWidth": 4,
          "swatchColors": [
            {"r":255,"g":255,"b":255,"a":255},
            {"r":229,"g":57,"b":53,"a":255},
            {"r":251,"g":140,"b":0,"a":255},
            {"r":67,"g":160,"b":71,"a":255},
            {"r":30,"g":136,"b":229,"a":255}
          ]
        }
        """#.utf8)
        var migrated = try JSONDecoder().decode(AirSnipConfig.self, from: legacyJSON)
        XCTAssertEqual(migrated.swatchColors[1], RGBAColor(r: 255, g: 0, b: 0))
        XCTAssertEqual(migrated.defaultLineWidth, 2.0)
        XCTAssertTrue(migrated.styleDefaultsMigratedV2)

        // Subsequent user option changes (including choosing 4px medium or fill) persist faithfully
        migrated.defaultLineWidth = 4.0
        migrated.defaultFillEnabled = true
        migrated.defaultBlurRadius = 28.0
        migrated.defaultFontSize = 30.0
        migrated.defaultFontBold = true
        migrated.defaultFontItalic = true
        migrated.defaultNumberFontSize = 26.0
        migrated.activeColorIndex = 4
        let saved = try JSONEncoder().encode(migrated)
        let reloaded = try JSONDecoder().decode(AirSnipConfig.self, from: saved)
        XCTAssertEqual(reloaded.defaultLineWidth, 4.0)
        XCTAssertTrue(reloaded.defaultFillEnabled)
        XCTAssertEqual(reloaded.defaultBlurRadius, 28.0)
        XCTAssertEqual(reloaded.defaultFontSize, 30.0)
        XCTAssertTrue(reloaded.defaultFontBold)
        XCTAssertTrue(reloaded.defaultFontItalic)
        XCTAssertEqual(reloaded.defaultNumberFontSize, 26.0)
        XCTAssertEqual(reloaded.activeColorIndex, 4)
    }

    func testLongshotAutoPagingSparseWebpageScrollbarAndFixedSidebar() {
        // 1. Sparse 90%-white webpage with a moving right-edge macOS scrollbar thumb + bottom detection
        let w = 240
        let fh = 120
        let pageH = 320
        var page = [UInt8](repeating: 255, count: w * pageH * 4)
        // Render sparse dark text paragraphs (only ~12% of rows have text; 88% pure white)
        for block in stride(from: 18, to: pageH - 16, by: 38) {
            for row in 0..<5 {
                let y = block + row
                for x in 24..<(w - 32) {
                    if ((x + block * 7 + row * 13) % 5) != 0 {
                        let o = (y * w + x) * 4
                        page[o] = UInt8((30 + block) & 0xFF)
                        page[o + 1] = UInt8((40 + row * 25) & 0xFF)
                        page[o + 2] = UInt8((60 + (x % 90)) & 0xFF)
                        page[o + 3] = 255
                    }
                }
            }
        }

        func renderWebFrame(scrollY: Int) -> PixelBufferRGBA {
            let clampedY = max(0, min(pageH - fh, scrollY))
            var frame = Array(page[(clampedY * w * 4)..<((clampedY + fh) * w * 4)])
            // Overlay a moving scrollbar thumb on the rightmost 14px (moves opposite to content!)
            let thumbTop = (clampedY * (fh - 34)) / max(1, pageH - fh)
            for y in thumbTop..<(thumbTop + 34) {
                for x in (w - 14)..<(w - 3) {
                    let o = (y * w + x) * 4
                    frame[o] = 120; frame[o + 1] = 124; frame[o + 2] = 130; frame[o + 3] = 255
                }
            }
            return PixelBufferRGBA(width: w, height: fh, rgba: frame)
        }

        let canvas = LongshotCanvas(width: w, frameHeight: fh, params: LongshotParams(minRatio: 0.84, minFixedRows: 8))
        canvas.seed(renderWebFrame(scrollY: 0))
        XCTAssertEqual(canvas.push(renderWebFrame(scrollY: 36)), .appended(offset: 36, rows: 36))
        XCTAssertEqual(canvas.push(renderWebFrame(scrollY: 72)), .appended(offset: 36, rows: 36))
        XCTAssertEqual(canvas.push(renderWebFrame(scrollY: 108)), .appended(offset: 36, rows: 36))
        XCTAssertEqual(canvas.push(renderWebFrame(scrollY: 144)), .appended(offset: 36, rows: 36))
        XCTAssertEqual(canvas.push(renderWebFrame(scrollY: 180)), .appended(offset: 36, rows: 36))
        XCTAssertEqual(canvas.push(renderWebFrame(scrollY: 200)), .appended(offset: 20, rows: 20))
        // Bottom reached -> subsequent auto-scroll ticks yield `.still`
        XCTAssertEqual(canvas.push(renderWebFrame(scrollY: 200)), .still)
        XCTAssertEqual(canvas.push(renderWebFrame(scrollY: 200)), .still)
        XCTAssertEqual(canvas.headerHeight, 0)
        XCTAssertEqual(canvas.footerHeight, 0)
        XCTAssertEqual(canvas.totalHeight, pageH)

        // 2. Webpage with fixed left sidebar (0..<52 static) + scrolling article on right (52..<240)
        func renderSidebarFrame(scrollY: Int) -> PixelBufferRGBA {
            var buf = [UInt8](repeating: 255, count: w * 100 * 4)
            for y in 0..<100 {
                for x in 0..<w {
                    let dst = (y * w + x) * 4
                    if x < 52 {
                        // Static left navigation sidebar with distinct per-row items
                        buf[dst] = UInt8((y * 9) & 0xFF)
                        buf[dst + 1] = UInt8((40 + y * 5) & 0xFF)
                        buf[dst + 2] = 95
                        buf[dst + 3] = 255
                    } else {
                        let sy = scrollY + y
                        buf[dst] = UInt8((sy * 7) & 0xFF)
                        buf[dst + 1] = UInt8((x * 3 + sy * 11) & 0xFF)
                        buf[dst + 2] = UInt8((sy * 17) & 0xFF)
                        buf[dst + 3] = 255
                    }
                }
            }
            return PixelBufferRGBA(width: w, height: 100, rgba: buf)
        }

        let sidebarCanvas = LongshotCanvas(width: w, frameHeight: 100, params: LongshotParams(minRatio: 0.84, minFixedRows: 8))
        sidebarCanvas.seed(renderSidebarFrame(scrollY: 0))
        XCTAssertEqual(sidebarCanvas.push(renderSidebarFrame(scrollY: 28)), .appended(offset: 28, rows: 28))
        XCTAssertEqual(sidebarCanvas.push(renderSidebarFrame(scrollY: 58)), .appended(offset: 30, rows: 30))
        XCTAssertEqual(sidebarCanvas.totalHeight, 158)
    }

    func testLongshotAutoScrollConfigAndConflictFreeMigration() throws {
        let cfg = AirSnipConfig()
        XCTAssertTrue(cfg.longshotAutoScroll)
        XCTAssertEqual(cfg.longshotScrollSpeed, .normal)
        XCTAssertEqual(cfg.hotkeys.longshotCapture, HotkeyBinding(keyCode: kVK_F4, modifiers: []))
        XCTAssertTrue(cfg.hotkeyConflicts().isEmpty)

        // Legacy config where user had already bound F4 to `screenshot` -> `longshotCapture` falls back to `.unbound` cleanly
        let legacyConflictJSON = Data(#"""
        {
          "hotkeys": {
            "screenshot": { "keyCode": 118, "modifiers": 0 }
          }
        }
        """#.utf8)
        let migrated = try JSONDecoder().decode(AirSnipConfig.self, from: legacyConflictJSON)
        XCTAssertEqual(migrated.hotkeys.screenshot.keyCode, kVK_F4)
        XCTAssertTrue(migrated.hotkeys.longshotCapture.isUnbound)
        XCTAssertTrue(migrated.hotkeyConflicts().isEmpty)

        // Persisting auto-scroll speed & toggle
        var custom = AirSnipConfig()
        custom.longshotAutoScroll = false
        custom.longshotScrollSpeed = .fast
        let data = try JSONEncoder().encode(custom)
        let decoded = try JSONDecoder().decode(AirSnipConfig.self, from: data)
        XCTAssertFalse(decoded.longshotAutoScroll)
        XCTAssertEqual(decoded.longshotScrollSpeed, .fast)
    }

    func testWindowSnapZOrderOcclusionPreventsBackgroundSplitThroughMaximizedBrowser() {
        let screen = ASRect(x: 0, y: 0, width: 1470, height: 956)
        // Exact real-world layout: maximized Chrome (1470x841) in front of two 735pt half-screen Terminal windows!
        let floatingWeChat = WindowSnapCandidate.make(
            localRect: ASRect(x: 594, y: 266, width: 280, height: 380),
            screenSize: screen
        )!
        let maximizedChrome = WindowSnapCandidate.make(
            localRect: ASRect(x: 0, y: 33, width: 1470, height: 841),
            screenSize: screen
        )!
        let hiddenLeftHalfTerminal = WindowSnapCandidate.make(
            localRect: ASRect(x: 0, y: 33, width: 735, height: 843),
            screenSize: screen
        )!
        let hiddenRightHalfTerminal = WindowSnapCandidate.make(
            localRect: ASRect(x: 735, y: 33, width: 735, height: 843),
            screenSize: screen
        )!

        XCTAssertFalse(floatingWeChat.isMaximizedLike)
        XCTAssertTrue(maximizedChrome.isMaximizedLike)
        XCTAssertFalse(hiddenLeftHalfTerminal.isMaximizedLike)
        XCTAssertFalse(hiddenRightHalfTerminal.isMaximizedLike)

        // Case 1: Chrome frontmost over two half-screen Terminals
        let chromeInFront = [maximizedChrome, hiddenLeftHalfTerminal, hiddenRightHalfTerminal]
        // In normal screenshot mode (`allowMaximizedSnap: false`), hovering Chrome returns `nil`
        // and NEVER pierces through Chrome to ghost-highlight the hidden 735pt half-screen Terminals!
        XCTAssertNil(WindowSnapResolver.resolve(at: ASPoint(350, 400), candidatesFrontToBack: chromeInFront, allowMaximizedSnap: false))
        XCTAssertNil(WindowSnapResolver.resolve(at: ASPoint(1100, 400), candidatesFrontToBack: chromeInFront, allowMaximizedSnap: false))

        // In Page Longshot mode (`allowMaximizedSnap: true`), hovering Chrome snaps cleanly to the FULL 1470x841 Chrome window!
        XCTAssertEqual(
            WindowSnapResolver.resolve(at: ASPoint(350, 400), candidatesFrontToBack: chromeInFront, allowMaximizedSnap: true),
            ASRect(x: 0, y: 33, width: 1470, height: 841)
        )
        XCTAssertEqual(
            WindowSnapResolver.resolve(at: ASPoint(1100, 400), candidatesFrontToBack: chromeInFront, allowMaximizedSnap: true),
            ASRect(x: 0, y: 33, width: 1470, height: 841)
        )

        // Case 2: Small floating window (WeChat) in front of maximized Chrome -> snaps to WeChat when hovered
        let weChatOverChrome = [floatingWeChat, maximizedChrome, hiddenLeftHalfTerminal, hiddenRightHalfTerminal]
        XCTAssertEqual(
            WindowSnapResolver.resolve(at: ASPoint(650, 350), candidatesFrontToBack: weChatOverChrome, allowMaximizedSnap: false),
            ASRect(x: 594, y: 266, width: 280, height: 380)
        )
        XCTAssertNil(WindowSnapResolver.resolve(at: ASPoint(200, 350), candidatesFrontToBack: weChatOverChrome, allowMaximizedSnap: false))
    }

    func testWindowCaptureOverlappingStackCycleAndDropShadowTransparency() throws {
        let screen = ASRect(x: 0, y: 0, width: 1470, height: 956)
        let topTerminal = WindowSnapCandidate.make(
            windowID: 101,
            localRect: ASRect(x: 0, y: 33, width: 735, height: 843),
            ownerName: "终端",
            title: "zsh",
            screenSize: screen
        )!
        let midCloudDesk = WindowSnapCandidate.make(
            windowID: 202,
            localRect: ASRect(x: 95, y: 53, width: 1280, height: 763),
            ownerName: "CloudDesk",
            title: "Workspace",
            screenSize: screen
        )!
        let backChrome = WindowSnapCandidate.make(
            windowID: 303,
            localRect: ASRect(x: 0, y: 33, width: 1470, height: 841),
            ownerName: "Google Chrome",
            title: "GitHub",
            screenSize: screen
        )!
        let stack = [topTerminal, midCloudDesk, backChrome]
        let pt = ASPoint(300, 300)

        let hits = WindowSnapResolver.candidatesContaining(at: pt, candidatesFrontToBack: stack, allowMaximizedSnap: true)
        XCTAssertEqual(hits.map(\.windowID), [101, 202, 303])
        XCTAssertEqual(WindowSnapResolver.resolveCandidate(at: pt, candidatesFrontToBack: stack, allowMaximizedSnap: true, depthIndex: 0)?.windowID, 101)
        XCTAssertEqual(WindowSnapResolver.resolveCandidate(at: pt, candidatesFrontToBack: stack, allowMaximizedSnap: true, depthIndex: 1)?.windowID, 202)
        XCTAssertEqual(WindowSnapResolver.resolveCandidate(at: pt, candidatesFrontToBack: stack, allowMaximizedSnap: true, depthIndex: 2)?.windowID, 303)
        XCTAssertEqual(WindowSnapResolver.resolveCandidate(at: pt, candidatesFrontToBack: stack, allowMaximizedSnap: true, depthIndex: 3)?.windowID, 101)

        // Verify HotkeyConfig F5 default + legacy conflict avoidance
        let defaultCfg = AirSnipConfig()
        XCTAssertEqual(defaultCfg.hotkeys.windowCapture, HotkeyBinding(keyCode: kVK_F5, modifiers: []))
        XCTAssertTrue(defaultCfg.windowCaptureShadow)
        XCTAssertTrue(defaultCfg.hotkeyConflicts().isEmpty)

        let f5OccupiedJSON = Data(#"""
        {
          "hotkeys": {
            "pin": { "keyCode": 96, "modifiers": 0 }
          }
        }
        """#.utf8)
        let migrated = try JSONDecoder().decode(AirSnipConfig.self, from: f5OccupiedJSON)
        XCTAssertEqual(migrated.hotkeys.pin.keyCode, kVK_F5)
        XCTAssertTrue(migrated.hotkeys.windowCapture.isUnbound)
        XCTAssertTrue(migrated.hotkeyConflicts().isEmpty)

        // Verify Window Drop Shadow preserves transparent rounded corners & 1:1 unscaled center pixels
        let w = 240, h = 160
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: 20, cornerHeight: 20, transform: nil))
        ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.52, blue: 0.96, alpha: 1.0))
        ctx.fillPath()
        let winImg = try XCTUnwrap(ctx.makeImage())
        let shadowed = try XCTUnwrap(AnnotationRenderer.applyWindowDropShadow(to: winImg, scale: 2.0))
        XCTAssertEqual(shadowed.width, w + 136)
        XCTAssertEqual(shadowed.height, h + 136)
        let shadowedBuf = try XCTUnwrap(PixelBufferRGBA(cgImage: shadowed))
        XCTAssertEqual(shadowedBuf.pixel(x: 0, y: 0).a, 0)
        XCTAssertEqual(shadowedBuf.pixel(x: shadowed.width / 2, y: shadowed.height / 2).a, 255)
        let shadowSample = shadowedBuf.pixel(x: shadowed.width / 2, y: 44 + h + 12)
        XCTAssertGreaterThan(shadowSample.a, 0)
        XCTAssertLessThan(shadowSample.a, 255)
    }

    func testLongshotInfiniteScrollDynamicContentRefreshAndTransientFailureRecovery() throws {
        let width = 180
        let frameH = 120
        let totalDocH = 360

        // Build a richly textured synthetic document (`y = 0..<360`)
        var doc = [UInt8](repeating: 255, count: width * totalDocH * 4)
        for y in 0..<totalDocH {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let band = (y / 7)
                doc[o] = UInt8((band * 37 + x * 3) & 0xFF)
                doc[o + 1] = UInt8((band * 73 + y * 5) & 0xFF)
                doc[o + 2] = UInt8((band * 19 + (x ^ y)) & 0xFF)
                doc[o + 3] = 255
            }
        }

        func sliceFrame(scrollY: Int, skeletonBottomRows: Int = 0) -> PixelBufferRGBA {
            var rgba = Array(doc[(scrollY * width * 4)..<((scrollY + frameH) * width * 4)])
            if skeletonBottomRows > 0 {
                // Simulate an infinite-scroll "Loading..." placeholder at the bottom of the viewport before new items appear
                let startY = max(0, frameH - skeletonBottomRows)
                for y in startY..<frameH {
                    for x in 0..<width {
                        let o = (y * width + x) * 4
                        rgba[o] = 230
                        rgba[o + 1] = 232
                        rgba[o + 2] = 236
                        rgba[o + 3] = 255
                    }
                }
            }
            return PixelBufferRGBA(width: width, height: frameH, rgba: rgba)
        }

        let canvas = LongshotCanvas(
            width: width,
            frameHeight: frameH,
            params: LongshotParams(minRatio: 0.84, minFixedRows: 8),
            maxHeight: 30000
        )

        // 1. Seed initial viewport (`scrollY = 0`), then scroll to `scrollY = 30` where bottom 34 rows still show a loading skeleton!
        canvas.seed(sliceFrame(scrollY: 0))
        let r1 = canvas.push(sliceFrame(scrollY: 30, skeletonBottomRows: 34))
        XCTAssertEqual(r1, .appended(offset: 30, rows: 30))
        XCTAssertEqual(canvas.totalHeight, 150)

        // 2. Transient mid-reflow frame (garbage noise) MUST NOT clobber `prevFrame`!
        let transientNoise = PixelBufferRGBA(width: width, height: frameH, rgba: [UInt8](repeating: 128, count: width * frameH * 4))
        XCTAssertEqual(canvas.push(transientNoise), .failed)

        // 3. Next frame settles at `scrollY = 66` WITH the newly loaded real content replacing the 34-row skeleton!
        //    Upper anchored band locks exact `offset = 36`, refreshes the skeleton rows in-place, and appends the new 36 rows!
        let r2 = canvas.push(sliceFrame(scrollY: 66, skeletonBottomRows: 0))
        XCTAssertEqual(r2, .appended(offset: 36, rows: 36))
        XCTAssertEqual(canvas.totalHeight, 186)

        let exported = try XCTUnwrap(canvas.exportBuffer())
        XCTAssertEqual(exported.height, 186)
        // Verify that row 130 (which used to be grey `230,232,236` skeleton at `scrollY=30`) was refreshed to true document pixels!
        let refreshedPx = exported.pixel(x: 90, y: 130)
        let expectedDocOffset = (130 * width + 90) * 4
        XCTAssertEqual(refreshedPx.r, doc[expectedDocOffset])
        XCTAssertEqual(refreshedPx.g, doc[expectedDocOffset + 1])
        XCTAssertEqual(refreshedPx.b, doc[expectedDocOffset + 2])

        // 4. Full-page stepping (`~80%-85%` of scrollable screen per jump with fixed top browser bar & bottom bar)
        XCTAssertGreaterThanOrEqual(LongshotScrollSpeed.normal.viewportStepFraction, 0.75)
        XCTAssertGreaterThanOrEqual(LongshotScrollSpeed.fast.viewportStepFraction, 0.84)

        let fullW = 200
        let fullFrameH = 240 // 30px fixed top bar + 190px scrollable body + 20px fixed bottom bar
        let fullDocH = 900
        var fullDoc = [UInt8](repeating: 255, count: fullW * fullDocH * 4)
        for y in 0..<fullDocH {
            for x in 0..<fullW {
                let o = (y * fullW + x) * 4
                fullDoc[o] = UInt8(((y / 5) * 41 + x * 3) & 0xFF)
                fullDoc[o + 1] = UInt8(((y / 5) * 83 + y * 7) & 0xFF)
                fullDoc[o + 2] = UInt8(((y / 5) * 29 + (x ^ y)) & 0xFF)
                fullDoc[o + 3] = 255
            }
        }
        func renderFullPageStep(scrollY: Int) -> PixelBufferRGBA {
            var rgba = [UInt8](repeating: 255, count: fullW * fullFrameH * 4)
            for y in 0..<fullFrameH {
                for x in 0..<fullW {
                    let dst = (y * fullW + x) * 4
                    if y < 30 {
                        rgba[dst] = 35; rgba[dst + 1] = UInt8(60 + x / 2); rgba[dst + 2] = 120; rgba[dst + 3] = 255
                    } else if y >= 220 {
                        rgba[dst] = 95; rgba[dst + 1] = 45; rgba[dst + 2] = UInt8(50 + x / 2); rgba[dst + 3] = 255
                    } else {
                        let src = ((scrollY + (y - 30)) * fullW + x) * 4
                        rgba[dst] = fullDoc[src]; rgba[dst + 1] = fullDoc[src + 1]; rgba[dst + 2] = fullDoc[src + 2]; rgba[dst + 3] = 255
                    }
                }
            }
            return PixelBufferRGBA(width: fullW, height: fullFrameH, rgba: rgba)
        }

        let pageCanvas = LongshotCanvas(width: fullW, frameHeight: fullFrameH, params: LongshotParams(minRatio: 0.84, minFixedRows: 8))
        pageCanvas.seed(renderFullPageStep(scrollY: 0))
        // Step 1: ~75% of body (`142` rows out of `190`), Step 2 & 3: `84%` of body (`160` rows out of `190` — nearly 1 full screen per jump!)
        XCTAssertEqual(pageCanvas.push(renderFullPageStep(scrollY: 142)), .appended(offset: 142, rows: 142))
        XCTAssertEqual(pageCanvas.headerHeight, 30)
        XCTAssertEqual(pageCanvas.footerHeight, 20)
        XCTAssertEqual(pageCanvas.push(renderFullPageStep(scrollY: 302)), .appended(offset: 160, rows: 160))
        XCTAssertEqual(pageCanvas.push(renderFullPageStep(scrollY: 462)), .appended(offset: 160, rows: 160))
        XCTAssertEqual(pageCanvas.totalHeight, 30 + (190 + 142 + 160 + 160) + 20)
    }

    func testLongshotRealBrowserStickyHeaderSubpixelNoiseSidebarAndNoDuplicateDump() throws {
        let w = 640
        let fh = 440
        let docH = 1400
        let sidebarW = 120

        // Build realistic forum topic list (`y = 0..<1400`) on white background with dark text rows & divider lines
        var doc = [UInt8](repeating: 255, count: w * docH * 4)
        for topicIdx in 0..<(docH / 44) {
            let baseY = topicIdx * 44
            // 1px topic divider line
            let divY = baseY + 43
            if divY < docH {
                for x in (sidebarW + 16)..<(w - 28) {
                    let o = (divY * w + x) * 4
                    doc[o] = 232; doc[o + 1] = 235; doc[o + 2] = 240; doc[o + 3] = 255
                }
            }
            // Topic title + tag badges (`8` text rows)
            for ty in 10..<20 {
                let y = baseY + ty
                guard y < docH else { continue }
                let titleEnd = sidebarW + 140 + ((topicIdx * 79) % 260)
                for x in (sidebarW + 20)..<min(w - 90, titleEnd) {
                    if ((x * 5 + topicIdx * 13 + ty * 7) % 4) != 0 {
                        let o = (y * w + x) * 4
                        doc[o] = UInt8(28 + (topicIdx * 17) % 70)
                        doc[o + 1] = UInt8(34 + (ty * 9) % 60)
                        doc[o + 2] = UInt8(45 + (x * 3 + topicIdx * 23) % 90)
                        doc[o + 3] = 255
                    }
                }
            }
        }

        func renderBrowserFrame(scrollY: Int, stepIdx: Int) -> PixelBufferRGBA {
            var rgba = [UInt8](repeating: 255, count: w * fh * 4)
            for y in 0..<fh {
                for x in 0..<w {
                    let dst = (y * w + x) * 4
                    // Deterministic ±2 RGB subpixel compositor noise crossing `& 0xFC` bucket boundaries (127<->128, 251<->252)
                    let jitter = ((x * 17 + y * 31 + stepIdx * 13) % 5) - 2
                    func clamp(_ v: Int) -> UInt8 { UInt8(max(0, min(255, v + jitter))) }

                    if y < 22 {
                        // Browser tab bar with animated tab favicon/title changing every frame!
                        rgba[dst] = UInt8((190 + stepIdx * 19 + x / 8) & 0xFF)
                        rgba[dst + 1] = UInt8((210 + stepIdx * 11) & 0xFF)
                        rgba[dst + 2] = 248
                        rgba[dst + 3] = 255
                    } else if y < 64 {
                        // Opaque browser URL & bookmarks bar (`127`/`251` values right on old `& 0xFC` hash boundary!)
                        rgba[dst] = clamp(x % 29 == 0 ? 127 : 237)
                        rgba[dst + 1] = clamp(242)
                        rgba[dst + 2] = clamp(251)
                        rgba[dst + 3] = 255
                    } else if y < 94 {
                        // Translucent `backdrop-filter: blur` sticky site header (background tint shifts slightly per step!)
                        let blurShift = (stepIdx * 3) % 7
                        if x > 40 && x < 170 && y >= 72 && y < 86 {
                            rgba[dst] = clamp(32); rgba[dst + 1] = clamp(36); rgba[dst + 2] = clamp(42)
                        } else {
                            rgba[dst] = clamp(249 - blurShift)
                            rgba[dst + 1] = clamp(250 - blurShift / 2)
                            rgba[dst + 2] = clamp(252)
                        }
                        rgba[dst + 3] = 255
                    } else if y < 96 {
                        // Crisp 2px bottom border of sticky site header (`headerHeight == 96`)
                        rgba[dst] = clamp(218); rgba[dst + 1] = clamp(222); rgba[dst + 2] = clamp(228); rgba[dst + 3] = 255
                    } else {
                        // Body region (`y = 96..<440`)
                        if x < sidebarW {
                            // Fixed left navigation sidebar: clean gap rows + stationary menu items + 1px divider at `sidebarW - 1`
                            if x == sidebarW - 1 {
                                rgba[dst] = 228; rgba[dst + 1] = 231; rgba[dst + 2] = 236; rgba[dst + 3] = 255
                            } else if y >= 112 && y < 136 && x >= 12 && x < sidebarW - 12 {
                                // Stationary active pill highlight in sidebar
                                rgba[dst] = 224; rgba[dst + 1] = 238; rgba[dst + 2] = 254; rgba[dst + 3] = 255
                            } else if (y >= 160 && y < 340) && ((y - 160) % 28 < 8) && x >= 18 && x < sidebarW - 24 && ((x + y) % 3 == 0) {
                                // Stationary sidebar menu text
                                rgba[dst] = 60; rgba[dst + 1] = 68; rgba[dst + 2] = 80; rgba[dst + 3] = 255
                            } else {
                                rgba[dst] = 255; rgba[dst + 1] = 255; rgba[dst + 2] = 255; rgba[dst + 3] = 255
                            }
                        } else {
                            let srcY = min(docH - 1, scrollY + (y - 96))
                            let src = (srcY * w + x) * 4
                            // Animated user avatar changing in a narrow column (`x = 520..<534`)
                            if x >= 520 && x < 534 && (srcY % 44 >= 12 && srcY % 44 < 24) {
                                rgba[dst] = UInt8((stepIdx * 53 + x * 7) & 0xFF)
                                rgba[dst + 1] = UInt8((stepIdx * 97 + y * 3) & 0xFF)
                                rgba[dst + 2] = 180
                                rgba[dst + 3] = 255
                            } else {
                                rgba[dst] = clamp(Int(doc[src]))
                                rgba[dst + 1] = clamp(Int(doc[src + 1]))
                                rgba[dst + 2] = clamp(Int(doc[src + 2]))
                                rgba[dst + 3] = 255
                            }
                        }

                        // Stationary dark wallpaper outside rounded bottom-left & bottom-right window corners (`y >= 418`)
                        if y >= 418 && (x < 5 || x >= w - 5) {
                            rgba[dst] = 24; rgba[dst + 1] = 26; rgba[dst + 2] = 32; rgba[dst + 3] = 255
                        }
                    }
                }
            }
            return PixelBufferRGBA(width: w, height: fh, rgba: rgba)
        }

        let canvas = LongshotCanvas(width: w, frameHeight: fh, params: LongshotParams(minRatio: 0.84, minFixedRows: 8), maxHeight: 30000)
        canvas.seed(renderBrowserFrame(scrollY: 0, stepIdx: 0))

        // Step 1: scroll 210px -> atomically locks exact `headerHeight == 96` and rounded corner cap!
        XCTAssertEqual(canvas.push(renderBrowserFrame(scrollY: 210, stepIdx: 1)), .appended(offset: 210, rows: 210))
        XCTAssertEqual(canvas.headerHeight, 96)
        XCTAssertGreaterThanOrEqual(canvas.footerHeight, 22)

        // 5 consecutive unaligned garbage frames MUST return `.failed` and NEVER stack full browser windows onto the canvas!
        let heightBeforeGarbage = canvas.totalHeight
        let garbage = PixelBufferRGBA(width: w, height: fh, rgba: [UInt8](repeating: 80, count: w * fh * 4))
        for _ in 0..<5 {
            XCTAssertEqual(canvas.push(garbage), .failed)
        }
        XCTAssertEqual(canvas.totalHeight, heightBeforeGarbage)

        // Step 2 & Step 3: ~80% full-screen jumps (`256px` out of `320px` scrollable body!) stitch seamlessly!
        XCTAssertEqual(canvas.push(renderBrowserFrame(scrollY: 466, stepIdx: 2)), .appended(offset: 256, rows: 256))
        XCTAssertEqual(canvas.push(renderBrowserFrame(scrollY: 722, stepIdx: 3)), .appended(offset: 256, rows: 256))
        XCTAssertEqual(canvas.totalHeight, fh + 210 + 256 + 256)

        let out = try XCTUnwrap(canvas.exportBuffer())
        XCTAssertEqual(out.height, fh + 210 + 256 + 256)
        // Verify intermediate seam rows (`y = 520`) do NOT have dark `(24,26,32)` rounded-corner notches at `x = 2`!
        XCTAssertGreaterThan(out.pixel(x: 2, y: 520).r, 200)
    }

    func testRetinaDPIMetadataPreservesOneToOneDisplayScaleAcrossAllFormatsAndSmartCompression() throws {
        let pxW = 420
        let pxH = 180
        var rgba = [UInt8](repeating: 255, count: pxW * pxH * 4)
        for y in 0..<pxH {
            for x in 0..<pxW {
                let i = (y * pxW + x) * 4
                rgba[i] = UInt8((x * 3 + y) & 0xFF)
                rgba[i + 1] = UInt8((120 + y) & 0xFF)
                rgba[i + 2] = UInt8((200 - (x / 3)) & 0xFF)
                rgba[i + 3] = (x < 8 && y < 8) ? 0 : 255
            }
        }
        let buf = PixelBufferRGBA(width: pxW, height: pxH, rgba: rgba)
        let cg = try XCTUnwrap(buf.makeCGImage())

        func readDPIAndPointSize(_ data: Data) throws -> (dpiW: Double, dpiH: Double, ptSize: NSSize) {
            let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
            let dpiW = try XCTUnwrap(props[kCGImagePropertyDPIWidth] as? Double)
            let dpiH = try XCTUnwrap(props[kCGImagePropertyDPIHeight] as? Double)
            let nsImg = try XCTUnwrap(NSImage(data: data))
            return (dpiW, dpiH, nsImg.size)
        }

        // 2x Retina (`144 DPI`, `pHYs = 5669` ppm): opening in Preview / NSImage MUST yield `210 x 90 pt` (1:1 Retina, never 2x enlarged!)
        let rawPng2x = try ImageEncoder.encode(cg, format: .png, scale: 2.0, smartPngCompression: false)
        let smartPng2x = try ImageEncoder.encodePNGWithReport(cg, scale: 2.0, smartCompression: true).data
        let jpeg2x = try ImageEncoder.encode(cg, format: .jpeg, scale: 2.0)
        let webp2x = try ImageEncoder.encode(cg, format: .webp, scale: 2.0)

        for (label, encoded) in [("rawPNG@2x", rawPng2x), ("smartPNG@2x", smartPng2x), ("JPEG@2x", jpeg2x), ("WebP@2x", webp2x)] {
            let info = try readDPIAndPointSize(encoded)
            XCTAssertEqual(info.dpiW, 144.0, accuracy: 0.5, "\(label) dpiWidth mismatch")
            XCTAssertEqual(info.dpiH, 144.0, accuracy: 0.5, "\(label) dpiHeight mismatch")
            XCTAssertEqual(Double(info.ptSize.width), Double(pxW) / 2.0, accuracy: 0.5, "\(label) NSImage point width was enlarged!")
            XCTAssertEqual(Double(info.ptSize.height), Double(pxH) / 2.0, accuracy: 0.5, "\(label) NSImage point height was enlarged!")
        }

        // Verify 2x WebP with VP8X+EXIF still preserves 100% lossless pixel & alpha roundtrip
        let webpSrc = try XCTUnwrap(CGImageSourceCreateWithData(webp2x as CFData, nil))
        let webpDecoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(webpSrc, 0, nil))
        XCTAssertEqual(PixelBufferRGBA(cgImage: webpDecoded), PixelBufferRGBA(cgImage: cg))

        // 1x non-Retina (`72 DPI`): logical point size equals pixel size (`420 x 180 pt`)
        let rawPng1x = try ImageEncoder.encode(cg, format: .png, scale: 1.0, smartPngCompression: false)
        let info1x = try readDPIAndPointSize(rawPng1x)
        XCTAssertEqual(info1x.dpiW, 72.0, accuracy: 0.5)
        XCTAssertEqual(Double(info1x.ptSize.width), Double(pxW), accuracy: 0.5)
        XCTAssertEqual(Double(info1x.ptSize.height), Double(pxH), accuracy: 0.5)
    }
}
