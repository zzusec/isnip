import AppKit
import SwiftUI
import AirSnipCore

@MainActor
public final class AirSnipAppController: NSObject, ObservableObject, NSMenuDelegate {
    @Published public private(set) var config: AirSnipConfig
    @Published public private(set) var hotkeyRegistrationErrors: [String] = []

    public let hotkeyManager = GlobalHotkeyManager()
    public let pinManager = PinManager()
    public let ocrBubbleManager = OCRBubbleManager()
    public var settingsController: SettingsWindowController?

    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu(title: "iSnip")
    private var activeCaptureSession: CaptureSessionCoordinator?
    private var activeLongshotSession: LongshotSessionController?
    private var isCapturingSnapshots = false
    private let configURL: URL

    private static let singleInstanceActivateNotification = Notification.Name("io.zzusec.airsnip.activateSettings")

    public init(configURL: URL = AirSnipConfig.defaultConfigFileURL()) {
        self.configURL = configURL
        self.config = AirSnipConfig.load(from: configURL)
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
        pinManager.onRequestOCRPin = { [weak self] pin in
            guard let self else { return }
            let f = pin.window.frame
            let anchor = NSPoint(x: f.midX, y: f.midY)
            self.ocrBubbleManager.recognizeAndPresent(
                rawSelectionImage: pin.cgImage,
                anchorScreenPoint: anchor,
                config: self.config
            )
        }

        ocrBubbleManager.onConfigChanged = { [weak self] lang, autoCopy, mergeBreaks in
            self?.updateConfig {
                $0.ocr.language = lang
                $0.ocr.autoCopy = autoCopy
                $0.ocr.mergeLineBreaks = mergeBreaks
            }
        }

        hotkeyManager.onTrigger = { [weak self] action in
            guard let self else { return }
            switch action {
            case .screenshot:
                self.triggerCapture()
            case .ocrCapture:
                self.triggerDirectOCRCapture()
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
                    ToastHUD.show("发现新版本 v\(rel.version)", symbol: "arrow.down.circle.fill", tint: .systemCyan, duration: 3.0)
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
        try? config.save(to: configURL)
        if config.hotkeys != oldHotkeys {
            hotkeyRegistrationErrors = hotkeyManager.apply(hotkeys: config.hotkeys)
        }
    }

    // MARK: - Menu Bar Status Item

    private func setupStatusBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = makeMenuBarTemplateIcon()
            button.toolTip = "iSnip"
        }
        statusMenu.delegate = self
        populateStatusMenu(statusMenu)
        item.menu = statusMenu
        self.statusItem = item
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        populateStatusMenu(menu)
    }

