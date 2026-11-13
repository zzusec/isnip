import AppKit
import Carbon
import AirSnipCore

@MainActor
public final class PinManager: ObservableObject {
    @Published public private(set) var windows: [PinWindowController] = []
    public var onRequestAnnotatePin: ((PinWindowController) -> Void)?
    public var onRequestOCRPin: ((PinWindowController) -> Void)?
    public var getConfig: (() -> AirSnipConfig)?
    public var updateConfig: (((inout AirSnipConfig) -> Void) -> Void)?

    public init() {}

    public var count: Int { windows.count }
    public var hasClickThroughPins: Bool { windows.contains { $0.isClickThrough } }

    public func createPin(
        cgImage: CGImage,
        backingScale: Double,
        preferredScreenOriginAppKit: CGPoint?,
        config: AirSnipConfig
    ) {
        if windows.count >= config.pinMaxCount {
            ToastHUD.show("已达上限（\(config.pinMaxCount) 张）")
            return
        }
        let pointW = max(32.0, Double(cgImage.width) / max(1.0, backingScale))
        let pointH = max(32.0, Double(cgImage.height) / max(1.0, backingScale))
        let size = NSSize(width: pointW, height: pointH)

        let screen = NSScreen.main ?? NSScreen.screens.first
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let origin: NSPoint
        if config.pinPosition == .original, let pref = preferredScreenOriginAppKit {
            origin = pref
        } else {
            let cascade = CGFloat(windows.count % 6) * 18.0
            origin = NSPoint(
                x: vis.midX - size.width * 0.5 + cascade,
                y: vis.midY - size.height * 0.5 - cascade
            )
        }

        let controller = PinWindowController(
            cgImage: cgImage,
            baseSize: size,
            backingScale: backingScale,
            origin: origin,
            showBorder: config.pinBorder,
            manager: self
        )
        windows.append(controller)
        controller.show()
    }

    public func remove(_ pin: PinWindowController) {
        pin.window.orderOut(nil)
        windows.removeAll { $0 === pin }
    }

    public func closeAll() {
        for w in windows {
            w.window.orderOut(nil)
        }
        windows.removeAll()
    }

    public func restoreAllClickThrough() {
        for w in windows where w.isClickThrough {
            w.setClickThrough(false)
        }
        ToastHUD.show("已恢复贴图交互")
    }

    public func toggleAllBorders() {
        let target = !(windows.first?.showBorder ?? true)
        for w in windows {
            w.setShowBorder(target)
        }
        updateConfig? { $0.pinBorder = target }
        ToastHUD.show(target ? "边框已开启" : "边框已隐藏")
    }
}

private final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
public final class PinWindowController: NSObject {
    public let window: NSPanel
    public private(set) var cgImage: CGImage
    public private(set) var baseSize: NSSize
    public let backingScale: Double
    public private(set) var zoomScale: CGFloat = 1.0
    public private(set) var opacity: CGFloat = 1.0
    public private(set) var showBorder: Bool
    public private(set) var isClickThrough: Bool = false

    private weak var manager: PinManager?
    private let contentView: PinCanvasView

    public init(
        cgImage: CGImage,
        baseSize: NSSize,
        backingScale: Double,
        origin: NSPoint,
        showBorder: Bool,
        manager: PinManager
    ) {
        self.cgImage = cgImage
        self.baseSize = baseSize
        self.backingScale = backingScale
        self.showBorder = showBorder
        self.manager = manager

        let rect = NSRect(origin: origin, size: baseSize)
        let panel = PinPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false

        self.contentView = PinCanvasView(frame: NSRect(origin: .zero, size: baseSize))
        self.window = panel
        super.init()

        contentView.owner = self
        panel.contentView = contentView
        contentView.needsDisplay = true
    }

