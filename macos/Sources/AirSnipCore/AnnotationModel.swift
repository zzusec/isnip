import Foundation
import CoreGraphics

public struct ASPoint: Equatable, Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public init(_ cg: CGPoint) {
        self.x = Double(cg.x)
        self.y = Double(cg.y)
    }

    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }

    public func distance(to other: ASPoint) -> Double {
        hypot(other.x - x, other.y - y)
    }

    public func offset(dx: Double, dy: Double) -> ASPoint {
        ASPoint(x + dx, y + dy)
    }

    public static func lerp(_ a: ASPoint, _ b: ASPoint, t: Double) -> ASPoint {
        ASPoint(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
    }
}

public struct ASRect: Equatable, Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = max(0, width)
        self.height = max(0, height)
    }

    public static func between(_ a: ASPoint, _ b: ASPoint) -> ASRect {
        let x0 = min(a.x, b.x)
        let y0 = min(a.y, b.y)
        return ASRect(x: x0, y: y0, width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width * 0.5 }
    public var midY: Double { y + height * 0.5 }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    public func insetBy(dx: Double, dy: Double) -> ASRect {
        ASRect(x: x + dx, y: y + dy, width: max(0, width - dx * 2), height: max(0, height - dy * 2))
    }

    public func contains(_ p: ASPoint) -> Bool {
        p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
    }
}

public enum ResizeHandle: Int, CaseIterable, Sendable {
    case topLeft = 0
    case top = 1
    case topRight = 2
    case right = 3
    case bottomRight = 4
    case bottom = 5
    case bottomLeft = 6
    case left = 7

    public func position(in rect: ASRect) -> ASPoint {
        switch self {
        case .topLeft:     return ASPoint(rect.minX, rect.minY)
        case .top:         return ASPoint(rect.midX, rect.minY)
        case .topRight:    return ASPoint(rect.maxX, rect.minY)
        case .right:       return ASPoint(rect.maxX, rect.midY)
        case .bottomRight: return ASPoint(rect.maxX, rect.maxY)
        case .bottom:      return ASPoint(rect.midX, rect.maxY)
        case .bottomLeft:  return ASPoint(rect.minX, rect.maxY)
        case .left:        return ASPoint(rect.minX, rect.midY)
        }
    }
}

public enum GeometrySnap {
    /// Constrains `to` relative to `from` to form an exact square while preserving quadrant sign.
    public static func squareCorner(from: ASPoint, to: ASPoint) -> ASPoint {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let side = max(abs(dx), abs(dy))
        let sx: Double = dx >= 0 ? 1.0 : -1.0
        let sy: Double = dy >= 0 ? 1.0 : -1.0
        return ASPoint(from.x + sx * side, from.y + sy * side)
    }

    /// Snaps direction to nearest 45-degree multiple (horizontal, vertical, or diagonal).
    public static func snapDirection(from: ASPoint, to: ASPoint) -> ASPoint {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let len = hypot(dx, dy)
        guard len > 1e-5 else { return to }
        let angle = atan2(dy, dx)
        let step = Double.pi / 4.0
        let snapped = (angle / step).rounded() * step
        return ASPoint(from.x + cos(snapped) * len, from.y + sin(snapped) * len)
    }
}

public enum CubicCurve {
    public static let segments = 48

    public static func point(p0: ASPoint, p1: ASPoint, p2: ASPoint, p3: ASPoint, t: Double) -> ASPoint {
        let u = 1.0 - t
        let tt = t * t
        let uu = u * u
        let uuu = uu * u
        let ttt = tt * t
        let x = uuu * p0.x + 3 * uu * t * p1.x + 3 * u * tt * p2.x + ttt * p3.x
        let y = uuu * p0.y + 3 * uu * t * p1.y + 3 * u * tt * p2.y + ttt * p3.y
        return ASPoint(x, y)
    }

