import AppKit
import Carbon
import SwiftUI
import AirSnipCore

private final class ControlBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class FullScreenBorderPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
public final class LongshotSessionController: ObservableObject {
    @Published public private(set) var pixelWidth: Int = 0
    @Published public private(set) var pixelHeight: Int = 0
    @Published public private(set) var segmentCount: Int = 0
    @Published public private(set) var canUndo: Bool = false
    @Published public private(set) var statusHint: String = "Space 自动翻页 · 滚轮手动拼接 · Enter 完成"
    @Published public private(set) var thumbnailImage: CGImage?
    @Published public private(set) var headerFooterHint: String?
    @Published public private(set) var isAutoScrolling: Bool = false
    @Published public private(set) var needsAccessibilityAuth: Bool = false
    @Published public private(set) var reachedBottom: Bool = false
    @Published public private(set) var scrollSpeed: LongshotScrollSpeed

    private let screen: NSScreen
    private let viewportTopDown: ASRect
    private let backingScale: Double
    private var config: AirSnipConfig
    private let autoStartRequested: Bool

    private var canvas: LongshotCanvas?
    private var borderWindow: NSPanel?
    private var previewWindow: NSPanel?
    private var controlWindow: ControlBarPanel?
    private var captureLoopTask: Task<Void, Never>?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    private var pendingInitialDelayMs: UInt64 = 0
    private var pendingInitialWarp: Bool = false
    private var consecutiveStillCount: Int = 0
    private var adaptiveScale: Double = 1.0
    private var goodStepStreak: Int = 0

    public var onSpeedChanged: ((LongshotScrollSpeed) -> Void)?
    public var onFinishCopy: ((CGImage, Double) -> Void)?
    public var onFinishSave: ((CGImage, Double) -> Void)?
    public var onFinishEdit: ((CGImage, Double, NSScreen) -> Void)?
    public var onFinishOCR: ((CGImage) -> Void)?
    public var onCancel: (() -> Void)?

    public init(
        screen: NSScreen,
        viewportTopDown: ASRect,
        initialCrop: PixelBufferRGBA,
        config: AirSnipConfig,
        autoStartScroll: Bool = false
    ) {
        self.screen = screen
        self.viewportTopDown = viewportTopDown
        self.backingScale = Double(screen.backingScaleFactor)
        self.config = config
        self.scrollSpeed = config.longshotScrollSpeed
        self.autoStartRequested = autoStartScroll
        self.pixelWidth = initialCrop.width
        self.pixelHeight = initialCrop.height

        let stitchCanvas = LongshotCanvas(
            width: initialCrop.width,
            frameHeight: initialCrop.height,
            params: LongshotParams(minRatio: 0.84, minFixedRows: 8),
            maxHeight: config.longshotMaxHeight
        )
        stitchCanvas.seed(initialCrop)
        self.canvas = stitchCanvas
        self.thumbnailImage = stitchCanvas.makeThumbnail(maxWidth: 160, maxHeight: 420)
    }

    public func start() {
        setupWindows()
        installKeyMonitors()
        if autoStartRequested {
            if AccessibilityService.hasPermission() {
                beginAutoScrolling(initialDelayMs: 220)
            } else {
                needsAccessibilityAuth = true
                _ = AccessibilityService.requestPermissionPrompt()
                statusHint = "授权辅助功能可自动翻页（也可直接手动滚动）"
            }
        }
        startSessionLoop()
    }

    public func stopAndCleanup() {
        isAutoScrolling = false
        captureLoopTask?.cancel()
        captureLoopTask = nil
        if let g = globalKeyMonitor { NSEvent.removeMonitor(g); globalKeyMonitor = nil }
        if let l = localKeyMonitor { NSEvent.removeMonitor(l); localKeyMonitor = nil }
        borderWindow?.orderOut(nil)
        previewWindow?.orderOut(nil)
        controlWindow?.orderOut(nil)
        borderWindow = nil
        previewWindow = nil
        controlWindow = nil
    }

    public func toggleAutoScroll() {
        if isAutoScrolling {
            pauseAutoScrolling()
        } else {
            beginAutoScrolling(initialDelayMs: 90)
        }
    }