    public func show() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(contentView)
    }

    public func updateImage(_ newImage: CGImage) {
        self.cgImage = newImage
        self.baseSize = NSSize(
            width: max(32.0, Double(newImage.width) / max(1.0, backingScale)),
            height: max(32.0, Double(newImage.height) / max(1.0, backingScale))
        )
        self.zoomScale = 1.0
        var frame = window.frame
        let center = NSPoint(x: frame.midX, y: frame.midY)
        frame.size = baseSize
        frame.origin = NSPoint(x: center.x - baseSize.width * 0.5, y: center.y - baseSize.height * 0.5)
        window.setFrame(frame, display: true)
        contentView.frame = NSRect(origin: .zero, size: baseSize)
        contentView.needsDisplay = true
    }

    public func setShowBorder(_ on: Bool) {
        showBorder = on
        contentView.needsDisplay = true
    }

    public func setClickThrough(_ on: Bool) {
        isClickThrough = on
        window.ignoresMouseEvents = on
        window.alphaValue = on ? min(opacity, 0.82) : opacity
        if on {
            ToastHUD.show("已开启穿透（菜单栏可恢复）")
        }
    }

    public func adjustZoom(delta: CGFloat, anchorInWindow: NSPoint) {
        let factor: CGFloat = delta > 0 ? 1.08 : 0.925
        let newScale = max(0.2, min(4.0, zoomScale * factor))
        guard abs(newScale - zoomScale) > 0.001 else { return }

        let oldFrame = window.frame
        let relX = anchorInWindow.x / max(1, oldFrame.width)
        let relY = anchorInWindow.y / max(1, oldFrame.height)

        zoomScale = newScale
        let newW = round(baseSize.width * zoomScale)
        let newH = round(baseSize.height * zoomScale)
        let screenAnchorX = oldFrame.minX + anchorInWindow.x
        let screenAnchorY = oldFrame.minY + anchorInWindow.y
        let newOrigin = NSPoint(x: screenAnchorX - newW * relX, y: screenAnchorY - newH * relY)

        window.setFrame(NSRect(origin: newOrigin, size: NSSize(width: newW, height: newH)), display: true)
        contentView.frame = NSRect(x: 0, y: 0, width: newW, height: newH)
        contentView.showBadgeTemporarily("\(Int((zoomScale * 100).rounded()))%")
        contentView.needsDisplay = true
    }

    public func adjustOpacity(delta: CGFloat) {
        let step: CGFloat = delta > 0 ? 0.06 : -0.06
        opacity = max(0.15, min(1.0, opacity + step))
        window.alphaValue = opacity
        contentView.showBadgeTemporarily("透明度 \(Int((opacity * 100).rounded()))%")
    }

    public func resetTransform() {
        zoomScale = 1.0
        opacity = 1.0
        window.alphaValue = 1.0
        var f = window.frame
        f.size = baseSize
        window.setFrame(f, display: true)
        contentView.frame = NSRect(origin: .zero, size: baseSize)
        contentView.needsDisplay = true
    }

    public func requestInlineAnnotate() {
        manager?.onRequestAnnotatePin?(self)
    }

    public func requestOCR() {
        manager?.onRequestOCRPin?(self)
    }

    public func copyToClipboard() {
        let cfg = manager?.getConfig?()
        OutputService.copyImageToClipboard(cgImage, backingScale: backingScale, config: cfg) { res in
            if res.savedRatioPercent >= 3 {
                ToastHUD.show("已复制 · \(res.compactBadgeSummary)")
            } else {
                ToastHUD.show("已复制")
            }
        }
    }

    public func savePin(forceDialog: Bool = false) {
        guard var cfg = manager?.getConfig?() else { return }
        let showToast = cfg.showCompletionToast
        if OutputService.saveImage(
            for: cgImage,
            backingScale: backingScale,
            config: &cfg,
            forceDialog: forceDialog,
            parentWindow: window,
            onFinalCompressed: { _, finalRes in
                guard showToast else { return }
                ToastHUD.show("已保存 · \(finalRes.compactBadgeSummary)")
            }
        ) != nil {
            let finalCfg = cfg
            manager?.updateConfig? { $0 = finalCfg }
            if showToast && !(finalCfg.lastSaveFormat == .png && finalCfg.smartPngCompression) {
                ToastHUD.show("已保存")
            }
        }
    }

    public func closeSelf() {
        manager?.remove(self)
    }

    public func closeAllPins() {
        manager?.closeAll()
    }
}

