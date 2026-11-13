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
private enum DirectionalResizeCursor {
    private static var cache: [Int: NSCursor] = [:]

    static func cursor(for handle: ResizeHandle) -> NSCursor {
        let angleSteps: Int
        switch handle {
        case .left, .right:
            angleSteps = 0      // 0°  (↔)
        case .topLeft, .bottomRight:
            angleSteps = 45     // 45° (↖↘)
        case .top, .bottom:
            angleSteps = 90     // 90° (↕)
        case .topRight, .bottomLeft:
            angleSteps = -45    // -45° (↙↗)
        }
        if let existing = cache[angleSteps] {
            return existing
        }
        let size = NSSize(width: 20, height: 20)
        let img = NSImage(size: size, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.translateBy(x: 10, y: 10)
            ctx.rotate(by: CGFloat(angleSteps) * .pi / 180.0)

            // Build double-headed arrow silhouette centered at (0, 0) along X axis
            let p = CGMutablePath()
            let tip: CGFloat = 7.6
            let headBase: CGFloat = 3.4
            let wing: CGFloat = 3.5
            let shaftHalf: CGFloat = 1.05

            p.move(to: CGPoint(x: -tip, y: 0))
            p.addLine(to: CGPoint(x: -headBase, y: -wing))
            p.addLine(to: CGPoint(x: -headBase, y: -shaftHalf))
            p.addLine(to: CGPoint(x: headBase, y: -shaftHalf))
            p.addLine(to: CGPoint(x: headBase, y: -wing))
            p.addLine(to: CGPoint(x: tip, y: 0))
            p.addLine(to: CGPoint(x: headBase, y: wing))
            p.addLine(to: CGPoint(x: headBase, y: shaftHalf))
            p.addLine(to: CGPoint(x: -headBase, y: shaftHalf))
            p.addLine(to: CGPoint(x: -headBase, y: wing))
            p.closeSubpath()

            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 0.8), blur: 1.6, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
            ctx.addPath(p)
            ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.setLineWidth(2.2)
            ctx.setLineJoin(.round)
            ctx.strokePath()
            ctx.restoreGState()

            ctx.addPath(p)
            ctx.setFillColor(CGColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 1))
            ctx.fillPath()
            return true
        }
        let c = NSCursor(image: img, hotSpot: NSPoint(x: 10, y: 10))
        cache[angleSteps] = c
        return c
    }
}

@MainActor
public final class CaptureSessionCoordinator {
    public enum SessionMode {
        case normalCapture
        case directWindowCapture
        case directOCRCapture
        case directLongshotCapture
        case inlinePinEdit(PinWindowController)
        case standaloneImageEdit(CGImage, Double, NSScreen)
    }

    public var isDirectWindowCapture: Bool {
        if case .directWindowCapture = mode { return true }
        return false
    }

    public var isDirectOCRCapture: Bool {
        if case .directOCRCapture = mode { return true }
        return false
    }

    public var isDirectLongshotCapture: Bool {
        if case .directLongshotCapture = mode { return true }
        return false
    }

    public var isInlinePinEdit: Bool {
        if case .inlinePinEdit = mode { return true }
        return false
    }

    public var canToggleWindowPickerWithSpace: Bool {
        switch mode {
        case .normalCapture, .directWindowCapture:
            return true
        default:
            return false
        }
    }

    private var screenControllers: [OverlayScreenController] = []
    private(set) var config: AirSnipConfig
    public let mode: SessionMode

    public var persistConfigChanges: Bool = true
    public var onCompleteCopy: ((CGImage, Double) -> Void)?
    public var onCompleteSave: ((CGImage, Double, Bool, inout AirSnipConfig) -> Bool)?
    public var onCompletePin: ((CGImage, Double, CGPoint?) -> Void)?
    public var onStartOCR: ((CGImage, NSPoint?) -> Void)?
    public var onStartLongshot: ((NSScreen, ASRect, PixelBufferRGBA, Bool) -> Void)?
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

    public func renderIsolatedWindowVerificationSample(windowImage: CGImage, rect: ASRect, includeShadow: Bool) -> CGImage? {
        guard let ctrl = screenControllers.first else { return nil }
        return ctrl.canvasView.renderIsolatedWindowVerificationSample(windowImage: windowImage, rect: rect, includeShadow: includeShadow)
    }

    public func renderStandaloneAnnotatedOutputSample() -> CGImage? {
        guard let ctrl = screenControllers.first else { return nil }
        return ctrl.canvasView.renderStandaloneAnnotatedOutputSample()
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
            windowsLocalTopDown: []
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

        // Fit image nicely within 85% of screen if very tall (e.g., longshot), while preserving 100% original resolution for baking/export
        let maxPxW = Double(fullW) * 0.88
        let maxPxH = Double(fullH) * 0.82
        let fitRatio = min(1.0, min(maxPxW / Double(cgImage.width), maxPxH / Double(cgImage.height)))
        let dispPxW = max(16.0, (Double(cgImage.width) * fitRatio).rounded())
        let dispW = dispPxW / scale
        let effectivePixelScale = Double(cgImage.width) / max(1.0, dispW)
        let dispH = Double(cgImage.height) / effectivePixelScale
        let dispPxH = dispH * scale

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
            width: dispW,
            height: dispH
        )

        let snap = CapturedScreenSnapshot(
            screen: screen,
            frameInGlobalAppKit: sFrame,
            frameTopDown: ASRect(x: 0, y: 0, width: Double(sFrame.width), height: Double(sFrame.height)),
            cgImage: fullCG,
            rawBuffer: fullBuf,
            backingScale: scale,
            windowsLocalTopDown: []
        )

        let ctrl = OverlayScreenController(snapshot: snap, coordinator: self, lockedInitialSelection: selTopDown)
        if let srcBuf = PixelBufferRGBA(cgImage: cgImage) {
            ctrl.canvasView.attachStandaloneSourceImage(
                cgImage: cgImage,
                rawBuffer: srcBuf,
                pixelScale: effectivePixelScale
            )
        }
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
        if persistConfigChanges {
            try? config.save()
        }
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

