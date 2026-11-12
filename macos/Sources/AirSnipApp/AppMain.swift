import AppKit
import SwiftUI
import AirSnipCore

@MainActor
public final class AirSnipAppController: NSObject, ObservableObject {
    @Published public private(set) var config: AirSnipConfig
    @Published public private(set) var hotkeyRegistrationErrors: [String] = []

    public let hotkeyManager = GlobalHotkeyManager()
    public let pinManager = PinManager()
    public let ocrBubbleManager = OCRBubbleManager()
    public var settingsController: SettingsWindowController?

    private var statusItem: NSStatusItem?
    private var activeCaptureSession: CaptureSessionCoordinator?
    private var activeLongshotSession: LongshotSessionController?

    private static let singleInstanceActivateNotification = Notification.Name("io.zzusec.airsnip.activateSettings")

    public override init() {
        self.config = AirSnipConfig.load()
        super.init()

        self.settingsController = SettingsWindowController(appController: self)

        pinManager.getConfig = { [weak self] in
            self?.config ?? AirSnipConfig()
        }
        pinManager.updateConfig = { [weak self] block in
            self?.updateConfig(block)
        }
        pinManager.onRequestAnnotatePin = { [weak self] pin in
            self?.startPinInlineEditSession(pin: pin)
        }

        ocrBubbleManager.onAutoCopyChanged = { [weak self] autoCopy in
            self?.updateConfig { $0.ocr.autoCopy = autoCopy }
        }

        hotkeyManager.onTrigger = { [weak self] action in
            guard let self else { return }
            switch action {
            case .screenshot:
                self.triggerCapture()
            case .pin:
                self.triggerGlobalPinFromClipboard()
            case .pinBorderToggle:
                self.pinManager.toggleAllBorders()
            }
        }
    }

    public func bootstrap() {
        setupStatusBarItem()
        hotkeyRegistrationErrors = hotkeyManager.apply(hotkeys: config.hotkeys)

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(onExternalShowSettings(_:)),
            name: Self.singleInstanceActivateNotification,
            object: nil
        )