    public func beginAutoScrolling(initialDelayMs: UInt64 = 90) {
        guard AccessibilityService.hasPermission() else {
            needsAccessibilityAuth = true
            isAutoScrolling = false
            _ = AccessibilityService.requestPermissionPrompt()
            statusHint = "请在系统设置中开启辅助功能以自动翻页"
            return
        }
        needsAccessibilityAuth = false
        reachedBottom = false
        consecutiveStillCount = 0
        adaptiveScale = 1.0
        goodStepStreak = 0
        pendingInitialDelayMs = initialDelayMs
        pendingInitialWarp = true
        isAutoScrolling = true
        statusHint = segmentCount > 0
            ? "自动翻页中（已拼 \(segmentCount) 段）· Space 暂停"
            : "自动翻页中 · Space 暂停 · Enter 完成"
    }

    public func pauseAutoScrolling(customHint: String? = nil) {
        isAutoScrolling = false
        if let customHint {
            statusHint = customHint
        } else if segmentCount > 0 {
            statusHint = "已暂停（\(segmentCount) 段）· Space 继续 · Enter 完成"
        } else {
            statusHint = "已暂停 · Space 自动翻页或手动滚轮"
        }
    }

    public func setScrollSpeed(_ speed: LongshotScrollSpeed) {
        guard scrollSpeed != speed else { return }
        scrollSpeed = speed
        config.longshotScrollSpeed = speed
        onSpeedChanged?(speed)
    }

    public func cycleScrollSpeed() {
        setScrollSpeed(scrollSpeed.next)
    }

    public func openAccessibilityAuthorization() {
        _ = AccessibilityService.requestPermissionPrompt()
        AccessibilityService.openSystemSettings()
    }

