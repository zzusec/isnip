import AppKit
import Carbon
import CoreGraphics
import AirSnipCore

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
public final class CaptureSessionCoordinator {
    public enum SessionMode {
        case normalCapture
        case directOCRCapture
        case inlinePinEdit(PinWindowController)
        case standaloneImageEdit(CGImage, Double, NSScreen)
    }

    public var isDirectOCRCapture: Bool {
        if case .directOCRCapture = mode { return true }
        return false
    }

    private var screenControllers: [OverlayScreenController] = []
    private(set) var config: AirSnipConfig
    public let mode: SessionMode

    public var onCompleteCopy: ((CGImage, Double) -> Void)?
    public var onCompleteSave: ((CGImage, Double, inout AirSnipConfig) -> Bool)?
    public var onCompletePin: ((CGImage, Double, CGPoint?) -> Void)?
    public var onStartOCR: ((CGImage, NSPoint?) -> Void)?
    public var onStartLongshot: ((NSScreen, ASRect, PixelBufferRGBA) -> Void)?
    public var onConfigMutated: ((AirSnipConfig) -> Void)?
    public var onSessionEnded: (() -> Void)?

    public init(config: AirSnipConfig, mode: SessionMode = .normalCapture) {
        self.config = config
        self.mode = mode
    }

    public var activeWindowNumbers: Set<Int> {
        Set(screenControllers.map { $0.panel.windowNumber })
    }

    public var hasVisibleWindows: Bool {
        screenControllers.contains { $0.panel.isVisible }
    }

    public var allPanelsPersistOnDeactivate: Bool {
        !screenControllers.isEmpty && screenControllers.allSatisfy { !$0.panel.hidesOnDeactivate }
    }

    public var allPanelsZeroAnimationAndExactFrame: Bool {
        !screenControllers.isEmpty && screenControllers.allSatisfy {
            $0.panel.animationBehavior == .none && $0.panel.frame == $0.expectedFrame
        }
    }

    public func renderToolbarVerificationSample(selection: ASRect) -> (toolbarIDs: [String], hasSecondaryBar: Bool, croppedImage: CGImage?)? {
        guard let ctrl = screenControllers.first else { return nil }
        return ctrl.canvasView.renderVerificationSample(selection: selection)
    }

    public func refocus() {
        screenControllers.first?.focusWindow()
    }

    public func startWithSnapshots(_ snapshots: [CapturedScreenSnapshot]) {
        guard !snapshots.isEmpty else {
            onSessionEnded?()
            return
        }

        let mouseGlobal = NSEvent.mouseLocation
        var targetController: OverlayScreenController?

        for snap in snapshots {
            let ctrl = OverlayScreenController(snapshot: snap, coordinator: self)
            screenControllers.append(ctrl)
            ctrl.show()
            if snap.frameInGlobalAppKit.contains(mouseGlobal) {
                targetController = ctrl
            }
        }
        (targetController ?? screenControllers.first)?.focusWindow()
    }

    public func startPinInlineEdit(pin: PinWindowController) {
        guard let screen = pin.window.screen ?? NSScreen.main ?? NSScreen.screens.first,
              let rawBuf = PixelBufferRGBA(cgImage: pin.cgImage) else {
            onSessionEnded?()
            return
        }
        // Build a synthetic full-screen snapshot with the pin's image placed at its current window position
        let sFrame = screen.frame
        let scale = pin.backingScale
        let fullW = max(1, Int((sFrame.width * CGFloat(scale)).rounded()))
        let fullH = max(1, Int((sFrame.height * CGFloat(scale)).rounded()))

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: fullW,
            height: fullH,
            bitsPerComponent: 8,
            bytesPerRow: fullW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            onSessionEnded?()
            return
        }

        ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: fullW, height: fullH))

        let pinFrame = pin.window.frame
        let drawW = CGFloat(rawBuf.width)
        let drawH = CGFloat(rawBuf.height)
        let localLeftPt = pinFrame.minX - sFrame.minX
        let localBottomPt = pinFrame.minY - sFrame.minY
        let cgDrawRect = CGRect(
            x: localLeftPt * CGFloat(scale),
            y: localBottomPt * CGFloat(scale),
            width: drawW,
            height: drawH
        )
        ctx.draw(pin.cgImage, in: cgDrawRect)

        guard let fullCG = ctx.makeImage(),
              let fullBuf = PixelBufferRGBA(cgImage: fullCG) else {
            onSessionEnded?()
            return
        }

        let selTopDown = ASRect(
            x: Double(localLeftPt),
            y: Double(sFrame.height - (localBottomPt + drawH / CGFloat(scale))),
            width: Double(drawW) / scale,
            height: Double(drawH) / scale
        )

        let snap = CapturedScreenSnapshot(
            screen: screen,
            frameInGlobalAppKit: sFrame,
            frameTopDown: ASRect(x: 0, y: 0, width: Double(sFrame.width), height: Double(sFrame.height)),
            cgImage: fullCG,
            rawBuffer: fullBuf,
            backingScale: scale,
            windowRectsLocalTopDown: []
        )

        pin.window.orderOut(nil)
        let ctrl = OverlayScreenController(snapshot: snap, coordinator: self, lockedInitialSelection: selTopDown)
        screenControllers.append(ctrl)
        ctrl.show()
        ctrl.focusWindow()
    }

    public func startStandaloneImageEdit(cgImage: CGImage, backingScale: Double, screen: NSScreen) {
        let sFrame = screen.frame
        let scale = max(1.0, backingScale)
        let fullW = max(1, Int((sFrame.width * CGFloat(scale)).rounded()))
        let fullH = max(1, Int((sFrame.height * CGFloat(scale)).rounded()))

        // Fit image nicely within 85% of screen if very tall (e.g., longshot)
        let maxPxW = Double(fullW) * 0.88
        let maxPxH = Double(fullH) * 0.82
        let fitRatio = min(1.0, min(maxPxW / Double(cgImage.width), maxPxH / Double(cgImage.height)))
        let dispPxW = max(16.0, (Double(cgImage.width) * fitRatio).rounded())
        let dispPxH = max(16.0, (Double(cgImage.height) * fitRatio).rounded())

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: fullW,
            height: fullH,
            bitsPerComponent: 8,
            bytesPerRow: fullW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            onSessionEnded?()
            return
        }

        ctx.setFillColor(CGColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: fullW, height: fullH))

        let drawX = ((Double(fullW) - dispPxW) * 0.5).rounded()
        let drawY = ((Double(fullH) - dispPxH) * 0.5).rounded()
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: drawX, y: drawY, width: dispPxW, height: dispPxH))

        guard let fullCG = ctx.makeImage(),
              let fullBuf = PixelBufferRGBA(cgImage: fullCG) else {
            onSessionEnded?()
            return
        }

        let selTopDown = ASRect(
            x: drawX / scale,
            y: (Double(fullH) - drawY - dispPxH) / scale,
            width: dispPxW / scale,
            height: dispPxH / scale
        )

        let snap = CapturedScreenSnapshot(
            screen: screen,
            frameInGlobalAppKit: sFrame,
            frameTopDown: ASRect(x: 0, y: 0, width: Double(sFrame.width), height: Double(sFrame.height)),
            cgImage: fullCG,
            rawBuffer: fullBuf,
            backingScale: scale,
            windowRectsLocalTopDown: []
        )

        let ctrl = OverlayScreenController(snapshot: snap, coordinator: self, lockedInitialSelection: selTopDown)
        screenControllers.append(ctrl)
        ctrl.show()
        ctrl.focusWindow()
    }

    func clearSelectionOnOtherScreens(except active: OverlayScreenController) {
        for c in screenControllers where c !== active {
            c.clearSelection()
        }
    }

    func mutateConfig(_ block: (inout AirSnipConfig) -> Void) {
        block(&config)
        try? config.save()
        onConfigMutated?(config)
    }

    func finishWithCopy(image: CGImage, scale: Double) {
        if case .inlinePinEdit(let pin) = mode {
            closeAllWindows()
            pin.updateImage(image)
            pin.show()
            onSessionEnded?()
            return
        }
        closeAllWindows()
        onCompleteCopy?(image, scale)
        onSessionEnded?()
    }

    func finishWithSave(image: CGImage, scale: Double) {
        // Hide overlay level temporarily so NSSavePanel appears cleanly above
        for c in screenControllers {
            c.panel.orderOut(nil)
        }
        var cfg = config
        let saved = onCompleteSave?(image, scale, &cfg) ?? false
        if saved {
            self.config = cfg
            if case .inlinePinEdit(let pin) = mode {
                pin.updateImage(image)
                pin.show()
            }
            closeAllWindows()
            onSessionEnded?()
        } else {
            // User cancelled save dialog -> restore overlay so work is not lost!
            for c in screenControllers {
                c.panel.makeKeyAndOrderFront(nil)
            }
        }
    }

    func finishWithPin(image: CGImage, scale: Double, appKitOrigin: CGPoint?) {
        if case .inlinePinEdit(let pin) = mode {
            closeAllWindows()
            pin.updateImage(image)
            pin.show()
            onSessionEnded?()
            return
        }
        closeAllWindows()
        onCompletePin?(image, scale, appKitOrigin)
        onSessionEnded?()
    }

    func finishWithOCR(rawImage: CGImage, anchorScreenPoint: NSPoint?) {
        if case .inlinePinEdit(let pin) = mode {
            pin.show()
        }
        closeAllWindows()
        onStartOCR?(rawImage, anchorScreenPoint)
        onSessionEnded?()
    }

    func finishIntoLongshot(screen: NSScreen, viewportTopDown: ASRect, initialCrop: PixelBufferRGBA) {
        closeAllWindows()
        onStartLongshot?(screen, viewportTopDown, initialCrop)
        onSessionEnded?()
    }

    public func cancelSession() {
        if case .inlinePinEdit(let pin) = mode {
            closeAllWindows()
            pin.show()
            onSessionEnded?()
            return
        }
        closeAllWindows()
        onSessionEnded?()
    }

    private func closeAllWindows() {
        for c in screenControllers {
            c.panel.orderOut(nil)
        }
        screenControllers.removeAll()
    }
}

@MainActor
final class OverlayScreenController {
    let panel: NSPanel
    let expectedFrame: CGRect
    let canvasView: OverlayCanvasView
    weak var coordinator: CaptureSessionCoordinator?