@MainActor
private final class PinCanvasView: NSView {
    weak var owner: PinWindowController?
    private var dragStartMouseScreen: NSPoint?
    private var dragStartWindowOrigin: NSPoint?
    private var badgeText: String?
    private var badgeClearTask: Task<Void, Never>?

    override var acceptsFirstResponder: Bool { true }

    func showBadgeTemporarily(_ text: String) {
        badgeText = text
        needsDisplay = true
        badgeClearTask?.cancel()
        badgeClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 850_000_000)
            guard !Task.isCancelled else { return }
            self?.badgeText = nil
            self?.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let owner, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r: CGFloat = 6.5
        let clipPath = CGPath(roundedRect: bounds, cornerWidth: r, cornerHeight: r, transform: nil)

        ctx.saveGState()
        ctx.addPath(clipPath)
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(owner.cgImage, in: bounds)
        ctx.restoreGState()

        if owner.showBorder {
            let insetRect = bounds.insetBy(dx: 0.75, dy: 0.75)
            let borderPath = CGPath(roundedRect: insetRect, cornerWidth: max(1, r - 0.75), cornerHeight: max(1, r - 0.75), transform: nil)
            ctx.addPath(borderPath)
            ctx.setStrokeColor(CGColor(srgbRed: 0.09, green: 0.56, blue: 1.0, alpha: 0.92))
            ctx.setLineWidth(1.5)
            ctx.strokePath()
        } else {
            // Subtle crisp hairline rim even when blue border is toggled off so light-on-light pins stay defined
            let insetRect = bounds.insetBy(dx: 0.5, dy: 0.5)
            let borderPath = CGPath(roundedRect: insetRect, cornerWidth: max(1, r - 0.5), cornerHeight: max(1, r - 0.5), transform: nil)
            ctx.addPath(borderPath)
            ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.14))
            ctx.setLineWidth(0.8)
            ctx.strokePath()
        }

        if let badge = badgeText {
            let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let sz = (badge as NSString).size(withAttributes: attrs)
            let pill = NSRect(x: 9, y: bounds.height - sz.height - 15, width: sz.width + 16, height: sz.height + 7)
            let path = NSBezierPath(roundedRect: pill, xRadius: pill.height * 0.5, yRadius: pill.height * 0.5)
            NSColor(calibratedWhite: 0.08, alpha: 0.80).setFill()
            path.fill()
            NSColor(calibratedWhite: 1.0, alpha: 0.18).setStroke()
            path.lineWidth = 0.75
            path.stroke()
            (badge as NSString).draw(at: NSPoint(x: pill.minX + 8, y: pill.minY + 3.5), withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            owner?.closeSelf()
            return
        }
        dragStartMouseScreen = NSEvent.mouseLocation
        dragStartWindowOrigin = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startMouse = dragStartMouseScreen,
              let startOrigin = dragStartWindowOrigin,
              let win = window else { return }
        let cur = NSEvent.mouseLocation
        win.setFrameOrigin(NSPoint(
            x: startOrigin.x + (cur.x - startMouse.x),
            y: startOrigin.y + (cur.y - startMouse.y)
        ))
    }

    override func mouseUp(with event: NSEvent) {
        dragStartMouseScreen = nil
        dragStartWindowOrigin = nil
    }

    override func scrollWheel(with event: NSEvent) {
        guard let owner else { return }
        let delta = abs(event.scrollingDeltaY) > 0.01 ? event.scrollingDeltaY : event.deltaY
        guard abs(delta) > 0.01 else { return }
        let flags = event.modifierFlags
        if flags.contains(.control) || flags.contains(.command) {
            owner.adjustOpacity(delta: delta)
        } else {
            let loc = convert(event.locationInWindow, from: nil)
            owner.adjustZoom(delta: delta, anchorInWindow: loc)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let owner, let win = window else { return }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 5.0 : 1.0
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if (flags.contains(.command) || flags.contains(.control)), event.keyCode == UInt16(kVK_ANSI_C) {
            owner.copyToClipboard()
            return
        }
        if (flags.contains(.command) || flags.contains(.control)), event.keyCode == UInt16(kVK_ANSI_S) {
            owner.savePin(forceDialog: flags.contains(.shift))
            return
        }

        switch Int(event.keyCode) {
        case kVK_Escape:
            owner.closeSelf()
        case kVK_Space:
            owner.requestInlineAnnotate()
        case kVK_ANSI_T:
            owner.requestOCR()
        case kVK_LeftArrow:
            win.setFrameOrigin(NSPoint(x: win.frame.origin.x - step, y: win.frame.origin.y))
        case kVK_RightArrow:
            win.setFrameOrigin(NSPoint(x: win.frame.origin.x + step, y: win.frame.origin.y))
        case kVK_UpArrow:
            win.setFrameOrigin(NSPoint(x: win.frame.origin.x, y: win.frame.origin.y + step))
        case kVK_DownArrow:
            win.setFrameOrigin(NSPoint(x: win.frame.origin.x, y: win.frame.origin.y - step))
        default:
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let owner else { return nil }
        let menu = NSMenu(title: "贴图")
        let editItem = NSMenuItem(title: "标注 (Space)", action: #selector(onEdit), keyEquivalent: "")
        editItem.target = self
        menu.addItem(editItem)

        let ocrItem = NSMenuItem(title: "识字 (T)", action: #selector(onOCR), keyEquivalent: "")
        ocrItem.target = self
        menu.addItem(ocrItem)

        let copyItem = NSMenuItem(title: "复制", action: #selector(onCopy), keyEquivalent: "c")
        copyItem.target = self
        menu.addItem(copyItem)

        let saveItem = NSMenuItem(title: "保存", action: #selector(onSave), keyEquivalent: "s")
        saveItem.target = self
        menu.addItem(saveItem)

        let saveAsItem = NSMenuItem(title: "另存为…", action: #selector(onSaveAs), keyEquivalent: "S")
        saveAsItem.target = self
        menu.addItem(saveAsItem)

        menu.addItem(.separator())

        let borderItem = NSMenuItem(title: owner.showBorder ? "隐藏边框" : "显示边框", action: #selector(onToggleBorder), keyEquivalent: "")
        borderItem.target = self
        menu.addItem(borderItem)

        let throughItem = NSMenuItem(title: "鼠标穿透", action: #selector(onClickThrough), keyEquivalent: "")
        throughItem.target = self
        menu.addItem(throughItem)

        let resetItem = NSMenuItem(title: "重置大小与透明度", action: #selector(onReset), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

        menu.addItem(.separator())

        let closeItem = NSMenuItem(title: "关闭 (Esc)", action: #selector(onClose), keyEquivalent: "")
        closeItem.target = self
        menu.addItem(closeItem)

        let closeAllItem = NSMenuItem(title: "关闭全部", action: #selector(onCloseAll), keyEquivalent: "")
        closeAllItem.target = self
        menu.addItem(closeAllItem)
        return menu
    }

    @objc private func onEdit() { owner?.requestInlineAnnotate() }
    @objc private func onOCR() { owner?.requestOCR() }
    @objc private func onCopy() { owner?.copyToClipboard() }
    @objc private func onSave() { owner?.savePin(forceDialog: false) }
    @objc private func onSaveAs() { owner?.savePin(forceDialog: true) }
    @objc private func onToggleBorder() {
        guard let owner else { return }
        owner.setShowBorder(!owner.showBorder)
    }
    @objc private func onClickThrough() { owner?.setClickThrough(true) }
    @objc private func onReset() { owner?.resetTransform() }
    @objc private func onClose() { owner?.closeSelf() }
    @objc private func onCloseAll() { owner?.closeAllPins() }
}