    private func menuIcon(_ symbolName: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13.0, weight: .medium)
        let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        img?.isTemplate = true
        return img
    }

    private func populateStatusMenu(_ menu: NSMenu) {
        let capHint = config.hotkeys.screenshot.isUnbound ? "" : " (\(config.hotkeys.screenshot.displayString))"
        let capItem = NSMenuItem(title: "截图\(capHint)", action: #selector(menuCapture), keyEquivalent: "")
        capItem.image = menuIcon("viewfinder")
        capItem.target = self
        menu.addItem(capItem)

        let ocrCapHint = config.hotkeys.ocrCapture.isUnbound ? "" : " (\(config.hotkeys.ocrCapture.displayString))"
        let ocrCapItem = NSMenuItem(title: "截图识字\(ocrCapHint)", action: #selector(menuDirectOCRCapture), keyEquivalent: "")
        ocrCapItem.image = menuIcon("text.viewfinder")
        ocrCapItem.target = self
        menu.addItem(ocrCapItem)

        let pinHint = config.hotkeys.pin.isUnbound ? "" : " (\(config.hotkeys.pin.displayString))"
        let pinItem = NSMenuItem(title: "剪贴板贴图\(pinHint)", action: #selector(menuPinClipboard), keyEquivalent: "")
        pinItem.image = menuIcon("pin")
        pinItem.target = self
        menu.addItem(pinItem)

        menu.addItem(.separator())

        let ocrClipItem = NSMenuItem(title: "识别剪贴板文字", action: #selector(menuOCRClipboard), keyEquivalent: "")
        ocrClipItem.image = menuIcon("doc.text.viewfinder")
        ocrClipItem.target = self
        menu.addItem(ocrClipItem)

        let ocrFileItem = NSMenuItem(title: "识别图片文字…", action: #selector(menuOCRFile), keyEquivalent: "")
        ocrFileItem.image = menuIcon("photo.badge.magnifyingglass")
        ocrFileItem.target = self
        menu.addItem(ocrFileItem)

        if pinManager.count > 0 {
            menu.addItem(.separator())
            if pinManager.hasClickThroughPins {
                let restoreItem = NSMenuItem(title: "取消贴图穿透", action: #selector(menuRestoreClickThrough), keyEquivalent: "")
                restoreItem.image = menuIcon("cursorarrow.click.2")
                restoreItem.target = self
                menu.addItem(restoreItem)
            }
            let closePins = NSMenuItem(title: "关闭全部贴图 (\(pinManager.count))", action: #selector(menuCloseAllPins), keyEquivalent: "")
            closePins.image = menuIcon("xmark.circle")
            closePins.target = self
            menu.addItem(closePins)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(menuSettings), keyEquivalent: ",")
        settingsItem.image = menuIcon("gearshape")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "退出 iSnip", action: #selector(menuQuit), keyEquivalent: "q")
        quitItem.image = menuIcon("power")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func menuCapture() {
        startScreenCaptureOverlay(mode: .normalCapture, fromMenu: true)
    }
    @objc private func menuDirectOCRCapture() {
        startScreenCaptureOverlay(mode: .directOCRCapture, fromMenu: true)
    }
    @objc private func menuPinClipboard() { triggerGlobalPinFromClipboard() }
    @objc private func menuOCRClipboard() { triggerOCRFromClipboard() }
    @objc private func menuOCRFile() { triggerOCRFromFile() }
    @objc private func menuRestoreClickThrough() { pinManager.restoreAllClickThrough() }
    @objc private func menuCloseAllPins() { pinManager.closeAll() }
    @objc private func menuSettings() { openSettings() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    private func makeMenuBarTemplateIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setLineWidth(1.55)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)

            // Four precision optical viewfinder corner brackets (matching the iSnip 3D AppIcon)
            let minX: CGFloat = 2.5
            let maxX: CGFloat = 15.5
            let minY: CGFloat = 3.0
            let maxY: CGFloat = 15.0
            let arm: CGFloat = 3.6
            let r: CGFloat = 2.0

            // Top-left
            ctx.move(to: CGPoint(x: minX, y: maxY - arm))
            ctx.addArc(tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: minX + arm, y: maxY), radius: r)
            ctx.addLine(to: CGPoint(x: minX + arm, y: maxY))
            // Top-right
            ctx.move(to: CGPoint(x: maxX - arm, y: maxY))
            ctx.addArc(tangent1End: CGPoint(x: maxX, y: maxY), tangent2End: CGPoint(x: maxX, y: maxY - arm), radius: r)
            ctx.addLine(to: CGPoint(x: maxX, y: maxY - arm))
            // Bottom-left
            ctx.move(to: CGPoint(x: minX, y: minY + arm))
            ctx.addArc(tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: minX + arm, y: minY), radius: r)
            ctx.addLine(to: CGPoint(x: minX + arm, y: minY))
            // Bottom-right
            ctx.move(to: CGPoint(x: maxX - arm, y: minY))
            ctx.addArc(tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX, y: minY + arm), radius: r)
            ctx.addLine(to: CGPoint(x: maxX, y: minY + arm))
            ctx.strokePath()

            // Center optical aperture ring + subtle focus dot
            ctx.setLineWidth(1.35)
            ctx.strokeEllipse(in: CGRect(x: 6.3, y: 6.3, width: 5.4, height: 5.4))
            ctx.fillEllipse(in: CGRect(x: 8.2, y: 8.2, width: 1.6, height: 1.6))
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
        startScreenCaptureOverlay(mode: .normalCapture)
    }

    public func triggerDirectOCRCapture() {
        startScreenCaptureOverlay(mode: .directOCRCapture)
    }

    private func cleanupStaleCaptureSessionIfNeeded() {
        if let existing = activeCaptureSession, !existing.hasVisibleWindows {
            existing.cancelSession()
            activeCaptureSession = nil
        }
    }

    private func startScreenCaptureOverlay(mode: CaptureSessionCoordinator.SessionMode, fromMenu: Bool = false) {
        guard activeLongshotSession == nil, !isCapturingSnapshots else { return }

        if let existing = activeCaptureSession {
            if !existing.hasVisibleWindows || fromMenu {
                existing.cancelSession()
                activeCaptureSession = nil
            } else {
                existing.refocus()
                return
            }
        }

        isCapturingSnapshots = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isCapturingSnapshots = false }
            if fromMenu {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            do {
                let snapshots = try await ScreenCaptureService.captureAllDisplays()
                guard !snapshots.isEmpty else { return }
                let coordinator = self.makeSessionCoordinator(mode: mode)
                self.activeCaptureSession = coordinator
                coordinator.startWithSnapshots(snapshots)
            } catch {
                ScreenCaptureService.showPermissionGuidanceAlert(error: error)
            }
        }
    }

    public func triggerOCRFromClipboard() {
        guard let clip = OutputService.readImageFromClipboard() else {
            ToastHUD.show("剪贴板无图片")
            return
        }
        ocrBubbleManager.recognizeAndPresent(
            rawSelectionImage: clip.cgImage,
            anchorScreenPoint: nil,
            config: config
        )
    }

    public func triggerOCRFromFile() {
        guard let cg = OutputService.readImageFromFileDialog() else {
            return
        }
        ocrBubbleManager.recognizeAndPresent(
            rawSelectionImage: cg,
            anchorScreenPoint: nil,
            config: config
        )
    }

    public func triggerGlobalPinFromClipboard() {
        cleanupStaleCaptureSessionIfNeeded()
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
        cleanupStaleCaptureSessionIfNeeded()
        guard activeCaptureSession == nil, activeLongshotSession == nil else { return }
        let coordinator = makeSessionCoordinator(mode: .inlinePinEdit(pin))
        activeCaptureSession = coordinator
        coordinator.startPinInlineEdit(pin: pin)
    }

    private func startStandaloneAnnotateSession(image: CGImage, scale: Double, screen: NSScreen) {
        cleanupStaleCaptureSessionIfNeeded()
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
            let currentCfg = self?.config
            let showToast = currentCfg?.showCompletionToast ?? true
            OutputService.copyImageToClipboard(cgImg, backingScale: scale, config: currentCfg) { res in
                guard showToast else { return }
                if res.savedRatioPercent >= 3 {
                    ToastHUD.show("已复制 · \(res.compactBadgeSummary)")
                } else {
                    ToastHUD.show("已复制")
                }
            }
        }
        coordinator.onCompleteSave = { [weak self] cgImg, scale, forceDialog, cfg in
            let _ = scale
            let showToast = cfg.showCompletionToast
            let cfgSaveURL = self?.configURL ?? AirSnipConfig.defaultConfigFileURL()
            guard OutputService.saveImage(
                for: cgImg,
                config: &cfg,
                forceDialog: forceDialog,
                configSaveURL: cfgSaveURL,
                onFinalCompressed: { _, finalRes in
                    guard showToast else { return }
                    ToastHUD.show("已保存 · \(finalRes.compactBadgeSummary)")
                }
            ) != nil else {
                return false
            }
            self?.config = cfg
            if cfg.showCompletionToast && !(cfg.lastSaveFormat == .png && cfg.smartPngCompression) {
                ToastHUD.show("已保存")
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
            let currentCfg = self?.config
            let showToast = currentCfg?.showCompletionToast ?? true
            self?.activeLongshotSession = nil
            OutputService.copyImageToClipboard(cgImg, backingScale: scale, config: currentCfg) { res in
                guard showToast else { return }
                if res.savedRatioPercent >= 3 {
                    ToastHUD.show("已复制 · \(res.compactBadgeSummary)")
                } else {
                    ToastHUD.show("已复制")
                }
            }
        }
        ls.onFinishSave = { [weak self] cgImg, scale in
            guard let self else { return }
            self.activeLongshotSession = nil
            OutputService.copyImageToClipboard(cgImg, backingScale: scale, config: self.config)
            var cfg = self.config
            let showToast = cfg.showCompletionToast
            if OutputService.saveImage(
                for: cgImg,
                config: &cfg,
                configSaveURL: self.configURL,
                onFinalCompressed: { _, finalRes in
                    guard showToast else { return }
                    ToastHUD.show("已保存 · \(finalRes.compactBadgeSummary)")
                }
            ) != nil {
                self.config = cfg
                if self.config.showCompletionToast && !(cfg.lastSaveFormat == .png && cfg.smartPngCompression) {
                    ToastHUD.show("已保存")
                }
            }
        }
        ls.onFinishEdit = { [weak self] cgImg, scale, scr in
            self?.activeLongshotSession = nil
            self?.startStandaloneAnnotateSession(image: cgImg, scale: scale, screen: scr)
        }
        ls.onFinishOCR = { [weak self] cgImg in
            guard let self else { return }
            self.activeLongshotSession = nil
            self.ocrBubbleManager.recognizeAndPresent(
                rawSelectionImage: cgImg,
                anchorScreenPoint: nil,
                config: self.config
            )
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
        if CommandLine.arguments.contains("--request-screen-capture") {
            _ = ScreenCaptureService.requestScreenCapturePermissionIfNeeded()
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