    private func setupWindows() {
        let sFrame = screen.frame
        // Convert local top-down viewport rect to AppKit global coordinates
        let vpAppKit = NSRect(
            x: sFrame.minX + CGFloat(viewportTopDown.minX),
            y: sFrame.maxY - CGFloat(viewportTopDown.maxY),
            width: CGFloat(viewportTopDown.width),
            height: CGFloat(viewportTopDown.height)
        )

        // 1. Click-through viewport frame window covering `screen`
        let bWin = FullScreenBorderPanel(
            contentRect: sFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        bWin.hidesOnDeactivate = false
        bWin.animationBehavior = .none
        bWin.setFrame(sFrame, display: false)
        bWin.isOpaque = false
        bWin.backgroundColor = .clear
        bWin.level = .statusBar
        bWin.ignoresMouseEvents = true
        bWin.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let borderView = LongshotFrameOverlayView(
            frame: NSRect(origin: .zero, size: sFrame.size),
            viewportInView: NSRect(
                x: vpAppKit.minX - sFrame.minX,
                y: vpAppKit.minY - sFrame.minY,
                width: vpAppKit.width,
                height: vpAppKit.height
            )
        )
        bWin.contentView = borderView
        bWin.orderFrontRegardless()
        self.borderWindow = bWin

        // 2. Side live thumbnail preview window (right side if >=176pt space, else left side)
        let rightSpace = sFrame.maxX - vpAppKit.maxX
        let leftSpace = vpAppKit.minX - sFrame.minX
        let previewW: CGFloat = 156
        let previewH = min(max(200, vpAppKit.height), sFrame.height - 80)
        var previewX: CGFloat?
        if rightSpace >= previewW + 20 {
            previewX = vpAppKit.maxX + 12
        } else if leftSpace >= previewW + 20 {
            previewX = vpAppKit.minX - previewW - 12
        }
        if let px = previewX {
            let pRect = NSRect(x: px, y: vpAppKit.minY, width: previewW, height: previewH)
            let pWin = NSPanel(
                contentRect: pRect,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            pWin.hidesOnDeactivate = false
            pWin.isOpaque = false
            pWin.backgroundColor = .clear
            pWin.hasShadow = true
            pWin.level = .statusBar
            pWin.ignoresMouseEvents = true
            pWin.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            pWin.contentView = NSHostingView(rootView: LongshotPreviewCard(controller: self))
            pWin.orderFrontRegardless()
            self.previewWindow = pWin
        }

        // 3. Control bar window below (or above) viewport
        let barW = min(max(560, sFrame.width - 24), 708)
        let barH: CGFloat = 54
        let barX = max(sFrame.minX + 12, min(sFrame.maxX - barW - 12, vpAppKit.midX - barW * 0.5))
        let barY: CGFloat = (vpAppKit.minY - barH - 12 >= sFrame.minY + 8)
            ? (vpAppKit.minY - barH - 10)
            : min(sFrame.maxY - barH - 10, vpAppKit.maxY + 10)

        let cWin = ControlBarPanel(
            contentRect: NSRect(x: barX, y: barY, width: barW, height: barH),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        cWin.hidesOnDeactivate = false
        cWin.isOpaque = false
        cWin.backgroundColor = .clear
        cWin.hasShadow = true
        cWin.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        cWin.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        cWin.contentView = NSHostingView(rootView: LongshotControlBarView(controller: self))
        cWin.orderFrontRegardless()
        self.controlWindow = cWin
    }

    private func installKeyMonitors() {
        let handleKey: (NSEvent) -> Bool = { [weak self] ev in
            guard let self else { return false }
            let flags = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let cmdOrCtrl = flags.contains(.command) || flags.contains(.control)
            let anyMod = cmdOrCtrl || flags.contains(.option) || flags.contains(.shift)
            switch Int(ev.keyCode) {
            case kVK_Space where !anyMod:
                self.toggleAutoScroll()
                return true
            case kVK_Return, kVK_ANSI_KeypadEnter:
                self.finishAndCopy()
                return true
            case kVK_Escape:
                self.cancel()
                return true
            case kVK_ANSI_Z where cmdOrCtrl:
                self.undoLastSegment()
                return true
            case kVK_ANSI_S where cmdOrCtrl:
                self.finishAndSave()
                return true
            case kVK_ANSI_T where !cmdOrCtrl:
                self.finishAndOCR()
                return true
            default:
                return false
            }
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { ev in
            Task { @MainActor in
                _ = handleKey(ev)
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            handleKey(ev) ? nil : ev
        }
    }

    private func startSessionLoop() {
        var ownWinIDs = Set<Int>()
        if let id = borderWindow?.windowNumber, id > 0 { ownWinIDs.insert(id) }
        if let id = previewWindow?.windowNumber, id > 0 { ownWinIDs.insert(id) }
        if let id = controlWindow?.windowNumber, id > 0 { ownWinIDs.insert(id) }

        let targetScreen = self.screen
        let targetRect = self.viewportTopDown

        captureLoopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { break }

                if self.needsAccessibilityAuth && AccessibilityService.hasPermission() {
                    self.needsAccessibilityAuth = false
                    if self.autoStartRequested && self.segmentCount == 0 && !self.isAutoScrolling {
                        self.beginAutoScrolling(initialDelayMs: 120)
                    } else if !self.isAutoScrolling {
                        self.statusHint = "辅助功能已就绪 · Space 自动翻页"
                    }
                }

                if self.isAutoScrolling {
                    if self.pendingInitialDelayMs > 0 {
                        let delayNs = self.pendingInitialDelayMs * 1_000_000
                        self.pendingInitialDelayMs = 0
                        try? await Task.sleep(nanoseconds: delayNs)
                        guard !Task.isCancelled, self.isAutoScrolling else { continue }
                    }

                    if self.pendingInitialWarp {
                        self.pendingInitialWarp = false
                        AccessibilityService.moveCursorIntoViewportIfNeeded(
                            screen: targetScreen,
                            viewportTopDown: targetRect
                        )
                        try? await Task.sleep(nanoseconds: 55_000_000)
                        guard !Task.isCancelled, self.isAutoScrolling else { continue }
                    }

                    // Hold scrolling steady while the user hovers over the control bar to click Pause / Finish / Save
                    if let cWin = self.controlWindow, cWin.frame.contains(NSEvent.mouseLocation) {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        continue
                    }

                    let probeBoost = (self.consecutiveStillCount == 1) ? 1.25 : 1.0
                    let fraction = min(0.46, self.scrollSpeed.viewportStepFraction * self.adaptiveScale * probeBoost)
                    let totalStepPt = max(36, min(280, Int((targetRect.height * fraction).rounded())))
                    let tickCount = 6
                    let baseTick = totalStepPt / tickCount
                    let remTicks = totalStepPt % tickCount
                    let scrollAnchor = AccessibilityService.globalCGPoint(
                        on: targetScreen,
                        localTopDownPoint: ASPoint(
                            targetRect.midX,
                            targetRect.minY + targetRect.height * 0.46
                        )
                    )

                    for t in 0..<tickCount {
                        guard !Task.isCancelled, self.isAutoScrolling else { break }
                        let delta = baseTick + (t < remTicks ? 1 : 0)
                        if delta > 0 {
                            AccessibilityService.postPixelScrollDown(at: scrollAnchor, deltaPointsDown: delta)
                        }
                        if t + 1 < tickCount {
                            try? await Task.sleep(nanoseconds: 15_000_000)
                        }
                    }

                    guard !Task.isCancelled, self.isAutoScrolling else { continue }
                    try? await Task.sleep(nanoseconds: self.scrollSpeed.settleMilliseconds * 1_000_000)
                    guard !Task.isCancelled, self.isAutoScrolling else { continue }

                    guard let frame = await ScreenCaptureService.captureDisplayRegion(
                        screen: targetScreen,
                        localTopDownRect: targetRect,
                        excludingWindowNumbers: ownWinIDs
                    ) else {
                        continue
                    }
                    self.handleAutoScrollFrame(frame, screen: targetScreen, viewport: targetRect)
                } else {
                    try? await Task.sleep(nanoseconds: 115_000_000)
                    guard !Task.isCancelled, !self.isAutoScrolling else { continue }
                    guard let frame = await ScreenCaptureService.captureDisplayRegion(
                        screen: targetScreen,
                        localTopDownRect: targetRect,
                        excludingWindowNumbers: ownWinIDs
                    ) else {
                        continue
                    }
                    _ = self.processFrame(frame, fromAutoScroll: false)
                }
            }
        }
    }

    private func handleAutoScrollFrame(_ frame: PixelBufferRGBA, screen: NSScreen, viewport: ASRect) {
        let step = processFrame(frame, fromAutoScroll: true)
        switch step {
        case .appended:
            consecutiveStillCount = 0
            reachedBottom = false
            goodStepStreak += 1
            if goodStepStreak >= 2 {
                adaptiveScale = 1.0
            }
            statusHint = "自动翻页中（已拼 \(segmentCount) 段）· Space 暂停"

        case .still:
            consecutiveStillCount += 1
            if segmentCount == 0 && consecutiveStillCount == 1 {
                AccessibilityService.moveCursorIntoViewportIfNeeded(screen: screen, viewportTopDown: viewport)
            }
            let stopThreshold = segmentCount > 0 ? 2 : 4
            if consecutiveStillCount >= stopThreshold {
                isAutoScrolling = false
                if segmentCount > 0 {
                    reachedBottom = true
                    statusHint = "已自动到底（共 \(segmentCount) 段）· Enter 完成"
                } else {
                    statusHint = "页面已到底或不可滚动 · Enter 完成"
                }
            }

        case .failed:
            goodStepStreak = 0
            adaptiveScale = max(0.45, adaptiveScale * 0.65)
            statusHint = "正在自适应调速拼接 · Space 暂停"

        case .limitReached:
            isAutoScrolling = false
            statusHint = "已达高度上限 · Enter 完成"
        }
    }

    @discardableResult
    private func processFrame(_ frame: PixelBufferRGBA, fromAutoScroll: Bool) -> LongshotStepResult {
        guard let canvas else { return .still }
        let step = canvas.push(frame)
        switch step {
        case .appended:
            pixelHeight = canvas.totalHeight
            segmentCount = canvas.segmentCount
            canUndo = canvas.canUndo
            reachedBottom = false
            if !fromAutoScroll {
                statusHint = "已拼接 \(segmentCount) 段 · Enter 完成"
            }
            if canvas.headerHeight > 0 || canvas.footerHeight > 0 {
                headerFooterHint = "已去页眉页脚"
            }
            thumbnailImage = canvas.makeThumbnail(maxWidth: 160, maxHeight: 420)
        case .still:
            break
        case .failed:
            if !fromAutoScroll {
                statusHint = "滚动过快，请慢速滚动（⌘Z 撤销）"
            }
        case .limitReached:
            if !fromAutoScroll {
                statusHint = "已达高度上限 · Enter 完成"
            }
        }
        return step
    }

    public func undoLastSegment() {
        if isAutoScrolling {
            isAutoScrolling = false
        }
        guard let canvas, canvas.undoLast() else { return }
        reachedBottom = false
        pixelHeight = canvas.totalHeight
        segmentCount = canvas.segmentCount
        canUndo = canvas.canUndo
        thumbnailImage = canvas.makeThumbnail(maxWidth: 160, maxHeight: 420)
        statusHint = "已撤销上一段 · Space 继续翻页"
    }

    public func finishAndCopy() {
        guard let cg = canvas?.exportBuffer()?.makeCGImage() else {
            cancel()
            return
        }
        let scale = backingScale
        stopAndCleanup()
        onFinishCopy?(cg, scale)
    }

    public func finishAndSave() {
        guard let cg = canvas?.exportBuffer()?.makeCGImage() else {
            cancel()
            return
        }
        let scale = backingScale
        stopAndCleanup()
        onFinishSave?(cg, scale)
    }

    public func finishAndAnnotate() {
        guard let cg = canvas?.exportBuffer()?.makeCGImage() else {
            cancel()
            return
        }
        let scale = backingScale
        let scr = screen
        stopAndCleanup()
        onFinishEdit?(cg, scale, scr)
    }

    public func finishAndOCR() {
        guard let cg = canvas?.exportBuffer()?.makeCGImage() else {
            cancel()
            return
        }
        stopAndCleanup()
        onFinishOCR?(cg)
    }

    public func cancel() {
        stopAndCleanup()
        onCancel?()
    }
}

private final class LongshotFrameOverlayView: NSView {
    let viewportInView: NSRect

    init(frame: NSRect, viewportInView: NSRect) {
        self.viewportInView = viewportInView
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Subtle outside dim while leaving viewport 100% clear
        ctx.saveGState()
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRect(viewportInView)
        ctx.addPath(path)
        ctx.clip(using: .evenOdd)
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28))
        ctx.fill(bounds)
        ctx.restoreGState()

        // Crisp dual-stroke border outside viewport
        let outer = viewportInView.insetBy(dx: -1.5, dy: -1.5)
        ctx.setStrokeColor(CGColor(srgbRed: 0.12, green: 0.53, blue: 0.96, alpha: 0.96))
        ctx.setLineWidth(2.0)
        ctx.stroke(outer)
    }
}

private struct LongshotPreviewCard: View {
    @ObservedObject var controller: LongshotSessionController

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Circle()
                    .fill(controller.isAutoScrolling ? Color.accentColor : Color.green)
                    .frame(width: 6, height: 6)
                Text(controller.isAutoScrolling ? "自动拼接" : "预览")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if let cg = controller.thumbnailImage {
                Image(decorative: cg, scale: 1.0)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1)
                    )
            }

            Text("\(controller.pixelWidth) × \(controller.pixelHeight) px")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
    }
}