        // One-shot silent update check 3 seconds after launch (no polling timer, 0% idle CPU)
        if config.autoCheckUpdate {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self else { return }
                if case .success(let rel?) = await UpdateChecker.checkLatest(),
                   self.config.skippedVersion != rel.version {
                    ToastHUD.show("发现新版本 AirSnip v\(rel.version)，可在「设置 → 关于」更新", duration: 3.0)
                }
            }
        }
    }

    @objc private func onExternalShowSettings(_ note: Notification) {
        openSettings()
    }

    public static func notifyExistingInstanceAndExitIfDuplicate() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != currentPID && !$0.isTerminated }
        if !others.isEmpty {
            DistributedNotificationCenter.default().postNotificationName(
                singleInstanceActivateNotification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            exit(0)
        }
    }

    public func updateConfig(_ mutate: (inout AirSnipConfig) -> Void) {
        let oldHotkeys = config.hotkeys
        mutate(&config)
        try? config.save()
        if config.hotkeys != oldHotkeys {
            hotkeyRegistrationErrors = hotkeyManager.apply(hotkeys: config.hotkeys)
        }
    }

    // MARK: - Menu Bar Status Item

    private func setupStatusBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = makeMenuBarTemplateIcon()
            button.toolTip = "AirSnip（轻截）— 点击打开菜单"
            button.target = self
            button.action = #selector(onStatusBarClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.statusItem = item
    }

    @objc private func onStatusBarClicked(_ sender: NSStatusBarButton) {
        guard let item = statusItem else { return }
        let menu = buildStatusMenu()
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu(title: "AirSnip")

        let capHint = config.hotkeys.screenshot.isUnbound ? "" : " (\(config.hotkeys.screenshot.displayString))"
        let capItem = NSMenuItem(title: "截图\(capHint)", action: #selector(menuCapture), keyEquivalent: "")
        capItem.target = self
        menu.addItem(capItem)

        let pinHint = config.hotkeys.pin.isUnbound ? "" : " (\(config.hotkeys.pin.displayString))"
        let pinItem = NSMenuItem(title: "从剪贴板贴图\(pinHint)", action: #selector(menuPinClipboard), keyEquivalent: "")
        pinItem.target = self
        menu.addItem(pinItem)

        if pinManager.count > 0 {
            menu.addItem(.separator())
            if pinManager.hasClickThroughPins {
                let restoreItem = NSMenuItem(title: "恢复全部鼠标穿透贴图", action: #selector(menuRestoreClickThrough), keyEquivalent: "")
                restoreItem.target = self
                menu.addItem(restoreItem)
            }
            let closePins = NSMenuItem(title: "关闭全部贴图（\(pinManager.count)）", action: #selector(menuCloseAllPins), keyEquivalent: "")
            closePins.target = self
            menu.addItem(closePins)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(menuSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "退出 AirSnip", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func menuCapture() { triggerCapture() }
    @objc private func menuPinClipboard() { triggerGlobalPinFromClipboard() }
    @objc private func menuRestoreClickThrough() { pinManager.restoreAllClickThrough() }
    @objc private func menuCloseAllPins() { pinManager.closeAll() }
    @objc private func menuSettings() { openSettings() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    private func makeMenuBarTemplateIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(1.65)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)

            // AirSnip crop frame mark
            let frameRect = CGRect(x: 4.0, y: 4.5, width: 10.0, height: 9.0)
            ctx.stroke(frameRect)
            // Crop ticks
            ctx.move(to: CGPoint(x: 4.0, y: 13.5)); ctx.addLine(to: CGPoint(x: 4.0, y: 16.0))
            ctx.move(to: CGPoint(x: 1.5, y: 13.5)); ctx.addLine(to: CGPoint(x: 4.0, y: 13.5))
            ctx.move(to: CGPoint(x: 14.0, y: 4.5)); ctx.addLine(to: CGPoint(x: 16.5, y: 4.5))
            ctx.move(to: CGPoint(x: 14.0, y: 2.0)); ctx.addLine(to: CGPoint(x: 14.0, y: 4.5))
            ctx.strokePath()
            return true
        }
        img.isTemplate = true
        return img
    }

    // MARK: - Workflows

    public func openSettings() {
        settingsController?.show()
    }

    public func triggerCapture() {
        guard activeCaptureSession == nil, activeLongshotSession == nil else { return }

        if !ScreenCaptureService.hasScreenCapturePermission() {
            let granted = ScreenCaptureService.requestScreenCapturePermissionIfNeeded()
            if !granted && !ScreenCaptureService.hasScreenCapturePermission() {
                ScreenCaptureService.showPermissionGuidanceAlert()
                return
            }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshots = try await ScreenCaptureService.captureAllDisplays()
                guard !snapshots.isEmpty else { return }
                let coordinator = self.makeSessionCoordinator(mode: .normalCapture)
                self.activeCaptureSession = coordinator
                coordinator.startWithSnapshots(snapshots)
            } catch {
                ScreenCaptureService.showPermissionGuidanceAlert()
            }
        }
    }

    public func triggerGlobalPinFromClipboard() {
        guard activeCaptureSession == nil else { return }
        guard let clip = OutputService.readImageFromClipboard() else {
            // Silent ignore when clipboard contains text or no image (matches AirSnip ADR)
            return
        }
        let scale = Double(clip.cgImage.width) / max(1.0, Double(clip.pointSize.width))
        var pinCfg = config
        pinCfg.pinPosition = .center
        pinManager.createPin(
            cgImage: clip.cgImage,
            backingScale: max(1.0, scale),
            preferredScreenOriginAppKit: nil,
            config: pinCfg
        )
    }

    private func startPinInlineEditSession(pin: PinWindowController) {
        guard activeCaptureSession == nil, activeLongshotSession == nil else { return }
        let coordinator = makeSessionCoordinator(mode: .inlinePinEdit(pin))
        activeCaptureSession = coordinator
        coordinator.startPinInlineEdit(pin: pin)
    }

    private func startStandaloneAnnotateSession(image: CGImage, scale: Double, screen: NSScreen) {
        guard activeCaptureSession == nil else { return }
        let coordinator = makeSessionCoordinator(mode: .standaloneImageEdit(image, scale, screen))
        activeCaptureSession = coordinator
        coordinator.startStandaloneImageEdit(cgImage: image, backingScale: scale, screen: screen)
    }

    private func makeSessionCoordinator(mode: CaptureSessionCoordinator.SessionMode) -> CaptureSessionCoordinator {
        let coordinator = CaptureSessionCoordinator(config: config, mode: mode)

        coordinator.onConfigMutated = { [weak self] updated in
            self?.config = updated
        }
        coordinator.onCompleteCopy = { [weak self] cgImg, scale in
            OutputService.copyImageToClipboard(cgImg, backingScale: scale)
            if self?.config.showCompletionToast == true {
                ToastHUD.show("截图已复制到剪贴板")
            }
        }
        coordinator.onCompleteSave = { [weak self] cgImg, scale, cfg in
            let _ = scale
            guard let savedURL = OutputService.presentSaveDialog(for: cgImg, config: &cfg) else {
                return false
            }
            self?.config = cfg
            if self?.config.showCompletionToast == true {
                ToastHUD.show("已保存 \(savedURL.lastPathComponent)")
            }
            return true
        }
        coordinator.onCompletePin = { [weak self] cgImg, scale, origin in
            guard let self else { return }
            self.pinManager.createPin(
                cgImage: cgImg,
                backingScale: scale,
                preferredScreenOriginAppKit: origin,
                config: self.config
            )
        }
        coordinator.onStartOCR = { [weak self] rawImg, anchor in
            guard let self else { return }
            self.ocrBubbleManager.recognizeAndPresent(
                rawSelectionImage: rawImg,
                anchorScreenPoint: anchor,
                config: self.config
            )
        }
        coordinator.onStartLongshot = { [weak self] screen, vpRect, initBuf in
            guard let self else { return }
            self.beginLongshotSession(screen: screen, viewportTopDown: vpRect, initialCrop: initBuf)
        }
        coordinator.onSessionEnded = { [weak self] in
            self?.activeCaptureSession = nil
        }
        return coordinator
    }

    private func beginLongshotSession(screen: NSScreen, viewportTopDown: ASRect, initialCrop: PixelBufferRGBA) {
        let ls = LongshotSessionController(
            screen: screen,
            viewportTopDown: viewportTopDown,
            initialCrop: initialCrop,
            config: config
        )
        ls.onFinishCopy = { [weak self] cgImg, scale in
            self?.activeLongshotSession = nil
            OutputService.copyImageToClipboard(cgImg, backingScale: scale)
            if self?.config.showCompletionToast == true {
                ToastHUD.show("长截图已复制到剪贴板（\(cgImg.width)×\(cgImg.height)）")
            }
        }
        ls.onFinishSave = { [weak self] cgImg, scale in
            guard let self else { return }
            self.activeLongshotSession = nil
            OutputService.copyImageToClipboard(cgImg, backingScale: scale)
            var cfg = self.config
            if let url = OutputService.presentSaveDialog(for: cgImg, config: &cfg) {
                self.config = cfg
                if self.config.showCompletionToast {
                    ToastHUD.show("已保存 \(url.lastPathComponent)")
                }
            }
        }
        ls.onFinishEdit = { [weak self] cgImg, scale, scr in
            self?.activeLongshotSession = nil
            self?.startStandaloneAnnotateSession(image: cgImg, scale: scale, screen: scr)
        }
        ls.onCancel = { [weak self] in
            self?.activeLongshotSession = nil
        }
        activeLongshotSession = ls
        ls.start()
    }
}

public final class AirSnipAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AirSnipAppController?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let ctrl = AirSnipAppController()
        self.controller = ctrl
        ctrl.bootstrap()

        if CommandLine.arguments.contains("--open-settings") {
            ctrl.openSettings()
        }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.openSettings()
        return true
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
public enum AirSnipMain {
    public static func main() {
        if CommandLine.arguments.contains("--smoke-test") {
            let ok = SmokeTestRunner.run()
            exit(ok ? 0 : 1)
        }

        AirSnipAppController.notifyExistingInstanceAndExitIfDuplicate()

        let app = NSApplication.shared
        let delegate = AirSnipAppDelegate()
        app.delegate = delegate
        app.run()
    }
}