    func finishWithSave(image: CGImage, scale: Double, forceDialog: Bool = false) {
        if !forceDialog && !config.askBeforeSave {
            closeAllWindows()
            var cfg = config
            if onCompleteSave?(image, scale, false, &cfg) ?? false {
                self.config = cfg
            }
            if case .inlinePinEdit(let pin) = mode {
                pin.updateImage(image)
                pin.show()
            }
            onSessionEnded?()
            return
        }

        // Hide overlay level temporarily so NSSavePanel appears cleanly above
        for c in screenControllers {
            c.panel.orderOut(nil)
        }
        var cfg = config
        let saved = onCompleteSave?(image, scale, true, &cfg) ?? false
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

    func finishIntoLongshot(
        screen: NSScreen,
        viewportTopDown: ASRect,
        initialCrop: PixelBufferRGBA,
        forceAutoScroll: Bool = false
    ) {
        closeAllWindows()
        onStartLongshot?(screen, viewportTopDown, initialCrop, forceAutoScroll)
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

    private struct IsolatedWindowCapture {
        let rawImage: CGImage
        let rawBuffer: PixelBufferRGBA
        let pixelScale: Double
        var includeShadow: Bool
        let ownerName: String
        var isWindowCapture: Bool = true
    }

    private var snapshot: CapturedScreenSnapshot
    private var selection: ASRect?
    private var selectionLocked: Bool
    private var windowPickerMode: Bool
    private var windowDepthIndex: Int = 0
    private var hoveredWindowCandidate: WindowSnapCandidate?
    private var isolatedWindowCapture: IsolatedWindowCapture?
    private var isCapturingIsolatedWindow: Bool = false
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
        case pressingToolbarItem(id: String)
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

    // Hover & press state + tooltip (EDT-10: 400ms delay)
    private var hoveredItemID: String?
    private var pressedItemID: String?
    private var hoveredResizeHandle: ResizeHandle?
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

    // Cached full-screen Gaussian-approximated backdrop for 120Hz Liquid Glass translucency
    private lazy var blurredBackdropCGImage: CGImage? = {
        let srcW = snapshot.cgImage.width
        let srcH = snapshot.cgImage.height
        let dsW = max(64, srcW / 4)
        let dsH = max(64, srcH / 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var buf = [UInt8](repeating: 0, count: dsW * dsH * 4)
        guard let ctx = CGContext(
            data: &buf,
            width: dsW,
            height: dsH,
            bitsPerComponent: 8,
            bytesPerRow: dsW * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.interpolationQuality = .medium
        ctx.draw(snapshot.cgImage, in: CGRect(x: 0, y: 0, width: dsW, height: dsH))
        let downsampled = PixelBufferRGBA(width: dsW, height: dsH, rgba: buf)
        return BoxBlurEngine.blur(downsampled, radius: 10).makeCGImage()
    }()

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
        self.fillEnabled = cfg.defaultFillEnabled
        self.currentLineWidth = cfg.defaultLineWidth
        self.currentBlurRadius = cfg.defaultBlurRadius
        self.currentFontSize = cfg.defaultFontSize
        self.currentNumberFontSize = cfg.defaultNumberFontSize
        self.currentFontFamily = cfg.defaultFontFamily
        self.textBold = cfg.defaultFontBold
        self.textItalic = cfg.defaultFontItalic
        self.selection = lockedInitialSelection
        self.selectionLocked = (lockedInitialSelection != nil)
        self.windowPickerMode = (lockedInitialSelection == nil) && coordinator.isDirectWindowCapture

        let globalMouse = NSEvent.mouseLocation
        let sf = snapshot.frameInGlobalAppKit
        let initX = max(0, min(Double(sf.width), Double(globalMouse.x - sf.minX)))
        let initY = max(0, min(Double(sf.height), Double(sf.maxY - globalMouse.y)))
        let initPt = ASPoint(initX, initY)
        self.cursorPoint = initPt
        if lockedInitialSelection == nil && (coordinator.isDirectWindowCapture || cfg.windowSnap) {
            self.hoveredWindowCandidate = WindowSnapResolver.resolveCandidate(
                at: initPt,
                candidatesFrontToBack: snapshot.windowsLocalTopDown,
                allowMaximizedSnap: coordinator.isDirectWindowCapture || coordinator.isDirectLongshotCapture
            )
        } else {
            self.hoveredWindowCandidate = nil
        }

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
        isolatedWindowCapture = nil
        selection = nil
        activeTool = nil
        pressedItemID = nil
        hoveredResizeHandle = nil
        document.clearAll()
        colorPicker = nil
        needsDisplay = true
    }

    func attachStandaloneSourceImage(cgImage: CGImage, rawBuffer: PixelBufferRGBA, pixelScale: Double) {
        isolatedWindowCapture = IsolatedWindowCapture(
            rawImage: cgImage,
            rawBuffer: rawBuffer,
            pixelScale: pixelScale,
            includeShadow: false,
            ownerName: "",
            isWindowCapture: false
        )
        needsDisplay = true
    }

    func renderStandaloneAnnotatedOutputSample() -> CGImage? {
        guard let sel = selection else { return nil }
        document.clearAll()
        document.add(
            AnnotationObject(
                style: AnnotationStyle(color: RGBAColor(r: 255, g: 0, b: 0), lineWidth: 2.0),
                kind: .rect(
                    a: ASPoint(sel.minX + 8, sel.minY + 8),
                    b: ASPoint(min(sel.maxX - 8, sel.minX + 68), min(sel.maxY - 8, sel.minY + 48)),
                    cornerRadius: 4,
                    filled: false
                )
            ),
            select: false
        )
        return bakeCurrentSelectionOutput(applyWindowShadow: true)
    }

    func renderIsolatedWindowVerificationSample(windowImage: CGImage, rect: ASRect, includeShadow: Bool) -> CGImage? {
        guard let rawBuf = PixelBufferRGBA(cgImage: windowImage) else { return nil }
        let pxScale = Double(windowImage.width) / max(1.0, rect.width)
        isolatedWindowCapture = IsolatedWindowCapture(
            rawImage: windowImage,
            rawBuffer: rawBuf,
            pixelScale: pxScale,
            includeShadow: includeShadow,
            ownerName: "SampleApp"
        )
        selection = rect
        selectionLocked = true
        document.clearAll()
        document.add(
            AnnotationObject(
                style: AnnotationStyle(color: RGBAColor(r: 255, g: 0, b: 0), lineWidth: 2.0),
                kind: .rect(
                    a: ASPoint(rect.minX + 12, rect.minY + 12),
                    b: ASPoint(min(rect.maxX - 12, rect.minX + 92), min(rect.maxY - 12, rect.minY + 52)),
                    cornerRadius: 4,
                    filled: false
                )
            ),
            select: false
        )
        let out = bakeCurrentSelectionOutput(applyWindowShadow: true)
        isolatedWindowCapture = nil
        selection = nil
        selectionLocked = false
        document.clearAll()
        return out
    }

    func renderVerificationSample(selection sel: ASRect) -> (toolbarIDs: [String], hasSecondaryBar: Bool, croppedImage: CGImage?) {
        self.selection = sel
        self.activeTool = nil
        self.colorPicker = nil
        self.needsDisplay = true
        var cropped: CGImage?
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            if let fullCG = rep.cgImage, mainToolbarRect != .zero {
                let scale = CGFloat(fullCG.width) / max(1, bounds.width)
                let cropPt = mainToolbarRect.insetBy(dx: -18, dy: -26)
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
        let ids = toolbarHitItems.map(\.id)
        let hadSub = (secondRowRect != .zero)

        // Optional rich multi-state verification dump for visual inspection
        if let dirPath = ProcessInfo.processInfo.environment["AIRSNIP_SMOKE_PREVIEW_DIR"] {
            let dirURL = URL(fileURLWithPath: dirPath)
            try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            func dumpRegion(_ name: String, computeRect: () -> CGRect) {
                guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return }
                cacheDisplay(in: bounds, to: rep)
                guard let fullCG = rep.cgImage else { return }
                let scale = CGFloat(fullCG.width) / max(1, bounds.width)
                let clamped = computeRect().intersection(bounds)
                let pxRect = CGRect(
                    x: (clamped.minX * scale).rounded(),
                    y: (clamped.minY * scale).rounded(),
                    width: max(1, (clamped.width * scale).rounded()),
                    height: max(1, (clamped.height * scale).rounded())
                )
                if let sub = fullCG.cropping(to: pxRect),
                   let png = NSBitmapImageRep(cgImage: sub).representation(using: .png, properties: [:]) {
                    try? png.write(to: dirURL.appendingPathComponent(name))
                }
            }
            // 1. Selection corner + dimension pill + main bar
            dumpRegion("01_selection_and_toolbar_light.png") {
                sel.cgRect.union(mainToolbarRect).insetBy(dx: -24, dy: -32)
            }

            // 2. Rect tool active -> callout popover with stroke dots + fill + circular swatches
            selectTool(.rect)
            dumpRegion("02_rect_subbar_light.png") {
                mainToolbarRect.union(secondRowRect).insetBy(dx: -18, dy: -16)
            }

            // 3. Double-click swatch -> smooth HSV color picker popover
            openColorPicker(for: activeColorIndex, anchorRect: secondRowRect)
            dumpRegion("03_color_picker_light.png") {
                let pRect = colorPicker?.panelRect ?? .zero
                return mainToolbarRect.union(secondRowRect).union(pRect).insetBy(dx: -18, dy: -16)
            }
            colorPicker = nil

            // 4. Text tool active -> typography callout popover
            selectTool(.text)
            dumpRegion("04_text_subbar_light.png") {
                mainToolbarRect.union(secondRowRect).insetBy(dx: -18, dy: -16)
            }

            // 5. Dark mode toolbar
            let prevTheme = coordinator?.config.theme ?? .follow
            coordinator?.mutateConfig { $0.theme = .dark }
            activeTool = nil
            needsDisplay = true
            dumpRegion("05_toolbar_dark.png") {
                mainToolbarRect.insetBy(dx: -18, dy: -22)
            }
            coordinator?.mutateConfig { $0.theme = prevTheme }
            activeTool = nil
        }

        return (ids, hadSub, cropped)
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

    // MARK: - Pixel Snapping & Frosted Glass Material Helpers

    private func pixelSnap(_ value: CGFloat, lineWidth: CGFloat) -> CGFloat {
        let s = CGFloat(max(1.0, snapshot.backingScale))
        let pxW = max(1, Int((lineWidth * s).rounded()))
        if pxW % 2 == 0 {
            return (value * s).rounded() / s
        } else {
            return (floor(value * s) + 0.5) / s
        }
    }

    private func pixelSnapRect(_ rect: CGRect, lineWidth: CGFloat) -> CGRect {
        let x0 = pixelSnap(rect.minX, lineWidth: lineWidth)
        let y0 = pixelSnap(rect.minY, lineWidth: lineWidth)
        let x1 = pixelSnap(rect.maxX, lineWidth: lineWidth)
        let y1 = pixelSnap(rect.maxY, lineWidth: lineWidth)
        return CGRect(x: x0, y: y0, width: max(1, x1 - x0), height: max(1, y1 - y0))
    }

    private func makeCalloutBubblePath(
        rect: CGRect,
        cornerRadius r0: CGFloat,
        arrowX: CGFloat?,
        arrowOnTop: Bool,
        arrowWidth: CGFloat = 11.0,
        arrowHeight: CGFloat = 5.5
    ) -> CGPath {
        let r = min(r0, min(rect.width, rect.height) * 0.5)
        guard let rawAX = arrowX else {
            return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        }
        let halfW = arrowWidth * 0.5
        let minAX = rect.minX + r + halfW + 2
        let maxAX = rect.maxX - r - halfW - 2
        guard maxAX >= minAX else {
            return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        }
        let cx = max(minAX, min(maxAX, rawAX))

        let p = CGMutablePath()
        p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        if arrowOnTop {
            p.addLine(to: CGPoint(x: cx - halfW, y: rect.minY))
            p.addLine(to: CGPoint(x: cx - 0.8, y: rect.minY - arrowHeight + 0.8))
            p.addQuadCurve(
                to: CGPoint(x: cx + 0.8, y: rect.minY - arrowHeight + 0.8),
                control: CGPoint(x: cx, y: rect.minY - arrowHeight)
            )
            p.addLine(to: CGPoint(x: cx + halfW, y: rect.minY))
        }
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r), radius: r)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - r, y: rect.maxY), radius: r)
        if !arrowOnTop {
            p.addLine(to: CGPoint(x: cx + halfW, y: rect.maxY))
            p.addLine(to: CGPoint(x: cx + 0.8, y: rect.maxY + arrowHeight - 0.8))
            p.addQuadCurve(
                to: CGPoint(x: cx - 0.8, y: rect.maxY + arrowHeight - 0.8),
                control: CGPoint(x: cx, y: rect.maxY + arrowHeight)
            )
            p.addLine(to: CGPoint(x: cx - halfW, y: rect.maxY))
        }
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - r), radius: r)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + r, y: rect.minY), radius: r)
        p.closeSubpath()
        return p
    }

    private func drawFrostedMaterial(
        in ctx: CGContext,
        path: CGPath,
        sampleRect: CGRect,
        dark: Bool,
        shadowOffsetY: CGFloat = 3.5,
        shadowBlur: CGFloat = 16.0,
        shadowAlpha: CGFloat = 0.22
    ) {
        let _ = sampleRect
        let bbox = path.boundingBoxOfPath
        let solidShadowFill = dark
            ? CGColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1.0)
            : CGColor(srgbRed: 0.96, green: 0.97, blue: 0.98, alpha: 1.0)

        // 1. Dual physical shadow (ambient + crisp contact shadow) clipped OUTSIDE the glass body
        ctx.saveGState()
        let outside = CGMutablePath()
        outside.addRect(bounds)
        outside.addPath(path)
        ctx.addPath(outside)
        ctx.clip(using: .evenOdd)

        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: shadowOffsetY),
            blur: shadowBlur,
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: shadowAlpha)
        )
        ctx.addPath(path)
        ctx.setFillColor(solidShadowFill)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: 1.0),
            blur: 2.5,
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: dark ? 0.28 : 0.12)
        )
        ctx.addPath(path)
        ctx.setFillColor(solidShadowFill)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.restoreGState()

        // 2. Real underlying screen optical blur + vertical Liquid Glass tint wash
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()

        if let blurCG = blurredBackdropCGImage {
            ctx.saveGState()
            ctx.interpolationQuality = .high
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(blurCG, in: CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height))
            ctx.restoreGState()
        }

        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let glassTop = dark
            ? CGColor(srgbRed: 0.16, green: 0.17, blue: 0.20, alpha: 0.78)
            : CGColor(srgbRed: 0.985, green: 0.988, blue: 0.994, alpha: 0.80)
        let glassBottom = dark
            ? CGColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 0.85)
            : CGColor(srgbRed: 0.945, green: 0.952, blue: 0.965, alpha: 0.86)
        if let grad = CGGradient(colorsSpace: cs, colors: [glassTop, glassBottom] as CFArray, locations: [0.0, 1.0]) {
            ctx.drawLinearGradient(
                grad,
                start: CGPoint(x: bbox.midX, y: bbox.minY),
                end: CGPoint(x: bbox.midX, y: bbox.maxY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        } else {
            ctx.setFillColor(glassBottom)
            ctx.fill(bbox)
        }

        // 3. Directional top-lit specular glass inner bevel
        ctx.addPath(path)
        ctx.setLineWidth(1.3)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let rimTop = dark
            ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22)
            : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92)
        let rimBottom = dark
            ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.06)
            : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.45)
        if let rimGrad = CGGradient(colorsSpace: cs, colors: [rimTop, rimBottom] as CFArray, locations: [0.0, 1.0]) {
            ctx.drawLinearGradient(
                rimGrad,
                start: CGPoint(x: bbox.midX, y: bbox.minY),
                end: CGPoint(x: bbox.midX, y: bbox.maxY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        ctx.restoreGState()

        // 4. Crisp outer hairline edge
        let outerRim = dark
            ? CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.52)
            : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.11)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(outerRim)
        ctx.setLineWidth(0.6)
        ctx.strokePath()
        ctx.restoreGState()
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
            if let iso = isolatedWindowCapture {
                // Isolated Window Capture stage: dim frozen desktop softly and present the unoccluded window
                ctx.saveGState()
                ctx.setFillColor(CGColor(srgbRed: 0.06, green: 0.07, blue: 0.09, alpha: 0.62))
                ctx.fill(bounds)

                let r = sel.cgRect
                ctx.saveGState()
                if iso.includeShadow {
                    ctx.setShadow(
                        offset: CGSize(width: 0, height: 10.0),
                        blur: 26.0,
                        color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.42)
                    )
                }
                ctx.translateBy(x: r.minX, y: r.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.interpolationQuality = .high
                ctx.draw(iso.rawImage, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
                ctx.restoreGState()
                ctx.restoreGState()

                AnnotationRenderer.drawAnnotations(
                    in: ctx,
                    objects: document.objects,
                    rawBuffer: iso.rawBuffer,
                    rawOrigin: ASPoint(sel.minX, sel.minY),
                    pixelScale: iso.pixelScale,
                    clipBounds: sel
                )

                drawSelectionFrameAndHandles(in: ctx, selection: sel)
                if let selObj = document.selectedObject {
                    AnnotationRenderer.drawSelectionGizmos(in: ctx, for: selObj)
                }

                let shadowTag = (iso.isWindowCapture && !iso.includeShadow) ? " · 无阴影" : ""
                let pillText = iso.ownerName.isEmpty
                    ? "\(iso.rawImage.width) × \(iso.rawImage.height)\(shadowTag)"
                    : "\(iso.ownerName) · \(iso.rawImage.width) × \(iso.rawImage.height)\(shadowTag)"
                drawDimensionPill(in: ctx, selection: sel, text: pillText)
            } else {
                // 2. Dim outside selection
                ctx.saveGState()
                let dimPath = CGMutablePath()
                dimPath.addRect(bounds)
                dimPath.addRect(sel.cgRect)
                ctx.addPath(dimPath)
                ctx.clip(using: .evenOdd)
                ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45))
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

                // 4. Precision 1px pixel-snapped selection border & 8 circular control knots
                drawSelectionFrameAndHandles(in: ctx, selection: sel)

                // 5. Selected annotation gizmos
                if let selObj = document.selectedObject {
                    AnnotationRenderer.drawSelectionGizmos(in: ctx, for: selObj)
                }

                // 6. Frosted pixel dimension pill at top-left of selection
                let pxW = max(1, Int((sel.width * snapshot.backingScale).rounded()))
                let pxH = max(1, Int((sel.height * snapshot.backingScale).rounded()))
                drawDimensionPill(in: ctx, selection: sel, text: "\(pxW) × \(pxH)")
            }

            // 7. Floating annotation toolbar + optional style sub-bar + color picker + tooltip
            if case .creatingSelection = dragOp {
                toolbarHitItems.removeAll()
                // Show precision pixel loupe while actively dragging/resizing selection!
                drawMagnifierHUD(in: ctx, at: cursorPoint)
            } else if case .resizingSelection = dragOp {
                toolbarHitItems.removeAll()
                drawMagnifierHUD(in: ctx, at: cursorPoint)
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
            // only dim outside a hovered window when window-snap or windowPickerMode highlights one.
            if let cand = hoveredWindowCandidate, (windowPickerMode || coordinator?.config.windowSnap == true) {
                let winRect = cand.rect
                let radius: CGFloat = windowPickerMode ? 10.0 : 0.0
                let highlightPath = radius > 0
                    ? CGPath(roundedRect: winRect.cgRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                    : CGPath(rect: winRect.cgRect, transform: nil)

                ctx.saveGState()
                let dimPath = CGMutablePath()
                dimPath.addRect(bounds)
                dimPath.addPath(highlightPath)
                ctx.addPath(dimPath)
                ctx.clip(using: .evenOdd)
                ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: windowPickerMode ? 0.36 : 0.26))
                ctx.fill(bounds)
                ctx.restoreGState()

                let snapped = pixelSnapRect(winRect.cgRect, lineWidth: windowPickerMode ? 2.0 : 1.5)
                let strokePath = radius > 0
                    ? CGPath(roundedRect: snapped, cornerWidth: radius, cornerHeight: radius, transform: nil)
                    : CGPath(rect: snapped, transform: nil)
                ctx.saveGState()
                ctx.addPath(strokePath)
                ctx.setFillColor(CGColor(srgbRed: 0.09, green: 0.56, blue: 1.0, alpha: windowPickerMode ? 0.07 : 0.04))
                ctx.fillPath()
                ctx.addPath(strokePath)
                ctx.setStrokeColor(CGColor(srgbRed: 0.09, green: 0.56, blue: 1.0, alpha: 0.96))
                ctx.setLineWidth(windowPickerMode ? 2.0 : 1.5)
                ctx.strokePath()
                ctx.restoreGState()

                let rawW = windowPickerMode ? cand.unclippedRect.width : winRect.width
                let rawH = windowPickerMode ? cand.unclippedRect.height : winRect.height
                let pxW = Int((rawW * snapshot.backingScale).rounded())
                let pxH = Int((rawH * snapshot.backingScale).rounded())
                let pillLabel: String
                if windowPickerMode {
                    let hits = WindowSnapResolver.candidatesContaining(
                        at: cursorPoint,
                        candidatesFrontToBack: snapshot.windowsLocalTopDown,
                        allowMaximizedSnap: true
                    )
                    let stackPrefix: String
                    if hits.count > 1 {
                        let curIdx = ((windowDepthIndex % hits.count) + hits.count) % hits.count
                        stackPrefix = "\(curIdx + 1)/\(hits.count) "
                    } else {
                        stackPrefix = ""
                    }
                    let namePart = cand.ownerName.isEmpty ? "" : "\(cand.ownerName) · "
                    pillLabel = "\(stackPrefix)\(namePart)\(pxW) × \(pxH)"
                } else {
                    pillLabel = "\(pxW) × \(pxH)"
                }
                drawDimensionPill(in: ctx, selection: winRect, text: pillLabel)
            }

            if !windowPickerMode {
                drawMagnifierHUD(in: ctx, at: cursorPoint)
            }

            if windowPickerMode, cancelConfirmBanner == nil {
                drawCancelConfirmBanner(in: ctx, message: "点击窗口截图（⌥切换阴影 · Tab切换叠放窗口） · Space 切换框选 · Esc 取消")
            } else if coordinator?.isDirectOCRCapture == true, cancelConfirmBanner == nil {
                drawCancelConfirmBanner(in: ctx, message: "框选或点击窗口识字 · Esc 取消")
            } else if coordinator?.isDirectLongshotCapture == true, cancelConfirmBanner == nil {
                drawCancelConfirmBanner(in: ctx, message: "框选滚动区域或点击窗口自动翻页长截图 · Esc 取消")
            }
        }

        if let banner = cancelConfirmBanner {
            drawCancelConfirmBanner(in: ctx, message: banner)
        }
    }

    private func visibleSelectionHandles(for sel: ASRect) -> [ResizeHandle] {
        ResizeHandle.allCases.filter { h in
            if (h == .top || h == .bottom) && sel.width < 52 { return false }
            if (h == .left || h == .right) && sel.height < 52 { return false }
            return true
        }
    }

    private func drawSelectionFrameAndHandles(in ctx: CGContext, selection sel: ASRect) {
        let accent = CGColor(srgbRed: 0.09, green: 0.56, blue: 1.0, alpha: 1.0)
        let frameRect = pixelSnapRect(sel.cgRect, lineWidth: 1.0)

        ctx.saveGState()
        // Subtle outer contrast hairline so blue border stays legible on white or cyan backgrounds
        ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.22))
        ctx.setLineWidth(1.0)
        ctx.stroke(frameRect.insetBy(dx: -0.6, dy: -0.6))

        // Crisp 1.0pt sky-blue selection hairline
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(1.0)
        ctx.stroke(frameRect)

        // 8 precision circular control knots (white core + sky-blue rim + subtle drop shadow)
        if !selectionLocked {
            for h in visibleSelectionHandles(for: sel) {
                let p = h.position(in: sel)
                let isHovered = (hoveredResizeHandle == h)
                let diameter: CGFloat = isHovered ? 8.6 : 7.0
                let knotRect = CGRect(
                    x: CGFloat(p.x) - diameter * 0.5,
                    y: CGFloat(p.y) - diameter * 0.5,
                    width: diameter,
                    height: diameter
                )
                ctx.saveGState()
                ctx.setShadow(
                    offset: CGSize(width: 0, height: 1),
                    blur: 2.5,
                    color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28)
                )
                ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                ctx.fillEllipse(in: knotRect)
                ctx.restoreGState()

                ctx.setStrokeColor(accent)
                ctx.setLineWidth(isHovered ? 1.6 : 1.35)
                ctx.strokeEllipse(in: knotRect)
            }
        }
        ctx.restoreGState()
    }

    private func drawDimensionPill(in ctx: CGContext, selection: ASRect, text: String) {
        let scaleFactor = CGFloat(coordinator?.config.uiScale.factor ?? 1.0)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11.0 * scaleFactor, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedWhite: 0.96, alpha: 1),
            .kern: 0.2
        ]
        let sz = (text as NSString).size(withAttributes: attrs)
        let w = (sz.width + 14 * scaleFactor).rounded()
        let h = (sz.height + 5 * scaleFactor).rounded()
        let x = max(6, min(bounds.width - w - 6, CGFloat(selection.minX)))
        let y = selection.minY >= Double(h + 10)
            ? CGFloat(selection.minY) - h - 6
            : CGFloat(selection.minY) + 7
        let pillRect = CGRect(x: x, y: y, width: w, height: h)

        let path = CGPath(roundedRect: pillRect, cornerWidth: 5.0 * scaleFactor, cornerHeight: 5.0 * scaleFactor, transform: nil)
        drawFrostedMaterial(
            in: ctx,
            path: path,
            sampleRect: pillRect,
            dark: true,
            shadowOffsetY: 1.5,
            shadowBlur: 6,
            shadowAlpha: 0.22
        )
        (text as NSString).draw(
            at: NSPoint(x: pillRect.minX + (w - sz.width) * 0.5, y: pillRect.minY + (h - sz.height) * 0.5),
            withAttributes: attrs
        )
    }

    private func drawMagnifierHUD(in ctx: CGContext, at point: ASPoint) {
        let pxX = max(0, min(snapshot.rawBuffer.width - 1, Int((point.x * snapshot.backingScale).rounded())))
        let pxY = max(0, min(snapshot.rawBuffer.height - 1, Int((point.y * snapshot.backingScale).rounded())))
        let centerColor = snapshot.rawBuffer.pixel(x: pxX, y: pxY)

        let gridCells = 11
        let cellSize: CGFloat = 10.5
        let gridSide = (CGFloat(gridCells) * cellSize).rounded()
        let pad: CGFloat = 8.5
        let cardW = gridSide + pad * 2
        let cardH = gridSide + pad + 54

        var ox = CGFloat(point.x) + 22
        var oy = CGFloat(point.y) + 22
        if ox + cardW > bounds.width - 8 { ox = CGFloat(point.x) - cardW - 22 }
        if oy + cardH > bounds.height - 8 { oy = CGFloat(point.y) - cardH - 22 }

        let cardRect = CGRect(x: ox.rounded(), y: oy.rounded(), width: cardW, height: cardH)
        let bgPath = CGPath(roundedRect: cardRect, cornerWidth: 11.0, cornerHeight: 11.0, transform: nil)
        drawFrostedMaterial(
            in: ctx,
            path: bgPath,
            sampleRect: cardRect,
            dark: true,
            shadowOffsetY: 5,
            shadowBlur: 18,
            shadowAlpha: 0.34
        )

        ctx.saveGState()
        let gx0 = cardRect.minX + pad
        let gy0 = cardRect.minY + pad
        let gridRect = CGRect(x: gx0, y: gy0, width: gridSide, height: gridSide)
        let gridClip = CGPath(roundedRect: gridRect, cornerWidth: 6.5, cornerHeight: 6.5, transform: nil)

        ctx.saveGState()
        ctx.addPath(gridClip)
        ctx.clip()
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
                ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.05))
                ctx.setLineWidth(0.5)
                ctx.stroke(r)
            }
        }
        // Subtle optical crosshair bands + crisp center pixel reticle
        let centerRect = CGRect(
            x: gx0 + CGFloat(half) * cellSize,
            y: gy0 + CGFloat(half) * cellSize,
            width: cellSize,
            height: cellSize
        )
        ctx.setFillColor(CGColor(srgbRed: 0.14, green: 0.62, blue: 1.0, alpha: 0.16))
        ctx.fill(CGRect(x: centerRect.minX, y: gy0, width: cellSize, height: gridSide))
        ctx.fill(CGRect(x: gx0, y: centerRect.minY, width: gridSide, height: cellSize))

        ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.62))
        ctx.setLineWidth(2.2)
        ctx.stroke(centerRect)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.98))
        ctx.setLineWidth(1.2)
        ctx.stroke(centerRect)
        ctx.restoreGState()

        ctx.addPath(gridClip)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18))
        ctx.setLineWidth(0.8)
        ctx.strokePath()

        // Color dot + HEX + mini [C] keycap + live size or pixel coordinate
        let infoY = gy0 + gridSide + 7
        let swatchRect = CGRect(x: gx0, y: infoY + 1.5, width: 12.5, height: 12.5)
        ctx.setFillColor(centerColor.cgColor)
        ctx.fillEllipse(in: swatchRect)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.72))
        ctx.setLineWidth(1.0)
        ctx.strokeEllipse(in: swatchRect)

        let monoFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold)
        let coordFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
        let keycapFont = NSFont.monospacedSystemFont(ofSize: 8.5, weight: .semibold)
        let primaryAttrs: [NSAttributedString.Key: Any] = [.font: monoFont, .foregroundColor: NSColor.white]
        let coordAttrs: [NSAttributedString.Key: Any] = [.font: coordFont, .foregroundColor: NSColor(calibratedWhite: 0.74, alpha: 1)]
        let keycapAttrs: [NSAttributedString.Key: Any] = [.font: keycapFont, .foregroundColor: NSColor(calibratedWhite: 0.88, alpha: 1)]

        (centerColor.hexString as NSString).draw(at: NSPoint(x: gx0 + 17.5, y: infoY), withAttributes: primaryAttrs)

        // Mini [C] keycap pill on the right of HEX
        let capRect = CGRect(x: cardRect.maxX - pad - 18, y: infoY + 0.5, width: 18, height: 14)
        let capPath = CGPath(roundedRect: capRect, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
        ctx.addPath(capPath)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12))
        ctx.fillPath()
        ctx.addPath(capPath)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22))
        ctx.setLineWidth(0.6)
        ctx.strokePath()
        ("C" as NSString).draw(at: NSPoint(x: capRect.minX + 5.5, y: capRect.minY + 1.5), withAttributes: keycapAttrs)

        let secondLine: String
        if let sel = selection, sel.width >= 2 && sel.height >= 2 {
            let sw = max(1, Int((sel.width * snapshot.backingScale).rounded()))
            let sh = max(1, Int((sel.height * snapshot.backingScale).rounded()))
            secondLine = "\(sw) × \(sh) px"
        } else {
            secondLine = "(\(pxX), \(pxY))"
        }
        (secondLine as NSString).draw(at: NSPoint(x: gx0, y: infoY + 19.5), withAttributes: coordAttrs)
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
        let btnSide: CGFloat = 28 * uis
        let padX: CGFloat = 9.5 * uis
        let padY: CGFloat = 4.5 * uis
        let gap: CGFloat = 3.5 * uis
        let groupDividerExtra: CGFloat = 8.0 * uis
        let barH = (btnSide + padY * 2).rounded()
        let cornerRadius: CGFloat = 8.5 * uis

        let dark = isDarkTheme
        let iconNormal = dark ? NSColor(calibratedWhite: 0.93, alpha: 1) : NSColor(calibratedWhite: 0.14, alpha: 1)
        let iconDisabled = dark ? NSColor(calibratedWhite: 0.40, alpha: 1) : NSColor(calibratedWhite: 0.62, alpha: 1)
        let badgeKnockout = dark
            ? NSColor(srgbRed: 0.14, green: 0.15, blue: 0.18, alpha: 1)
            : NSColor(srgbRed: 0.97, green: 0.975, blue: 0.985, alpha: 1)
        let hoverBg = dark
            ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.11)
            : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.065)
        let pressBg = dark
            ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.17)
            : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.11)
        let cancelHoverBg = dark
            ? CGColor(srgbRed: 0.96, green: 0.28, blue: 0.28, alpha: 0.22)
            : CGColor(srgbRed: 0.94, green: 0.24, blue: 0.24, alpha: 0.12)
        let copyHoverBg = dark
            ? CGColor(srgbRed: 0.16, green: 0.78, blue: 0.48, alpha: 0.22)
            : CGColor(srgbRed: 0.10, green: 0.68, blue: 0.40, alpha: 0.13)
        let activeBg = dark
            ? CGColor(srgbRed: 0.14, green: 0.58, blue: 1.0, alpha: 0.25)
            : CGColor(srgbRed: 0.09, green: 0.56, blue: 1.0, alpha: 0.14)
        let activeBorder = CGColor(srgbRed: 0.09, green: 0.56, blue: 1.0, alpha: dark ? 0.48 : 0.30)
        let activeAccent = dark
            ? NSColor(srgbRed: 0.40, green: 0.75, blue: 1.0, alpha: 1)
            : NSColor(srgbRed: 0.05, green: 0.47, blue: 0.92, alpha: 1)
        let cancelHoverTint = dark
            ? NSColor(srgbRed: 1.0, green: 0.42, blue: 0.42, alpha: 1)
            : NSColor(srgbRed: 0.88, green: 0.20, blue: 0.22, alpha: 1)
        let copyTint = dark
            ? NSColor(srgbRed: 0.26, green: 0.86, blue: 0.54, alpha: 1)
            : NSColor(srgbRed: 0.08, green: 0.62, blue: 0.36, alpha: 1)
        let dividerStroke = dark
            ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10)
            : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.085)

        struct BarButtonSpec {
            let id: String
            let zone: Int // 0 = tools, 1 = pin/undo/ocr, 2 = cancel/longshot/save/copy
            let glyph: ToolbarGlyph
            let selected: Bool
            let enabled: Bool
            let tooltip: String
            let action: () -> Void
        }

        // Exact 16-item single-pill layout grouped subtly into 3 optical zones:
        // [□  ○  ╱  ↗  ✎  ▚  A  ①  ▣] | [📌  ↺  OCR] | [✕  ↕  ↓  ✓]
        var items: [BarButtonSpec] = []

        let orderedPrimaryTools: [AnnotationTool] = [
            .rect, .ellipse, .line, .arrow, .freehand, .blur, .text, .number, .glow
        ]
        for tool in orderedPrimaryTools where vis.isVisible(.tool(tool)) {
            let keyText = cfg.toolKeys.binding(for: tool).isUnbound ? "" : " · \(cfg.toolKeys.binding(for: tool).displayString)"
            items.append(BarButtonSpec(
                id: ToolbarSlot.tool(tool).key,
                zone: 0,
                glyph: glyph(for: tool),
                selected: activeTool == tool,
                enabled: true,
                tooltip: "\(tool.displayName)\(keyText)",
                action: { [weak self] in self?.selectTool(tool) }
            ))
        }

        if vis.isVisible(.pin), !(coordinator?.isInlinePinEdit ?? false) {
            let pinKey = cfg.hotkeys.pin.isUnbound ? "" : " · \(cfg.hotkeys.pin.displayString)"
            items.append(BarButtonSpec(
                id: "output.pin",
                zone: 1,
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
                zone: 1,
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
                zone: 1,
                glyph: .ocr,
                selected: false,
                enabled: true,
                tooltip: "识字\(ocrKey)",
                action: { [weak self] in self?.triggerOCR() }
            ))
        }

        items.append(BarButtonSpec(
            id: "file.cancel",
            zone: 2,
            glyph: .cancel,
            selected: false,
            enabled: true,
            tooltip: "取消 · Esc",
            action: { [weak self] in self?.attemptCancel() }
        ))

        if vis.isVisible(.longshot), !selectionLocked {
            let lsKey = cfg.hotkeys.longshot.isUnbound ? "" : " · \(cfg.hotkeys.longshot.displayString)"
            items.append(BarButtonSpec(
                id: "output.longshot",
                zone: 2,
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
                zone: 2,
                glyph: .save,
                selected: false,
                enabled: true,
                tooltip: "保存 · ⌘S",
                action: { [weak self] in self?.triggerSaveOutput(forceDialog: NSEvent.modifierFlags.contains(.option)) }
            ))
        }

        if vis.isVisible(.copy) {
            items.append(BarButtonSpec(
                id: "file.copy",
                zone: 2,
                glyph: .copy,
                selected: false,
                enabled: true,
                tooltip: "完成 · Enter",
                action: { [weak self] in self?.triggerCopyOutput() }
            ))
        }

        guard !items.isEmpty else { return }

        var zoneTransitions = 0
        for i in 1..<items.count where items[i].zone != items[i - 1].zone {
            zoneTransitions += 1
        }

        let totalWidth = (padX * 2 + CGFloat(items.count) * btnSide + CGFloat(max(0, items.count - 1)) * gap + CGFloat(zoneTransitions) * groupDividerExtra).rounded()
        var barX = (CGFloat(selection.maxX) - totalWidth).rounded()
        barX = max(8, min(bounds.width - totalWidth - 8, barX))

        let subMode = currentStyleSubBarMode(vis: vis)
        let secondRowH: CGFloat = (subMode == .none) ? 0 : (33 * uis).rounded()
        let calloutGap: CGFloat = 7.5 * uis
        let totalStackH = barH + ((subMode == .none) ? 0 : (secondRowH + calloutGap))

        var barY = (CGFloat(selection.maxY) + 8.5).rounded()
        if barY + totalStackH > bounds.height - 8 {
            let aboveY = (CGFloat(selection.minY) - totalStackH - 8.5).rounded()
            if aboveY >= 8 {
                barY = aboveY
            } else {
                barY = (CGFloat(selection.maxY) - totalStackH - 8.5).rounded()
            }
        }
        barY = max(8, min(bounds.height - barH - 8, barY))

        let barRect = CGRect(x: barX, y: barY, width: totalWidth, height: barH)
        mainToolbarRect = barRect

        let barPath = CGPath(roundedRect: barRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        drawFrostedMaterial(
            in: ctx,
            path: barPath,
            sampleRect: barRect,
            dark: dark,
            shadowOffsetY: 4.0,
            shadowBlur: 16,
            shadowAlpha: dark ? 0.36 : 0.18
        )

        let selectedObjToolKey: String? = {
            guard let selObj = document.selectedObject else { return nil }
            switch selObj.kind {
            case .rect: return ToolbarSlot.tool(.rect).key
            case .ellipse: return ToolbarSlot.tool(.ellipse).key
            case .line: return ToolbarSlot.tool(.line).key
            case .arrow: return ToolbarSlot.tool(.arrow).key
            case .freehand: return ToolbarSlot.tool(.freehand).key
            case .blur: return ToolbarSlot.tool(.blur).key
            case .text: return ToolbarSlot.tool(.text).key
            case .number: return ToolbarSlot.tool(.number).key
            case .glow: return ToolbarSlot.tool(.glow).key
            case .highlight: return ToolbarSlot.tool(.highlight).key
            }
        }()

        var activeToolAnchorX: CGFloat?
        var curX = barRect.minX + padX
        let itemY = barRect.minY + padY

        for (idx, item) in items.enumerated() {
            if idx > 0 && item.zone != items[idx - 1].zone {
                let divX = pixelSnap(curX - gap * 0.5 + groupDividerExtra * 0.5, lineWidth: 1.0)
                let divH = 14.0 * uis
                let divY0 = (barRect.midY - divH * 0.5).rounded()
                ctx.saveGState()
                ctx.setStrokeColor(dividerStroke)
                ctx.setLineWidth(1.0)
                ctx.move(to: CGPoint(x: divX, y: divY0))
                ctx.addLine(to: CGPoint(x: divX, y: divY0 + divH))
                ctx.strokePath()
                ctx.restoreGState()
                curX += groupDividerExtra
            }

            let itemRect = CGRect(x: curX, y: itemY, width: btnSide, height: btnSide)
            let isPressed = (pressedItemID == item.id && item.enabled)
            let isHovered = (hoveredItemID == item.id && item.enabled)
            let pillRect = itemRect.insetBy(dx: 0.8 * uis, dy: 0.8 * uis)

            if item.selected {
                activeToolAnchorX = itemRect.midX
                let p = CGPath(roundedRect: pillRect, cornerWidth: 6.0 * uis, cornerHeight: 6.0 * uis, transform: nil)
                ctx.addPath(p)
                ctx.setFillColor(activeBg)
                ctx.fillPath()
                ctx.addPath(p)
                ctx.setStrokeColor(activeBorder)
                ctx.setLineWidth(0.75)
                ctx.strokePath()
            } else if isPressed {
                let p = CGPath(roundedRect: pillRect, cornerWidth: 6.0 * uis, cornerHeight: 6.0 * uis, transform: nil)
                ctx.addPath(p)
                ctx.setFillColor(item.id == "file.cancel" ? cancelHoverBg : (item.id == "file.copy" ? copyHoverBg : pressBg))
                ctx.fillPath()
            } else if isHovered {
                let p = CGPath(roundedRect: pillRect, cornerWidth: 6.0 * uis, cornerHeight: 6.0 * uis, transform: nil)
                ctx.addPath(p)
                ctx.setFillColor(item.id == "file.cancel" ? cancelHoverBg : (item.id == "file.copy" ? copyHoverBg : hoverBg))
                ctx.fillPath()
            }

            if activeToolAnchorX == nil, item.id == selectedObjToolKey {
                activeToolAnchorX = itemRect.midX
            }

            let tint: NSColor
            if !item.enabled {
                tint = iconDisabled
            } else if item.selected {
                tint = activeAccent
            } else if item.id == "file.cancel" && (isHovered || isPressed) {
                tint = cancelHoverTint
            } else if item.id == "file.copy" {
                tint = copyTint
            } else {
                tint = iconNormal
            }

            if isPressed {
                ctx.saveGState()
                ctx.translateBy(x: itemRect.midX, y: itemRect.midY)
                ctx.scaleBy(x: 0.92, y: 0.92)
                ctx.translateBy(x: -itemRect.midX, y: -itemRect.midY)
                drawToolbarGlyph(item.glyph, in: ctx, rect: itemRect, uis: uis, color: tint, knockoutColor: badgeKnockout)
                ctx.restoreGState()
            } else {
                drawToolbarGlyph(item.glyph, in: ctx, rect: itemRect, uis: uis, color: tint, knockoutColor: badgeKnockout)
            }

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
                anchorX: activeToolAnchorX,
                height: secondRowH,
                uis: uis,
                dark: dark,
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
        let backing = CGFloat(max(1.0, snapshot.backingScale))
        // Snap stroke weight to exact integer physical pixels (2px on 2x Retina at 1.0x scale)
        let lw = max(1.0, (1.0 * uis * backing).rounded()) / backing

        ctx.saveGState()
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(lw)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch glyph {
        case .rect:
            let s = 13.0 * uis
            let r = pixelSnapRect(CGRect(x: cx - s * 0.5, y: cy - s * 0.5, width: s, height: s), lineWidth: lw)
            ctx.setLineJoin(.miter)
            ctx.stroke(r)

        case .ellipse:
            let s = 13.6 * uis
            ctx.strokeEllipse(in: CGRect(x: cx - s * 0.5, y: cy - s * 0.5, width: s, height: s))

        case .line:
            let d = 5.8 * uis
            ctx.move(to: CGPoint(x: cx - d, y: cy + d))
            ctx.addLine(to: CGPoint(x: cx + d, y: cy - d))
            ctx.strokePath()

        case .arrow:
            let d = 5.9 * uis
            ctx.move(to: CGPoint(x: cx - d, y: cy + d))
            ctx.addLine(to: CGPoint(x: cx + 3.4 * uis, y: cy - 3.4 * uis))
            ctx.strokePath()
            // Crisp solid triangular arrowhead at top-right
            let tip = CGPoint(x: cx + 6.0 * uis, y: cy - 6.0 * uis)
            let leftWing = CGPoint(x: cx + 1.2 * uis, y: cy - 5.6 * uis)
            let rightWing = CGPoint(x: cx + 5.6 * uis, y: cy - 1.2 * uis)
            ctx.move(to: tip)
            ctx.addLine(to: leftWing)
            ctx.addLine(to: rightWing)
            ctx.closePath()
            ctx.fillPath()

        case .pen:
            // Slender 45° marker/pencil silhouette with crisp 1px stroke
            let pNib = CGPoint(x: cx - 6.0 * uis, y: cy + 6.0 * uis)
            let pLeft = CGPoint(x: cx - 5.6 * uis, y: cy + 2.8 * uis)
            let pTopLeft = CGPoint(x: cx + 3.1 * uis, y: cy - 5.9 * uis)
            let pTopRight = CGPoint(x: cx + 5.9 * uis, y: cy - 3.1 * uis)
            let pBottom = CGPoint(x: cx - 2.8 * uis, y: cy + 5.6 * uis)
            ctx.move(to: pNib)
            ctx.addLine(to: pLeft)
            ctx.addLine(to: pTopLeft)
            ctx.addLine(to: pTopRight)
            ctx.addLine(to: pBottom)
            ctx.closePath()
            ctx.strokePath()

        case .mosaic:
            // Pixel-snapped 2×2 checkerboard inside 1px square frame
            let s = 13.0 * uis
            let outer = pixelSnapRect(CGRect(x: cx - s * 0.5, y: cy - s * 0.5, width: s, height: s), lineWidth: lw)
            let xm = (outer.midX * backing).rounded() / backing
            let ym = (outer.midY * backing).rounded() / backing
            ctx.setLineJoin(.miter)
            ctx.stroke(outer)
            ctx.fill(CGRect(x: outer.minX, y: outer.minY, width: xm - outer.minX, height: ym - outer.minY))
            ctx.fill(CGRect(x: xm, y: ym, width: outer.maxX - xm, height: outer.maxY - ym))

        case .text:
            let top = CGPoint(x: cx, y: cy - 6.4 * uis)
            let bl = CGPoint(x: cx - 5.2 * uis, y: cy + 6.2 * uis)
            let br = CGPoint(x: cx + 5.2 * uis, y: cy + 6.2 * uis)
            ctx.move(to: bl)
            ctx.addLine(to: top)
            ctx.addLine(to: br)
            let barY = pixelSnap(cy + 1.9 * uis, lineWidth: lw)
            ctx.move(to: CGPoint(x: cx - 3.3 * uis, y: barY))
            ctx.addLine(to: CGPoint(x: cx + 3.3 * uis, y: barY))
            ctx.strokePath()

        case .number:
            let s = 14.6 * uis
            ctx.strokeEllipse(in: CGRect(x: cx - s * 0.5, y: cy - s * 0.5, width: s, height: s))
            let font = NSFont(name: "TimesNewRomanPS-BoldMT", size: 10.6 * uis)
                ?? NSFont.systemFont(ofSize: 10.2 * uis, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let str: NSString = "1"
            let sz = str.size(withAttributes: attrs)
            str.draw(at: NSPoint(x: cx - sz.width * 0.5, y: cy - sz.height * 0.5), withAttributes: attrs)

        case .spotlight:
            let outerS = 13.2 * uis
            let innerS = 5.8 * uis
            let outerR = pixelSnapRect(CGRect(x: cx - outerS * 0.5, y: cy - outerS * 0.5, width: outerS, height: outerS), lineWidth: lw)
            let innerR = pixelSnapRect(CGRect(x: cx - innerS * 0.5, y: cy - innerS * 0.5, width: innerS, height: innerS), lineWidth: lw)
            ctx.setLineJoin(.miter)
            ctx.stroke(outerR)
            ctx.stroke(innerR)

        case .pin:
            // Classic curved bell-collar thumbtack rotated +45° with tapered sharp needle
            ctx.translateBy(x: cx, y: cy)
            ctx.rotate(by: .pi / 4.0)
            let head = CGMutablePath()
            // Top cap rim
            head.move(to: CGPoint(x: -3.2 * uis, y: -6.3 * uis))
            head.addLine(to: CGPoint(x: 3.2 * uis, y: -6.3 * uis))
            head.addLine(to: CGPoint(x: 3.2 * uis, y: -4.9 * uis))
            // Concave waist flaring smoothly into bell collar
            head.addLine(to: CGPoint(x: 1.85 * uis, y: -4.5 * uis))
            head.addQuadCurve(
                to: CGPoint(x: 4.35 * uis, y: 0.95 * uis),
                control: CGPoint(x: 2.15 * uis, y: -1.1 * uis)
            )
            head.addLine(to: CGPoint(x: -4.35 * uis, y: 0.95 * uis))
            head.addQuadCurve(
                to: CGPoint(x: -1.85 * uis, y: -4.5 * uis),
                control: CGPoint(x: -2.15 * uis, y: -1.1 * uis)
            )
            head.addLine(to: CGPoint(x: -3.2 * uis, y: -4.9 * uis))
            head.closeSubpath()
            ctx.addPath(head)
            ctx.fillPath()

            // Sharp tapered filled needle
            let needle = CGMutablePath()
            needle.move(to: CGPoint(x: -0.72 * uis, y: 0.9 * uis))
            needle.addLine(to: CGPoint(x: 0.72 * uis, y: 0.9 * uis))
            needle.addLine(to: CGPoint(x: 0, y: 7.1 * uis))
            needle.closeSubpath()
            ctx.addPath(needle)
            ctx.fillPath()

        case .undo:
            // Crisp circular arc starting at 9 o'clock curving over top/right/bottom + solid downward triangle at 9 o'clock
            let r = 5.5 * uis
            let arcCenterX = cx + 0.5 * uis
            ctx.addArc(
                center: CGPoint(x: arcCenterX, y: cy),
                radius: r,
                startAngle: -.pi,
                endAngle: 0.52 * .pi,
                clockwise: false
            )
            ctx.strokePath()

            let ax = arcCenterX - r
            let ay = cy
            ctx.move(to: CGPoint(x: ax - 2.2 * uis, y: ay - 0.6 * uis))
            ctx.addLine(to: CGPoint(x: ax + 2.2 * uis, y: ay - 0.6 * uis))
            ctx.addLine(to: CGPoint(x: ax, y: ay + 2.5 * uis))
            ctx.closePath()
            ctx.fillPath()

        case .ocr:
            // Compact rounded-rect badge with bold slanted knocked-out "OCR"
            let bw = 19.6 * uis
            let bh = 13.0 * uis
            let rawBadge = CGRect(x: cx - bw * 0.5, y: cy - bh * 0.5, width: bw, height: bh)
            let badgeRect = CGRect(
                x: (rawBadge.minX * backing).rounded() / backing,
                y: (rawBadge.minY * backing).rounded() / backing,
                width: (rawBadge.width * backing).rounded() / backing,
                height: (rawBadge.height * backing).rounded() / backing
            )
            let bp = CGPath(roundedRect: badgeRect, cornerWidth: 2.5 * uis, cornerHeight: 2.5 * uis, transform: nil)
            ctx.addPath(bp)
            ctx.fillPath()
            let font = NSFont.systemFont(ofSize: 7.5 * uis, weight: .black)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: knockoutColor,
                .obliqueness: 0.14,
                .kern: -0.25 * uis
            ]
            let str: NSString = "OCR"
            let sz = str.size(withAttributes: attrs)
            str.draw(
                at: NSPoint(x: badgeRect.midX - sz.width * 0.5 - 0.25 * uis, y: badgeRect.midY - sz.height * 0.5),
                withAttributes: attrs
            )

        case .cancel:
            let d = 5.3 * uis
            ctx.move(to: CGPoint(x: cx - d, y: cy - d))
            ctx.addLine(to: CGPoint(x: cx + d, y: cy + d))
            ctx.move(to: CGPoint(x: cx + d, y: cy - d))
            ctx.addLine(to: CGPoint(x: cx - d, y: cy + d))
            ctx.strokePath()

        case .longshot:
            let bw = 6.8 * uis
            let bh = 8.2 * uis
            let box = pixelSnapRect(CGRect(x: cx - bw * 0.5, y: cy - bh * 0.5, width: bw, height: bh), lineWidth: lw)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: 1.0 * uis, cornerHeight: 1.0 * uis, transform: nil))
            ctx.strokePath()
            // Flatter, wider top & bottom chevrons
            ctx.move(to: CGPoint(x: cx - 2.7 * uis, y: cy - 6.0 * uis))
            ctx.addLine(to: CGPoint(x: cx, y: cy - 8.0 * uis))
            ctx.addLine(to: CGPoint(x: cx + 2.7 * uis, y: cy - 6.0 * uis))
            ctx.move(to: CGPoint(x: cx - 2.7 * uis, y: cy + 6.0 * uis))
            ctx.addLine(to: CGPoint(x: cx, y: cy + 8.0 * uis))
            ctx.addLine(to: CGPoint(x: cx + 2.7 * uis, y: cy + 6.0 * uis))
            ctx.strokePath()

        case .save:
            // Shallow pixel-snapped tray [ _ ]
            let xL = pixelSnap(cx - 6.2 * uis, lineWidth: lw)
            let xR = pixelSnap(cx + 6.2 * uis, lineWidth: lw)
            let yBot = pixelSnap(cy + 6.0 * uis, lineWidth: lw)
            let yLip = pixelSnap(cy + 3.4 * uis, lineWidth: lw)
            let xMid = pixelSnap(cx, lineWidth: lw)
            ctx.setLineJoin(.miter)
            ctx.move(to: CGPoint(x: xL, y: yLip))
            ctx.addLine(to: CGPoint(x: xL, y: yBot))
            ctx.addLine(to: CGPoint(x: xR, y: yBot))
            ctx.addLine(to: CGPoint(x: xR, y: yLip))
            ctx.strokePath()

            // Vertical arrow stem + compact solid triangle head
            ctx.setLineJoin(.round)
            ctx.move(to: CGPoint(x: xMid, y: cy - 6.2 * uis))
            ctx.addLine(to: CGPoint(x: xMid, y: cy + 1.4 * uis))
            ctx.strokePath()

            ctx.move(to: CGPoint(x: xMid - 2.9 * uis, y: cy + 0.5 * uis))
            ctx.addLine(to: CGPoint(x: xMid + 2.9 * uis, y: cy + 0.5 * uis))
            ctx.addLine(to: CGPoint(x: xMid, y: cy + 3.9 * uis))
            ctx.closePath()
            ctx.fillPath()

        case .copy:
            let checkLW = max(1.0, (1.15 * uis * backing).rounded()) / backing
            ctx.setLineWidth(checkLW)
            ctx.move(to: CGPoint(x: cx - 6.0 * uis, y: cy + 0.6 * uis))
            ctx.addLine(to: CGPoint(x: cx - 1.8 * uis, y: cy + 5.2 * uis))
            ctx.addLine(to: CGPoint(x: cx + 6.4 * uis, y: cy - 5.0 * uis))
            ctx.strokePath()

        case .highlight:
            drawSymbol("highlighter", in: rect, pointSize: 13.0 * uis, color: color)
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
        anchorX: CGFloat?,
        height: CGFloat,
        uis: CGFloat,
        dark: Bool,
        textColor: NSColor,
        cfg: AirSnipConfig
    ) {
        let vis = cfg.toolbar
        let visibleSwatchIndices = (0..<ColorPalette.swatchCount).filter { vis.isVisible(.color($0)) }
        let swatchSlot: CGFloat = 23 * uis
        let swatchGap: CGFloat = 2.5 * uis
        let swatchesW: CGFloat = visibleSwatchIndices.isEmpty
            ? 0
            : (CGFloat(visibleSwatchIndices.count) * swatchSlot + CGFloat(visibleSwatchIndices.count - 1) * swatchGap)

        let rowW: CGFloat
        switch mode {
        case .none:
            return
        case .blur:
            rowW = (106 * uis).rounded()
        case .stroke(let showFill):
            let leftW: CGFloat = (3 * 24 + 2 * 3 + (showFill ? 29 : 0)) * uis
            rowW = (14 * uis + leftW + (swatchesW > 0 ? (13 * uis + swatchesW) : 0)).rounded()
        case .text:
            let textControlsW: CGFloat = 270 * uis
            rowW = (textControlsW + (swatchesW > 0 ? (12 * uis + swatchesW + 6 * uis) : 0)).rounded()
        }

        let targetCenter = anchorX ?? (mainBar.minX + min(mainBar.width * 0.5, rowW * 0.5))
        var rowX = (targetCenter - rowW * 0.5).rounded()
        // Keep sub-bar comfortably within horizontal bounds and visually connected to mainBar
        let minConnectedX = max(8, mainBar.minX - 24 * uis)
        let maxConnectedX = min(bounds.width - rowW - 8, max(minConnectedX, mainBar.maxX - rowW + 24 * uis))
        rowX = max(minConnectedX, min(maxConnectedX, rowX))
        rowX = max(8, min(bounds.width - rowW - 8, rowX))

        let calloutGap: CGFloat = 7 * uis
        let placedBelow = (mainBar.maxY + height + calloutGap <= bounds.height - 6)
        let rowY = (placedBelow ? (mainBar.maxY + calloutGap) : (mainBar.minY - height - calloutGap)).rounded()
        let rect = CGRect(x: rowX, y: rowY, width: rowW, height: height)
        secondRowRect = rect

        let bubblePath = makeCalloutBubblePath(
            rect: rect,
            cornerRadius: 6.5 * uis,
            arrowX: anchorX,
            arrowOnTop: placedBelow,
            arrowWidth: 10.5 * uis,
            arrowHeight: 5.0 * uis
        )
        drawFrostedMaterial(
            in: ctx,
            path: bubblePath,
            sampleRect: rect,
            dark: dark,
            shadowOffsetY: 3.0,
            shadowBlur: 12,
            shadowAlpha: dark ? 0.32 : 0.18
        )

        let dividerColor = dark
            ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.13)
            : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.10)
        let hoverCircle = dark
            ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.09)
            : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.06)
        let activeHalo = dark
            ? CGColor(srgbRed: 0.12, green: 0.56, blue: 1.0, alpha: 0.24)
            : CGColor(srgbRed: 0.09, green: 0.56, blue: 1.0, alpha: 0.15)
        let activeDot = CGColor(srgbRed: 0.09, green: 0.56, blue: 1.0, alpha: 1.0)
        var curX = rect.minX + 7 * uis

        switch mode {
        case .none:
            break

        case .blur:
            let presets: [(Double, CGFloat, String)] = [(8, 2.6, "轻"), (16, 4.1, "中"), (28, 5.7, "强")]
            let activeBlur: Double = {
                if let obj = document.selectedObject, case .blur(_, _, let br, _) = obj.kind { return br }
                return currentBlurRadius
            }()
            for (idx, preset) in presets.enumerated() {
                let itemID = "blur.preset.\(idx)"
                let bRect = CGRect(x: curX, y: rect.minY + 4 * uis, width: 28 * uis, height: height - 8 * uis)
                let isSel = abs(activeBlur - preset.0) < 3.5
                if isSel || hoveredItemID == itemID {
                    let hr: CGFloat = 10.0 * uis
                    ctx.setFillColor(isSel ? activeHalo : hoverCircle)
                    ctx.fillEllipse(in: CGRect(x: bRect.midX - hr, y: bRect.midY - hr, width: hr * 2, height: hr * 2))
                }
                let r = preset.1 * uis
                ctx.setFillColor(isSel ? activeDot : textColor.cgColor)
                ctx.fillEllipse(in: CGRect(x: bRect.midX - r, y: bRect.midY - r, width: r * 2, height: r * 2))
                let val = preset.0
                toolbarHitItems.append(ToolbarHitItem(
                    id: itemID,
                    rect: bRect,
                    tooltip: preset.2,
                    action: { [weak self] in self?.selectBlurRadiusPreset(val) },
                    doubleClickAction: nil
                ))
                curX += 31 * uis
            }

        case .stroke(let showFill):
            let presets: [(Double, CGFloat, String)] = [(2, 2.0, "细"), (4, 3.4, "中"), (8, 5.0, "粗")]
            let activeWidth: Double = document.selectedObject?.style.lineWidth ?? currentLineWidth
            for (idx, preset) in presets.enumerated() {
                let itemID = "stroke.preset.\(idx)"
                let bRect = CGRect(x: curX, y: rect.minY + 4 * uis, width: 24 * uis, height: height - 8 * uis)
                let isSel = abs(activeWidth - preset.0) < 1.2
                if isSel || hoveredItemID == itemID {
                    let hr: CGFloat = 9.5 * uis
                    ctx.setFillColor(isSel ? activeHalo : hoverCircle)
                    ctx.fillEllipse(in: CGRect(x: bRect.midX - hr, y: bRect.midY - hr, width: hr * 2, height: hr * 2))
                }
                let r = preset.1 * uis
                ctx.setFillColor(isSel ? activeDot : textColor.cgColor)
                ctx.fillEllipse(in: CGRect(x: bRect.midX - r, y: bRect.midY - r, width: r * 2, height: r * 2))
                let val = preset.0
                toolbarHitItems.append(ToolbarHitItem(
                    id: itemID,
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
                let fRect = CGRect(x: curX + 2 * uis, y: rect.minY + 4 * uis, width: 24 * uis, height: height - 8 * uis)
                if isFilledNow || hoveredItemID == "edit.fill" {
                    ctx.addPath(CGPath(roundedRect: fRect, cornerWidth: 5 * uis, cornerHeight: 5 * uis, transform: nil))
                    ctx.setFillColor(isFilledNow ? activeHalo : hoverCircle)
                    ctx.fillPath()
                }
                // Crisp custom 1px fill-toggle glyph
                let chipSide = 11.4 * uis
                let chipRect = pixelSnapRect(
                    CGRect(x: fRect.midX - chipSide * 0.5, y: fRect.midY - chipSide * 0.5, width: chipSide, height: chipSide),
                    lineWidth: 1.0
                )
                let chipPath = CGPath(roundedRect: chipRect, cornerWidth: 2.0 * uis, cornerHeight: 2.0 * uis, transform: nil)
                if isFilledNow {
                    ctx.addPath(chipPath)
                    ctx.setFillColor(activeDot)
                    ctx.fillPath()
                } else {
                    ctx.saveGState()
                    ctx.addPath(chipPath)
                    ctx.setStrokeColor(textColor.cgColor)
                    ctx.setLineWidth(1.0)
                    ctx.setLineDash(phase: 0, lengths: [2.2 * uis, 1.8 * uis])
                    ctx.strokePath()
                    ctx.restoreGState()
                }
                toolbarHitItems.append(ToolbarHitItem(
                    id: "edit.fill",
                    rect: fRect,
                    tooltip: "填充",
                    action: { [weak self] in self?.toggleFill() },
                    doubleClickAction: nil
                ))
                curX = fRect.maxX + 3 * uis
            }

            if !visibleSwatchIndices.isEmpty {
                let sepX = pixelSnap(curX + 4 * uis, lineWidth: 1.0)
                ctx.setStrokeColor(dividerColor)
                ctx.setLineWidth(1.0)
                ctx.move(to: CGPoint(x: sepX, y: rect.minY + 7 * uis))
                ctx.addLine(to: CGPoint(x: sepX, y: rect.maxY - 7 * uis))
                ctx.strokePath()
                curX = sepX + 6 * uis
                drawInlineSwatches(
                    in: ctx,
                    indices: visibleSwatchIndices,
                    startX: curX,
                    rowRect: rect,
                    slotSide: swatchSlot,
                    gap: swatchGap,
                    uis: uis,
                    dark: dark,
                    cfg: cfg
                )
            }

        case .text:
            let effectiveState = currentEffectiveTextAttributes
            let capsuleFill = dark
                ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.07)
                : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.045)
            let capsuleBorder = dark
                ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12)
                : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.09)

            // 1. Font family selector capsule
            let fontBtnRect = CGRect(x: rect.minX + 6 * uis, y: rect.minY + 4 * uis, width: 112 * uis, height: height - 8 * uis)
            let fp = CGPath(roundedRect: fontBtnRect, cornerWidth: 5 * uis, cornerHeight: 5 * uis, transform: nil)
            ctx.addPath(fp)
            ctx.setFillColor(hoveredItemID == "text.family" ? hoverCircle : capsuleFill)
            ctx.fillPath()
            ctx.addPath(fp)
            ctx.setStrokeColor(capsuleBorder)
            ctx.setLineWidth(0.75)
            ctx.strokePath()

            let labelFont = NSFont.systemFont(ofSize: 11.0 * uis, weight: .medium)
            let attrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: textColor]
            let shortFam = effectiveState.family.count > 13 ? String(effectiveState.family.prefix(12)) + "…" : effectiveState.family
            let famSz = (shortFam as NSString).size(withAttributes: attrs)
            (shortFam as NSString).draw(
                at: NSPoint(x: fontBtnRect.minX + 7 * uis, y: fontBtnRect.midY - famSz.height * 0.5),
                withAttributes: attrs
            )
            // Crisp vector downward chevron
            let chevX = fontBtnRect.maxX - 9 * uis
            let chevY = fontBtnRect.midY
            ctx.setStrokeColor(textColor.withAlphaComponent(0.7).cgColor)
            ctx.setLineWidth(1.1 * uis)
            ctx.move(to: CGPoint(x: chevX - 2.6 * uis, y: chevY - 1.2 * uis))
            ctx.addLine(to: CGPoint(x: chevX, y: chevY + 1.6 * uis))
            ctx.addLine(to: CGPoint(x: chevX + 2.6 * uis, y: chevY - 1.2 * uis))
            ctx.strokePath()

            toolbarHitItems.append(ToolbarHitItem(
                id: "text.family",
                rect: fontBtnRect,
                tooltip: "字体",
                action: { [weak self] in self?.popFontMenu(from: fontBtnRect) },
                doubleClickAction: nil
            ))

            // 2. Bold & Italic toggles
            let bRect = CGRect(x: fontBtnRect.maxX + 4 * uis, y: rect.minY + 4 * uis, width: 24 * uis, height: height - 8 * uis)
            if effectiveState.bold || hoveredItemID == "text.bold" {
                ctx.setFillColor(effectiveState.bold ? activeHalo : hoverCircle)
                ctx.addPath(CGPath(roundedRect: bRect, cornerWidth: 5 * uis, cornerHeight: 5 * uis, transform: nil))
                ctx.fillPath()
            }
            drawSymbol("bold", in: bRect, pointSize: 11.0 * uis, color: effectiveState.bold ? NSColor(srgbRed: 0.09, green: 0.56, blue: 1.0, alpha: 1) : textColor)
            toolbarHitItems.append(ToolbarHitItem(id: "text.bold", rect: bRect, tooltip: "粗体", action: { [weak self] in self?.toggleBold() }, doubleClickAction: nil))

            let iRect = CGRect(x: bRect.maxX + 2 * uis, y: rect.minY + 4 * uis, width: 24 * uis, height: height - 8 * uis)
            if effectiveState.italic || hoveredItemID == "text.italic" {
                ctx.setFillColor(effectiveState.italic ? activeHalo : hoverCircle)
                ctx.addPath(CGPath(roundedRect: iRect, cornerWidth: 5 * uis, cornerHeight: 5 * uis, transform: nil))
                ctx.fillPath()
            }
            drawSymbol("italic", in: iRect, pointSize: 11.0 * uis, color: effectiveState.italic ? NSColor(srgbRed: 0.09, green: 0.56, blue: 1.0, alpha: 1) : textColor)
            toolbarHitItems.append(ToolbarHitItem(id: "text.italic", rect: iRect, tooltip: "斜体", action: { [weak self] in self?.toggleItalic() }, doubleClickAction: nil))

            // 3. Unified `- 24 +` stepper capsule
            let stepperRect = CGRect(x: iRect.maxX + 5 * uis, y: rect.minY + 4 * uis, width: 76 * uis, height: height - 8 * uis)
            let spPath = CGPath(roundedRect: stepperRect, cornerWidth: 5 * uis, cornerHeight: 5 * uis, transform: nil)
            ctx.addPath(spPath)
            ctx.setFillColor(capsuleFill)
            ctx.fillPath()
            ctx.addPath(spPath)
            ctx.setStrokeColor(capsuleBorder)
            ctx.setLineWidth(0.75)
            ctx.strokePath()

            let minusRect = CGRect(x: stepperRect.minX, y: stepperRect.minY, width: 22 * uis, height: stepperRect.height)
            let plusRect = CGRect(x: stepperRect.maxX - 22 * uis, y: stepperRect.minY, width: 22 * uis, height: stepperRect.height)
            let midRect = CGRect(x: minusRect.maxX, y: stepperRect.minY, width: stepperRect.width - 44 * uis, height: stepperRect.height)

            // Crisp vector minus / plus
            ctx.setStrokeColor(textColor.cgColor)
            ctx.setLineWidth(1.15 * uis)
            ctx.move(to: CGPoint(x: minusRect.midX - 3.6 * uis, y: minusRect.midY))
            ctx.addLine(to: CGPoint(x: minusRect.midX + 3.6 * uis, y: minusRect.midY))
            ctx.move(to: CGPoint(x: plusRect.midX - 3.6 * uis, y: plusRect.midY))
            ctx.addLine(to: CGPoint(x: plusRect.midX + 3.6 * uis, y: plusRect.midY))
            ctx.move(to: CGPoint(x: plusRect.midX, y: plusRect.midY - 3.6 * uis))
            ctx.addLine(to: CGPoint(x: plusRect.midX, y: plusRect.midY + 3.6 * uis))
            ctx.strokePath()

            let numFont = NSFont.monospacedDigitSystemFont(ofSize: 11.0 * uis, weight: .medium)
            let numAttrs: [NSAttributedString.Key: Any] = [.font: numFont, .foregroundColor: textColor]
            let sizeStr = "\(Int(effectiveState.size.rounded()))"
            let numSz = (sizeStr as NSString).size(withAttributes: numAttrs)
            (sizeStr as NSString).draw(
                at: NSPoint(x: midRect.midX - numSz.width * 0.5, y: midRect.midY - numSz.height * 0.5),
                withAttributes: numAttrs
            )

            toolbarHitItems.append(ToolbarHitItem(id: "text.size.down", rect: minusRect, tooltip: "减小字号", action: { [weak self] in self?.stepFontSize(-2) }, doubleClickAction: nil))
            toolbarHitItems.append(ToolbarHitItem(id: "text.size.up", rect: plusRect, tooltip: "增大字号", action: { [weak self] in self?.stepFontSize(2) }, doubleClickAction: nil))

            if !visibleSwatchIndices.isEmpty {
                let sepX = pixelSnap(stepperRect.maxX + 6 * uis, lineWidth: 1.0)
                ctx.setStrokeColor(dividerColor)
                ctx.setLineWidth(1.0)
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
                    dark: dark,
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
        dark: Bool,
        cfg: AirSnipConfig
    ) {
        var sx = startX
        let slotY = rowRect.midY - slotSide * 0.5
        for idx in indices {
            let itemID = "swatch.\(idx)"
            let itemRect = CGRect(x: sx, y: slotY, width: slotSide, height: slotSide)
            let isHovered = (hoveredItemID == itemID)
            let isActive = (activeColorIndex == idx)
            let swSide = (isHovered ? 16.6 : 15.2) * uis
            let swRect = CGRect(
                x: itemRect.midX - swSide * 0.5,
                y: itemRect.midY - swSide * 0.5,
                width: swSide,
                height: swSide
            )
            let col = cfg.swatchColors[idx]

            // Circular color dot
            ctx.saveGState()
            ctx.setShadow(
                offset: CGSize(width: 0, height: 1),
                blur: 2.0,
                color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.16)
            )
            ctx.setFillColor(col.cgColor)
            ctx.fillEllipse(in: swRect)
            ctx.restoreGState()

            // Crisp perimeter hairline so pure white / black swatches never vanish into glass
            let lum = (0.299 * Double(col.r) + 0.587 * Double(col.g) + 0.114 * Double(col.b)) / 255.0
            let rimColor = (dark && lum < 0.22)
                ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.28)
                : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.18)
            ctx.setStrokeColor(rimColor)
            ctx.setLineWidth(0.8)
            ctx.strokeEllipse(in: swRect)

            if isActive {
                let ring = swRect.insetBy(dx: -2.4 * uis, dy: -2.4 * uis)
                ctx.setStrokeColor(CGColor(srgbRed: 0.09, green: 0.56, blue: 1.0, alpha: 0.95))
                ctx.setLineWidth(1.4 * uis)
                ctx.strokeEllipse(in: ring)

                // Contrast-aware inner checkmark ✓
                let checkColor = lum > 0.68
                    ? CGColor(srgbRed: 0.10, green: 0.12, blue: 0.15, alpha: 0.92)
                    : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.96)
                ctx.saveGState()
                ctx.setStrokeColor(checkColor)
                ctx.setLineWidth(1.35 * uis)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                let cx = swRect.midX
                let cy = swRect.midY
                ctx.move(to: CGPoint(x: cx - 3.3 * uis, y: cy + 0.2 * uis))
                ctx.addLine(to: CGPoint(x: cx - 0.8 * uis, y: cy + 2.7 * uis))
                ctx.addLine(to: CGPoint(x: cx + 3.6 * uis, y: cy - 2.4 * uis))
                ctx.strokePath()
                ctx.restoreGState()
            }

            toolbarHitItems.append(ToolbarHitItem(
                id: itemID,
                rect: itemRect,
                tooltip: "双击自定义颜色",
                action: { [weak self] in self?.selectColorSwatch(idx) },
                doubleClickAction: { [weak self] in self?.openColorPicker(for: idx, anchorRect: itemRect) }
            ))
            sx += slotSide + gap
        }
    }

    private func drawColorPickerPopover(in ctx: CGContext) {
        guard var picker = colorPicker else { return }
        let pw: CGFloat = 216
        let ph: CGFloat = 210
        let anchorBar = (secondRowRect != .zero) ? secondRowRect : mainToolbarRect
        let swatchItem = toolbarHitItems.first(where: { $0.id == "swatch.\(picker.swatchIndex)" })?.rect ?? anchorBar
        var px = (swatchItem.midX - pw * 0.5).rounded()
        px = max(8, min(bounds.width - pw - 8, px))

        let stackBottom = max(mainToolbarRect.maxY, secondRowRect.maxY)
        let stackTop = (secondRowRect != .zero) ? min(mainToolbarRect.minY, secondRowRect.minY) : mainToolbarRect.minY
        let calloutGap: CGFloat = 8
        var placedBelow = true
        var py = (stackBottom + calloutGap).rounded()
        if py + ph > bounds.height - 8 {
            py = max(8, (stackTop - ph - calloutGap).rounded())
            placedBelow = false
        }

        let panelRect = CGRect(x: px, y: py, width: pw, height: ph)
        picker.panelRect = panelRect

        let dark = isDarkTheme
        let bubblePath = makeCalloutBubblePath(
            rect: panelRect,
            cornerRadius: 10.0,
            arrowX: swatchItem.midX,
            arrowOnTop: placedBelow,
            arrowWidth: 12.0,
            arrowHeight: 5.5
        )
        drawFrostedMaterial(
            in: ctx,
            path: bubblePath,
            sampleRect: panelRect,
            dark: dark,
            shadowOffsetY: 5,
            shadowBlur: 18,
            shadowAlpha: dark ? 0.38 : 0.24
        )

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let pureHue = ColorPalette.hsvToRGB(h: picker.hue, s: 1.0, v: 1.0)
        let liveColor = ColorPalette.hsvToRGB(h: picker.hue, s: picker.sat, v: picker.val)

        // 1. Smooth continuous 2D Saturation-Value gradient square
        let svRect = CGRect(x: panelRect.minX + 12, y: panelRect.minY + 12, width: pw - 24, height: 100)
        picker.svRect = svRect
        let svClip = CGPath(roundedRect: svRect, cornerWidth: 6.5, cornerHeight: 6.5, transform: nil)

        ctx.saveGState()
        ctx.addPath(svClip)
        ctx.clip()
        if let satGrad = CGGradient(
            colorsSpace: colorSpace,
            colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), pureHue.cgColor] as CFArray,
            locations: [0.0, 1.0]
        ) {
            ctx.drawLinearGradient(
                satGrad,
                start: CGPoint(x: svRect.minX, y: svRect.midY),
                end: CGPoint(x: svRect.maxX, y: svRect.midY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        if let valGrad = CGGradient(
            colorsSpace: colorSpace,
            colors: [CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0), CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)] as CFArray,
            locations: [0.0, 1.0]
        ) {
            ctx.drawLinearGradient(
                valGrad,
                start: CGPoint(x: svRect.midX, y: svRect.minY),
                end: CGPoint(x: svRect.midX, y: svRect.maxY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        ctx.restoreGState()

        ctx.addPath(svClip)
        ctx.setStrokeColor(dark ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16) : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.14))
        ctx.setLineWidth(0.8)
        ctx.strokePath()

        // SV live-filled loupe ring
        let knobX = svRect.minX + CGFloat(picker.sat) * svRect.width
        let knobY = svRect.minY + CGFloat(1.0 - picker.val) * svRect.height
        let svKnobRect = CGRect(x: knobX - 5.5, y: knobY - 5.5, width: 11, height: 11)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.42))
        ctx.setFillColor(liveColor.cgColor)
        ctx.fillEllipse(in: svKnobRect)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.setLineWidth(2.0)
        ctx.strokeEllipse(in: svKnobRect)
        ctx.restoreGState()

        // 2. Smooth 7-stop Rainbow Hue pill slider
        let hueRect = CGRect(x: svRect.minX, y: svRect.maxY + 11, width: svRect.width, height: 10)
        picker.hueRect = hueRect
        let hueClip = CGPath(roundedRect: hueRect, cornerWidth: 5, cornerHeight: 5, transform: nil)
        ctx.saveGState()
        ctx.addPath(hueClip)
        ctx.clip()
        let hueStops: [CGColor] = [0.0, 60.0, 120.0, 180.0, 240.0, 300.0, 360.0].map {
            ColorPalette.hsvToRGB(h: $0, s: 1.0, v: 1.0).cgColor
        }
        let hueLocs: [CGFloat] = [0.0, 1.0 / 6.0, 2.0 / 6.0, 3.0 / 6.0, 4.0 / 6.0, 5.0 / 6.0, 1.0]
        if let hueGrad = CGGradient(colorsSpace: colorSpace, colors: hueStops as CFArray, locations: hueLocs) {
            ctx.drawLinearGradient(
                hueGrad,
                start: CGPoint(x: hueRect.minX, y: hueRect.midY),
                end: CGPoint(x: hueRect.maxX, y: hueRect.midY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        ctx.restoreGState()

        ctx.addPath(hueClip)
        ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.14))
        ctx.setLineWidth(0.6)
        ctx.strokePath()

        let rawHueX = hueRect.minX + CGFloat(picker.hue / 360.0) * hueRect.width
        let hueKnobX = max(hueRect.minX + 5.0, min(hueRect.maxX - 5.0, rawHueX))
        let hueThumb = CGRect(x: hueKnobX - 6.5, y: hueRect.midY - 6.5, width: 13, height: 13)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 2.5, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.36))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: hueThumb)
        ctx.restoreGState()
        ctx.setFillColor(pureHue.cgColor)
        ctx.fillEllipse(in: hueThumb.insetBy(dx: 3.0, dy: 3.0))

        // 3. Live HEX readout & swatch preview strip
        let hexY = hueRect.maxY + 10
        let previewDot = CGRect(x: svRect.minX, y: hexY + 1, width: 13, height: 13)
        ctx.setFillColor(liveColor.cgColor)
        ctx.fillEllipse(in: previewDot)
        ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.18))
        ctx.setLineWidth(0.8)
        ctx.strokeEllipse(in: previewDot)

        let hexFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold)
        let primaryText = dark ? NSColor(calibratedWhite: 0.92, alpha: 1) : NSColor(calibratedWhite: 0.18, alpha: 1)
        let secondaryText = dark ? NSColor(calibratedWhite: 0.56, alpha: 1) : NSColor(calibratedWhite: 0.50, alpha: 1)
        (liveColor.hexString as NSString).draw(
            at: NSPoint(x: svRect.minX + 18, y: hexY),
            withAttributes: [.font: hexFont, .foregroundColor: primaryText]
        )
        let tipStr: NSString = "预设"
        let tipAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9.5, weight: .regular), .foregroundColor: secondaryText]
        let tipSz = tipStr.size(withAttributes: tipAttrs)
        tipStr.draw(at: NSPoint(x: svRect.maxX - tipSz.width, y: hexY + 1), withAttributes: tipAttrs)

        // 4. Circular quick swatches (2 rows x 6 cols)
        var quickRects: [(CGRect, RGBAColor)] = []
        let qTop = hexY + 21
        let qSide: CGFloat = 18
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
            ctx.setFillColor(qc.cgColor)
            ctx.fillEllipse(in: qr)
            ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.18))
            ctx.setLineWidth(0.8)
            ctx.strokeEllipse(in: qr)
            quickRects.append((qr, qc))
        }
        picker.quickRects = quickRects
        self.colorPicker = picker
    }

    private func drawTooltipBubble(in ctx: CGContext, text: String, anchor: CGRect) {
        let font = NSFont.systemFont(ofSize: 11.0, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(calibratedWhite: 0.97, alpha: 1)]
        let sz = (text as NSString).size(withAttributes: attrs)
        let w = (sz.width + 14).rounded()
        let h = (sz.height + 7).rounded()
        let x = max(6, min(bounds.width - w - 6, (anchor.midX - w * 0.5).rounded()))
        var placedBelow = true
        var y = (anchor.maxY + 7).rounded()
        if y + h > bounds.height - 6 {
            y = (anchor.minY - h - 7).rounded()
            placedBelow = false
        }
        let rect = CGRect(x: x, y: y, width: w, height: h)
        let path = makeCalloutBubblePath(
            rect: rect,
            cornerRadius: 5.5,
            arrowX: anchor.midX,
            arrowOnTop: placedBelow,
            arrowWidth: 8.5,
            arrowHeight: 4.0
        )
        drawFrostedMaterial(
            in: ctx,
            path: path,
            sampleRect: rect,
            dark: true,
            shadowOffsetY: 2.0,
            shadowBlur: 8.0,
            shadowAlpha: 0.26
        )
        (text as NSString).draw(
            at: NSPoint(x: rect.minX + (w - sz.width) * 0.5, y: rect.minY + (h - sz.height) * 0.5),
            withAttributes: attrs
        )
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

    private func hitSelectionResizeHandle(at pt: ASPoint, in sel: ASRect) -> ResizeHandle? {
        let corners: [ResizeHandle] = [.topLeft, .topRight, .bottomRight, .bottomLeft]
        for h in corners where pt.distance(to: h.position(in: sel)) <= 9.0 {
            return h
        }
        let visibleMids = visibleSelectionHandles(for: sel).filter { !corners.contains($0) }
        for h in visibleMids where pt.distance(to: h.position(in: sel)) <= 8.5 {
            return h
        }
        guard sel.width >= 20 && sel.height >= 20 else { return nil }
        let innerMargin = (activeTool == nil) ? 4.5 : 3.2
        let outerMargin = 5.0
        if pt.x >= sel.minX - outerMargin && pt.x <= sel.maxX + outerMargin {
            if pt.y >= sel.minY - outerMargin && pt.y <= sel.minY + innerMargin { return .top }
            if pt.y >= sel.maxY - innerMargin && pt.y <= sel.maxY + outerMargin { return .bottom }
        }
        if pt.y >= sel.minY - outerMargin && pt.y <= sel.maxY + outerMargin {
            if pt.x >= sel.minX - outerMargin && pt.x <= sel.minX + innerMargin { return .left }
            if pt.x >= sel.maxX - innerMargin && pt.x <= sel.maxX + outerMargin { return .right }
        }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = ASPoint(convert(event.locationInWindow, from: nil))
        guard let sel = selection else {
            if hoveredResizeHandle != nil { hoveredResizeHandle = nil }
            let prevFrontID = WindowSnapResolver.resolveCandidate(
                at: cursorPoint,
                candidatesFrontToBack: snapshot.windowsLocalTopDown,
                allowMaximizedSnap: true
            )?.windowID
            let nextFrontID = WindowSnapResolver.resolveCandidate(
                at: pt,
                candidatesFrontToBack: snapshot.windowsLocalTopDown,
                allowMaximizedSnap: true
            )?.windowID
            if prevFrontID != nextFrontID {
                windowDepthIndex = 0
            }
            cursorPoint = pt
            hoveredWindowCandidate = resolveHoveredWindowCandidate(at: pt)
            updateCursor(at: pt, flags: event.modifierFlags)
            needsDisplay = true
            return
        }
        cursorPoint = pt

        // Toolbar hover & 400ms tooltip (EDT-10)
        var shouldRedraw = false
        if let hit = toolbarHitItems.first(where: { $0.rect.contains(pt.cgPoint) }) {
            if hoveredResizeHandle != nil {
                hoveredResizeHandle = nil
                shouldRedraw = true
            }
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
                shouldRedraw = true
            }
        } else {
            if let selObj = document.selectedObject,
               let cp = selObj.cornerHandlePoint,
               pt.distance(to: cp) <= 8.0 {
                if hoveredItemID != "gizmo.corner" {
                    hoveredItemID = "gizmo.corner"
                    tooltipTask?.cancel()
                    let anchor = CGRect(x: cp.x - 5, y: cp.y - 5, width: 10, height: 10)
                    tooltipTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        guard !Task.isCancelled else { return }
                        self?.activeTooltip = ("圆角", anchor)
                        self?.needsDisplay = true
                    }
                }
            } else if hoveredItemID != nil {
                hoveredItemID = nil
                activeTooltip = nil
                tooltipTask?.cancel()
                shouldRedraw = true
            }

            let nextKnot: ResizeHandle? = {
                guard !selectionLocked else { return nil }
                for h in visibleSelectionHandles(for: sel) where pt.distance(to: h.position(in: sel)) <= 8.5 {
                    return h
                }
                return nil
            }()
            if hoveredResizeHandle != nextKnot {
                hoveredResizeHandle = nextKnot
                shouldRedraw = true
            }
        }

        if shouldRedraw {
            needsDisplay = true
        }
        updateCursor(at: pt, flags: event.modifierFlags)
    }

    private func resolveHoveredWindowCandidate(at pt: ASPoint) -> WindowSnapCandidate? {
        if windowPickerMode {
            return WindowSnapResolver.resolveCandidate(
                at: pt,
                candidatesFrontToBack: snapshot.windowsLocalTopDown,
                allowMaximizedSnap: true,
                depthIndex: windowDepthIndex
            )
        }
        guard coordinator?.config.windowSnap == true else { return nil }
        return WindowSnapResolver.resolveCandidate(
            at: pt,
            candidatesFrontToBack: snapshot.windowsLocalTopDown,
            allowMaximizedSnap: coordinator?.isDirectLongshotCapture == true
        )
    }

    private func updateCursor(at pt: ASPoint, flags: NSEvent.ModifierFlags) {
        if toolbarHitItems.contains(where: { $0.rect.contains(pt.cgPoint) }) {
            NSCursor.pointingHand.set()
            return
        }
        if let picker = colorPicker, picker.panelRect.contains(pt.cgPoint) {
            if picker.quickRects.contains(where: { $0.0.contains(pt.cgPoint) }) {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.crosshair.set()
            }
            return
        }
        guard let sel = selection else {
            if windowPickerMode && hoveredWindowCandidate != nil {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.crosshair.set()
            }
            return
        }
        if spacePressed {
            NSCursor.openHand.set()
            return
        }
        if let selObj = document.selectedObject {
            for h in ResizeHandle.allCases where pt.distance(to: h.position(in: selObj.boundingBox)) <= 8.0 {
                DirectionalResizeCursor.cursor(for: h).set()
                return
            }
            if let cp = selObj.cornerHandlePoint, pt.distance(to: cp) <= 8.0 {
                NSCursor.pointingHand.set()
                return
            }
            if let curve = selObj.curveControlPoints,
               (pt.distance(to: curve.c1) <= 8.0 || pt.distance(to: curve.c2) <= 8.0) {
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
        if !selectionLocked, let h = hitSelectionResizeHandle(at: pt, in: sel) {
            DirectionalResizeCursor.cursor(for: h).set()
            return
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

        // 2. Toolbar hit check (with tactile press state & drag-out cancellation)
        if let hit = toolbarHitItems.first(where: { $0.rect.contains(pt.cgPoint) }) {
            if event.clickCount == 2, let dbl = hit.doubleClickAction {
                pressedItemID = nil
                dragOp = .none
                dbl()
            } else if hit.id == "text.family" {
                pressedItemID = nil
                dragOp = .none
                hit.action()
            } else {
                pressedItemID = hit.id
                dragOp = .pressingToolbarItem(id: hit.id)
                needsDisplay = true
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
                DirectionalResizeCursor.cursor(for: h).set()
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

        // 5. Selection 8 resize knots + 4 border edges
        if !selectionLocked, let h = hitSelectionResizeHandle(at: pt, in: sel) {
            DirectionalResizeCursor.cursor(for: h).set()
            dragOp = .resizingSelection(handle: h, initialRect: sel)
            needsDisplay = true
            return
        }

        // 6. Space + drag -> move whole selection
        if spacePressed && !selectionLocked {
            NSCursor.closedHand.set()
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
                        NSCursor.closedHand.set()
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

        case .pressingToolbarItem(let id):
            let inside = toolbarHitItems
                .first(where: { $0.id == id })?
                .rect
                .insetBy(dx: -8, dy: -8)
                .contains(rawPt.cgPoint) ?? false
            let nextPressed = inside ? id : nil
            if pressedItemID != nextPressed {
                pressedItemID = nextPressed
                needsDisplay = true
            }

        case .adjustingColorSV(let idx):
            applyColorPickerSV(at: rawPt.cgPoint, swatchIndex: idx)

        case .adjustingColorHue(let idx):
            applyColorPickerHue(at: rawPt.cgPoint, swatchIndex: idx)

        case .creatingSelection(let origin, _):
            let endPt = shift ? GeometrySnap.squareCorner(from: origin, to: clampedPt) : clampedPt
            let threshold = windowPickerMode ? 5.0 : 3.0
            let moved = origin.distance(to: clampedPt) >= threshold
            dragOp = .creatingSelection(origin: origin, moved: moved)
            if moved {
                if windowPickerMode {
                    windowPickerMode = false
                    hoveredWindowCandidate = nil
                }
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
        let pt = ASPoint(convert(event.locationInWindow, from: nil))
        switch dragOp {
        case .pressingToolbarItem(let id):
            let wasActivePress = (pressedItemID == id)
            pressedItemID = nil
            dragOp = .none
            if wasActivePress, let hit = toolbarHitItems.first(where: { $0.id == id }) {
                hit.action()
            }
            needsDisplay = true
            updateCursor(at: pt, flags: event.modifierFlags)
            return

        case .creatingSelection(_, let moved):
            if !moved {
                if windowPickerMode {
                    if let cand = hoveredWindowCandidate ?? resolveHoveredWindowCandidate(at: pt) {
                        let defaultShadow = coordinator?.config.windowCaptureShadow ?? true
                        let includeShadow = event.modifierFlags.contains(.option) ? !defaultShadow : defaultShadow
                        dragOp = .none
                        captureAndPresentIsolatedWindow(candidate: cand, includeShadow: includeShadow)
                        return
                    }
                } else if let cand = hoveredWindowCandidate ?? resolveHoveredWindowCandidate(at: pt),
                          coordinator?.config.windowSnap == true {
                    selection = cand.rect
                }
            } else if let sel = selection, (sel.width < 4 || sel.height < 4) {
                selection = nil
            }
            if coordinator?.isDirectOCRCapture == true, let sel = selection, sel.width >= 4, sel.height >= 4 {
                dragOp = .none
                triggerOCR()
                return
            }
            if coordinator?.isDirectLongshotCapture == true, let sel = selection {
                dragOp = .none
                if sel.width >= 24 && sel.height >= 24 {
                    triggerLongshot(forceAutoScroll: true)
                    return
                } else {
                    selection = nil
                    ToastHUD.show("选区过小，请框选页面滚动区域")
                }
            }
            needsDisplay = true

        case .resizingSelection:
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
        updateCursor(at: pt, flags: event.modifierFlags)
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
                    coordinator?.mutateConfig { $0.defaultBlurRadius = nextR }
                    obj.kind = .blur(a: a, b: b, blurRadius: nextR, cornerRadius: cr)
                case .text(let pos, let txt, let fs, let ff, let bold, let italic, _, _):
                    let nextFS = max(10.0, min(96.0, fs + step * 2.0))
                    currentFontSize = nextFS
                    coordinator?.mutateConfig { $0.defaultFontSize = nextFS }
                    let m = AnnotationRenderer.measureText(txt, fontFamily: ff, fontSize: nextFS, bold: bold, italic: italic)
                    obj.kind = .text(pos: pos, text: txt, fontSize: nextFS, fontFamily: ff, bold: bold, italic: italic, measuredWidth: m.width, measuredHeight: m.height)
                case .number(let center, let tip, let n, let fs):
                    let nextFS = max(12.0, min(64.0, fs + step * 2.0))
                    currentNumberFontSize = nextFS
                    coordinator?.mutateConfig { $0.defaultNumberFontSize = nextFS }
                    obj.kind = .number(center: center, tip: tip, number: n, fontSize: nextFS)
                default:
                    let nextW = max(1.0, min(36.0, obj.style.lineWidth + step))
                    currentLineWidth = nextW
                    coordinator?.mutateConfig { $0.defaultLineWidth = nextW }
                    obj.style.lineWidth = nextW
                }
            }
            needsDisplay = true
            return
        }

        guard let tool = activeTool else { return }
        switch tool {
        case .blur:
            let nextR = max(4.0, min(64.0, currentBlurRadius + step * 2.0))
            currentBlurRadius = nextR
            coordinator?.mutateConfig { $0.defaultBlurRadius = nextR }
        case .text:
            let nextFS = max(10.0, min(96.0, currentFontSize + step * 2.0))
            currentFontSize = nextFS
            coordinator?.mutateConfig { $0.defaultFontSize = nextFS }
        case .number:
            let nextFS = max(12.0, min(64.0, currentNumberFontSize + step * 2.0))
            currentNumberFontSize = nextFS
            coordinator?.mutateConfig { $0.defaultNumberFontSize = nextFS }
        default:
            let nextW = max(1.0, min(36.0, currentLineWidth + step))
            currentLineWidth = nextW
            coordinator?.mutateConfig { $0.defaultLineWidth = nextW }
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
            if selection == nil {
                if !event.isARepeat, coordinator?.canToggleWindowPickerWithSpace == true {
                    windowPickerMode.toggle()
                    windowDepthIndex = 0
                    hoveredWindowCandidate = resolveHoveredWindowCandidate(at: cursorPoint)
                    updateCursor(at: cursorPoint, flags: event.modifierFlags)
                    needsDisplay = true
                }
                return
            }
            spacePressed = true
            NSCursor.openHand.set()
            return
        }

        if kc == kVK_Tab, selection == nil, windowPickerMode {
            let hits = WindowSnapResolver.candidatesContaining(
                at: cursorPoint,
                candidatesFrontToBack: snapshot.windowsLocalTopDown,
                allowMaximizedSnap: true
            )
            if hits.count > 1 {
                windowDepthIndex += shift ? -1 : 1
                hoveredWindowCandidate = resolveHoveredWindowCandidate(at: cursorPoint)
                updateCursor(at: cursorPoint, flags: event.modifierFlags)
                needsDisplay = true
            }
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
                if !cfg.hotkeys.pin.isUnbound && candidateBinding == cfg.hotkeys.pin && !(coordinator?.isInlinePinEdit ?? false) {
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
            ToastHUD.show("已复制 \(copied)")
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
                triggerSaveOutput(forceDialog: shift)
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
            } else if let iso = isolatedWindowCapture, iso.isWindowCapture, document.isEmpty {
                isolatedWindowCapture = nil
                selection = nil
                selectionLocked = false
                activeTool = nil
                windowPickerMode = true
                hoveredWindowCandidate = resolveHoveredWindowCandidate(at: cursorPoint)
                updateCursor(at: cursorPoint, flags: event.modifierFlags)
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
                if flags.contains(.option) {
                    // Option + Arrow: 1pt / 5pt precision width/height micro-resize
                    sel.width = max(8, min(Double(bounds.width) - sel.x, sel.width + dx))
                    sel.height = max(8, min(Double(bounds.height) - sel.y, sel.height + dy))
                } else {
                    sel.x = max(0, min(Double(bounds.width) - sel.width, sel.x + dx))
                    sel.y = max(0, min(Double(bounds.height) - sel.height, sel.y + dy))
                }
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
        coordinator?.mutateConfig { $0.defaultLineWidth = width }
        if let selID = document.selectedID {
            document.updateObject(id: selID, recordUndo: true) { $0.style.lineWidth = width }
        }
        needsDisplay = true
    }

    private func selectBlurRadiusPreset(_ radius: Double) {
        currentBlurRadius = radius
        coordinator?.mutateConfig { $0.defaultBlurRadius = radius }
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
        let newFill: Bool
        if let selID = document.selectedID, let selObj = document.selectedObject {
            switch selObj.kind {
            case .rect(_, _, _, let f), .ellipse(_, _, let f):
                newFill = !f
            default:
                newFill = !fillEnabled
            }
            fillEnabled = newFill
            document.updateObject(id: selID, recordUndo: true) { obj in
                switch obj.kind {
                case .rect(let a, let b, let r, _):
                    obj.kind = .rect(a: a, b: b, cornerRadius: r, filled: newFill)
                case .ellipse(let a, let b, _):
                    obj.kind = .ellipse(a: a, b: b, filled: newFill)
                default:
                    break
                }
            }
        } else {
            fillEnabled.toggle()
            newFill = fillEnabled
        }
        coordinator?.mutateConfig { $0.defaultFillEnabled = newFill }
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
        let nextBold = !currentEffectiveTextAttributes.bold
        textBold = nextBold
        coordinator?.mutateConfig { $0.defaultFontBold = nextBold }
        updateSelectedTextObject { _, txt, fs, ff, _, i in (txt, fs, ff, nextBold, i) }
        needsDisplay = true
    }

    private func toggleItalic() {
        let nextItalic = !currentEffectiveTextAttributes.italic
        textItalic = nextItalic
        coordinator?.mutateConfig { $0.defaultFontItalic = nextItalic }
        updateSelectedTextObject { _, txt, fs, ff, b, _ in (txt, fs, ff, b, nextItalic) }
        needsDisplay = true
    }

    private func stepFontSize(_ delta: Double) {
        let cur = currentEffectiveTextAttributes.size
        let next = max(10.0, min(96.0, cur + delta))
        currentFontSize = next
        coordinator?.mutateConfig { $0.defaultFontSize = next }
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
            windowsLocalTopDown: []
        )
        isolatedWindowCapture = nil
        selection = nil
        selectionLocked = false
        windowPickerMode = false
        activeTool = nil
        document.clearAll()
        colorPicker = nil
        ToastHUD.show("已重新抓屏")
        needsDisplay = true
    }

    private func captureAndPresentIsolatedWindow(candidate: WindowSnapCandidate, includeShadow: Bool) {
        guard !isCapturingIsolatedWindow else { return }
        isCapturingIsolatedWindow = true
        let fallbackScale = snapshot.backingScale
        let screenW = Double(bounds.width)
        let screenH = Double(bounds.height)

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isCapturingIsolatedWindow = false }

            let capturedCG: CGImage
            if let singleCG = await ScreenCaptureService.captureSingleWindow(windowID: candidate.windowID, fallbackScale: fallbackScale) {
                capturedCG = singleCG
            } else {
                let pxRect = CGRect(
                    x: (candidate.rect.minX * fallbackScale).rounded(.down),
                    y: (candidate.rect.minY * fallbackScale).rounded(.down),
                    width: max(1, (candidate.rect.width * fallbackScale).rounded()),
                    height: max(1, (candidate.rect.height * fallbackScale).rounded())
                )
                guard let fallbackCG = self.snapshot.cgImage.cropping(to: pxRect) else { return }
                capturedCG = fallbackCG
            }
            guard let rawBuf = PixelBufferRGBA(cgImage: capturedCG) else { return }

            let logicalW = Double(capturedCG.width) / max(1.0, fallbackScale)
            let logicalH = Double(capturedCG.height) / max(1.0, fallbackScale)
            let maxDispW = max(32.0, screenW * 0.92)
            let maxDispH = max(32.0, screenH * 0.86)
            let fitRatio = min(1.0, min(maxDispW / max(1.0, logicalW), maxDispH / max(1.0, logicalH)))
            let dispW = (logicalW * fitRatio).rounded()
            let dispH = (logicalH * fitRatio).rounded()

            let targetX: Double
            let targetY: Double
            if fitRatio >= 0.999
                && candidate.unclippedRect.minX >= 0
                && candidate.unclippedRect.minY >= 0
                && candidate.unclippedRect.maxX <= screenW
                && candidate.unclippedRect.maxY <= screenH {
                targetX = candidate.unclippedRect.minX
                targetY = candidate.unclippedRect.minY
            } else {
                targetX = max(8.0, min(screenW - dispW - 8.0, candidate.rect.midX - dispW * 0.5)).rounded()
                targetY = max(8.0, min(screenH - dispH - 52.0, candidate.rect.midY - dispH * 0.5)).rounded()
            }

            let displayRect = ASRect(x: targetX, y: targetY, width: dispW, height: dispH)
            let effectiveScale = Double(capturedCG.width) / max(1.0, dispW)

            if let owner = self.ownerController {
                self.coordinator?.clearSelectionOnOtherScreens(except: owner)
            }
            self.document.clearAll()
            self.activeTool = nil
            self.colorPicker = nil
            self.isolatedWindowCapture = IsolatedWindowCapture(
                rawImage: capturedCG,
                rawBuffer: rawBuf,
                pixelScale: effectiveScale,
                includeShadow: includeShadow,
                ownerName: candidate.ownerName
            )
            self.selection = displayRect
            self.selectionLocked = true
            self.needsDisplay = true
        }
    }

    // MARK: - Baking Raw vs Output & Finalizing

    private func cropRawSelectionImage() -> CGImage? {
        if let iso = isolatedWindowCapture {
            return iso.rawImage
        }
        guard let sel = selection, sel.width >= 1 && sel.height >= 1 else { return nil }
        let pxRect = CGRect(
            x: (sel.minX * snapshot.backingScale).rounded(.down),
            y: (sel.minY * snapshot.backingScale).rounded(.down),
            width: max(1, (sel.width * snapshot.backingScale).rounded()),
            height: max(1, (sel.height * snapshot.backingScale).rounded())
        )
        return snapshot.cgImage.cropping(to: pxRect)
    }

    private func bakeCurrentSelectionOutput(applyWindowShadow: Bool = true) -> CGImage? {
        commitInlineEditorsIfNeeded()
        if let iso = isolatedWindowCapture, let sel = selection {
            let baseCG = iso.rawImage
            let baked: CGImage
            if document.isEmpty {
                baked = baseCG
            } else {
                baked = AnnotationRenderer.bakeOutput(
                    rawSelection: baseCG,
                    objects: document.objects,
                    selectionOrigin: ASPoint(sel.minX, sel.minY),
                    pixelScale: iso.pixelScale
                ) ?? baseCG
            }
            if applyWindowShadow && iso.includeShadow {
                let shadowScale = iso.isWindowCapture ? iso.pixelScale : snapshot.backingScale
                return AnnotationRenderer.applyWindowDropShadow(to: baked, scale: shadowScale) ?? baked
            }
            return baked
        }

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

    private var outputBackingScale: Double {
        if let iso = isolatedWindowCapture, iso.isWindowCapture {
            return iso.pixelScale
        }
        return snapshot.backingScale
    }

    private func triggerCopyOutput() {
        guard let out = bakeCurrentSelectionOutput(applyWindowShadow: true) else { return }
        coordinator?.finishWithCopy(image: out, scale: outputBackingScale)
    }

    private func triggerSaveOutput(forceDialog: Bool = false) {
        guard let out = bakeCurrentSelectionOutput(applyWindowShadow: true) else { return }
        coordinator?.finishWithSave(image: out, scale: outputBackingScale, forceDialog: forceDialog)
    }

    private func triggerPinOutput() {
        guard let sel = selection, let out = bakeCurrentSelectionOutput(applyWindowShadow: false) else { return }
        let sFrame = snapshot.frameInGlobalAppKit
        let appKitOrigin = CGPoint(
            x: sFrame.minX + CGFloat(sel.minX),
            y: sFrame.maxY - CGFloat(sel.maxY)
        )
        coordinator?.finishWithPin(image: out, scale: outputBackingScale, appKitOrigin: appKitOrigin)
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

    private func triggerLongshot(forceAutoScroll: Bool = false) {
        guard let sel = selection, sel.width >= 24 && sel.height >= 24 else {
            ToastHUD.show("选区过小")
            return
        }
        let pxRect = PixelRect(
            x: Int((sel.minX * snapshot.backingScale).rounded()),
            y: Int((sel.minY * snapshot.backingScale).rounded()),
            width: max(1, Int((sel.width * snapshot.backingScale).rounded())),
            height: max(1, Int((sel.height * snapshot.backingScale).rounded()))
        )
        guard let initialCrop = snapshot.rawBuffer.cropped(to: pxRect) else { return }
        coordinator?.finishIntoLongshot(
            screen: snapshot.screen,
            viewportTopDown: sel,
            initialCrop: initialCrop,
            forceAutoScroll: forceAutoScroll
        )
    }

    private func attemptCancel() {
        if !document.isEmpty && (coordinator?.config.confirmCancel == true) {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastCancelAttemptTime <= 1.8 {
                coordinator?.cancelSession()
                return
            }
            lastCancelAttemptTime = now
            cancelConfirmBanner = "再按一次 Esc 退出"
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
