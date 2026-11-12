import Foundation
import CoreGraphics
import CoreText
import AppKit

public enum AnnotationRenderer {
    public static func measureText(
        _ text: String,
        fontFamily: String,
        fontSize: Double,
        bold: Bool,
        italic: Bool
    ) -> (width: Double, height: Double) {
        let display = text.isEmpty ? " " : text
        let font = resolveNSFont(family: fontFamily, size: CGFloat(fontSize), bold: bold, italic: italic)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let lines = display.components(separatedBy: "\n")
        var maxW: CGFloat = 0
        let lineH = max(CGFloat(fontSize * 1.28), ceil(font.ascender - font.descender + font.leading))
        for line in lines {
            let s = (line.isEmpty ? " " : line) as NSString
            let sz = s.size(withAttributes: attrs)
            maxW = max(maxW, ceil(sz.width))
        }
        return (Double(max(12, maxW)), Double(max(lineH, lineH * CGFloat(lines.count))))
    }

    public static func resolveNSFont(family: String, size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }

        if let base = NSFont(name: family, size: size) {
            if traits.isEmpty { return base }
            return NSFontManager.shared.convert(base, toHaveTrait: traits)
        }
        let sys = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        if italic {
            return NSFontManager.shared.convert(sys, toHaveTrait: .italicFontMask)
        }
        return sys
    }

    /// Bakes `rawSelection` + `objects` (whose coordinates are in overlay point space) into a pixel-accurate output `CGImage`.
    /// `selectionOrigin` is the top-left of the selection in the same point coordinate space as `objects`,
    /// and `pixelScale` converts points -> physical pixels (e.g., 2.0 on Retina).
    public static func bakeOutput(
        rawSelection: CGImage,
        objects: [AnnotationObject],
        selectionOrigin: ASPoint,
        pixelScale: Double
    ) -> CGImage? {
        let outW = rawSelection.width
        let outH = rawSelection.height
        guard outW > 0, outH > 0 else { return nil }
        guard let rawBuffer = PixelBufferRGBA(cgImage: rawSelection) else { return nil }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: outW,
            height: outH,
            bitsPerComponent: 8,
            bytesPerRow: outW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        // Draw base raw image (CGContext default is bottom-left origin, which matches CGImage upright)
        ctx.draw(rawSelection, in: CGRect(x: 0, y: 0, width: outW, height: outH))

        // Switch context to top-down point coordinates mapped by `pixelScale` and offset by `-selectionOrigin`
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(outH))
        ctx.scaleBy(x: CGFloat(pixelScale), y: -CGFloat(pixelScale))
        ctx.translateBy(x: -CGFloat(selectionOrigin.x), y: -CGFloat(selectionOrigin.y))

        let logicalRect = ASRect(
            x: selectionOrigin.x,
            y: selectionOrigin.y,
            width: Double(outW) / pixelScale,
            height: Double(outH) / pixelScale
        )

        drawAnnotations(
            in: ctx,
            objects: objects,
            rawBuffer: rawBuffer,
            rawOrigin: selectionOrigin,
            pixelScale: pixelScale,
            clipBounds: logicalRect
        )

        ctx.restoreGState()
        return ctx.makeImage()
    }

    /// Wraps a 1:1 Retina window image (with transparent rounded corners) in a native macOS-style
    /// soft ambient drop shadow while preserving full RGBA transparency and exact unscaled window pixels.
    public static func applyWindowDropShadow(
        to windowImage: CGImage,
        scale: Double
    ) -> CGImage? {
        let w = windowImage.width
        let h = windowImage.height
        guard w > 0, h > 0 else { return nil }
        let s = max(1.0, scale)
        let padX = Int((34.0 * s).rounded())
        let padTop = Int((22.0 * s).rounded())
        let padBottom = Int((46.0 * s).rounded())
        let outW = w + padX * 2
        let outH = h + padTop + padBottom

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: outW,
            height: outH,
            bitsPerComponent: 8,
            bytesPerRow: outW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        // CGContext uses bottom-left origin: window sits `padBottom` from bottom and `padTop` from top.
        let drawRect = CGRect(x: padX, y: padBottom, width: w, height: h)
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -CGFloat(10.0 * s)),
            blur: CGFloat(26.0 * s),
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.30)
        )
        ctx.draw(windowImage, in: drawRect)
        ctx.restoreGState()
        return ctx.makeImage()
    }

    /// Draws all annotation objects in top-down point space into `ctx`.
    public static func drawAnnotations(
        in ctx: CGContext,
        objects: [AnnotationObject],
        rawBuffer: PixelBufferRGBA?,
        rawOrigin: ASPoint,
        pixelScale: Double,
        clipBounds: ASRect
    ) {
        ctx.saveGState()
        ctx.clip(to: clipBounds.cgRect)

        // 1. Spotlight (Glow): if one or more Glow objects exist, dim selection and punch bright holes
        let glowObjects = objects.filter {
            if case .glow = $0.kind { return true }
            return false
        }
        if !glowObjects.isEmpty {
            ctx.saveGState()
            let maskPath = CGMutablePath()
            maskPath.addRect(clipBounds.cgRect)
            for g in glowObjects {
                if case .glow(let a, let b, let cr) = g.kind {
                    let rect = ASRect.between(a, b)
                    if rect.width > 0.5 && rect.height > 0.5 {
                        let r = min(cr, min(rect.width, rect.height) * 0.5)
                        maskPath.addPath(CGPath(roundedRect: rect.cgRect, cornerWidth: r, cornerHeight: r, transform: nil))
                    }
                }
            }
            ctx.addPath(maskPath)
            ctx.clip(using: .evenOdd)
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.52))
            ctx.fill(clipBounds.cgRect)
            ctx.restoreGState()
        }

        // 2. Render objects in Z-order
        for obj in objects {
            drawSingleObject(
                in: ctx,
                object: obj,
                rawBuffer: rawBuffer,
                rawOrigin: rawOrigin,
                pixelScale: pixelScale
            )
        }

        ctx.restoreGState()
    }

    public static func drawSingleObject(
        in ctx: CGContext,
        object: AnnotationObject,
        rawBuffer: PixelBufferRGBA?,
        rawOrigin: ASPoint,
        pixelScale: Double
    ) {
        let color = object.style.color
        let lineW = CGFloat(object.style.lineWidth)

        switch object.kind {
        case .glow:
            // Already composited in the spotlight layer
            break

        case .blur(let a, let b, let blurRadius, let cornerRadius):
            let box = ASRect.between(a, b)
            guard box.width >= 2 && box.height >= 2, let raw = rawBuffer else { break }
            let pxX = Int(((box.minX - rawOrigin.x) * pixelScale).rounded(.down))
            let pxY = Int(((box.minY - rawOrigin.y) * pixelScale).rounded(.down))
            let pxW = max(1, Int((box.width * pixelScale).rounded(.up)))
            let pxH = max(1, Int((box.height * pixelScale).rounded(.up)))
            let cropRect = PixelRect(x: pxX, y: pxY, width: pxW, height: pxH)
            guard let sub = raw.cropped(to: cropRect) else { break }
            let scaledRadius = max(2, Int((blurRadius * max(1.0, pixelScale * 0.65)).rounded()))
            let blurred = BoxBlurEngine.blur(sub, radius: scaledRadius)
            guard let blurredCG = blurred.makeCGImage() else { break }

            ctx.saveGState()
            let r = CGFloat(min(cornerRadius, min(box.width, box.height) * 0.5))
            let clipPath = CGPath(roundedRect: box.cgRect, cornerWidth: r, cornerHeight: r, transform: nil)
            ctx.addPath(clipPath)
            ctx.clip()
            // Flip locally to draw upright CGImage in top-down space
            ctx.translateBy(x: CGFloat(box.minX), y: CGFloat(box.maxY))
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(blurredCG, in: CGRect(x: 0, y: 0, width: box.width, height: box.height))
            ctx.restoreGState()

        case .highlight(let a, let b, let cornerRadius):
            let box = ASRect.between(a, b)
            guard box.width >= 1 && box.height >= 1 else { break }
            ctx.saveGState()
            ctx.setBlendMode(.multiply)
            let r = CGFloat(min(cornerRadius, min(box.width, box.height) * 0.5))
            let path = CGPath(roundedRect: box.cgRect, cornerWidth: r, cornerHeight: r, transform: nil)
            let fillCol = CGColor(
                srgbRed: CGFloat(color.r) / 255.0,
                green: CGFloat(color.g) / 255.0,
                blue: CGFloat(color.b) / 255.0,
                alpha: 0.42
            )
            ctx.addPath(path)
            ctx.setFillColor(fillCol)
            ctx.fillPath()
            ctx.restoreGState()

        case .rect(let a, let b, let cornerRadius, let filled):
            let box = ASRect.between(a, b)
            guard box.width >= 1 || box.height >= 1 else { break }
            ctx.saveGState()
            let r = CGFloat(min(cornerRadius, min(box.width, box.height) * 0.5))
            let path = CGPath(roundedRect: box.cgRect, cornerWidth: r, cornerHeight: r, transform: nil)
            if filled {
                ctx.addPath(path)
                ctx.setFillColor(CGColor(
                    srgbRed: CGFloat(color.r) / 255.0,
                    green: CGFloat(color.g) / 255.0,
                    blue: CGFloat(color.b) / 255.0,
                    alpha: 0.24
                ))
                ctx.fillPath()
            }
            ctx.addPath(path)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(lineW)
            ctx.setLineJoin(.round)
            ctx.strokePath()
            ctx.restoreGState()

        case .ellipse(let a, let b, let filled):
            let box = ASRect.between(a, b)
            guard box.width >= 1 && box.height >= 1 else { break }
            ctx.saveGState()
            if filled {
                ctx.setFillColor(CGColor(
                    srgbRed: CGFloat(color.r) / 255.0,
                    green: CGFloat(color.g) / 255.0,
                    blue: CGFloat(color.b) / 255.0,
                    alpha: 0.24
                ))
                ctx.fillEllipse(in: box.cgRect)
            }
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(lineW)
            ctx.strokeEllipse(in: box.cgRect)
            ctx.restoreGState()

        case .line(let from, let to):
            ctx.saveGState()
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(lineW)
            ctx.setLineCap(.round)
            ctx.move(to: from.cgPoint)
            ctx.addLine(to: to.cgPoint)
            ctx.strokePath()
            ctx.restoreGState()

        case .arrow(let from, let c1, let c2, let to):
            drawCubicArrow(in: ctx, from: from, c1: c1, c2: c2, to: to, color: color.cgColor, lineWidth: Double(lineW))

        case .freehand(let pts):
            guard !pts.isEmpty else { break }
            ctx.saveGState()
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(lineW)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            if pts.count == 1 {
                let p = pts[0]
                ctx.setFillColor(color.cgColor)
                ctx.fillEllipse(in: CGRect(x: p.x - Double(lineW) * 0.5, y: p.y - Double(lineW) * 0.5, width: Double(lineW), height: Double(lineW)))
            } else if pts.count == 2 {
                ctx.move(to: pts[0].cgPoint)
                ctx.addLine(to: pts[1].cgPoint)
                ctx.strokePath()
            } else {
                // Midpoint quadratic Bezier smoothing (matches AirSnip EDT-15)
                ctx.move(to: pts[0].cgPoint)
                for i in 1..<(pts.count - 1) {
                    let mid = ASPoint.lerp(pts[i], pts[i + 1], t: 0.5)
                    ctx.addQuadCurve(to: mid.cgPoint, control: pts[i].cgPoint)
                }
                ctx.addLine(to: pts[pts.count - 1].cgPoint)
                ctx.strokePath()
            }
            ctx.restoreGState()

        case .number(let center, let tip, let n, let fontSize):
            let badgeR = AnnotationKind.badgeRadius(fontSize: fontSize, number: n)
            ctx.saveGState()
            // Leader arrow if dragged outside badge
            let dist = center.distance(to: tip)
            if dist > badgeR + 6.0 {
                let dx = (tip.x - center.x) / dist
                let dy = (tip.y - center.y) / dist
                let start = ASPoint(center.x + dx * (badgeR - 1.0), center.y + dy * (badgeR - 1.0))
                let c1 = ASPoint.lerp(start, tip, t: 1.0 / 3.0)
                let c2 = ASPoint.lerp(start, tip, t: 2.0 / 3.0)
                drawCubicArrow(
                    in: ctx,
                    from: start,
                    c1: c1,
                    c2: c2,
                    to: tip,
                    color: color.cgColor,
                    lineWidth: max(2.5, fontSize * 0.16)
                )
            }
            // Filled badge circle + subtle white outline for contrast on any background
            let circleRect = CGRect(x: center.x - badgeR, y: center.y - badgeR, width: badgeR * 2, height: badgeR * 2)
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: circleRect)
            ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.88))
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: circleRect)

            // Contrast-aware label color (black on very bright swatches like white, white otherwise)
            let lum = 0.299 * Double(color.r) + 0.587 * Double(color.g) + 0.114 * Double(color.b)
            let textCol = lum > 205 ? NSColor.black : NSColor.white
            let numStr = "\(n)"
            let font = NSFont.monospacedDigitSystemFont(ofSize: CGFloat(fontSize * 0.85), weight: .bold)
            drawUprightString(
                in: ctx,
                text: numStr,
                font: font,
                color: textCol,
                centeredAt: center
            )
            ctx.restoreGState()

        case .text(let pos, let text, let fontSize, let fontFamily, let bold, let italic, _, _):
            guard !text.isEmpty else { break }
            let font = resolveNSFont(family: fontFamily, size: CGFloat(fontSize), bold: bold, italic: italic)
            let nsColor = NSColor(
                srgbRed: CGFloat(color.r) / 255.0,
                green: CGFloat(color.g) / 255.0,
                blue: CGFloat(color.b) / 255.0,
                alpha: CGFloat(color.a) / 255.0
            )
            drawMultilineText(in: ctx, text: text, font: font, color: nsColor, topLeft: ASPoint(pos.x + 4, pos.y + 3))
        }
    }

    private static func drawCubicArrow(
        in ctx: CGContext,
        from: ASPoint,
        c1: ASPoint,
        c2: ASPoint,
        to: ASPoint,
        color: CGColor,
        lineWidth: Double
    ) {
        let pts = CubicCurve.flatten(p0: from, p1: c1, p2: c2, p3: to)
        let headLen = AnnotationKind.arrowHeadLength(lineWidth: lineWidth)
        let headHalfWidth = headLen * 0.44
        let tangent = CubicCurve.endTangent(p0: from, p1: c1, p2: c2, p3: to)
        let nx = -tangent.y
        let ny = tangent.x

        ctx.saveGState()
        // Truncate shaft at base of arrowhead (EDT-3a) so thick strokes don't poke past tip
        let totalArc = zip(pts, pts.dropFirst()).reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
        if totalArc > headLen * 0.72 {
            let cutT = CubicCurve.tAtArcFromEnd(pts: pts, arcFromEnd: headLen * 0.72)
            let (s0, s1, s2, s3) = CubicCurve.splitLeft(p0: from, p1: c1, p2: c2, p3: to, t: cutT)
            ctx.move(to: s0.cgPoint)
            ctx.addCurve(to: s3.cgPoint, control1: s1.cgPoint, control2: s2.cgPoint)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(CGFloat(lineWidth))
            ctx.setLineCap(.round)
            ctx.strokePath()
        }

        // Sleek swept arrowhead polygon
        let baseCenter = ASPoint(to.x - tangent.x * headLen, to.y - tangent.y * headLen)
        let notchCenter = ASPoint(to.x - tangent.x * (headLen * 0.82), to.y - tangent.y * (headLen * 0.82))
        let wing1 = ASPoint(baseCenter.x + nx * headHalfWidth, baseCenter.y + ny * headHalfWidth)
        let wing2 = ASPoint(baseCenter.x - nx * headHalfWidth, baseCenter.y - ny * headHalfWidth)

        ctx.move(to: to.cgPoint)
        ctx.addLine(to: wing1.cgPoint)
        ctx.addLine(to: notchCenter.cgPoint)
        ctx.addLine(to: wing2.cgPoint)
        ctx.closePath()
        ctx.setFillColor(color)
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func drawUprightString(
        in ctx: CGContext,
        text: String,
        font: NSFont,
        color: NSColor,
        centeredAt center: ASPoint
    ) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrStr)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        ctx.saveGState()
        ctx.translateBy(x: CGFloat(center.x) - width * 0.5, y: CGFloat(center.y) + (ascent - descent) * 0.5)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func drawMultilineText(
        in ctx: CGContext,
        text: String,
        font: NSFont,
        color: NSColor,
        topLeft: ASPoint
    ) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let lines = text.components(separatedBy: "\n")
        let lineHeight = max(font.pointSize * 1.28, ceil(font.ascender - font.descender + font.leading))

        ctx.saveGState()
        for (idx, rawLine) in lines.enumerated() {
            guard !rawLine.isEmpty else { continue }
            let attrStr = NSAttributedString(string: rawLine, attributes: attrs)
            let ctLine = CTLineCreateWithAttributedString(attrStr)
            let baselineY = CGFloat(topLeft.y) + CGFloat(idx) * lineHeight + font.ascender

            ctx.saveGState()
            ctx.translateBy(x: CGFloat(topLeft.x), y: baselineY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textMatrix = .identity
            ctx.textPosition = .zero
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    /// Screen-only selection adornments (bounding frame, 8 resize handles, corner-radius handle, Bezier curve handles).
    public static func drawSelectionGizmos(in ctx: CGContext, for object: AnnotationObject) {
        let accent = CGColor(srgbRed: 0.09, green: 0.56, blue: 1.0, alpha: 1.0)
        let box = object.boundingBox

        ctx.saveGState()
        // Crisp dashed bounding frame
        ctx.setStrokeColor(CGColor(srgbRed: 0.09, green: 0.56, blue: 1.0, alpha: 0.85))
        ctx.setLineWidth(1.0)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(box.cgRect)
        ctx.setLineDash(phase: 0, lengths: [])

        // 8 precision circular resize handles with soft shadow
        let handleDiameter: CGFloat = 6.8
        for h in ResizeHandle.allCases {
            if (h == .top || h == .bottom) && box.width < 36 { continue }
            if (h == .left || h == .right) && box.height < 36 { continue }
            let p = h.position(in: box)
            let hr = CGRect(
                x: CGFloat(p.x) - handleDiameter * 0.5,
                y: CGFloat(p.y) - handleDiameter * 0.5,
                width: handleDiameter,
                height: handleDiameter
            )
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.25))
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fillEllipse(in: hr)
            ctx.restoreGState()
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(1.3)
            ctx.strokeEllipse(in: hr)
        }

        // Corner radius circular handle (warm amber core to distinguish from resize handles)
        if let cp = object.cornerHandlePoint {
            let r: CGFloat = 4.2
            let cr = CGRect(x: CGFloat(cp.x) - r, y: CGFloat(cp.y) - r, width: r * 2, height: r * 2)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.25))
            ctx.setFillColor(CGColor(srgbRed: 1.0, green: 0.96, blue: 0.84, alpha: 1))
            ctx.fillEllipse(in: cr)
            ctx.restoreGState()
            ctx.setStrokeColor(CGColor(srgbRed: 0.96, green: 0.62, blue: 0.04, alpha: 1))
            ctx.setLineWidth(1.4)
            ctx.strokeEllipse(in: cr)
        }

        // Cubic arrow control handles + dashed guide lines (EDT-3)
        if let curve = object.curveControlPoints {
            ctx.setStrokeColor(CGColor(srgbRed: 0.09, green: 0.56, blue: 1.0, alpha: 0.65))
            ctx.setLineWidth(1.0)
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.move(to: curve.from.cgPoint)
            ctx.addLine(to: curve.c1.cgPoint)
            ctx.move(to: curve.to.cgPoint)
            ctx.addLine(to: curve.c2.cgPoint)
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])

            for pt in [curve.c1, curve.c2] {
                let r: CGFloat = 4.6
                let cr = CGRect(x: CGFloat(pt.x) - r, y: CGFloat(pt.y) - r, width: r * 2, height: r * 2)
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28))
                ctx.setFillColor(accent)
                ctx.fillEllipse(in: cr)
                ctx.restoreGState()
                ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                ctx.setLineWidth(1.4)
                ctx.strokeEllipse(in: cr)
            }
        }
        ctx.restoreGState()
    }
}
