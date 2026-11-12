import XCTest
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
}