    public static func flatten(p0: ASPoint, p1: ASPoint, p2: ASPoint, p3: ASPoint, count: Int = segments) -> [ASPoint] {
        (0...count).map { i in
            point(p0: p0, p1: p1, p2: p2, p3: p3, t: Double(i) / Double(count))
        }
    }

    public static func endTangent(p0: ASPoint, p1: ASPoint, p2: ASPoint, p3: ASPoint) -> ASPoint {
        let dx1 = p3.x - p2.x
        let dy1 = p3.y - p2.y
        if hypot(dx1, dy1) > 0.5 {
            let l = hypot(dx1, dy1)
            return ASPoint(dx1 / l, dy1 / l)
        }
        let dx2 = p3.x - p1.x
        let dy2 = p3.y - p1.y
        if hypot(dx2, dy2) > 0.5 {
            let l = hypot(dx2, dy2)
            return ASPoint(dx2 / l, dy2 / l)
        }
        let dx3 = p3.x - p0.x
        let dy3 = p3.y - p0.y
        let l = max(1e-5, hypot(dx3, dy3))
        return ASPoint(dx3 / l, dy3 / l)
    }

    /// Splits cubic curve `[0, t]` via de Casteljau so arrow shaft terminates cleanly at arrowhead base.
    public static func splitLeft(
        p0: ASPoint,
        p1: ASPoint,
        p2: ASPoint,
        p3: ASPoint,
        t: Double
    ) -> (ASPoint, ASPoint, ASPoint, ASPoint) {
        let q0 = ASPoint.lerp(p0, p1, t: t)
        let q1 = ASPoint.lerp(p1, p2, t: t)
        let q2 = ASPoint.lerp(p2, p3, t: t)
        let r0 = ASPoint.lerp(q0, q1, t: t)
        let r1 = ASPoint.lerp(q1, q2, t: t)
        let s0 = ASPoint.lerp(r0, r1, t: t)
        return (p0, q0, r0, s0)
    }

    public static func tAtArcFromEnd(pts: [ASPoint], arcFromEnd: Double) -> Double {
        guard pts.count >= 2 else { return 1.0 }
        var accum = 0.0
        for i in stride(from: pts.count - 1, through: 1, by: -1) {
            let segLen = pts[i].distance(to: pts[i - 1])
            if accum + segLen >= arcFromEnd && segLen > 1e-6 {
                let rem = arcFromEnd - accum
                let frac = 1.0 - (rem / segLen)
                return (Double(i - 1) + frac) / Double(pts.count - 1)
            }
            accum += segLen
        }
        return 0.0
    }

    public static func distanceToSegment(p: ASPoint, a: ASPoint, b: ASPoint) -> Double {
        let vx = b.x - a.x
        let vy = b.y - a.y
        let len2 = vx * vx + vy * vy
        if len2 < 1e-8 { return p.distance(to: a) }
        let t = max(0.0, min(1.0, ((p.x - a.x) * vx + (p.y - a.y) * vy) / len2))
        let proj = ASPoint(a.x + t * vx, a.y + t * vy)
        return p.distance(to: proj)
    }

    public static func distanceToPolyline(p: ASPoint, pts: [ASPoint]) -> Double {
        guard !pts.isEmpty else { return .infinity }
        if pts.count == 1 { return p.distance(to: pts[0]) }
        var best = Double.infinity
        for i in 0..<(pts.count - 1) {
            best = min(best, distanceToSegment(p: p, a: pts[i], b: pts[i + 1]))
        }
        return best
    }
}

public struct AnnotationStyle: Equatable, Codable, Sendable {
    public var color: RGBAColor
    public var lineWidth: Double

    public init(color: RGBAColor, lineWidth: Double = 4.0) {
        self.color = color
        self.lineWidth = max(1.0, min(48.0, lineWidth))
    }
}

