import AppKit
import Carbon
import SwiftUI
import AirSnipCore

private final class ControlBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
public final class LongshotSessionController: ObservableObject {
    @Published public private(set) var pixelWidth: Int = 0
    @Published public private(set) var pixelHeight: Int = 0
    @Published public private(set) var segmentCount: Int = 0
    @Published public private(set) var canUndo: Bool = false
    @Published public private(set) var statusHint: String = "请在蓝色选框内上下滚动页面，按 Enter 完成"
    @Published public private(set) var thumbnailImage: CGImage?
    @Published public private(set) var headerFooterHint: String?

    private let screen: NSScreen
    private let viewportTopDown: ASRect
    private let backingScale: Double
    private var config: AirSnipConfig

    private var canvas: LongshotCanvas?
    private var borderWindow: NSPanel?
    private var previewWindow: NSPanel?
    private var controlWindow: ControlBarPanel?
    private var captureLoopTask: Task<Void, Never>?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    public var onFinishCopy: ((CGImage, Double) -> Void)?
    public var onFinishSave: ((CGImage, Double) -> Void)?
    public var onFinishEdit: ((CGImage, Double, NSScreen) -> Void)?
    public var onCancel: (() -> Void)?

    public init(
        screen: NSScreen,
        viewportTopDown: ASRect,
        initialCrop: PixelBufferRGBA,
        config: AirSnipConfig
    ) {
        self.screen = screen
        self.viewportTopDown = viewportTopDown
        self.backingScale = Double(screen.backingScaleFactor)
        self.config = config
        self.pixelWidth = initialCrop.width
        self.pixelHeight = initialCrop.height

        let stitchCanvas = LongshotCanvas(
            width: initialCrop.width,
            frameHeight: initialCrop.height,
            params: LongshotParams(minRatio: 0.86, minFixedRows: 8),
            maxHeight: config.longshotMaxHeight
        )
        stitchCanvas.seed(initialCrop)
        self.canvas = stitchCanvas
        self.thumbnailImage = stitchCanvas.makeThumbnail(maxWidth: 160, maxHeight: 420)
    }

    public func start() {
        setupWindows()
        installKeyMonitors()
        startCaptureLoop()
    }

    public func stopAndCleanup() {
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
        let bWin = NSPanel(
            contentRect: sFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
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

        // 2. Side live thumbnail preview window (LNG-14: right side if >=130pt space, else left side)
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
        let barW: CGFloat = 540
        let barH: CGFloat = 52
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
            switch Int(ev.keyCode) {
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

    private func startCaptureLoop() {
        var ownWinIDs = Set<Int>()
        if let id = borderWindow?.windowNumber, id > 0 { ownWinIDs.insert(id) }
        if let id = previewWindow?.windowNumber, id > 0 { ownWinIDs.insert(id) }
        if let id = controlWindow?.windowNumber, id > 0 { ownWinIDs.insert(id) }

        let targetScreen = self.screen
        let targetRect = self.viewportTopDown

        captureLoopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 115_000_000)
                guard !Task.isCancelled, let self else { break }
                guard let frame = await ScreenCaptureService.captureDisplayRegion(
                    screen: targetScreen,
                    localTopDownRect: targetRect,
                    excludingWindowNumbers: ownWinIDs
                ) else {
                    continue
                }
                self.processFrame(frame)
            }
        }
    }

    private func processFrame(_ frame: PixelBufferRGBA) {
        guard let canvas else { return }
        let step = canvas.push(frame)
        switch step {
        case .appended(let offset, _):
            pixelHeight = canvas.totalHeight
            segmentCount = canvas.segmentCount
            canUndo = canvas.canUndo
            let dir = offset > 0 ? "向下" : "向上"
            statusHint = "正在\(dir)拼接（共 \(segmentCount) 段），按 Enter 完成"
            if canvas.headerHeight > 0 || canvas.footerHeight > 0 {
                headerFooterHint = "已自动过滤固定页眉/页脚"
            }
            thumbnailImage = canvas.makeThumbnail(maxWidth: 160, maxHeight: 420)
        case .still:
            break
        case .failed:
            statusHint = "滚动过快或含动态内容，请缓慢滚动（可 ⌘Z 撤销最后一段）"
        case .limitReached:
            statusHint = "已达长截图高度上限（\(config.longshotMaxHeight) px），请按 Enter 完成"
        }
    }

    public func undoLastSegment() {
        guard let canvas, canvas.undoLast() else { return }
        pixelHeight = canvas.totalHeight
        segmentCount = canvas.segmentCount
        canUndo = canvas.canUndo
        thumbnailImage = canvas.makeThumbnail(maxWidth: 160, maxHeight: 420)
        statusHint = "已撤销最后一段，可继续滚动或按 Enter 完成"
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
            Text("实时拼接预览")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

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

private struct LongshotControlBarView: View {
    @ObservedObject var controller: LongshotSessionController

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
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

            Button {
                controller.undoLastSegment()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!controller.canUndo)
            .help("撤销最后一段 (⌘Z)")

            Button("标注") {
                controller.finishAndAnnotate()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("完成拼接并进入标注编辑")

            Button("保存") {
                controller.finishAndSave()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("另存为 PNG / JPEG / WebP (⌘S)")

            Button("完成") {
                controller.finishAndCopy()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("复制到剪贴板并结束 (Enter)")

            Button {
                controller.cancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
            .help("取消长截图 (Esc)")
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