struct LongshotControlBarView: View {
    @ObservedObject var controller: LongshotSessionController

    private var statusDotColor: Color {
        if controller.needsAccessibilityAuth {
            return .orange
        }
        if controller.isAutoScrolling {
            return .accentColor
        }
        return .green
    }

    private var autoScrollButtonLabel: String {
        if controller.isAutoScrolling {
            return "暂停"
        }
        if controller.segmentCount > 0 && !controller.reachedBottom {
            return "继续翻页"
        }
        return "自动翻页"
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 7, height: 7)
                    Text("\(controller.pixelWidth) × \(controller.pixelHeight) px")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    if let hf = controller.headerFooterHint {
                        Text(hf)
                            .font(.system(size: 10))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                    }
                }
                Text(controller.statusHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if controller.needsAccessibilityAuth {
                Button("授权") {
                    controller.openAccessibilityAuthorization()
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .controlSize(.small)
                .help("打开辅助功能权限设置")
            }

            Button {
                controller.toggleAutoScroll()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: controller.isAutoScrolling ? "pause.fill" : "play.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text(autoScrollButtonLabel)
                }
            }
            .buttonStyle(.bordered)
            .tint(controller.isAutoScrolling ? .accentColor : nil)
            .controlSize(.small)
            .help("自动翻页 / 暂停 (Space)")

            Button {
                controller.cycleScrollSpeed()
            } label: {
                Text(controller.scrollSpeed.title)
                    .font(.system(size: 11, weight: .medium))
                    .frame(minWidth: 26)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("翻页速度：\(controller.scrollSpeed.title)（点击切换）")

            Divider()
                .frame(height: 18)

            Button {
                controller.undoLastSegment()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!controller.canUndo)
            .help("撤销上一段 (⌘Z)")

            Button("OCR") {
                controller.finishAndOCR()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("识字 (T)")

            Button("标注") {
                controller.finishAndAnnotate()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("标注")

            Button("保存") {
                controller.finishAndSave()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("保存 (⌘S)")

            Button("完成") {
                controller.finishAndCopy()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("完成并复制 (Enter)")

            Button {
                controller.cancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 3)
            .help("取消 (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
        )
    }
}