public enum AnnotationKind: Equatable, Codable, Sendable {
    case rect(a: ASPoint, b: ASPoint, cornerRadius: Double, filled: Bool)
    case arrow(from: ASPoint, c1: ASPoint, c2: ASPoint, to: ASPoint)
    case text(pos: ASPoint, text: String, fontSize: Double, fontFamily: String, bold: Bool, italic: Bool, measuredWidth: Double, measuredHeight: Double)
    case highlight(a: ASPoint, b: ASPoint, cornerRadius: Double)
    case blur(a: ASPoint, b: ASPoint, blurRadius: Double, cornerRadius: Double)
    case glow(a: ASPoint, b: ASPoint, cornerRadius: Double)
    case number(center: ASPoint, tip: ASPoint, number: Int, fontSize: Double)
    case line(from: ASPoint, to: ASPoint)
    case ellipse(a: ASPoint, b: ASPoint, filled: Bool)
    case freehand(points: [ASPoint])

    public static func straightArrow(from: ASPoint, to: ASPoint) -> AnnotationKind {
        .arrow(
            from: from,
            c1: ASPoint.lerp(from, to, t: 1.0 / 3.0),
            c2: ASPoint.lerp(from, to, t: 2.0 / 3.0),
            to: to
        )
    }

    public static func badgeRadius(fontSize: Double, number: Int) -> Double {
        let digits = max(1, String(abs(number)).count)
        let base = fontSize * 0.78
        return digits <= 2 ? base : base + Double(digits - 2) * fontSize * 0.22
    }

    public static func arrowHeadLength(lineWidth: Double) -> Double {
        max(12.0, lineWidth * 3.6 + 4.0)
    }
}

public struct AnnotationObject: Equatable, Identifiable, Codable, Sendable {
    public var id: UUID
    public var style: AnnotationStyle
    public var kind: AnnotationKind

    public init(id: UUID = UUID(), style: AnnotationStyle, kind: AnnotationKind) {
        self.id = id
        self.style = style
        self.kind = kind
    }

