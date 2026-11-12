import XCTest
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
            OCRTextSegment(left: 25, top: 100, bottom: 116, words: ["第二行"]),
            OCRTextSegment(left: 236, top: 58, bottom: 74, words: ["中段"]),
            OCRTextSegment(left: 640, top: 58, bottom: 74, words: ["尾段"]),
        ]
        XCTAssertEqual(OCRLinesJoiner.joinSegments(segs), "第一行中段尾段\n第二行")
        XCTAssertEqual(
            OCRLinesJoiner.joinSegments([OCRTextSegment(left: 0, top: 0, bottom: 16, words: ["讠 兑", "你 好"])]),
            "讠兑你好"
        )
    }
}
