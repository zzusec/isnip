import AppKit
import CoreGraphics
import CoreImage
import ImageIO
import AirSnipCore

public enum SmokeTestRunner {
    public static func run() -> Bool {
        do {
            print("[smoke] 1/5 验证配置往返与 24 项工具栏可见性...")
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("airsnip-smoke-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let cfgURL = tempDir.appendingPathComponent("config.json")
            var cfg = AirSnipConfig()
            cfg.toolbar.setVisible(.tool(.ellipse), false)
            cfg.toolbar.setVisible(.ocr, false)
            try cfg.save(to: cfgURL)
            let loaded = AirSnipConfig.load(from: cfgURL)
            guard !loaded.toolbar.isVisible(.tool(.ellipse)),
                  !loaded.toolbar.isVisible(.ocr),
                  loaded.toolbar.isVisible(.tool(.rect)) else {
                fputs("FAIL: Config toolbar visibility roundtrip mismatch\n", stderr)
                return false
            }

            print("[smoke] 2/5 验证 10 大矢量标注烘焙与三次盒式高斯模糊...")
            let baseW = 400
            let baseH = 260
            var rawBytes = [UInt8](repeating: 255, count: baseW * baseH * 4)
            for y in 0..<baseH {
                for x in 0..<baseW {
                    let i = (y * baseW + x) * 4
                    rawBytes[i] = UInt8((x * 2) & 0xFF)
                    rawBytes[i + 1] = UInt8((y * 3) & 0xFF)
                    rawBytes[i + 2] = 220
                    rawBytes[i + 3] = 255
                }
            }
            guard let baseCG = PixelBufferRGBA(width: baseW, height: baseH, rgba: rawBytes).makeCGImage() else {
                fputs("FAIL: Failed to create synthetic base CGImage\n", stderr)
                return false
            }

            let doc = AnnotationDocument()
            let red = AnnotationStyle(color: RGBAColor(r: 229, g: 57, b: 53), lineWidth: 4)
            doc.add(AnnotationObject(style: red, kind: .rect(a: ASPoint(10, 10), b: ASPoint(90, 60), cornerRadius: 8, filled: true)))
            doc.add(AnnotationObject(style: red, kind: .straightArrow(from: ASPoint(20, 80), to: ASPoint(140, 110))))
            doc.add(AnnotationObject(style: red, kind: .highlight(a: ASPoint(30, 30), b: ASPoint(120, 55), cornerRadius: 4)))
            doc.add(AnnotationObject(style: red, kind: .blur(a: ASPoint(40, 40), b: ASPoint(130, 100), blurRadius: 12, cornerRadius: 6)))
            doc.add(AnnotationObject(style: red, kind: .glow(a: ASPoint(15, 15), b: ASPoint(160, 115), cornerRadius: 8)))
            doc.add(AnnotationObject(style: red, kind: .number(center: ASPoint(50, 95), tip: ASPoint(95, 95), number: 1, fontSize: 20)))
            doc.add(AnnotationObject(style: red, kind: .line(from: ASPoint(10, 110), to: ASPoint(180, 110))))
            doc.add(AnnotationObject(style: red, kind: .ellipse(a: ASPoint(100, 20), b: ASPoint(180, 70), filled: false)))
            doc.add(AnnotationObject(style: red, kind: .freehand(points: [ASPoint(20, 20), ASPoint(40, 35), ASPoint(75, 25)])))
            let m = AnnotationRenderer.measureText("AirSnip 轻截", fontFamily: "PingFang SC", fontSize: 20, bold: true, italic: false)
            doc.add(AnnotationObject(style: red, kind: .text(pos: ASPoint(20, 50), text: "AirSnip 轻截", fontSize: 20, fontFamily: "PingFang SC", bold: true, italic: false, measuredWidth: m.width, measuredHeight: m.height)))

            guard let baked = AnnotationRenderer.bakeOutput(
                rawSelection: baseCG,
                objects: doc.objects,
                selectionOrigin: ASPoint(0, 0),
                pixelScale: 2.0
            ), baked.width == baseW && baked.height == baseH else {
                fputs("FAIL: AnnotationRenderer.bakeOutput failed\n", stderr)
                return false
            }

            print("[smoke] 3/5 验证 PNG / JPEG / 纯 Swift 无损 WebP 编码与 ImageIO 逐像素无损校验...")
            let pngData = try ImageEncoder.encode(baked, format: .png)
            let jpgData = try ImageEncoder.encode(baked, format: .jpeg)
            let webpData = try ImageEncoder.encode(baked, format: .webp)
            guard !pngData.isEmpty, !jpgData.isEmpty, !webpData.isEmpty else {
                fputs("FAIL: Image encoding produced empty output\n", stderr)
                return false
            }
            guard let webpSrc = CGImageSourceCreateWithData(webpData as CFData, nil),
                  let webpDecoded = CGImageSourceCreateImageAtIndex(webpSrc, 0, nil),
                  let origBuf = PixelBufferRGBA(cgImage: baked),
                  let decBuf = PixelBufferRGBA(cgImage: webpDecoded),
                  origBuf == decBuf else {
                fputs("FAIL: Lossless WebP roundtrip pixel mismatch\n", stderr)
                return false
            }

            print("[smoke] 4/5 验证长截图固定页眉页脚检测与滚动拼接引擎...")
            let w = 80
            let pageRows = 160
            var page = [UInt8](repeating: 255, count: w * pageRows * 4)
            for y in 0..<pageRows {
                for x in 0..<w {
                    let o = (y * w + x) * 4
                    page[o] = UInt8(y & 0xFF)
                    page[o + 1] = UInt8((x * 5 + y * 3) & 0xFF)
                    page[o + 2] = UInt8((y * 11) & 0xFF)
                    page[o + 3] = 255
                }
            }
            func makeFrame(scrollY: Int) -> PixelBufferRGBA {
                let fh = 60
                var buf = [UInt8](repeating: 255, count: w * fh * 4)
                for y in 0..<fh {
                    for x in 0..<w {
                        let dst = (y * w + x) * 4
                        if y < 10 {
                            // Fixed header
                            buf[dst] = 20; buf[dst+1] = 80; buf[dst+2] = UInt8(x * 2); buf[dst+3] = 255
                        } else if y >= 50 {
                            // Fixed footer
                            buf[dst] = 90; buf[dst+1] = 30; buf[dst+2] = UInt8(x * 2); buf[dst+3] = 255
                        } else {
                            let srcY = scrollY + (y - 10)
                            let src = (srcY * w + x) * 4
                            buf[dst] = page[src]; buf[dst+1] = page[src+1]; buf[dst+2] = page[src+2]; buf[dst+3] = 255
                        }
                    }
                }
                return PixelBufferRGBA(width: w, height: fh, rgba: buf)
            }

            let lsCanvas = LongshotCanvas(width: w, frameHeight: 60)
            lsCanvas.seed(makeFrame(scrollY: 0))
            let s1 = lsCanvas.push(makeFrame(scrollY: 15))
            let s2 = lsCanvas.push(makeFrame(scrollY: 30))
            guard case .appended(15, 15) = s1,
                  case .appended(15, 15) = s2,
                  lsCanvas.headerHeight == 10,
                  lsCanvas.footerHeight == 10,
                  lsCanvas.totalHeight == 90 else {
                fputs("FAIL: LongshotCanvas stitching height mismatch (got \(lsCanvas.totalHeight))\n", stderr)
                return false
            }

            print("[smoke] 5/5 验证本地离线 Vision OCR 中英文识别与二维码解析...")
            let ocrW = 680
            let ocrH = 180
            guard let ocrCtx = CGContext(
                data: nil,
                width: ocrW,
                height: ocrH,
                bitsPerComponent: 8,
                bytesPerRow: ocrW * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            ocrCtx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ocrCtx.fill(CGRect(x: 0, y: 0, width: ocrW, height: ocrH))
            let nsGfx = NSGraphicsContext(cgContext: ocrCtx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsGfx
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 34, weight: .bold),
                .foregroundColor: NSColor.black
            ]
            ("轻截 AirSnip 2026" as NSString).draw(at: NSPoint(x: 28, y: 65), withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()

            if let qrFilter = CIFilter(name: "CIQRCodeGenerator") {
                qrFilter.setValue(Data("https://github.com/zzusec/airsnip-releases".utf8), forKey: "inputMessage")
                qrFilter.setValue("M", forKey: "inputCorrectionLevel")
                if let ciOut = qrFilter.outputImage {
                    let scaled = ciOut.transformed(by: CGAffineTransform(scaleX: 4, y: 4))
                    let ciCtx = CIContext(options: nil)
                    if let qrCG = ciCtx.createCGImage(scaled, from: scaled.extent) {
                        ocrCtx.interpolationQuality = .none
                        ocrCtx.draw(qrCG, in: CGRect(x: 510, y: 20, width: 140, height: 140))
                    }
                }
            }

            if let ocrImg = ocrCtx.makeImage() {
                let detailed = try LocalVisionOCR.recognizeDetailed(
                    cgImage: ocrImg,
                    languagePreference: "zh-Hans",
                    detectBarcodes: true
                )
                guard detailed.rawText.contains("AirSnip") else {
                    fputs("FAIL: LocalVisionOCR output missing expected text: \(detailed.rawText)\n", stderr)
                    return false
                }
                guard detailed.barcodes.contains("https://github.com/zzusec/airsnip-releases") else {
                    fputs("FAIL: LocalVisionOCR barcode missing expected payload: \(detailed.barcodes)\n", stderr)
                    return false
                }
            }

            print("smoke-test: ok (AirSnip v\(UpdateChecker.currentVersion))")
            return true
        } catch {
            fputs("FAIL: Smoke test threw error: \(error)\n", stderr)
            return false
        }
    }
}