    public var boundingBox: ASRect {
        switch kind {
        case .rect(let a, let b, _, _),
             .highlight(let a, let b, _),
             .blur(let a, let b, _, _),
             .glow(let a, let b, _),
             .ellipse(let a, let b, _):
            return ASRect.between(a, b)
        case .line(let from, let to):
            return ASRect.between(from, to)
        case .arrow(let from, let c1, let c2, let to):
            let pts = CubicCurve.flatten(p0: from, p1: c1, p2: c2, p3: to, count: 24)
            let xs = pts.map(\.x)
            let ys = pts.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
                return ASRect.between(from, to)
            }
            return ASRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .text(let pos, _, let fontSize, _, _, _, let mw, let mh):
            let w = max(mw, fontSize * 0.8)
            let h = max(mh, fontSize * 1.3)
            return ASRect(x: pos.x, y: pos.y, width: w + 8, height: h + 6)
        case .number(let center, let tip, let n, let fontSize):
            let r = AnnotationKind.badgeRadius(fontSize: fontSize, number: n)
            let x0 = min(center.x - r, tip.x)
            let y0 = min(center.y - r, tip.y)
            let x1 = max(center.x + r, tip.x)
            let y1 = max(center.y + r, tip.y)
            return ASRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        case .freehand(let points):
            let xs = points.map(\.x)
            let ys = points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
                return ASRect(x: 0, y: 0, width: 1, height: 1)
            }
            return ASRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
        }
    }

    public var supportsCornerRadius: Bool {
        switch kind {
        case .rect, .highlight, .blur, .glow:
            return true
        default:
            return false
        }
    }

    public var cornerRadius: Double {
        switch kind {
        case .rect(_, _, let r, _),
             .highlight(_, _, let r),
             .blur(_, _, _, let r),
             .glow(_, _, let r):
            return r
        default:
            return 0
        }
    }

    public var maxCornerRadius: Double {
        let box = boundingBox
        return max(0, min(box.width, box.height) * 0.5)
    }

    /// Position of the interactive corner-radius handle (inset from top-right corner like AirSnip ADR 0010/0011).
    public var cornerHandlePoint: ASPoint? {
        guard supportsCornerRadius else { return nil }
        let box = boundingBox
        guard box.width >= 20 && box.height >= 20 else { return nil }
        let clampedR = max(0, min(maxCornerRadius, cornerRadius))
        let inset = max(10.0, clampedR * 0.7071 + 8.0)
        let hx = max(box.midX, box.maxX - inset)
        let hy = min(box.midY, box.minY + inset)
        return ASPoint(hx, hy)
    }

    public mutating func setCornerRadius(_ radius: Double) {
        let r = max(0, min(maxCornerRadius, radius))
        switch kind {
        case .rect(let a, let b, _, let filled):
            kind = .rect(a: a, b: b, cornerRadius: r, filled: filled)
        case .highlight(let a, let b, _):
            kind = .highlight(a: a, b: b, cornerRadius: r)
        case .blur(let a, let b, let br, _):
            kind = .blur(a: a, b: b, blurRadius: br, cornerRadius: r)
        case .glow(let a, let b, _):
            kind = .glow(a: a, b: b, cornerRadius: r)
        default:
            break
        }
    }

    public var curveControlPoints: (c1: ASPoint, c2: ASPoint, from: ASPoint, to: ASPoint)? {
        if case .arrow(let from, let c1, let c2, let to) = kind {
            return (c1, c2, from, to)
        }
        return nil
    }

    public mutating func setCurveControlPoint(index: Int, to pt: ASPoint) {
        if case .arrow(let from, var c1, var c2, let to) = kind {
            if index == 0 { c1 = pt } else { c2 = pt }
            kind = .arrow(from: from, c1: c1, c2: c2, to: to)
        }
    }

    public mutating func resetCurveToStraight() -> Bool {
        guard case .arrow(let from, _, _, let to) = kind else { return false }
        let straight = AnnotationKind.straightArrow(from: from, to: to)
        if straight == kind { return false }
        kind = straight
        return true
    }

    public mutating func translate(dx: Double, dy: Double) {
        switch kind {
        case .rect(let a, let b, let r, let filled):
            kind = .rect(a: a.offset(dx: dx, dy: dy), b: b.offset(dx: dx, dy: dy), cornerRadius: r, filled: filled)
        case .arrow(let from, let c1, let c2, let to):
            kind = .arrow(
                from: from.offset(dx: dx, dy: dy),
                c1: c1.offset(dx: dx, dy: dy),
                c2: c2.offset(dx: dx, dy: dy),
                to: to.offset(dx: dx, dy: dy)
            )
        case .text(let pos, let text, let fs, let ff, let bold, let italic, let mw, let mh):
            kind = .text(pos: pos.offset(dx: dx, dy: dy), text: text, fontSize: fs, fontFamily: ff, bold: bold, italic: italic, measuredWidth: mw, measuredHeight: mh)
        case .highlight(let a, let b, let r):
            kind = .highlight(a: a.offset(dx: dx, dy: dy), b: b.offset(dx: dx, dy: dy), cornerRadius: r)
        case .blur(let a, let b, let br, let cr):
            kind = .blur(a: a.offset(dx: dx, dy: dy), b: b.offset(dx: dx, dy: dy), blurRadius: br, cornerRadius: cr)
        case .glow(let a, let b, let r):
            kind = .glow(a: a.offset(dx: dx, dy: dy), b: b.offset(dx: dx, dy: dy), cornerRadius: r)
        case .number(let center, let tip, let n, let fs):
            kind = .number(center: center.offset(dx: dx, dy: dy), tip: tip.offset(dx: dx, dy: dy), number: n, fontSize: fs)
        case .line(let from, let to):
            kind = .line(from: from.offset(dx: dx, dy: dy), to: to.offset(dx: dx, dy: dy))
        case .ellipse(let a, let b, let filled):
            kind = .ellipse(a: a.offset(dx: dx, dy: dy), b: b.offset(dx: dx, dy: dy), filled: filled)
        case .freehand(let pts):
            kind = .freehand(points: pts.map { $0.offset(dx: dx, dy: dy) })
        }
    }

    public mutating func applyResize(from oldBox: ASRect, to newBox: ASRect) {
        let ow = max(1.0, oldBox.width)
        let oh = max(1.0, oldBox.height)
        func mapPt(_ p: ASPoint) -> ASPoint {
            let nx = newBox.minX + ((p.x - oldBox.minX) / ow) * newBox.width
            let ny = newBox.minY + ((p.y - oldBox.minY) / oh) * newBox.height
            return ASPoint(nx, ny)
        }
        switch kind {
        case .rect(let a, let b, let r, let filled):
            kind = .rect(a: mapPt(a), b: mapPt(b), cornerRadius: r, filled: filled)
        case .arrow(let from, let c1, let c2, let to):
            kind = .arrow(from: mapPt(from), c1: mapPt(c1), c2: mapPt(c2), to: mapPt(to))
        case .text(_, let text, let fs, let ff, let bold, let italic, let mw, let mh):
            let ratio = max(0.3, newBox.height / oh)
            let newFS = max(10.0, min(96.0, fs * ratio))
            kind = .text(pos: ASPoint(newBox.minX, newBox.minY), text: text, fontSize: newFS, fontFamily: ff, bold: bold, italic: italic, measuredWidth: mw * (newFS / fs), measuredHeight: mh * (newFS / fs))
        case .highlight(let a, let b, let r):
            kind = .highlight(a: mapPt(a), b: mapPt(b), cornerRadius: r)
        case .blur(let a, let b, let br, let cr):
            kind = .blur(a: mapPt(a), b: mapPt(b), blurRadius: br, cornerRadius: cr)
        case .glow(let a, let b, let r):
            kind = .glow(a: mapPt(a), b: mapPt(b), cornerRadius: r)
        case .number(let center, let tip, let n, let fs):
            kind = .number(center: mapPt(center), tip: mapPt(tip), number: n, fontSize: fs)
        case .line(let from, let to):
            kind = .line(from: mapPt(from), to: mapPt(to))
        case .ellipse(let a, let b, let filled):
            kind = .ellipse(a: mapPt(a), b: mapPt(b), filled: filled)
        case .freehand(let pts):
            kind = .freehand(points: pts.map(mapPt))
        }
    }

    public func hitTestBody(_ point: ASPoint, tolerance: Double = 6.0) -> Bool {
        let pad = max(tolerance, style.lineWidth * 0.5 + 3.0)
        switch kind {
        case .rect(let a, let b, _, let filled):
            let box = ASRect.between(a, b)
            if filled { return box.insetBy(dx: -pad, dy: -pad).contains(point) }
            let outer = box.insetBy(dx: -pad, dy: -pad)
            let inner = box.insetBy(dx: pad, dy: pad)
            return outer.contains(point) && (!inner.contains(point) || box.width <= pad * 2 || box.height <= pad * 2)
        case .highlight(let a, let b, _),
             .blur(let a, let b, _, _),
             .glow(let a, let b, _):
            return ASRect.between(a, b).insetBy(dx: -3.0, dy: -3.0).contains(point)
        case .text:
            return boundingBox.insetBy(dx: -3.0, dy: -3.0).contains(point)
        case .arrow(let from, let c1, let c2, let to):
            let pts = CubicCurve.flatten(p0: from, p1: c1, p2: c2, p3: to, count: 32)
            return CubicCurve.distanceToPolyline(p: point, pts: pts) <= max(pad, 8.0)
        case .line(let from, let to):
            return CubicCurve.distanceToSegment(p: point, a: from, b: to) <= max(pad, 7.0)
        case .ellipse(let a, let b, let filled):
            let box = ASRect.between(a, b)
            let rx = max(1.0, box.width * 0.5)
            let ry = max(1.0, box.height * 0.5)
            let dx = point.x - box.midX
            let dy = point.y - box.midY
            let norm = hypot(dx / rx, dy / ry)
            if filled {
                return norm <= 1.0 + pad / min(rx, ry)
            }
            let delta = abs(norm - 1.0) * min(rx, ry)
            return delta <= pad
        case .number(let center, let tip, let n, let fs):
            let r = AnnotationKind.badgeRadius(fontSize: fs, number: n)
            if point.distance(to: center) <= r + 4.0 { return true }
            if center.distance(to: tip) > r + 4.0 {
                return CubicCurve.distanceToSegment(p: point, a: center, b: tip) <= max(pad, 7.0)
            }
            return false
        case .freehand(let pts):
            return CubicCurve.distanceToPolyline(p: point, pts: pts) <= max(pad, 7.0)
        }
    }

    /// EDT-11: Selected object's bounding frame edge (~6pt ring; or entire box if object <= 14pt).
    public func hitTestFrameBorder(_ point: ASPoint, band: Double = 6.0) -> Bool {
        let box = boundingBox
        let outer = box.insetBy(dx: -band, dy: -band)
        guard outer.contains(point) else { return false }
        if box.width <= 14.0 || box.height <= 14.0 { return true }
        let inner = box.insetBy(dx: band, dy: band)
        return !inner.contains(point)
    }
}