    init(
        snapshot: CapturedScreenSnapshot,
        coordinator: CaptureSessionCoordinator,
        lockedInitialSelection: ASRect? = nil
    ) {
        self.coordinator = coordinator
        self.expectedFrame = snapshot.frameInGlobalAppKit
        let p = OverlayPanel(
            contentRect: snapshot.frameInGlobalAppKit,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.animationBehavior = .none
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = false
        p.isOpaque = true
        p.hasShadow = false
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.acceptsMouseMovedEvents = true
        p.setFrame(snapshot.frameInGlobalAppKit, display: false)

        let view = OverlayCanvasView(
            frame: NSRect(origin: .zero, size: snapshot.frameInGlobalAppKit.size),
            snapshot: snapshot,
            coordinator: coordinator,
            lockedInitialSelection: lockedInitialSelection
        )
        p.contentView = view
        self.panel = p
        self.canvasView = view
        view.ownerController = self
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func focusWindow() {
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(canvasView)
    }

    func clearSelection() {
        canvasView.resetSelectionState()
    }
}

// MARK: - Interactive Overlay Canvas (Top-Down Flipped Coordinates)

@MainActor
final class OverlayCanvasView: NSView {
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    weak var ownerController: OverlayScreenController?
    weak var coordinator: CaptureSessionCoordinator?

    private var snapshot: CapturedScreenSnapshot
    private var selection: ASRect?
    private let selectionLocked: Bool
    private var hoveredWindowRect: ASRect?
    private var cursorPoint: ASPoint = ASPoint(200, 200)

    private let document = AnnotationDocument()
    private var activeTool: AnnotationTool? = nil
    private var activeColorIndex: Int
    private var fillEnabled: Bool = false
    private var currentLineWidth: Double
    private var currentBlurRadius: Double
    private var currentFontSize: Double
    private var currentNumberFontSize: Double = 20.0
    private var currentFontFamily: String
    private var textBold: Bool = false
    private var textItalic: Bool = false

    // Interaction state machine
    private enum DragOperation {
        case none
        case creatingSelection(origin: ASPoint, moved: Bool)
        case movingSelection(startMouse: ASPoint, initialRect: ASRect)
        case resizingSelection(handle: ResizeHandle, initialRect: ASRect)
        case drawingNewAnnotation(origin: ASPoint, draftObjectID: UUID?, freehandPts: [ASPoint], hitCandidateID: UUID?)
        case movingObject(id: UUID, lastPoint: ASPoint, undoRecorded: Bool)
        case resizingObject(id: UUID, handle: ResizeHandle, initialBox: ASRect, initialObject: AnnotationObject, undoRecorded: Bool)
        case adjustingCornerRadius(id: UUID, box: ASRect, undoRecorded: Bool)
        case adjustingCurveControl(id: UUID, controlIndex: Int, undoRecorded: Bool)
        case adjustingColorSV(swatchIndex: Int)
        case adjustingColorHue(swatchIndex: Int)
    }

    private var dragOp: DragOperation = .none
    private var spacePressed: Bool = false

    // Toolbar hit regions (recomputed each draw)
    struct ToolbarHitItem {
        let id: String
        let rect: CGRect
        let tooltip: String
        let action: () -> Void
        let doubleClickAction: (() -> Void)?
    }
    private var toolbarHitItems: [ToolbarHitItem] = []
    private var mainToolbarRect: CGRect = .zero
    private var secondRowRect: CGRect = .zero

    // Hover tooltip (EDT-10: 400ms delay)
    private var hoveredItemID: String?
    private var activeTooltip: (text: String, anchorRect: CGRect)?
    private var tooltipTask: Task<Void, Never>?

    // Custom HSV Color Picker Popover (EDT-7: double-click swatch)
    private struct ColorPickerState {
        var swatchIndex: Int
        var hue: Double
        var sat: Double
        var val: Double
        var panelRect: CGRect = .zero
        var svRect: CGRect = .zero
        var hueRect: CGRect = .zero
        var quickRects: [(CGRect, RGBAColor)] = []
    }
    private var colorPicker: ColorPickerState?

    // Inline native IME text editor & badge number editor
    private var activeTextScrollView: NSScrollView?
    private var activeTextEditor: NSTextView?
    private var editingTextObjectID: UUID?
    private var editingTextOrigin: ASPoint = ASPoint(0, 0)

    private var activeNumberField: NSTextField?
    private var editingNumberObjectID: UUID?

    // Double-Esc cancel guard (ADR 0027)
    private var lastCancelAttemptTime: TimeInterval = 0
    private var cancelConfirmBanner: String?
    private var cancelBannerTask: Task<Void, Never>?

    init(
        frame: NSRect,
        snapshot: CapturedScreenSnapshot,
        coordinator: CaptureSessionCoordinator,
        lockedInitialSelection: ASRect?
    ) {
        self.snapshot = snapshot
        self.coordinator = coordinator
        let cfg = coordinator.config
        self.activeTool = nil
        self.activeColorIndex = cfg.toolbar.settleColorIndex(cfg.activeColorIndex)
        self.currentLineWidth = cfg.defaultLineWidth
        self.currentBlurRadius = cfg.defaultBlurRadius
        self.currentFontSize = cfg.defaultFontSize
        self.currentFontFamily = cfg.defaultFontFamily
        self.selection = lockedInitialSelection
        self.selectionLocked = (lockedInitialSelection != nil)

        let globalMouse = NSEvent.mouseLocation
        let sf = snapshot.frameInGlobalAppKit
        let initX = max(0, min(Double(sf.width), Double(globalMouse.x - sf.minX)))
        let initY = max(0, min(Double(sf.height), Double(sf.maxY - globalMouse.y)))
        self.cursorPoint = ASPoint(initX, initY)

        super.init(frame: frame)

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    required init?(coder: NSCoder) { nil }

    func resetSelectionState() {
        guard !selectionLocked else { return }
        commitInlineEditorsIfNeeded()
        selection = nil
        activeTool = nil
        document.clearAll()
        colorPicker = nil
        needsDisplay = true
    }

    func renderVerificationSample(selection sel: ASRect) -> (toolbarIDs: [String], hasSecondaryBar: Bool, croppedImage: CGImage?) {
        self.selection = sel
        self.activeTool = nil
        self.needsDisplay = true
        var cropped: CGImage?
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            if let fullCG = rep.cgImage, mainToolbarRect != .zero {
                let scale = CGFloat(fullCG.width) / max(1, bounds.width)
                let cropPt = mainToolbarRect.insetBy(dx: -16, dy: -22)
                let clamped = cropPt.intersection(bounds)
                let pxRect = CGRect(
                    x: (clamped.minX * scale).rounded(),
                    y: (clamped.minY * scale).rounded(),
                    width: (clamped.width * scale).rounded(),
                    height: (clamped.height * scale).rounded()
                )
                cropped = fullCG.cropping(to: pxRect)
            }
        }
        return (toolbarHitItems.map(\.id), secondRowRect != .zero, cropped)
    }

    private var currentSwatchColor: RGBAColor {
        guard let cfg = coordinator?.config else { return ColorPalette.defaultSwatches[1] }
        let idx = max(0, min(cfg.swatchColors.count - 1, activeColorIndex))
        return cfg.swatchColors[idx]
    }

    private var isDarkTheme: Bool {
        guard let theme = coordinator?.config.theme else { return true }
        switch theme {
        case .dark: return true
        case .light: return false
        case .follow:
            let name = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            return name == .darkAqua
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 1. Draw frozen full-screen background upright in flipped coordinates
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(snapshot.cgImage, in: CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height))
        ctx.restoreGState()

        if let sel = selection, sel.width >= 1 && sel.height >= 1 {
            // 2. Dim outside selection
            ctx.saveGState()
            let dimPath = CGMutablePath()
            dimPath.addRect(bounds)
            dimPath.addRect(sel.cgRect)
            ctx.addPath(dimPath)
            ctx.clip(using: .evenOdd)
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.48))
            ctx.fill(bounds)
            ctx.restoreGState()

            // 3. Draw annotations clipped inside selection
            AnnotationRenderer.drawAnnotations(
                in: ctx,
                objects: document.objects,
                rawBuffer: snapshot.rawBuffer,
                rawOrigin: ASPoint(0, 0),
                pixelScale: snapshot.backingScale,
                clipBounds: sel
            )

            // 4. Selection border & 4 L-shaped corner brackets
            let accent = CGColor(srgbRed: 0.16, green: 0.68, blue: 0.98, alpha: 1.0)
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(1.4)
            ctx.stroke(sel.cgRect)
            if !selectionLocked {
                drawCornerBrackets(in: ctx, rect: sel.cgRect, color: accent)
            }

            // 5. Selected annotation gizmos
            if let selObj = document.selectedObject {
                AnnotationRenderer.drawSelectionGizmos(in: ctx, for: selObj)
            }

            // 6. Pixel dimension pill at top-left of selection
            let pxW = max(1, Int((sel.width * snapshot.backingScale).rounded()))
            let pxH = max(1, Int((sel.height * snapshot.backingScale).rounded()))
            drawDimensionPill(in: ctx, selection: sel, text: "\(pxW) × \(pxH)")

            // 7. Floating annotation toolbar + optional style sub-bar + color picker + tooltip
            if case .creatingSelection = dragOp {
                toolbarHitItems.removeAll()
            } else {
                drawFloatingToolbar(in: ctx, selection: sel)
                if colorPicker != nil {
                    drawColorPickerPopover(in: ctx)
                }
                if let tip = activeTooltip {
                    drawTooltipBubble(in: ctx, text: tip.text, anchor: tip.anchorRect)
                }
            }
        } else {
            toolbarHitItems.removeAll()
            // Unselected state: keep frozen screen completely still at 100% original brightness;
            // only dim outside a hovered floating window when window-snap highlights one.
            if let winRect = hoveredWindowRect, coordinator?.config.windowSnap == true {
                ctx.saveGState()
                let dimPath = CGMutablePath()
                dimPath.addRect(bounds)
                dimPath.addRect(winRect.cgRect)
                ctx.addPath(dimPath)
                ctx.clip(using: .evenOdd)
                ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28))
                ctx.fill(bounds)
                ctx.restoreGState()

                let snapAccent = CGColor(srgbRed: 0.16, green: 0.68, blue: 0.98, alpha: 0.95)
                ctx.setStrokeColor(snapAccent)
                ctx.setLineWidth(1.8)
                ctx.stroke(winRect.cgRect)
                drawCornerBrackets(in: ctx, rect: winRect.cgRect, color: snapAccent)

                let pxW = Int((winRect.width * snapshot.backingScale).rounded())
                let pxH = Int((winRect.height * snapshot.backingScale).rounded())
                drawDimensionPill(in: ctx, selection: winRect, text: "\(pxW) × \(pxH)")
            }

            drawMagnifierHUD(in: ctx, at: cursorPoint)