public final class AnnotationDocument {
    public static let maxHistory = 100

    public private(set) var objects: [AnnotationObject] = []
    public var selectedID: UUID?
    private var undoStack: [[AnnotationObject]] = []
    private var redoStack: [[AnnotationObject]] = []

    public init() {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var isEmpty: Bool { objects.isEmpty }

    public var selectedObject: AnnotationObject? {
        guard let id = selectedID else { return nil }
        return objects.first { $0.id == id }
    }

    public func recordSnapshotForMutation() {
        pushUndoSnapshot(objects)
        redoStack.removeAll()
    }

    private func pushUndoSnapshot(_ snap: [AnnotationObject]) {
        if undoStack.last == snap { return }
        undoStack.append(snap)
        if undoStack.count > Self.maxHistory {
            undoStack.removeFirst(undoStack.count - Self.maxHistory)
        }
    }

    public func add(_ object: AnnotationObject, select: Bool = true) {
        recordSnapshotForMutation()
        objects.append(object)
        if select {
            selectedID = object.id
        }
    }

    public func updateObject(id: UUID, recordUndo: Bool, mutate: (inout AnnotationObject) -> Void) {
        guard let idx = objects.firstIndex(where: { $0.id == id }) else { return }
        if recordUndo {
            recordSnapshotForMutation()
        }
        mutate(&objects[idx])
    }

    @discardableResult
    public func deleteSelected() -> Bool {
        guard let id = selectedID, let idx = objects.firstIndex(where: { $0.id == id }) else {
            return false
        }
        recordSnapshotForMutation()
        objects.remove(at: idx)
        selectedID = nil
        return true
    }

    @discardableResult
    public func undo() -> Bool {
        guard let prev = undoStack.popLast() else { return false }
        redoStack.append(objects)
        objects = prev
        if let sel = selectedID, !objects.contains(where: { $0.id == sel }) {
            selectedID = nil
        }
        return true
    }

    @discardableResult
    public func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(objects)
        objects = next
        if let sel = selectedID, !objects.contains(where: { $0.id == sel }) {
            selectedID = nil
        }
        return true
    }

    public func clearAll() {
        objects.removeAll()
        selectedID = nil
        undoStack.removeAll()
        redoStack.removeAll()
    }

    public func nextMarkerNumber() -> Int {
        var maxNum = 0
        for obj in objects {
            if case .number(_, _, let n, _) = obj.kind {
                maxNum = max(maxNum, n)
            }
        }
        return maxNum + 1
    }

    /// Topmost object hitting `point` (back-to-front in z-order).
    public func hitTopmostObject(at point: ASPoint) -> AnnotationObject? {
        for obj in objects.reversed() {
            if obj.hitTestBody(point) {
                return obj
            }
        }
        return nil
    }
}