            if coordinator?.isDirectOCRCapture == true, cancelConfirmBanner == nil {
                drawCancelConfirmBanner(in: ctx, message: "OCR 文字识别模式：框选区域或单击窗口即可直接识别文字 · Esc 取消")
            }
        }

        if let banner = cancelConfirmBanner {
            drawCancelConfirmBanner(in: ctx, message: banner)
        }
    }

    private func drawCornerBrackets(in ctx: CGContext, rect: CGRect, color: CGColor) {
        let len = max(4, min(12, min(rect.width, rect.height) * 0.35))
        ctx.saveGState()
        ctx.setStrokeColor(color)
        ctx.setLineWidth(3.0)
        ctx.setLineCap(.square)
        ctx.setLineJoin(.miter)

        // Top-left
        ctx.move(to: CGPoint(x: rect.minX, y: rect.minY + len))
        ctx.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        ctx.addLine(to: CGPoint(x: rect.minX + len, y: rect.minY))
        // Top-right
        ctx.move(to: CGPoint(x: rect.maxX - len, y: rect.minY))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + len))
        // Bottom-right
        ctx.move(to: CGPoint(x: rect.maxX, y: rect.maxY - len))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        ctx.addLine(to: CGPoint(x: rect.maxX - len, y: rect.maxY))
        // Bottom-left
        ctx.move(to: CGPoint(x: rect.minX + len, y: rect.maxY))
        ctx.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        ctx.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - len))

        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawDimensionPill(in ctx: CGContext, selection: ASRect, text: String) {
        let scaleFactor = CGFloat(coordinator?.config.uiScale.factor ?? 1.0)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5 * scaleFactor, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let sz = (text as NSString).size(withAttributes: attrs)
        let w = sz.width + 14 * scaleFactor
        let h = sz.height + 6 * scaleFactor
        let x = max(6, min(bounds.width - w - 6, CGFloat(selection.minX)))
        let y = selection.minY >= Double(h + 8) ? CGFloat(selection.minY) - h - 5 : CGFloat(selection.minY) + 6
        let pillRect = CGRect(x: x, y: y, width: w, height: h)

        let path = CGPath(roundedRect: pillRect, cornerWidth: 5, cornerHeight: 5, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 0.82))
        ctx.fillPath()
        (text as NSString).draw(at: NSPoint(x: pillRect.minX + 7 * scaleFactor, y: pillRect.minY + 3 * scaleFactor), withAttributes: attrs)
    }

    private func drawMagnifierHUD(in ctx: CGContext, at point: ASPoint) {
        let pxX = max(0, min(snapshot.rawBuffer.width - 1, Int((point.x * snapshot.backingScale).rounded())))
        let pxY = max(0, min(snapshot.rawBuffer.height - 1, Int((point.y * snapshot.backingScale).rounded())))
        let centerColor = snapshot.rawBuffer.pixel(x: pxX, y: pxY)

        let gridCells = 11
        let cellSize: CGFloat = 10
        let gridSide = CGFloat(gridCells) * cellSize
        let cardW = gridSide + 16
        let cardH = gridSide + 64

        var ox = CGFloat(point.x) + 20
        var oy = CGFloat(point.y) + 20
        if ox + cardW > bounds.width - 8 { ox = CGFloat(point.x) - cardW - 20 }
        if oy + cardH > bounds.height - 8 { oy = CGFloat(point.y) - cardH - 20 }

        let cardRect = CGRect(x: ox, y: oy, width: cardW, height: cardH)
        ctx.saveGState()
        let bgPath = CGPath(roundedRect: cardRect, cornerWidth: 9, cornerHeight: 9, transform: nil)
        ctx.addPath(bgPath)
        ctx.setFillColor(CGColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 0.92))
        ctx.fillPath()
        ctx.addPath(bgPath)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16))
        ctx.setLineWidth(1)
        ctx.strokePath()

        let gx0 = cardRect.minX + 8
        let gy0 = cardRect.minY + 8
        let half = gridCells / 2
        for dy in -half...half {
            for dx in -half...half {
                let c = snapshot.rawBuffer.pixel(x: pxX + dx, y: pxY + dy)
                let r = CGRect(
                    x: gx0 + CGFloat(dx + half) * cellSize,
                    y: gy0 + CGFloat(dy + half) * cellSize,
                    width: cellSize,
                    height: cellSize
                )
                ctx.setFillColor(c.cgColor)
                ctx.fill(r)
                ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.08))
                ctx.setLineWidth(0.5)
                ctx.stroke(r)
            }
        }
        // Highlight center pixel
        let centerRect = CGRect(x: gx0 + CGFloat(half) * cellSize, y: gy0 + CGFloat(half) * cellSize, width: cellSize, height: cellSize)
        ctx.setStrokeColor(CGColor(srgbRed: 0.12, green: 0.60, blue: 1.0, alpha: 1.0))
        ctx.setLineWidth(1.8)
        ctx.stroke(centerRect)

        // Color swatch + coordinate + HEX
        let infoY = gy0 + gridSide + 7
        let swatchRect = CGRect(x: gx0, y: infoY + 1, width: 13, height: 13)
        ctx.setFillColor(centerColor.cgColor)
        ctx.fill(swatchRect)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5))
        ctx.setLineWidth(1)
        ctx.stroke(swatchRect)

        let monoFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold)
        let subFont = NSFont.systemFont(ofSize: 9.5, weight: .regular)
        let primaryAttrs: [NSAttributedString.Key: Any] = [.font: monoFont, .foregroundColor: NSColor.white]
        let secondaryAttrs: [NSAttributedString.Key: Any] = [.font: subFont, .foregroundColor: NSColor(calibratedWhite: 0.75, alpha: 1)]

        (centerColor.hexString as NSString).draw(at: NSPoint(x: gx0 + 18, y: infoY), withAttributes: primaryAttrs)
        ("(\(pxX), \(pxY))" as NSString).draw(at: NSPoint(x: gx0, y: infoY + 17), withAttributes: secondaryAttrs)
        ("C 复制HEX · ⇧C RGB" as NSString).draw(at: NSPoint(x: gx0, y: infoY + 32), withAttributes: secondaryAttrs)
        ctx.restoreGState()
    }

    // MARK: - Floating Toolbar & HSV Color Picker

    private enum ToolbarGlyph {
        case rect
        case ellipse
        case line
        case arrow
        case pen
        case mosaic
        case text
        case number
        case spotlight
        case pin
        case undo
        case ocr
        case cancel
        case longshot
        case save
        case copy
        case highlight
    }

    private func glyph(for tool: AnnotationTool) -> ToolbarGlyph {
        switch tool {
        case .rect:      return .rect
        case .ellipse:   return .ellipse
        case .line:      return .line
        case .arrow:     return .arrow
        case .freehand:  return .pen
        case .blur:      return .mosaic
        case .text:      return .text
        case .number:    return .number
        case .glow:      return .spotlight
        case .highlight: return .highlight
        }
    }

    private func drawFloatingToolbar(in ctx: CGContext, selection: ASRect) {
        toolbarHitItems.removeAll()
        mainToolbarRect = .zero
        secondRowRect = .zero

        guard let cfg = coordinator?.config else { return }
        let vis = cfg.toolbar
        if vis.isEntireToolbarHidden { return }

        let uis = CGFloat(cfg.uiScale.factor)
        let btnSide: CGFloat = 29 * uis
        let padX: CGFloat = 8 * uis
        let padY: CGFloat = 5 * uis
        let gap: CGFloat = 2.5 * uis
        let barH = btnSide + padY * 2

        let dark = isDarkTheme
        let barBg = dark
            ? CGColor(srgbRed: 0.14, green: 0.15, blue: 0.18, alpha: 0.96)
            : CGColor(srgbRed: 0.96, green: 0.97, blue: 0.98, alpha: 0.96)
        let barBorder = dark
            ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14)
            : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.12)
        let iconNormal = dark ? NSColor(calibratedWhite: 0.92, alpha: 1) : NSColor(calibratedWhite: 0.16, alpha: 1)
        let iconDisabled = dark ? NSColor(calibratedWhite: 0.42, alpha: 1) : NSColor(calibratedWhite: 0.65, alpha: 1)
        let badgeKnockout = dark
            ? NSColor(srgbRed: 0.14, green: 0.15, blue: 0.18, alpha: 1)
            : NSColor(srgbRed: 0.96, green: 0.97, blue: 0.98, alpha: 1)
        let hoverBg = dark
            ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10)
            : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.07)
        let activeBg = CGColor(srgbRed: 0.12, green: 0.53, blue: 0.94, alpha: 0.20)
        let activeAccent = NSColor(srgbRed: 0.12, green: 0.54, blue: 0.96, alpha: 1)

        struct BarButtonSpec {
            let id: String
            let glyph: ToolbarGlyph
            let selected: Bool
            let enabled: Bool
            let tooltip: String
            let action: () -> Void
        }

        // Exact 16-item single-pill layout:
        // □  ○  ╱  ↗  ✎  ▚  A  ①  ▣  📌  ↺  [OCR]  ✕  ↕  ↓  ✓
        var items: [BarButtonSpec] = []

        let orderedPrimaryTools: [AnnotationTool] = [
            .rect, .ellipse, .line, .arrow, .freehand, .blur, .text, .number, .glow
        ]
        for tool in orderedPrimaryTools where vis.isVisible(.tool(tool)) {
            let keyText = cfg.toolKeys.binding(for: tool).isUnbound ? "" : " · \(cfg.toolKeys.binding(for: tool).displayString)"
            items.append(BarButtonSpec(
                id: ToolbarSlot.tool(tool).key,
                glyph: glyph(for: tool),
                selected: activeTool == tool,
                enabled: true,
                tooltip: "\(tool.displayName)\(keyText)",
                action: { [weak self] in self?.selectTool(tool) }
            ))
        }

        if vis.isVisible(.pin), !selectionLocked {
            let pinKey = cfg.hotkeys.pin.isUnbound ? "" : " · \(cfg.hotkeys.pin.displayString)"
            items.append(BarButtonSpec(
                id: "output.pin",
                glyph: .pin,
                selected: false,
                enabled: true,
                tooltip: "贴图\(pinKey)",
                action: { [weak self] in self?.triggerPinOutput() }
            ))
        }

        if vis.isVisible(.undo) {
            items.append(BarButtonSpec(
                id: "edit.undo",
                glyph: .undo,
                selected: false,
                enabled: document.canUndo,
                tooltip: "撤销 · ⌘Z",
                action: { [weak self] in self?.performUndo() }
            ))
        }

        if vis.isVisible(.ocr) {
            let ocrKey = cfg.hotkeys.ocr.isUnbound ? "" : " · \(cfg.hotkeys.ocr.displayString)"
            items.append(BarButtonSpec(
                id: "output.ocr",
                glyph: .ocr,
                selected: false,
                enabled: true,
                tooltip: "OCR 文字识别\(ocrKey)",
                action: { [weak self] in self?.triggerOCR() }
            ))
        }

        items.append(BarButtonSpec(
            id: "file.cancel",
            glyph: .cancel,
            selected: false,
            enabled: true,
            tooltip: "取消截图 · Esc",
            action: { [weak self] in self?.attemptCancel() }
        ))

        if vis.isVisible(.longshot), !selectionLocked {
            let lsKey = cfg.hotkeys.longshot.isUnbound ? "" : " · \(cfg.hotkeys.longshot.displayString)"
            items.append(BarButtonSpec(
                id: "output.longshot",
                glyph: .longshot,
                selected: false,
                enabled: true,
                tooltip: "长截图\(lsKey)",
                action: { [weak self] in self?.triggerLongshot() }
            ))
        }

        if vis.isVisible(.save) {
            items.append(BarButtonSpec(
                id: "file.save",
                glyph: .save,
                selected: false,
                enabled: true,
                tooltip: "保存 · ⌘S",
                action: { [weak self] in self?.triggerSaveOutput() }
            ))
        }

        if vis.isVisible(.copy) {
            items.append(BarButtonSpec(
                id: "file.copy",
                glyph: .copy,
                selected: false,
                enabled: true,
                tooltip: "完成复制 · Enter",
                action: { [weak self] in self?.triggerCopyOutput() }
            ))
        }

        guard !items.isEmpty else { return }

        let totalWidth = padX * 2 + CGFloat(items.count) * btnSide + CGFloat(max(0, items.count - 1)) * gap
        var barX = CGFloat(selection.maxX) - totalWidth
        barX = max(8, min(bounds.width - totalWidth - 8, barX))

        let subMode = currentStyleSubBarMode(vis: vis)
        let secondRowH: CGFloat = (subMode == .none) ? 0 : (32 * uis)
        let totalStackH = barH + ((subMode == .none) ? 0 : (secondRowH + 5))

        var barY = CGFloat(selection.maxY) + 8
        if barY + totalStackH > bounds.height - 8 {
            let aboveY = CGFloat(selection.minY) - totalStackH - 8
            if aboveY >= 8 {
                barY = aboveY
            } else {
                barY = CGFloat(selection.maxY) - totalStackH - 8
            }
        }
        barY = max(8, min(bounds.height - barH - 8, barY))

        let barRect = CGRect(x: barX, y: barY, width: totalWidth, height: barH)
        mainToolbarRect = barRect

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 12, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.25))
        let barPath = CGPath(roundedRect: barRect, cornerWidth: 8.5 * uis, cornerHeight: 8.5 * uis, transform: nil)
        ctx.addPath(barPath)
        ctx.setFillColor(barBg)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.addPath(barPath)
        ctx.setStrokeColor(barBorder)
        ctx.setLineWidth(1)
        ctx.strokePath()

        var curX = barRect.minX + padX
        let itemY = barRect.minY + padY

        for item in items {
            let itemRect = CGRect(x: curX, y: itemY, width: btnSide, height: btnSide)
            if item.selected {
                let p = CGPath(roundedRect: itemRect, cornerWidth: 6 * uis, cornerHeight: 6 * uis, transform: nil)
                ctx.addPath(p)
                ctx.setFillColor(activeBg)
                ctx.fillPath()
            } else if hoveredItemID == item.id && item.enabled {
                let p = CGPath(roundedRect: itemRect, cornerWidth: 6 * uis, cornerHeight: 6 * uis, transform: nil)
                ctx.addPath(p)
                ctx.setFillColor(hoverBg)
                ctx.fillPath()
            }

            let tint = !item.enabled ? iconDisabled : (item.selected ? activeAccent : iconNormal)
            drawToolbarGlyph(item.glyph, in: ctx, rect: itemRect, uis: uis, color: tint, knockoutColor: badgeKnockout)

            let action = item.action
            let enabled = item.enabled
            toolbarHitItems.append(ToolbarHitItem(
                id: item.id,
                rect: itemRect,
                tooltip: item.tooltip,
                action: { if enabled { action() } },
                doubleClickAction: nil
            ))
            curX += btnSide + gap
        }

        if subMode != .none {
            drawStyleSubBar(
                in: ctx,
                mode: subMode,
                mainBar: barRect,
                height: secondRowH,
                uis: uis,
                dark: dark,
                barBg: barBg,
                barBorder: barBorder,
                textColor: iconNormal,
                cfg: cfg
            )
        }
    }

    private enum StyleSubBarMode: Equatable {
        case none
        case stroke(showFill: Bool)
        case blur
        case text
    }

    private func currentStyleSubBarMode(vis: ToolbarVisibilityConfig) -> StyleSubBarMode {
        if let selObj = document.selectedObject {
            switch selObj.kind {
            case .text:
                return vis.isVisible(.textRow) ? .text : .none
            case .blur:
                return .blur
            case .glow:
                return .none
            case .rect, .ellipse:
                return .stroke(showFill: vis.isVisible(.fill))
            default:
                return .stroke(showFill: false)
            }
        }
        guard let tool = activeTool else { return .none }
        switch tool {
        case .glow:
            return .none
        case .blur:
            return .blur
        case .text:
            return vis.isVisible(.textRow) ? .text : .stroke(showFill: false)
        case .rect, .ellipse:
            return .stroke(showFill: vis.isVisible(.fill))
        case .line, .arrow, .freehand, .number, .highlight:
            return .stroke(showFill: false)
        }
    }

    private func drawToolbarGlyph(
        _ glyph: ToolbarGlyph,
        in ctx: CGContext,
        rect: CGRect,
        uis: CGFloat,
        color: NSColor,
        knockoutColor: NSColor
    ) {
        let cx = rect.midX
        let cy = rect.midY
        let lw = 1.4 * uis

        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(lw)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch glyph {
        case .rect:
            let s = 14.2 * uis
            let r = CGRect(x: cx - s * 0.5, y: cy - s * 0.5, width: s, height: s)
            ctx.setLineJoin(.miter)
            ctx.stroke(r)

        case .ellipse:
            let s = 14.8 * uis
            ctx.strokeEllipse(in: CGRect(x: cx - s * 0.5, y: cy - s * 0.5, width: s, height: s))

        case .line:
            let d = 6.4 * uis
            ctx.move(to: CGPoint(x: cx - d, y: cy + d))
            ctx.addLine(to: CGPoint(x: cx + d, y: cy - d))
            ctx.strokePath()

        case .arrow:
            let d = 6.5 * uis
            ctx.move(to: CGPoint(x: cx - d, y: cy + d))
            ctx.addLine(to: CGPoint(x: cx + 3.6 * uis, y: cy - 3.6 * uis))
            ctx.strokePath()
            // Crisp solid triangular arrowhead at top-right
            let tip = CGPoint(x: cx + d, y: cy - d)
            let leftWing = CGPoint(x: cx + 1.0 * uis, y: cy - d + 0.4 * uis)
            let rightWing = CGPoint(x: cx + d - 0.4 * uis, y: cy - 1.0 * uis)
            ctx.move(to: tip)
            ctx.addLine(to: leftWing)
            ctx.addLine(to: rightWing)
            ctx.closePath()
            ctx.fillPath()

        case .pen:
            // 45° marker/pencil silhouette matching reference toolbar
            let pNib = CGPoint(x: cx - 6.8 * uis, y: cy + 6.8 * uis)
            let pLeft = CGPoint(x: cx - 6.5 * uis, y: cy + 3.4 * uis)
            let pTopLeft = CGPoint(x: cx + 3.4 * uis, y: cy - 6.5 * uis)
            let pTopRight = CGPoint(x: cx + 6.5 * uis, y: cy - 3.4 * uis)
            let pBottom = CGPoint(x: cx - 3.4 * uis, y: cy + 6.5 * uis)
            ctx.move(to: pNib)
            ctx.addLine(to: pLeft)
            ctx.addLine(to: pTopLeft)
            ctx.addLine(to: pTopRight)
            ctx.addLine(to: pBottom)
            ctx.closePath()
            ctx.strokePath()

        case .mosaic:
            // 2×2 checkerboard inside crisp square frame
            let s = 14.4 * uis
            let half = s * 0.5
            let x0 = cx - half
            let y0 = cy - half
            ctx.setLineWidth(1.25 * uis)
            ctx.setLineJoin(.miter)
            ctx.stroke(CGRect(x: x0, y: y0, width: s, height: s))
            ctx.fill(CGRect(x: x0, y: y0, width: half, height: half))
            ctx.fill(CGRect(x: cx, y: cy, width: half, height: half))

        case .text:
            let top = CGPoint(x: cx, y: cy - 7.0 * uis)
            let bl = CGPoint(x: cx - 5.8 * uis, y: cy + 6.8 * uis)
            let br = CGPoint(x: cx + 5.8 * uis, y: cy + 6.8 * uis)
            ctx.move(to: bl)
            ctx.addLine(to: top)
            ctx.addLine(to: br)
            let barY = cy + 2.2 * uis
            ctx.move(to: CGPoint(x: cx - 3.7 * uis, y: barY))
            ctx.addLine(to: CGPoint(x: cx + 3.7 * uis, y: barY))
            ctx.strokePath()

        case .number:
            let s = 16.0 * uis
            ctx.setLineWidth(1.25 * uis)
            ctx.strokeEllipse(in: CGRect(x: cx - s * 0.5, y: cy - s * 0.5, width: s, height: s))
            let font = NSFont(name: "TimesNewRomanPS-BoldMT", size: 11.2 * uis)
                ?? NSFont.systemFont(ofSize: 10.8 * uis, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let str: NSString = "1"
            let sz = str.size(withAttributes: attrs)
            str.draw(at: NSPoint(x: cx - sz.width * 0.5, y: cy - sz.height * 0.5), withAttributes: attrs)

        case .spotlight:
            let outer = 14.4 * uis
            let inner = 6.4 * uis
            ctx.setLineWidth(1.3 * uis)
            ctx.setLineJoin(.miter)
            ctx.stroke(CGRect(x: cx - outer * 0.5, y: cy - outer * 0.5, width: outer, height: outer))
            ctx.stroke(CGRect(x: cx - inner * 0.5, y: cy - inner * 0.5, width: inner, height: inner))

        case .pin:
            // Symmetric pushpin rotated +45° so head is top-right and needle points bottom-left
            ctx.translateBy(x: cx, y: cy)
            ctx.rotate(by: .pi / 4.0)
            let path = CGMutablePath()
            // Top cap flange
            path.move(to: CGPoint(x: -3.6 * uis, y: -7.0 * uis))
            path.addLine(to: CGPoint(x: 3.6 * uis, y: -7.0 * uis))
            path.addLine(to: CGPoint(x: 3.6 * uis, y: -5.2 * uis))
            // Waist
            path.addLine(to: CGPoint(x: 2.1 * uis, y: -4.6 * uis))
            path.addLine(to: CGPoint(x: 2.5 * uis, y: -0.6 * uis))
            // Lower collar
            path.addLine(to: CGPoint(x: 4.8 * uis, y: 1.4 * uis))
            path.addLine(to: CGPoint(x: -4.8 * uis, y: 1.4 * uis))
            path.addLine(to: CGPoint(x: -2.5 * uis, y: -0.6 * uis))
            path.addLine(to: CGPoint(x: -2.1 * uis, y: -4.6 * uis))
            path.addLine(to: CGPoint(x: -3.6 * uis, y: -5.2 * uis))
            path.closeSubpath()
            ctx.addPath(path)
            ctx.fillPath()
            // Needle
            ctx.setLineWidth(1.5 * uis)
            ctx.move(to: CGPoint(x: 0, y: 1.4 * uis))
            ctx.addLine(to: CGPoint(x: 0, y: 7.4 * uis))
            ctx.strokePath()

        case .undo:
            let r = 6.2 * uis
            let aStart = -0.78 * CGFloat.pi
            let aEnd = 0.72 * CGFloat.pi
            var first = true
            var a = aStart
            while a <= aEnd + 0.001 {
                let pt = CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
                if first {
                    ctx.move(to: pt)
                    first = false
                } else {
                    ctx.addLine(to: pt)
                }
                a += 0.08
            }
            ctx.strokePath()
            // Arrowhead at start of counter-clockwise arc (upper-left pointing down-left)
            let tip = CGPoint(x: cx + r * cos(aStart), y: cy + r * sin(aStart))
            ctx.move(to: CGPoint(x: tip.x - 0.5 * uis, y: tip.y - 3.4 * uis))
            ctx.addLine(to: tip)
            ctx.addLine(to: CGPoint(x: tip.x + 3.4 * uis, y: tip.y - 0.4 * uis))
            ctx.strokePath()

        case .ocr:
            let bw = 22.0 * uis
            let bh = 15.0 * uis
            let badgeRect = CGRect(x: cx - bw * 0.5, y: cy - bh * 0.5, width: bw, height: bh)
            let bp = CGPath(roundedRect: badgeRect, cornerWidth: 3.8 * uis, cornerHeight: 3.8 * uis, transform: nil)
            ctx.addPath(bp)
            ctx.fillPath()
            let font = NSFont.systemFont(ofSize: 8.4 * uis, weight: .heavy)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: knockoutColor,
                .kern: -0.2 * uis
            ]
            let str: NSString = "OCR"
            let sz = str.size(withAttributes: attrs)
            str.draw(at: NSPoint(x: cx - sz.width * 0.5, y: cy - sz.height * 0.5), withAttributes: attrs)

        case .cancel:
            let d = 5.8 * uis
            ctx.move(to: CGPoint(x: cx - d, y: cy - d))
            ctx.addLine(to: CGPoint(x: cx + d, y: cy + d))
            ctx.move(to: CGPoint(x: cx + d, y: cy - d))
            ctx.addLine(to: CGPoint(x: cx - d, y: cy + d))
            ctx.strokePath()

        case .longshot:
            let bw = 7.8 * uis
            let bh = 9.4 * uis
            let box = CGRect(x: cx - bw * 0.5, y: cy - bh * 0.5, width: bw, height: bh)
            ctx.setLineWidth(1.25 * uis)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: 1.5 * uis, cornerHeight: 1.5 * uis, transform: nil))
            ctx.strokePath()
            // Top chevron ^
            ctx.move(to: CGPoint(x: cx - 3.0 * uis, y: cy - 6.6 * uis))
            ctx.addLine(to: CGPoint(x: cx, y: cy - 9.0 * uis))
            ctx.addLine(to: CGPoint(x: cx + 3.0 * uis, y: cy - 6.6 * uis))
            // Bottom chevron v
            ctx.move(to: CGPoint(x: cx - 3.0 * uis, y: cy + 6.6 * uis))
            ctx.addLine(to: CGPoint(x: cx, y: cy + 9.0 * uis))
            ctx.addLine(to: CGPoint(x: cx + 3.0 * uis, y: cy + 6.6 * uis))
            ctx.strokePath()

        case .save:
            // Tray [ _ ]
            ctx.move(to: CGPoint(x: cx - 6.8 * uis, y: cy + 3.0 * uis))
            ctx.addLine(to: CGPoint(x: cx - 6.8 * uis, y: cy + 6.8 * uis))
            ctx.addLine(to: CGPoint(x: cx + 6.8 * uis, y: cy + 6.8 * uis))
            ctx.addLine(to: CGPoint(x: cx + 6.8 * uis, y: cy + 3.0 * uis))
            // Vertical arrow stem
            ctx.move(to: CGPoint(x: cx, y: cy - 7.0 * uis))
            ctx.addLine(to: CGPoint(x: cx, y: cy + 1.8 * uis))
            ctx.strokePath()
            // Solid downward arrowhead
            ctx.move(to: CGPoint(x: cx - 3.4 * uis, y: cy + 0.6 * uis))
            ctx.addLine(to: CGPoint(x: cx + 3.4 * uis, y: cy + 0.6 * uis))
            ctx.addLine(to: CGPoint(x: cx, y: cy + 4.5 * uis))
            ctx.closePath()
            ctx.fillPath()

        case .copy:
            ctx.setLineWidth(1.55 * uis)
            ctx.move(to: CGPoint(x: cx - 6.8 * uis, y: cy + 0.8 * uis))
            ctx.addLine(to: CGPoint(x: cx - 1.8 * uis, y: cy + 6.0 * uis))
            ctx.addLine(to: CGPoint(x: cx + 7.0 * uis, y: cy - 5.4 * uis))
            ctx.strokePath()

        case .highlight:
            drawSymbol("highlighter", in: rect, pointSize: 13.5 * uis, color: color)
        }

        ctx.restoreGState()
    }

    private var isTextObjectSelected: Bool {
        if let obj = document.selectedObject, case .text = obj.kind { return true }
        return false
    }

    private func drawStyleSubBar(
        in ctx: CGContext,
        mode: StyleSubBarMode,
        mainBar: CGRect,
        height: CGFloat,
        uis: CGFloat,
        dark: Bool,
        barBg: CGColor,
        barBorder: CGColor,
        textColor: NSColor,
        cfg: AirSnipConfig
    ) {
        let vis = cfg.toolbar
        let visibleSwatchIndices = (0..<ColorPalette.swatchCount).filter { vis.isVisible(.color($0)) }
        let swatchSlot: CGFloat = 24 * uis
        let swatchGap: CGFloat = 3 * uis
        let swatchesW: CGFloat = visibleSwatchIndices.isEmpty
            ? 0
            : (CGFloat(visibleSwatchIndices.count) * swatchSlot + CGFloat(visibleSwatchIndices.count - 1) * swatchGap)

        let rowW: CGFloat
        switch mode {
        case .none:
            return
        case .blur:
            rowW = 108 * uis
        case .stroke(let showFill):
            let leftW: CGFloat = (3 * 24 + 2 * 3 + (showFill ? 30 : 0)) * uis
            rowW = 14 * uis + leftW + (swatchesW > 0 ? (12 * uis + swatchesW) : 0)
        case .text:
            let textControlsW: CGFloat = 278 * uis
            rowW = textControlsW + (swatchesW > 0 ? (12 * uis + swatchesW + 6 * uis) : 0)
        }

        let rowX = max(8, min(bounds.width - rowW - 8, mainBar.minX))
        let rowY = (mainBar.maxY + height + 5 <= bounds.height - 6)
            ? (mainBar.maxY + 5)
            : (mainBar.minY - height - 5)
        let rect = CGRect(x: rowX, y: rowY, width: rowW, height: height)
        secondRowRect = rect

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 8, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.20))
        let path = CGPath(roundedRect: rect, cornerWidth: 7.5 * uis, cornerHeight: 7.5 * uis, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(barBg)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.addPath(path)
        ctx.setStrokeColor(barBorder)
        ctx.setLineWidth(1)
        ctx.strokePath()

        let activeBg = CGColor(srgbRed: 0.12, green: 0.53, blue: 0.94, alpha: 0.22)
        let activeDot = CGColor(srgbRed: 0.14, green: 0.56, blue: 0.98, alpha: 1)
        var curX = rect.minX + 7 * uis

        switch mode {
        case .none:
            break

        case .blur:
            let presets: [(Double, CGFloat, String)] = [(8, 3.0, "细颗粒"), (16, 4.6, "标准"), (28, 6.4, "强模糊")]
            let activeBlur: Double = {
                if let obj = document.selectedObject, case .blur(_, _, let br, _) = obj.kind { return br }
                return currentBlurRadius
            }()
            for (idx, preset) in presets.enumerated() {
                let bRect = CGRect(x: curX, y: rect.minY + 4 * uis, width: 28 * uis, height: height - 8 * uis)
                let isSel = abs(activeBlur - preset.0) < 3.5
                if isSel {
                    ctx.addPath(CGPath(roundedRect: bRect, cornerWidth: 5 * uis, cornerHeight: 5 * uis, transform: nil))
                    ctx.setFillColor(activeBg)
                    ctx.fillPath()
                }
                let r = preset.1 * uis
                ctx.setFillColor(isSel ? activeDot : textColor.cgColor)
                ctx.fillEllipse(in: CGRect(x: bRect.midX - r, y: bRect.midY - r, width: r * 2, height: r * 2))
                let val = preset.0
                toolbarHitItems.append(ToolbarHitItem(
                    id: "blur.preset.\(idx)",
                    rect: bRect,
                    tooltip: preset.2,
                    action: { [weak self] in self?.selectBlurRadiusPreset(val) },
                    doubleClickAction: nil
                ))
                curX += 31 * uis
            }

        case .stroke(let showFill):
            let presets: [(Double, CGFloat, String)] = [(2, 2.2, "细线"), (4, 3.8, "中线"), (8, 5.6, "粗线")]
            let activeWidth: Double = document.selectedObject?.style.lineWidth ?? currentLineWidth
            for (idx, preset) in presets.enumerated() {
                let bRect = CGRect(x: curX, y: rect.minY + 4 * uis, width: 24 * uis, height: height - 8 * uis)
                let isSel = abs(activeWidth - preset.0) < 1.2
                if isSel {
                    ctx.addPath(CGPath(roundedRect: bRect, cornerWidth: 5 * uis, cornerHeight: 5 * uis, transform: nil))
                    ctx.setFillColor(activeBg)
                    ctx.fillPath()
                }
                let r = preset.1 * uis
                ctx.setFillColor(isSel ? activeDot : textColor.cgColor)
                ctx.fillEllipse(in: CGRect(x: bRect.midX - r, y: bRect.midY - r, width: r * 2, height: r * 2))
                let val = preset.0
                toolbarHitItems.append(ToolbarHitItem(
                    id: "stroke.preset.\(idx)",
                    rect: bRect,
                    tooltip: preset.2,
                    action: { [weak self] in self?.selectLineWidthPreset(val) },
                    doubleClickAction: nil
                ))
                curX += 27 * uis
            }

            if showFill {
                let isFilledNow: Bool = {
                    if let selObj = document.selectedObject {
                        switch selObj.kind {
                        case .rect(_, _, _, let f), .ellipse(_, _, let f): return f
                        default: break
                        }
                    }
                    return fillEnabled
                }()
                let fRect = CGRect(x: curX + 2 * uis, y: rect.minY + 4 * uis, width: 25 * uis, height: height - 8 * uis)
                if isFilledNow {
                    ctx.addPath(CGPath(roundedRect: fRect, cornerWidth: 5 * uis, cornerHeight: 5 * uis, transform: nil))
                    ctx.setFillColor(activeBg)
                    ctx.fillPath()
                }
                drawSymbol(isFilledNow ? "square.fill" : "square.dotted", in: fRect, pointSize: 12 * uis, color: textColor)
                toolbarHitItems.append(ToolbarHitItem(
                    id: "edit.fill",
                    rect: fRect,
                    tooltip: "填充开关",
                    action: { [weak self] in self?.toggleFill() },
                    doubleClickAction: nil
                ))
                curX = fRect.maxX + 3 * uis
            }

            if !visibleSwatchIndices.isEmpty {
                let sepX = curX + 4 * uis
                ctx.setStrokeColor(barBorder)
                ctx.setLineWidth(1)
                ctx.move(to: CGPoint(x: sepX, y: rect.minY + 7 * uis))
                ctx.addLine(to: CGPoint(x: sepX, y: rect.maxY - 7 * uis))
                ctx.strokePath()
                curX = sepX + 6 * uis
                drawInlineSwatches(in: ctx, indices: visibleSwatchIndices, startX: curX, rowRect: rect, slotSide: swatchSlot, gap: swatchGap, uis: uis, cfg: cfg)
            }

        case .text:
            let effectiveState = currentEffectiveTextAttributes
            let fontBtnRect = CGRect(x: rect.minX + 6 * uis, y: rect.minY + 3 * uis, width: 112 * uis, height: height - 6 * uis)
            let fp = CGPath(roundedRect: fontBtnRect, cornerWidth: 5 * uis, cornerHeight: 5 * uis, transform: nil)
            ctx.addPath(fp)
            ctx.setFillColor(dark ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.07) : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.05))
            ctx.fillPath()

            let labelFont = NSFont.systemFont(ofSize: 11.5 * uis, weight: .medium)
            let attrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: textColor]
            let shortFam = effectiveState.family.count > 11 ? String(effectiveState.family.prefix(11)) + "…" : effectiveState.family
            ("\(shortFam) ▾" as NSString).draw(at: NSPoint(x: fontBtnRect.minX + 7 * uis, y: fontBtnRect.minY + 4 * uis), withAttributes: attrs)
            toolbarHitItems.append(ToolbarHitItem(
                id: "text.family",
                rect: fontBtnRect,
                tooltip: "切换字体",
                action: { [weak self] in self?.popFontMenu(from: fontBtnRect) },
                doubleClickAction: nil
            ))

            let bRect = CGRect(x: fontBtnRect.maxX + 5 * uis, y: rect.minY + 3 * uis, width: 25 * uis, height: height - 6 * uis)
            if effectiveState.bold {
                ctx.setFillColor(activeBg)
                ctx.addPath(CGPath(roundedRect: bRect, cornerWidth: 5 * uis, cornerHeight: 5 * uis, transform: nil))
                ctx.fillPath()
            }
            drawSymbol("bold", in: bRect, pointSize: 11.5 * uis, color: textColor)
            toolbarHitItems.append(ToolbarHitItem(id: "text.bold", rect: bRect, tooltip: "粗体", action: { [weak self] in self?.toggleBold() }, doubleClickAction: nil))

            let iRect = CGRect(x: bRect.maxX + 3 * uis, y: rect.minY + 3 * uis, width: 25 * uis, height: height - 6 * uis)
            if effectiveState.italic {
                ctx.setFillColor(activeBg)
                ctx.addPath(CGPath(roundedRect: iRect, cornerWidth: 5 * uis, cornerHeight: 5 * uis, transform: nil))
                ctx.fillPath()
            }
            drawSymbol("italic", in: iRect, pointSize: 11.5 * uis, color: textColor)
            toolbarHitItems.append(ToolbarHitItem(id: "text.italic", rect: iRect, tooltip: "斜体", action: { [weak self] in self?.toggleItalic() }, doubleClickAction: nil))

            let minusRect = CGRect(x: iRect.maxX + 6 * uis, y: rect.minY + 3 * uis, width: 22 * uis, height: height - 6 * uis)
            drawSymbol("minus", in: minusRect, pointSize: 10.5 * uis, color: textColor)
            toolbarHitItems.append(ToolbarHitItem(id: "text.size.down", rect: minusRect, tooltip: "减小字号", action: { [weak self] in self?.stepFontSize(-2) }, doubleClickAction: nil))

            let sizeStr = "\(Int(effectiveState.size.rounded()))px"
            let szRect = CGRect(x: minusRect.maxX + 1 * uis, y: rect.minY + 6 * uis, width: 38 * uis, height: height - 10 * uis)
            (sizeStr as NSString).draw(at: NSPoint(x: szRect.minX + 3 * uis, y: szRect.minY), withAttributes: attrs)

            let plusRect = CGRect(x: szRect.maxX + 1 * uis, y: rect.minY + 3 * uis, width: 22 * uis, height: height - 6 * uis)
            drawSymbol("plus", in: plusRect, pointSize: 10.5 * uis, color: textColor)
            toolbarHitItems.append(ToolbarHitItem(id: "text.size.up", rect: plusRect, tooltip: "增大字号", action: { [weak self] in self?.stepFontSize(2) }, doubleClickAction: nil))

            if !visibleSwatchIndices.isEmpty {
                let sepX = plusRect.maxX + 6 * uis
                ctx.setStrokeColor(barBorder)
                ctx.setLineWidth(1)
                ctx.move(to: CGPoint(x: sepX, y: rect.minY + 7 * uis))
                ctx.addLine(to: CGPoint(x: sepX, y: rect.maxY - 7 * uis))
                ctx.strokePath()
                drawInlineSwatches(
                    in: ctx,
                    indices: visibleSwatchIndices,
                    startX: sepX + 6 * uis,
                    rowRect: rect,
                    slotSide: swatchSlot,
                    gap: swatchGap,
                    uis: uis,
                    cfg: cfg
                )
            }
        }
    }

    private func drawInlineSwatches(
        in ctx: CGContext,
        indices: [Int],
        startX: CGFloat,
        rowRect: CGRect,
        slotSide: CGFloat,
        gap: CGFloat,
        uis: CGFloat,
        cfg: AirSnipConfig
    ) {
        var sx = startX
        let slotY = rowRect.midY - slotSide * 0.5
        let swSide = 16 * uis
        for idx in indices {
            let itemRect = CGRect(x: sx, y: slotY, width: slotSide, height: slotSide)
            let swRect = CGRect(
                x: itemRect.midX - swSide * 0.5,
                y: itemRect.midY - swSide * 0.5,
                width: swSide,
                height: swSide
            )
            let col = cfg.swatchColors[idx]
            if activeColorIndex == idx {
                let ring = swRect.insetBy(dx: -2.6 * uis, dy: -2.6 * uis)
                let rp = CGPath(roundedRect: ring, cornerWidth: 5 * uis, cornerHeight: 5 * uis, transform: nil)
                ctx.addPath(rp)
                ctx.setStrokeColor(CGColor(srgbRed: 0.16, green: 0.56, blue: 0.98, alpha: 1))
                ctx.setLineWidth(1.6)
                ctx.strokePath()
            }
            let sp = CGPath(roundedRect: swRect, cornerWidth: 3.8 * uis, cornerHeight: 3.8 * uis, transform: nil)
            ctx.addPath(sp)
            ctx.setFillColor(col.cgColor)
            ctx.fillPath()
            ctx.addPath(sp)
            ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.24))
            ctx.setLineWidth(1)
            ctx.strokePath()

            toolbarHitItems.append(ToolbarHitItem(
                id: "swatch.\(idx)",
                rect: itemRect,
                tooltip: "单击选色 · 双击自定义取色",
                action: { [weak self] in self?.selectColorSwatch(idx) },
                doubleClickAction: { [weak self] in self?.openColorPicker(for: idx, anchorRect: itemRect) }
            ))
            sx += slotSide + gap
        }
    }

    private func drawColorPickerPopover(in ctx: CGContext) {
        guard var picker = colorPicker else { return }
        let pw: CGFloat = 212
        let ph: CGFloat = 192
        let anchorBar = (secondRowRect != .zero) ? secondRowRect : mainToolbarRect
        let swatchItem = toolbarHitItems.first(where: { $0.id == "swatch.\(picker.swatchIndex)" })?.rect ?? anchorBar
        var px = swatchItem.midX - pw * 0.5
        px = max(8, min(bounds.width - pw - 8, px))
        let stackBottom = max(mainToolbarRect.maxY, secondRowRect.maxY)
        let stackTop = (secondRowRect != .zero) ? min(mainToolbarRect.minY, secondRowRect.minY) : mainToolbarRect.minY
        var py = stackBottom + 6
        if py + ph > bounds.height - 8 {
            py = max(8, stackTop - ph - 6)
        }

        let panelRect = CGRect(x: px, y: py, width: pw, height: ph)
        picker.panelRect = panelRect

        let dark = isDarkTheme
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 14, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.34))
        let bgPath = CGPath(roundedRect: panelRect, cornerWidth: 10, cornerHeight: 10, transform: nil)
        ctx.addPath(bgPath)
        ctx.setFillColor(dark ? CGColor(srgbRed: 0.15, green: 0.16, blue: 0.19, alpha: 0.98) : CGColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 0.98))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.addPath(bgPath)
        ctx.setStrokeColor(dark ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16) : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.14))
        ctx.setLineWidth(1)
        ctx.strokePath()

        // 1. Saturation-Value 2D square
        let svRect = CGRect(x: panelRect.minX + 12, y: panelRect.minY + 12, width: pw - 24, height: 96)
        picker.svRect = svRect
        let cols = 32
        let rows = 18
        let cw = svRect.width / CGFloat(cols)
        let ch = svRect.height / CGFloat(rows)
        for ry in 0..<rows {
            let v = 1.0 - Double(ry) / Double(rows - 1)
            for cx in 0..<cols {
                let s = Double(cx) / Double(cols - 1)
                let c = ColorPalette.hsvToRGB(h: picker.hue, s: s, v: v)
                ctx.setFillColor(c.cgColor)
                ctx.fill(CGRect(x: svRect.minX + CGFloat(cx) * cw, y: svRect.minY + CGFloat(ry) * ch, width: cw + 0.6, height: ch + 0.6))
            }
        }
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.25))
        ctx.stroke(svRect)

        // SV indicator circle
        let knobX = svRect.minX + CGFloat(picker.sat) * svRect.width
        let knobY = svRect.minY + CGFloat(1.0 - picker.val) * svRect.height
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: CGRect(x: knobX - 5, y: knobY - 5, width: 10, height: 10))

        // 2. Hue rainbow slider
        let hueRect = CGRect(x: svRect.minX, y: svRect.maxY + 10, width: svRect.width, height: 12)
        picker.hueRect = hueRect
        let hSteps = 48
        let hw = hueRect.width / CGFloat(hSteps)
        for i in 0..<hSteps {
            let h = Double(i) / Double(hSteps) * 360.0
            ctx.setFillColor(ColorPalette.hsvToRGB(h: h, s: 1.0, v: 1.0).cgColor)
            ctx.fill(CGRect(x: hueRect.minX + CGFloat(i) * hw, y: hueRect.minY, width: hw + 0.6, height: hueRect.height))
        }
        let hueKnobX = hueRect.minX + CGFloat(picker.hue / 360.0) * hueRect.width
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.setLineWidth(2)
        ctx.stroke(CGRect(x: hueKnobX - 3, y: hueRect.minY - 2, width: 6, height: hueRect.height + 4))

        // 3. Quick swatches (2 rows x 6 cols, matching AirSnip `QUICK`)
        var quickRects: [(CGRect, RGBAColor)] = []
        let qTop = hueRect.maxY + 10
        let qSide: CGFloat = 20
        let qGapX = (svRect.width - qSide * 6) / 5.0
        for (idx, qc) in ColorPalette.quickColors.enumerated() {
            let r = idx / 6
            let c = idx % 6
            let qr = CGRect(
                x: svRect.minX + CGFloat(c) * (qSide + qGapX),
                y: qTop + CGFloat(r) * (qSide + 6),
                width: qSide,
                height: qSide
            )
            let qp = CGPath(roundedRect: qr, cornerWidth: 4, cornerHeight: 4, transform: nil)
            ctx.addPath(qp)
            ctx.setFillColor(qc.cgColor)
            ctx.fillPath()
            ctx.addPath(qp)
            ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.25))
            ctx.setLineWidth(1)
            ctx.strokePath()
            quickRects.append((qr, qc))
        }
        picker.quickRects = quickRects
        self.colorPicker = picker
    }

    private func drawTooltipBubble(in ctx: CGContext, text: String, anchor: CGRect) {
        let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let sz = (text as NSString).size(withAttributes: attrs)
        let w = sz.width + 14
        let h = sz.height + 7
        let x = max(6, min(bounds.width - w - 6, anchor.midX - w * 0.5))
        var y = anchor.maxY + 7
        if y + h > bounds.height - 6 {
            y = anchor.minY - h - 7
        }
        let rect = CGRect(x: x, y: y, width: w, height: h)
        let path = CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 0.90))
        ctx.fillPath()
        (text as NSString).draw(at: NSPoint(x: rect.minX + 7, y: rect.minY + 3.5), withAttributes: attrs)
    }

    private func drawCancelConfirmBanner(in ctx: CGContext, message: String) {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let sz = (message as NSString).size(withAttributes: attrs)
        let w = sz.width + 26
        let h = sz.height + 12
        let rect = CGRect(x: bounds.midX - w * 0.5, y: 28, width: w, height: h)
        let path = CGPath(roundedRect: rect, cornerWidth: h * 0.5, cornerHeight: h * 0.5, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 0.90))
        ctx.fillPath()
        (message as NSString).draw(at: NSPoint(x: rect.minX + 13, y: rect.minY + 6), withAttributes: attrs)
    }

    private func drawSymbol(_ name: String, in rect: CGRect, pointSize: CGFloat, color: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        guard let baseImg = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
            return
        }
        let img = (baseImg.copy() as? NSImage) ?? baseImg
        img.isTemplate = false
        let imgSize = img.size
        let drawRect = CGRect(
            x: rect.midX - imgSize.width * 0.5,
            y: rect.midY - imgSize.height * 0.5,
            width: imgSize.width,
            height: imgSize.height
        )
        // Tint symbol cleanly
        let tinted = NSImage(size: imgSize, flipped: false) { r in
            baseImg.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: drawRect)
    }

    // MARK: - Mouse Events & Direct Manipulation

    override func mouseMoved(with event: NSEvent) {
        let pt = ASPoint(convert(event.locationInWindow, from: nil))
        cursorPoint = pt

        if selection == nil {
            if coordinator?.config.windowSnap == true {
                hoveredWindowRect = snapshot.windowRectsLocalTopDown.first(where: { $0.contains(pt) })
            } else {
                hoveredWindowRect = nil
            }
            needsDisplay = true
            return
        }

        // Toolbar hover & 400ms tooltip (EDT-10)
        if let hit = toolbarHitItems.first(where: { $0.rect.contains(pt.cgPoint) }) {
            if hoveredItemID != hit.id {
                hoveredItemID = hit.id
                activeTooltip = nil
                tooltipTask?.cancel()
                let tipText = hit.tooltip
                let anchor = hit.rect
                tooltipTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard !Task.isCancelled else { return }
                    self?.activeTooltip = (tipText, anchor)
                    self?.needsDisplay = true
                }
                needsDisplay = true
            }
        } else if let selObj = document.selectedObject,
                  let cp = selObj.cornerHandlePoint,
                  pt.distance(to: cp) <= 8.0 {
            if hoveredItemID != "gizmo.corner" {
                hoveredItemID = "gizmo.corner"
                tooltipTask?.cancel()
                let anchor = CGRect(x: cp.x - 5, y: cp.y - 5, width: 10, height: 10)
                tooltipTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard !Task.isCancelled else { return }
                    self?.activeTooltip = ("拖动调整圆角", anchor)
                    self?.needsDisplay = true
                }
            }
        } else if hoveredItemID != nil {
            hoveredItemID = nil
            activeTooltip = nil
            tooltipTask?.cancel()
            needsDisplay = true
        }

        updateCursor(at: pt, flags: event.modifierFlags)
    }

    private func updateCursor(at pt: ASPoint, flags: NSEvent.ModifierFlags) {
        if toolbarHitItems.contains(where: { $0.rect.contains(pt.cgPoint) }) {
            NSCursor.pointingHand.set()
            return
        }
        if let picker = colorPicker, picker.panelRect.contains(pt.cgPoint) {
            NSCursor.crosshair.set()
            return
        }
        guard let sel = selection else {
            NSCursor.crosshair.set()
            return
        }
        if spacePressed {
            NSCursor.openHand.set()
            return
        }
        if let selObj = document.selectedObject {
            for h in ResizeHandle.allCases where pt.distance(to: h.position(in: selObj.boundingBox)) <= 7.5 {
                NSCursor.crosshair.set()
                return
            }
            if let cp = selObj.cornerHandlePoint, pt.distance(to: cp) <= 7.5 {
                NSCursor.pointingHand.set()
                return
            }
            if let curve = selObj.curveControlPoints,
               (pt.distance(to: curve.c1) <= 7.5 || pt.distance(to: curve.c2) <= 7.5) {
                NSCursor.pointingHand.set()
                return
            }
            if selObj.hitTestFrameBorder(pt) {
                NSCursor.openHand.set()
                return
            }
        }
        if (flags.contains(.control) || flags.contains(.command)), document.hitTopmostObject(at: pt) != nil {
            NSCursor.openHand.set()
            return
        }
        if !selectionLocked {
            for h in ResizeHandle.allCases where pt.distance(to: h.position(in: sel)) <= 7.5 {
                NSCursor.crosshair.set()
                return
            }
        }
        if activeTool == nil, sel.contains(pt) {
            if document.hitTopmostObject(at: pt) != nil || !selectionLocked {
                NSCursor.openHand.set()
                return
            }
        }
        NSCursor.crosshair.set()
    }

    override func mouseDown(with event: NSEvent) {
        ownerController?.focusWindow()
        tooltipTask?.cancel()
        activeTooltip = nil

        let pt = ASPoint(convert(event.locationInWindow, from: nil))

        // Commit inline text/number editor if user clicks outside it
        if activeTextScrollView != nil || activeNumberField != nil {
            commitInlineEditorsIfNeeded()
            needsDisplay = true
        }

        // 1. Color picker popover interaction
        if let picker = colorPicker {
            if picker.panelRect.contains(pt.cgPoint) {
                if picker.svRect.contains(pt.cgPoint) {
                    dragOp = .adjustingColorSV(swatchIndex: picker.swatchIndex)
                    applyColorPickerSV(at: pt.cgPoint, swatchIndex: picker.swatchIndex)
                    return
                }
                if picker.hueRect.contains(pt.cgPoint) {
                    dragOp = .adjustingColorHue(swatchIndex: picker.swatchIndex)
                    applyColorPickerHue(at: pt.cgPoint, swatchIndex: picker.swatchIndex)
                    return
                }
                for (qr, qc) in picker.quickRects where qr.contains(pt.cgPoint) {
                    applySwatchColor(qc, at: picker.swatchIndex)
                    let hsv = ColorPalette.rgbToHSV(qc)
                    colorPicker?.hue = hsv.h
                    colorPicker?.sat = hsv.s
                    colorPicker?.val = hsv.v
                    needsDisplay = true
                    return
                }
                return
            } else {
                colorPicker = nil
                needsDisplay = true
            }
        }

        // 2. Toolbar hit check
        if let hit = toolbarHitItems.first(where: { $0.rect.contains(pt.cgPoint) }) {
            if event.clickCount == 2, let dbl = hit.doubleClickAction {
                dbl()
            } else {
                hit.action()
            }
            return
        }

        // 3. Unselected mode: create selection (or double-click for full screen CAP-7)
        guard let sel = selection else {
            if let owner = ownerController {
                coordinator?.clearSelectionOnOtherScreens(except: owner)
            }
            if event.clickCount == 2 {
                selection = ASRect(x: 0, y: 0, width: Double(bounds.width), height: Double(bounds.height))
                needsDisplay = true
                return
            }
            dragOp = .creatingSelection(origin: pt, moved: false)
            return
        }

        // 4. Selected object handles & double-click actions (EDT-11 priority order)
        if let selObj = document.selectedObject {
            // 4a. Double-click curve control handle -> reset straight arrow (EDT-3)
            if let curve = selObj.curveControlPoints {
                if pt.distance(to: curve.c1) <= 8.5 {
                    if event.clickCount == 2 {
                        document.updateObject(id: selObj.id, recordUndo: true) { _ = $0.resetCurveToStraight() }
                        needsDisplay = true
                        return
                    }
                    dragOp = .adjustingCurveControl(id: selObj.id, controlIndex: 0, undoRecorded: false)
                    return
                }
                if pt.distance(to: curve.c2) <= 8.5 {
                    if event.clickCount == 2 {
                        document.updateObject(id: selObj.id, recordUndo: true) { _ = $0.resetCurveToStraight() }
                        needsDisplay = true
                        return
                    }
                    dragOp = .adjustingCurveControl(id: selObj.id, controlIndex: 1, undoRecorded: false)
                    return
                }
            }
            // 4b. Corner radius circular handle
            if let cp = selObj.cornerHandlePoint, pt.distance(to: cp) <= 8.0 {
                dragOp = .adjustingCornerRadius(id: selObj.id, box: selObj.boundingBox, undoRecorded: false)
                return
            }
            // 4c. 8 object resize handles
            for h in ResizeHandle.allCases where pt.distance(to: h.position(in: selObj.boundingBox)) <= 8.0 {
                dragOp = .resizingObject(
                    id: selObj.id,
                    handle: h,
                    initialBox: selObj.boundingBox,
                    initialObject: selObj,
                    undoRecorded: false
                )
                return
            }
        }

        // 5. Selection 8 resize handles
        if !selectionLocked {
            for h in ResizeHandle.allCases where pt.distance(to: h.position(in: sel)) <= 8.0 {
                dragOp = .resizingSelection(handle: h, initialRect: sel)
                return
            }
        }

        // 6. Space + drag -> move whole selection
        if spacePressed && !selectionLocked {
            dragOp = .movingSelection(startMouse: pt, initialRect: sel)
            return
        }

        // 7. Double-click on Text or Number object -> re-edit; double-click blank inside selection -> Copy & Finish!
        if event.clickCount == 2, sel.contains(pt) {
            if let hitObj = document.hitTopmostObject(at: pt) {
                switch hitObj.kind {
                case .text:
                    document.selectedID = hitObj.id
                    beginInlineTextEdit(existingObject: hitObj, at: pt)
                    return
                case .number:
                    document.selectedID = hitObj.id
                    beginInlineNumberEdit(for: hitObj)
                    return
                default:
                    break
                }
            } else {
                triggerCopyOutput()
                return
            }
        }

        // 8. Ctrl / Cmd + drag object body -> move object (EDT-11 channel 1)
        let flags = event.modifierFlags
        if flags.contains(.control) || flags.contains(.command),
           let hitObj = document.hitTopmostObject(at: pt) {
            document.selectedID = hitObj.id
            dragOp = .movingObject(id: hitObj.id, lastPoint: pt, undoRecorded: false)
            needsDisplay = true
            return
        }

        // 9. Selected object's 6pt frame border -> move object (EDT-11 channel 2)
        if let selObj = document.selectedObject, selObj.hitTestFrameBorder(pt) {
            dragOp = .movingObject(id: selObj.id, lastPoint: pt, undoRecorded: false)
            return
        }

        // 10. Inside selection: move selection / select object when no tool active; Drawing-first when tool active!
        if sel.contains(pt) {
            let hitCandidate = document.hitTopmostObject(at: pt)
            guard let tool = activeTool else {
                if let hitObj = hitCandidate {
                    document.selectedID = hitObj.id
                    dragOp = .movingObject(id: hitObj.id, lastPoint: pt, undoRecorded: false)
                } else {
                    document.selectedID = nil
                    if !selectionLocked {
                        dragOp = .movingSelection(startMouse: pt, initialRect: sel)
                    }
                }
                needsDisplay = true
                return
            }

            if tool == .text {
                if let hc = hitCandidate, case .text = hc.kind {
                    document.selectedID = hc.id
                    needsDisplay = true
                } else {
                    beginInlineTextEdit(existingObject: nil, at: pt)
                }
                return
            }
            if tool == .number {
                // Place badge immediately on mouseDown, drag pulls out arrow tip!
                let n = document.nextMarkerNumber()
                let obj = AnnotationObject(
                    style: AnnotationStyle(color: currentSwatchColor, lineWidth: currentLineWidth),
                    kind: .number(center: pt, tip: pt, number: n, fontSize: currentNumberFontSize)
                )
                document.add(obj, select: true)
                dragOp = .drawingNewAnnotation(origin: pt, draftObjectID: obj.id, freehandPts: [pt], hitCandidateID: nil)
                needsDisplay = true
                return
            }

            dragOp = .drawingNewAnnotation(origin: pt, draftObjectID: nil, freehandPts: [pt], hitCandidateID: hitCandidate?.id)
            return
        }

        // Outside selection: start a fresh selection if unlocked & unannotated
        if !selectionLocked {
            document.selectedID = nil
            if document.isEmpty {
                dragOp = .creatingSelection(origin: pt, moved: false)
            }
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let rawPt = ASPoint(convert(event.locationInWindow, from: nil))
        let clampedPt = ASPoint(
            max(0, min(Double(bounds.width), rawPt.x)),
            max(0, min(Double(bounds.height), rawPt.y))
        )
        cursorPoint = clampedPt
        let shift = event.modifierFlags.contains(.shift)

        switch dragOp {
        case .none:
            break

        case .adjustingColorSV(let idx):
            applyColorPickerSV(at: rawPt.cgPoint, swatchIndex: idx)

        case .adjustingColorHue(let idx):
            applyColorPickerHue(at: rawPt.cgPoint, swatchIndex: idx)

        case .creatingSelection(let origin, _):
            let endPt = shift ? GeometrySnap.squareCorner(from: origin, to: clampedPt) : clampedPt
            let moved = origin.distance(to: clampedPt) >= 3.0
            dragOp = .creatingSelection(origin: origin, moved: moved)
            if moved {
                selection = ASRect.between(origin, endPt)
                needsDisplay = true
            }

        case .movingSelection(let startMouse, let initialRect):
            let dx = clampedPt.x - startMouse.x
            let dy = clampedPt.y - startMouse.y
            let nx = max(0, min(Double(bounds.width) - initialRect.width, initialRect.x + dx))
            let ny = max(0, min(Double(bounds.height) - initialRect.height, initialRect.y + dy))
            selection = ASRect(x: nx, y: ny, width: initialRect.width, height: initialRect.height)
            needsDisplay = true

        case .resizingSelection(let handle, let initialRect):
            selection = computeResizedRect(initial: initialRect, handle: handle, to: clampedPt, proportional: shift)
                .clampedToBounds(width: Double(bounds.width), height: Double(bounds.height))
            needsDisplay = true

        case .movingObject(let id, let lastPoint, var undoRecorded):
            var dx = clampedPt.x - lastPoint.x
            var dy = clampedPt.y - lastPoint.y
            if shift {
                if abs(dx) >= abs(dy) { dy = 0 } else { dx = 0 }
            }
            document.updateObject(id: id, recordUndo: !undoRecorded) { obj in
                obj.translate(dx: dx, dy: dy)
            }
            undoRecorded = true
            dragOp = .movingObject(id: id, lastPoint: ASPoint(lastPoint.x + dx, lastPoint.y + dy), undoRecorded: undoRecorded)
            needsDisplay = true

        case .resizingObject(let id, let handle, let initialBox, let initialObj, var undoRecorded):
            let newBox = computeResizedRect(initial: initialBox, handle: handle, to: clampedPt, proportional: shift)
            guard newBox.width >= 4 && newBox.height >= 4 else { break }
            document.updateObject(id: id, recordUndo: !undoRecorded) { obj in
                obj = initialObj
                obj.applyResize(from: initialBox, to: newBox)
            }
            undoRecorded = true
            dragOp = .resizingObject(id: id, handle: handle, initialBox: initialBox, initialObject: initialObj, undoRecorded: undoRecorded)
            needsDisplay = true

        case .adjustingCornerRadius(let id, let box, var undoRecorded):
            let dx = max(0, box.maxX - clampedPt.x)
            let dy = max(0, clampedPt.y - box.minY)
            let dist = min(dx, dy)
            let newR = max(0, dist - 6.0)
            document.updateObject(id: id, recordUndo: !undoRecorded) { obj in
                obj.setCornerRadius(newR)
            }
            undoRecorded = true
            dragOp = .adjustingCornerRadius(id: id, box: box, undoRecorded: undoRecorded)
            needsDisplay = true

        case .adjustingCurveControl(let id, let idx, var undoRecorded):
            document.updateObject(id: id, recordUndo: !undoRecorded) { obj in
                obj.setCurveControlPoint(index: idx, to: clampedPt)
            }
            undoRecorded = true
            dragOp = .adjustingCurveControl(id: id, controlIndex: idx, undoRecorded: undoRecorded)
            needsDisplay = true

        case .drawingNewAnnotation(let origin, let draftObjectID, var pts, let hitCandidateID):
            guard let sel = selection, let tool = activeTool else { break }
            let constrainedPt = ASPoint(
                max(sel.minX, min(sel.maxX, clampedPt.x)),
                max(sel.minY, min(sel.maxY, clampedPt.y))
            )

            if tool == .number {
                if let draftID = draftObjectID {
                    let target = shift ? GeometrySnap.snapDirection(from: origin, to: constrainedPt) : constrainedPt
                    document.updateObject(id: draftID, recordUndo: false) { obj in
                        if case .number(let center, _, let n, let fs) = obj.kind {
                            obj.kind = .number(center: center, tip: target, number: n, fontSize: fs)
                        }
                    }
                    needsDisplay = true
                }
                return
            }

            let dist = origin.distance(to: constrainedPt)
            if draftObjectID == nil && dist < 3.0 {
                // Still within click hysteresis: don't spawn a tiny 1px shape (EDT-11)
                return
            }

            if pts.last.map({ $0.distance(to: constrainedPt) >= 2.0 }) ?? true {
                pts.append(constrainedPt)
            }

            let kind = buildDraftKind(tool: tool, origin: origin, current: constrainedPt, freehandPts: pts, shift: shift)
            if let draftID = draftObjectID {
                document.updateObject(id: draftID, recordUndo: false) { obj in
                    obj.kind = kind
                }
                dragOp = .drawingNewAnnotation(origin: origin, draftObjectID: draftID, freehandPts: pts, hitCandidateID: hitCandidateID)
            } else {
                let newObj = AnnotationObject(
                    style: AnnotationStyle(color: currentSwatchColor, lineWidth: currentLineWidth),
                    kind: kind
                )
                document.add(newObj, select: true)
                dragOp = .drawingNewAnnotation(origin: origin, draftObjectID: newObj.id, freehandPts: pts, hitCandidateID: nil)
            }
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch dragOp {
        case .creatingSelection(_, let moved):
            if !moved {
                if let snapped = hoveredWindowRect, coordinator?.config.windowSnap == true {
                    selection = snapped
                }
            } else if let sel = selection, (sel.width < 4 || sel.height < 4) {
                selection = nil
            }
            if coordinator?.isDirectOCRCapture == true, let sel = selection, sel.width >= 4, sel.height >= 4 {
                dragOp = .none
                triggerOCR()
                return
            }
            needsDisplay = true

        case .drawingNewAnnotation(_, let draftObjectID, _, let hitCandidateID):
            if activeTool != .number && draftObjectID == nil {
                // Click without drag inside selection -> select hit object (or deselect if blank)! (EDT-11)
                document.selectedID = hitCandidateID
                needsDisplay = true
            }

        default:
            break
        }
        dragOp = .none
    }

    override func rightMouseDown(with event: NSEvent) {
        if activeTextScrollView != nil || activeNumberField != nil {
            // Right-click during text input = finish & keep text (OUT-3)
            commitInlineEditorsIfNeeded()
            needsDisplay = true
            return
        }
        if colorPicker != nil {
            colorPicker = nil
            needsDisplay = true
            return
        }
        attemptCancel()
    }

    override func scrollWheel(with event: NSEvent) {
        guard selection != nil else { return }
        let delta = abs(event.scrollingDeltaY) > 0.01 ? event.scrollingDeltaY : event.deltaY
        guard abs(delta) > 0.01 else { return }
        let step = delta > 0 ? 1.0 : -1.0

        // Adjust selected object or current tool defaults with mouse wheel!
        if let selObj = document.selectedObject {
            document.updateObject(id: selObj.id, recordUndo: true) { obj in
                switch obj.kind {
                case .blur(let a, let b, let br, let cr):
                    let nextR = max(4.0, min(64.0, br + step * 2.0))
                    currentBlurRadius = nextR
                    obj.kind = .blur(a: a, b: b, blurRadius: nextR, cornerRadius: cr)
                case .text(let pos, let txt, let fs, let ff, let bold, let italic, _, _):
                    let nextFS = max(10.0, min(96.0, fs + step * 2.0))
                    currentFontSize = nextFS
                    let m = AnnotationRenderer.measureText(txt, fontFamily: ff, fontSize: nextFS, bold: bold, italic: italic)
                    obj.kind = .text(pos: pos, text: txt, fontSize: nextFS, fontFamily: ff, bold: bold, italic: italic, measuredWidth: m.width, measuredHeight: m.height)
                case .number(let center, let tip, let n, let fs):
                    let nextFS = max(12.0, min(64.0, fs + step * 2.0))
                    currentNumberFontSize = nextFS
                    obj.kind = .number(center: center, tip: tip, number: n, fontSize: nextFS)
                default:
                    let nextW = max(1.0, min(36.0, obj.style.lineWidth + step))
                    currentLineWidth = nextW
                    obj.style.lineWidth = nextW
                }
            }
            needsDisplay = true
            return
        }

        guard let tool = activeTool else { return }
        switch tool {
        case .blur:
            currentBlurRadius = max(4.0, min(64.0, currentBlurRadius + step * 2.0))
        case .text:
            currentFontSize = max(10.0, min(96.0, currentFontSize + step * 2.0))
        case .number:
            currentNumberFontSize = max(12.0, min(64.0, currentNumberFontSize + step * 2.0))
        default:
            currentLineWidth = max(1.0, min(36.0, currentLineWidth + step))
        }
        needsDisplay = true
    }

    // MARK: - Keyboard Shortcuts

    override func flagsChanged(with event: NSEvent) {
        updateCursor(at: cursorPoint, flags: event.modifierFlags)
    }

    override func keyDown(with event: NSEvent) {
        if activeTextScrollView != nil || activeNumberField != nil {
            if Int(event.keyCode) == kVK_Escape {
                cancelInlineEditors()
                needsDisplay = true
            }
            return
        }

        let kc = Int(event.keyCode)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmdOrCtrl = flags.contains(.command) || flags.contains(.control)
        let shift = flags.contains(.shift)

        if kc == kVK_Space {
            spacePressed = true
            NSCursor.openHand.set()
            return
        }

        // Custom overlay hotkeys from config (Recapture, Longshot, OCR, Tool 1..0)
        if let cfg = coordinator?.config {
            let pressedMods = HotkeyModifiers.fromNSEventFlags(flags)
            let candidateBinding = HotkeyBinding(keyCode: kc, modifiers: pressedMods)

            if !cfg.hotkeys.recapture.isUnbound && candidateBinding == cfg.hotkeys.recapture {
                triggerRecaptureSelfUI()
                return
            }
            if selection != nil {
                if !cfg.hotkeys.longshot.isUnbound && candidateBinding == cfg.hotkeys.longshot && !selectionLocked {
                    triggerLongshot()
                    return
                }
                if !cfg.hotkeys.ocr.isUnbound && candidateBinding == cfg.hotkeys.ocr {
                    triggerOCR()
                    return
                }
                if !cfg.hotkeys.pin.isUnbound && candidateBinding == cfg.hotkeys.pin && !selectionLocked {
                    triggerPinOutput()
                    return
                }
                for tool in AnnotationTool.allOrdered {
                    let b = cfg.toolKeys.binding(for: tool)
                    if !b.isUnbound && candidateBinding == b {
                        selectTool(tool)
                        return
                    }
                }
            }
        }

        // Unselected magnifier color copy: `C` -> HEX, `Shift+C` -> RGB
        if selection == nil && !cmdOrCtrl && kc == kVK_ANSI_C {
            let pxX = max(0, min(snapshot.rawBuffer.width - 1, Int((cursorPoint.x * snapshot.backingScale).rounded())))
            let pxY = max(0, min(snapshot.rawBuffer.height - 1, Int((cursorPoint.y * snapshot.backingScale).rounded())))
            let col = snapshot.rawBuffer.pixel(x: pxX, y: pxY)
            let copied = shift ? col.rgbString : col.hexString
            OutputService.copyStringToClipboard(copied)
            ToastHUD.show("已复制色值 \(copied)")
            coordinator?.cancelSession()
            return
        }

        // Standard shortcuts
        if cmdOrCtrl {
            switch kc {
            case kVK_ANSI_C where selection != nil:
                triggerCopyOutput()
                return
            case kVK_ANSI_S where selection != nil:
                triggerSaveOutput()
                return
            case kVK_ANSI_Z:
                if shift { performRedo() } else { performUndo() }
                return
            case kVK_ANSI_Y:
                performRedo()
                return
            default:
                break
            }
        }

        switch kc {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if selection != nil { triggerCopyOutput() }
        case kVK_Escape:
            if colorPicker != nil {
                colorPicker = nil
                needsDisplay = true
            } else {
                attemptCancel()
            }
        case kVK_Delete, kVK_ForwardDelete:
            if document.deleteSelected() {
                needsDisplay = true
            }
        case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
            let step = shift ? 5.0 : 1.0
            let dx = kc == kVK_LeftArrow ? -step : (kc == kVK_RightArrow ? step : 0)
            let dy = kc == kVK_UpArrow ? -step : (kc == kVK_DownArrow ? step : 0)
            if let selID = document.selectedID {
                document.updateObject(id: selID, recordUndo: true) { $0.translate(dx: dx, dy: dy) }
                needsDisplay = true
            } else if var sel = selection, !selectionLocked {
                sel.x = max(0, min(Double(bounds.width) - sel.width, sel.x + dx))
                sel.y = max(0, min(Double(bounds.height) - sel.height, sel.y + dy))
                selection = sel
                needsDisplay = true
            }
        default:
            break
        }
    }

    override func keyUp(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Space {
            spacePressed = false
            updateCursor(at: cursorPoint, flags: event.modifierFlags)
        }
    }

    // MARK: - Tool, Color, Inline Text/Number & Output Actions

    private func selectTool(_ tool: AnnotationTool) {
        commitInlineEditorsIfNeeded()
        activeTool = (activeTool == tool) ? nil : tool
        document.selectedID = nil
        colorPicker = nil
        coordinator?.mutateConfig { $0.lastTool = tool }
        needsDisplay = true
    }

    private func selectLineWidthPreset(_ width: Double) {
        currentLineWidth = width
        if let selID = document.selectedID {
            document.updateObject(id: selID, recordUndo: true) { $0.style.lineWidth = width }
        }
        needsDisplay = true
    }

    private func selectBlurRadiusPreset(_ radius: Double) {
        currentBlurRadius = radius
        if let selID = document.selectedID {
            document.updateObject(id: selID, recordUndo: true) { obj in
                if case .blur(let a, let b, _, let cr) = obj.kind {
                    obj.kind = .blur(a: a, b: b, blurRadius: radius, cornerRadius: cr)
                }
            }
        }
        needsDisplay = true
    }

    private func selectColorSwatch(_ index: Int) {
        activeColorIndex = index
        coordinator?.mutateConfig { $0.activeColorIndex = index }
        let col = currentSwatchColor
        if let selID = document.selectedID {
            document.updateObject(id: selID, recordUndo: true) { $0.style.color = col }
        }
        needsDisplay = true
    }

    private func openColorPicker(for index: Int, anchorRect: CGRect) {
        selectColorSwatch(index)
        let col = currentSwatchColor
        let hsv = ColorPalette.rgbToHSV(col)
        colorPicker = ColorPickerState(swatchIndex: index, hue: hsv.h, sat: hsv.s, val: hsv.v)
        needsDisplay = true
    }

    private func applyColorPickerSV(at pt: CGPoint, swatchIndex: Int) {
        guard var picker = colorPicker else { return }
        let s = max(0.0, min(1.0, Double((pt.x - picker.svRect.minX) / max(1, picker.svRect.width))))
        let v = max(0.0, min(1.0, 1.0 - Double((pt.y - picker.svRect.minY) / max(1, picker.svRect.height))))
        picker.sat = s
        picker.val = v
        colorPicker = picker
        let rgb = ColorPalette.hsvToRGB(h: picker.hue, s: s, v: v)
        applySwatchColor(rgb, at: swatchIndex)
        needsDisplay = true
    }

    private func applyColorPickerHue(at pt: CGPoint, swatchIndex: Int) {
        guard var picker = colorPicker else { return }
        let h = max(0.0, min(359.9, Double((pt.x - picker.hueRect.minX) / max(1, picker.hueRect.width)) * 360.0))
        picker.hue = h
        colorPicker = picker
        let rgb = ColorPalette.hsvToRGB(h: h, s: picker.sat, v: picker.val)
        applySwatchColor(rgb, at: swatchIndex)
        needsDisplay = true
    }

    private func applySwatchColor(_ color: RGBAColor, at index: Int) {
        coordinator?.mutateConfig { cfg in
            if (0..<cfg.swatchColors.count).contains(index) {
                cfg.swatchColors[index] = color
            }
            cfg.activeColorIndex = index
        }
        if let selID = document.selectedID {
            document.updateObject(id: selID, recordUndo: false) { $0.style.color = color }
        }
    }

    private func toggleFill() {
        fillEnabled.toggle()
        if let selID = document.selectedID {
            document.updateObject(id: selID, recordUndo: true) { obj in
                switch obj.kind {
                case .rect(let a, let b, let r, let f):
                    obj.kind = .rect(a: a, b: b, cornerRadius: r, filled: !f)
                case .ellipse(let a, let b, let f):
                    obj.kind = .ellipse(a: a, b: b, filled: !f)
                default:
                    break
                }
            }
        }
        needsDisplay = true
    }

    private func performUndo() {
        commitInlineEditorsIfNeeded()
        if document.undo() { needsDisplay = true }
    }

    private func performRedo() {
        commitInlineEditorsIfNeeded()
        if document.redo() { needsDisplay = true }
    }

    // Text styling helpers
    private var currentEffectiveTextAttributes: (family: String, bold: Bool, italic: Bool, size: Double) {
        if let selObj = document.selectedObject,
           case .text(_, _, let fs, let ff, let b, let i, _, _) = selObj.kind {
            return (ff, b, i, fs)
        }
        return (currentFontFamily, textBold, textItalic, currentFontSize)
    }

    private func popFontMenu(from rect: CGRect) {
        let menu = NSMenu(title: "字体")
        let preferred = ["PingFang SC", "Helvetica Neue", "Menlo", "SF Pro Display", "Songti SC", "Kaiti SC", "Heiti SC", "Arial"]
        let allInstalled = NSFontManager.shared.availableFontFamilies
        var listed = preferred.filter { allInstalled.contains($0) }
        for f in allInstalled.prefix(35) where !listed.contains(f) {
            listed.append(f)
        }
        for fam in listed {
            let item = NSMenuItem(title: fam, action: #selector(onSelectFontFamily(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = fam
            if fam == currentEffectiveTextAttributes.family { item.state = .on }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY + 4), in: self)
    }

    @objc private func onSelectFontFamily(_ sender: NSMenuItem) {
        guard let fam = sender.representedObject as? String else { return }
        currentFontFamily = fam
        coordinator?.mutateConfig { $0.defaultFontFamily = fam }
        updateSelectedTextObject { _, txt, fs, _, b, i in (txt, fs, fam, b, i) }
        needsDisplay = true
    }

    private func toggleBold() {
        textBold.toggle()
        updateSelectedTextObject { _, txt, fs, ff, b, i in (txt, fs, ff, !b, i) }
        needsDisplay = true
    }

    private func toggleItalic() {
        textItalic.toggle()
        updateSelectedTextObject { _, txt, fs, ff, b, i in (txt, fs, ff, b, !i) }
        needsDisplay = true
    }

    private func stepFontSize(_ delta: Double) {
        let cur = currentEffectiveTextAttributes.size
        let next = max(10.0, min(96.0, cur + delta))
        currentFontSize = next
        updateSelectedTextObject { _, txt, _, ff, b, i in (txt, next, ff, b, i) }
        needsDisplay = true
    }

    private func updateSelectedTextObject(
        transform: (ASPoint, String, Double, String, Bool, Bool) -> (String, Double, String, Bool, Bool)
    ) {
        guard let selID = document.selectedID else { return }
        document.updateObject(id: selID, recordUndo: true) { obj in
            if case .text(let pos, let txt, let fs, let ff, let b, let i, _, _) = obj.kind {
                let (nt, nfs, nff, nb, ni) = transform(pos, txt, fs, ff, b, i)
                let m = AnnotationRenderer.measureText(nt, fontFamily: nff, fontSize: nfs, bold: nb, italic: ni)
                obj.kind = .text(pos: pos, text: nt, fontSize: nfs, fontFamily: nff, bold: nb, italic: ni, measuredWidth: m.width, measuredHeight: m.height)
            }
        }
    }

    // Inline native IME NSTextView
    private func beginInlineTextEdit(existingObject: AnnotationObject?, at point: ASPoint) {
        commitInlineEditorsIfNeeded()

        var initialString = ""
        var pos = point
        var fs = currentFontSize
        var ff = currentFontFamily
        var bold = textBold
        var italic = textItalic
        var col = currentSwatchColor

        if let existing = existingObject,
           case .text(let ePos, let eText, let eFS, let eFF, let eB, let eI, _, _) = existing.kind {
            editingTextObjectID = existing.id
            initialString = eText
            pos = ePos
            fs = eFS
            ff = eFF
            bold = eB
            italic = eI
            col = existing.style.color
        } else {
            editingTextObjectID = nil
        }
        editingTextOrigin = pos

        let maxW = max(160.0, (selection?.maxX ?? Double(bounds.width)) - pos.x - 8)
        let boxH = max(44.0, fs * 2.4)
        let frameRect = NSRect(x: pos.x, y: pos.y, width: min(360.0, maxW), height: boxH)

        let scroll = NSScrollView(frame: frameRect)
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 0.55)
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 5
        scroll.layer?.borderWidth = 1.2
        scroll.layer?.borderColor = NSColor.controlAccentColor.cgColor

        let tv = NSTextView(frame: NSRect(origin: .zero, size: frameRect.size))
        tv.isRichText = false
        tv.drawsBackground = false
        tv.font = AnnotationRenderer.resolveNSFont(family: ff, size: CGFloat(fs), bold: bold, italic: italic)
        tv.textColor = NSColor(srgbRed: CGFloat(col.r) / 255.0, green: CGFloat(col.g) / 255.0, blue: CGFloat(col.b) / 255.0, alpha: 1.0)
        tv.insertionPointColor = .white
        tv.string = initialString
        scroll.documentView = tv

        addSubview(scroll)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(tv)
        activeTextScrollView = scroll
        activeTextEditor = tv
    }

    private func beginInlineNumberEdit(for object: AnnotationObject) {
        commitInlineEditorsIfNeeded()
        guard case .number(let center, _, let n, _) = object.kind else { return }
        editingNumberObjectID = object.id

        let tf = NSTextField(frame: NSRect(x: center.x - 28, y: center.y - 13, width: 56, height: 26))
        tf.stringValue = "\(n)"
        tf.alignment = .center
        tf.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        tf.target = self
        tf.action = #selector(onCommitNumberField(_:))
        addSubview(tf)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(tf)
        activeNumberField = tf
    }

    @objc private func onCommitNumberField(_ sender: NSTextField) {
        commitInlineEditorsIfNeeded()
        needsDisplay = true
    }

    private func commitInlineEditorsIfNeeded() {
        if let tv = activeTextEditor, let scroll = activeTextScrollView {
            let content = tv.string.trimmingCharacters(in: .newlines)
            let editID = editingTextObjectID
            let origin = editingTextOrigin
            scroll.removeFromSuperview()
            activeTextScrollView = nil
            activeTextEditor = nil
            editingTextObjectID = nil
            window?.makeFirstResponder(self)

            if !content.isEmpty {
                let m = AnnotationRenderer.measureText(
                    content,
                    fontFamily: currentFontFamily,
                    fontSize: currentFontSize,
                    bold: textBold,
                    italic: textItalic
                )
                if let id = editID {
                    document.updateObject(id: id, recordUndo: true) { obj in
                        if case .text(let p, _, let fs, let ff, let b, let i, _, _) = obj.kind {
                            let em = AnnotationRenderer.measureText(content, fontFamily: ff, fontSize: fs, bold: b, italic: i)
                            obj.kind = .text(pos: p, text: content, fontSize: fs, fontFamily: ff, bold: b, italic: i, measuredWidth: em.width, measuredHeight: em.height)
                        }
                    }
                } else {
                    let obj = AnnotationObject(
                        style: AnnotationStyle(color: currentSwatchColor, lineWidth: currentLineWidth),
                        kind: .text(
                            pos: origin,
                            text: content,
                            fontSize: currentFontSize,
                            fontFamily: currentFontFamily,
                            bold: textBold,
                            italic: textItalic,
                            measuredWidth: m.width,
                            measuredHeight: m.height
                        )
                    )
                    document.add(obj, select: true)
                }
            }
        }

        if let nf = activeNumberField {
            let val = Int(nf.stringValue.trimmingCharacters(in: .whitespaces))
            let id = editingNumberObjectID
            nf.removeFromSuperview()
            activeNumberField = nil
            editingNumberObjectID = nil
            window?.makeFirstResponder(self)
            if let id, let v = val, v >= 0 {
                document.updateObject(id: id, recordUndo: true) { obj in
                    if case .number(let c, let tip, _, let fs) = obj.kind {
                        obj.kind = .number(center: c, tip: tip, number: v, fontSize: fs)
                    }
                }
            }
        }
    }

    private func cancelInlineEditors() {
        activeTextScrollView?.removeFromSuperview()
        activeTextScrollView = nil
        activeTextEditor = nil
        editingTextObjectID = nil

        activeNumberField?.removeFromSuperview()
        activeNumberField = nil
        editingNumberObjectID = nil
        window?.makeFirstResponder(self)
    }

    // MARK: - Recapture Self UI (Shift+F1, CAP-8 / ADR 0031)

    private func triggerRecaptureSelfUI() {
        commitInlineEditorsIfNeeded()
        guard let bitmapRep = bitmapImageRepForCachingDisplay(in: bounds) else { return }
        cacheDisplay(in: bounds, to: bitmapRep)
        guard let cg = bitmapRep.cgImage,
              let newBuf = PixelBufferRGBA(cgImage: cg) else {
            return
        }
        snapshot = CapturedScreenSnapshot(
            screen: snapshot.screen,
            frameInGlobalAppKit: snapshot.frameInGlobalAppKit,
            frameTopDown: snapshot.frameTopDown,
            cgImage: cg,
            rawBuffer: newBuf,
            backingScale: Double(cg.width) / max(1.0, Double(bounds.width)),
            windowRectsLocalTopDown: []
        )
        selection = nil
        activeTool = nil
        document.clearAll()
        colorPicker = nil
        ToastHUD.show("已再次冻结当前画面，请重新框选")
        needsDisplay = true
    }

    // MARK: - Baking Raw vs Output & Finalizing

    private func cropRawSelectionImage() -> CGImage? {
        guard let sel = selection, sel.width >= 1 && sel.height >= 1 else { return nil }
        let pxRect = CGRect(
            x: (sel.minX * snapshot.backingScale).rounded(.down),
            y: (sel.minY * snapshot.backingScale).rounded(.down),
            width: max(1, (sel.width * snapshot.backingScale).rounded()),
            height: max(1, (sel.height * snapshot.backingScale).rounded())
        )
        return snapshot.cgImage.cropping(to: pxRect)
    }

    private func bakeCurrentSelectionOutput() -> CGImage? {
        commitInlineEditorsIfNeeded()
        guard let sel = selection, let rawCG = cropRawSelectionImage() else { return nil }
        if document.isEmpty {
            return rawCG
        }
        return AnnotationRenderer.bakeOutput(
            rawSelection: rawCG,
            objects: document.objects,
            selectionOrigin: ASPoint(sel.minX, sel.minY),
            pixelScale: snapshot.backingScale
        )
    }

    private func triggerCopyOutput() {
        guard let out = bakeCurrentSelectionOutput() else { return }
        coordinator?.finishWithCopy(image: out, scale: snapshot.backingScale)
    }

    private func triggerSaveOutput() {
        guard let out = bakeCurrentSelectionOutput() else { return }
        coordinator?.finishWithSave(image: out, scale: snapshot.backingScale)
    }

    private func triggerPinOutput() {
        guard let sel = selection, let out = bakeCurrentSelectionOutput() else { return }
        let sFrame = snapshot.frameInGlobalAppKit
        let appKitOrigin = CGPoint(
            x: sFrame.minX + CGFloat(sel.minX),
            y: sFrame.maxY - CGFloat(sel.maxY)
        )
        coordinator?.finishWithPin(image: out, scale: snapshot.backingScale, appKitOrigin: appKitOrigin)
    }

    private func triggerOCR() {
        // OCR-4: Strictly pass RAW selection (without annotations) so arrows/blurs never pollute OCR!
        guard let sel = selection, let raw = cropRawSelectionImage() else { return }
        let sFrame = snapshot.frameInGlobalAppKit
        let centerScreen = NSPoint(
            x: sFrame.minX + CGFloat(sel.midX),
            y: sFrame.maxY - CGFloat(sel.midY)
        )
        coordinator?.finishWithOCR(rawImage: raw, anchorScreenPoint: centerScreen)
    }

    private func triggerLongshot() {
        guard let sel = selection, sel.width >= 24 && sel.height >= 24 else {
            ToastHUD.show("请先框选至少 24×24 的滚动区域")
            return
        }
        let pxRect = PixelRect(
            x: Int((sel.minX * snapshot.backingScale).rounded()),
            y: Int((sel.minY * snapshot.backingScale).rounded()),
            width: max(1, Int((sel.width * snapshot.backingScale).rounded())),
            height: max(1, Int((sel.height * snapshot.backingScale).rounded()))
        )
        guard let initialCrop = snapshot.rawBuffer.cropped(to: pxRect) else { return }
        coordinator?.finishIntoLongshot(screen: snapshot.screen, viewportTopDown: sel, initialCrop: initialCrop)
    }

    private func attemptCancel() {
        if !document.isEmpty && (coordinator?.config.confirmCancel == true) {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastCancelAttemptTime <= 1.8 {
                coordinator?.cancelSession()
                return
            }
            lastCancelAttemptTime = now
            cancelConfirmBanner = "已有未保存标注，再按一次 Esc 确认放弃"
            needsDisplay = true
            cancelBannerTask?.cancel()
            cancelBannerTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                guard !Task.isCancelled else { return }
                self?.cancelConfirmBanner = nil
                self?.needsDisplay = true
            }
            return
        }
        coordinator?.cancelSession()
    }

    // MARK: - Geometry Helpers

    private func buildDraftKind(
        tool: AnnotationTool,
        origin: ASPoint,
        current: ASPoint,
        freehandPts: [ASPoint],
        shift: Bool
    ) -> AnnotationKind {
        switch tool {
        case .rect:
            let end = shift ? GeometrySnap.squareCorner(from: origin, to: current) : current
            return .rect(a: origin, b: end, cornerRadius: 0, filled: fillEnabled)
        case .ellipse:
            let end = shift ? GeometrySnap.squareCorner(from: origin, to: current) : current
            return .ellipse(a: origin, b: end, filled: fillEnabled)
        case .highlight:
            let end = shift ? GeometrySnap.squareCorner(from: origin, to: current) : current
            return .highlight(a: origin, b: end, cornerRadius: 4)
        case .blur:
            let end = shift ? GeometrySnap.squareCorner(from: origin, to: current) : current
            return .blur(a: origin, b: end, blurRadius: currentBlurRadius, cornerRadius: 0)
        case .glow:
            let end = shift ? GeometrySnap.squareCorner(from: origin, to: current) : current
            return .glow(a: origin, b: end, cornerRadius: 6)
        case .arrow:
            let end = shift ? GeometrySnap.snapDirection(from: origin, to: current) : current
            return .straightArrow(from: origin, to: end)
        case .line:
            let end = shift ? GeometrySnap.snapDirection(from: origin, to: current) : current
            return .line(from: origin, to: end)
        case .freehand:
            let cleanPts = freehandPts.count > 1 ? Array(freehandPts.prefix(freehandPts.count)) : [origin, current]
            return .freehand(points: cleanPts)
        case .number:
            let end = shift ? GeometrySnap.snapDirection(from: origin, to: current) : current
            return .number(center: origin, tip: end, number: 1, fontSize: currentNumberFontSize)
        case .text:
            return .text(pos: origin, text: "", fontSize: currentFontSize, fontFamily: currentFontFamily, bold: textBold, italic: textItalic, measuredWidth: 20, measuredHeight: 24)
        }
    }

    private func computeResizedRect(initial: ASRect, handle: ResizeHandle, to pt: ASPoint, proportional: Bool) -> ASRect {
        var x0 = initial.minX
        var y0 = initial.minY
        var x1 = initial.maxX
        var y1 = initial.maxY

        switch handle {
        case .topLeft:     x0 = pt.x; y0 = pt.y
        case .top:         y0 = pt.y
        case .topRight:    x1 = pt.x; y0 = pt.y
        case .right:       x1 = pt.x
        case .bottomRight: x1 = pt.x; y1 = pt.y
        case .bottom:      y1 = pt.y
        case .bottomLeft:  x0 = pt.x; y1 = pt.y
        case .left:        x0 = pt.x
        }

        if proportional, initial.width > 1 && initial.height > 1 {
            let aspect = initial.width / initial.height
            let w = abs(x1 - x0)
            let h = abs(y1 - y0)
            if w / max(1, h) > aspect {
                let targetH = w / aspect
                if handle == .topLeft || handle == .topRight || handle == .top {
                    y0 = y1 - (y1 >= y0 ? targetH : -targetH)
                } else {
                    y1 = y0 + (y1 >= y0 ? targetH : -targetH)
                }
            } else {
                let targetW = h * aspect
                if handle == .topLeft || handle == .bottomLeft || handle == .left {
                    x0 = x1 - (x1 >= x0 ? targetW : -targetW)
                } else {
                    x1 = x0 + (x1 >= x0 ? targetW : -targetW)
                }
            }
        }
        return ASRect.between(ASPoint(x0, y0), ASPoint(x1, y1))
    }
}

private extension ASRect {
    func clampedToBounds(width: Double, height: Double) -> ASRect {
        let x0 = max(0, min(width, minX))
        let y0 = max(0, min(height, minY))
        let x1 = max(x0, min(width, maxX))
        let y1 = max(y0, min(height, maxY))
        return ASRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

extension HotkeyModifiers {
    static func fromNSEventFlags(_ flags: NSEvent.ModifierFlags) -> HotkeyModifiers {
        var m: HotkeyModifiers = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option)  { m.insert(.option) }
        if flags.contains(.shift)   { m.insert(.shift) }
        return m
    }
}
