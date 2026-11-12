import AppKit
import Carbon
import CoreGraphics
import ImageIO
import QuartzCore
import ScreenCaptureKit
import ServiceManagement
import UniformTypeIdentifiers
import AirSnipCore

public struct CapturedScreenSnapshot {
    public let screen: NSScreen
    public let frameInGlobalAppKit: CGRect
    /// Top-down frame where (0,0) is top-left of primary screen
    public let frameTopDown: ASRect
    public let cgImage: CGImage
    public let rawBuffer: PixelBufferRGBA
    public let backingScale: Double
    /// Visible window rects localized to this screen's top-down point coordinates (0,0 = screen top-left)
    public let windowRectsLocalTopDown: [ASRect]
}

@MainActor
public enum ScreenCaptureService {
    public static func hasScreenCapturePermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public static func requestScreenCapturePermissionIfNeeded() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        return CGRequestScreenCaptureAccess()
    }

    public static func openScreenCaptureSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    public static func relaunchApplication(extraArguments: [String] = []) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let bundlePath = Bundle.main.bundleURL.path
        let script = """
        pid="$1"; app="$2"; shift 2
        while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done
        if [ "$#" -gt 0 ]; then
          open "$app" --args "$@"
        else
          open "$app"
        fi
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script, "relaunch", "\(pid)", bundlePath] + extraArguments
        try? proc.run()
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            exit(0)
        }
    }

    public static func resetScreenCapturePermissionAndRelaunch() {
        if let bundleID = Bundle.main.bundleIdentifier {
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", "ScreenCapture", bundleID]
            try? reset.run()
            reset.waitUntilExit()
        }
        relaunchApplication(extraArguments: ["--request-screen-capture"])
    }

    public static func showPermissionGuidanceAlert(error: Error? = nil) {
        let _ = error
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "需要「屏幕录制」权限"
        alert.informativeText = """
        请在「系统设置 → 录屏与系统录音」中开启 iSnip：
        • 刚开启开关：点「重启应用」生效
        • 已开启仍提示：点「重置权限」修复旧授权记录
        """
        alert.addButton(withTitle: "重启应用")
        alert.addButton(withTitle: "重置权限")
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            relaunchApplication()
        case .alertSecondButtonReturn:
            resetScreenCapturePermissionAndRelaunch()
        case .alertThirdButtonReturn:
            openScreenCaptureSystemSettings()
        default:
            break
        }
    }

    /// Queries on-screen application windows via CoreGraphics (top-down global coordinates).
    public static func queryOnScreenWindowsGlobalTopDown(excludingPID: pid_t = ProcessInfo.processInfo.processIdentifier) -> [ASRect] {
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let ignoredOwners: Set<String> = [
            "Dock", "Window Server", "WindowManager", "Wallpaper",
            "SystemUIServer", "Control Center", "Notification Center", "Spotlight"
        ]
        var rects: [ASRect] = []
        for entry in infoList {
            if let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t, ownerPID == excludingPID {
                continue
            }
            if let ownerName = entry[kCGWindowOwnerName as String] as? String, ignoredOwners.contains(ownerName) {
                continue
            }
            let layer = (entry[kCGWindowLayer as String] as? Int) ?? 0
            if layer != 0 { continue } // Normal app windows live at layer 0
            let alpha = (entry[kCGWindowAlpha as String] as? Double) ?? 1.0
            if alpha <= 0.05 { continue }
            guard let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let cgRect = CGRect(dictionaryRepresentation: boundsDict),
                  cgRect.width >= 24 && cgRect.height >= 24 else {
                continue
            }
            rects.append(ASRect(x: cgRect.origin.x, y: cgRect.origin.y, width: cgRect.width, height: cgRect.height))
        }
        return rects
    }

    /// Captures all connected displays in parallel at native physical pixel resolution.
    public static func captureAllDisplays(excludingWindowNumbers: Set<Int> = []) async throws -> [CapturedScreenSnapshot] {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return [] }
        let primaryHeight = screens[0].frame.height
        let globalWinRects = queryOnScreenWindowsGlobalTopDown()

        let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let excludedSCWindows = shareable.windows.filter { excludingWindowNumbers.contains(Int($0.windowID)) }

        var results: [CapturedScreenSnapshot] = []
        for screen in screens {
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let scDisplay = shareable.displays.first(where: { $0.displayID == screenNumber }) else {
                continue
            }
            let scale = Double(screen.backingScaleFactor)
            let pixelW = max(1, Int((screen.frame.width * screen.backingScaleFactor).rounded()))
            let pixelH = max(1, Int((screen.frame.height * screen.backingScaleFactor).rounded()))

            let filter = SCContentFilter(display: scDisplay, excludingWindows: excludedSCWindows)
            let cfg = SCStreamConfiguration()
            cfg.width = pixelW
            cfg.height = pixelH
            cfg.showsCursor = false
            cfg.capturesAudio = false

            let cgImg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            guard let rawBuf = PixelBufferRGBA(cgImage: cgImg) else { continue }

            // Convert AppKit screen frame (bottom-left origin) to CG global top-down coordinates
            let topDownY = primaryHeight - screen.frame.maxY
            let screenTopDown = ASRect(
                x: Double(screen.frame.minX),
                y: Double(topDownY),
                width: Double(screen.frame.width),
                height: Double(screen.frame.height)
            )

            let fullArea = max(1.0, screenTopDown.width * screenTopDown.height)
            let localWinRects: [ASRect] = globalWinRects.compactMap { wr in
                let ix0 = max(screenTopDown.minX, wr.minX)
                let iy0 = max(screenTopDown.minY, wr.minY)
                let ix1 = min(screenTopDown.maxX, wr.maxX)
                let iy1 = min(screenTopDown.maxY, wr.maxY)
                let w = ix1 - ix0
                let h = iy1 - iy0
                guard w >= 16 && h >= 16 else { return nil }
                // Exclude maximized / fullscreen windows so pressing the capture hotkey
                // does not feel like the entire screen is automatically selected.
                if w >= screenTopDown.width * 0.92 && h >= screenTopDown.height * 0.82 && (w * h) / fullArea >= 0.78 {
                    return nil
                }
                return ASRect(
                    x: ix0 - screenTopDown.minX,
                    y: iy0 - screenTopDown.minY,
                    width: w,
                    height: h
                )
            }

            results.append(CapturedScreenSnapshot(
                screen: screen,
                frameInGlobalAppKit: screen.frame,
                frameTopDown: screenTopDown,
                cgImage: cgImg,
                rawBuffer: rawBuf,
                backingScale: scale,
                windowRectsLocalTopDown: localWinRects
            ))
        }
        return results
    }

    /// Captures a specific sub-region of a single display for live Longshot scrolling, excluding AirSnip's own windows.
    public static func captureDisplayRegion(
        screen: NSScreen,
        localTopDownRect: ASRect,
        excludingWindowNumbers: Set<Int>
    ) async -> PixelBufferRGBA? {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        do {
            let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scDisplay = shareable.displays.first(where: { $0.displayID == screenNumber }) else {
                return nil
            }
            let excluded = shareable.windows.filter { excludingWindowNumbers.contains(Int($0.windowID)) }
            let filter = SCContentFilter(display: scDisplay, excludingWindows: excluded)
            let scale = Double(screen.backingScaleFactor)
            let cfg = SCStreamConfiguration()
            cfg.sourceRect = localTopDownRect.cgRect
            cfg.width = max(1, Int((localTopDownRect.width * scale).rounded()))
            cfg.height = max(1, Int((localTopDownRect.height * scale).rounded()))
            cfg.showsCursor = false
            cfg.capturesAudio = false

            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            return PixelBufferRGBA(cgImage: img)
        } catch {
            return nil
        }
    }
}

@MainActor
public enum OutputService {
    public struct SaveOutcome: Sendable {
        public let url: URL
        public let initialResult: PngCompressionResult?
    }

    private static func writePngDataToPasteboard(_ pngData: Data) -> Int {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        // Write PNG data ONLY (omitting uncompressed TIFF avoids 10-20 MB clipboard bloat!)
        item.setData(pngData, forType: .png)
        pb.writeObjects([item])
        return pb.changeCount
    }

    public static func copyImageToClipboard(
        _ cgImage: CGImage,
        backingScale: Double = 2.0,
        config: AirSnipConfig? = nil,
        onCompressed: (@MainActor @Sendable (PngCompressionResult) -> Void)? = nil
    ) {
        let pointSize = NSSize(
            width: CGFloat(Double(cgImage.width) / max(1.0, backingScale)),
            height: CGFloat(Double(cgImage.height) / max(1.0, backingScale))
        )
        let nsImage = NSImage(cgImage: cgImage, size: pointSize)

        guard let rawPngData = try? ImageEncoder.encode(cgImage, format: .png) else {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([nsImage])
            return
        }

        let initialChangeCount = writePngDataToPasteboard(rawPngData)
        let shouldCompress = (config?.smartPngCompression ?? true) && (config?.compressClipboardPng ?? true)
        let qualityPreset = config?.pngCompressionQuality ?? .visuallyLossless

        guard shouldCompress else {
            let passthrough = PngCompressionResult(
                data: rawPngData,
                originalBytes: rawPngData.count,
                compressedBytes: rawPngData.count,
                usedPngquant: false,
                usedOxipng: false
            )
            onCompressed?(passthrough)
            return
        }

        Task.detached(priority: .userInitiated) {
            // Stage 1 (~200ms): fast perceptual quantization (`pngquant --speed 1`)
            let stage1 = PngSmartCompressor.compress(
                rawPngData,
                quality: qualityPreset,
                mode: .fastQuantizeOnly
            )
            let afterStage1Count: Int? = await MainActor.run {
                let pb = NSPasteboard.general
                guard pb.changeCount == initialChangeCount else { return nil }
                var nextCount = initialChangeCount
                if stage1.compressedBytes < rawPngData.count {
                    nextCount = writePngDataToPasteboard(stage1.data)
                }
                onCompressed?(stage1)
                return nextCount
            }
            guard let expectedCount = afterStage1Count else { return }

            // Stage 2: lossless `oxipng -o max` bit-stream squeeze in background
            let stage2 = PngSmartCompressor.optimizeWithOxipng(
                stage1.data,
                originalBytes: rawPngData.count,
                usedPngquant: stage1.usedPngquant,
                oxipngMax: true
            )
            guard stage2.compressedBytes < stage1.compressedBytes else { return }
            await MainActor.run {
                let pb = NSPasteboard.general
                guard pb.changeCount == expectedCount else { return }
                _ = writePngDataToPasteboard(stage2.data)
            }
        }
    }

    public static func copyStringToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    public static func readImageFromClipboard() -> (cgImage: CGImage, pointSize: NSSize)? {
        let pb = NSPasteboard.general
        guard let nsImage = NSImage(pasteboard: pb) else { return nil }
        var rect = NSRect(origin: .zero, size: nsImage.size)
        guard let cg = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              cg.width > 0 && cg.height > 0 else {
            return nil
        }
        let ptSize = nsImage.size.width > 1 && nsImage.size.height > 1
            ? nsImage.size
            : NSSize(width: CGFloat(cg.width) / 2.0, height: CGFloat(cg.height) / 2.0)
        return (cg, ptSize)
    }

    public static func readImageFromFileDialog() -> CGImage? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "选择图片"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]

        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
           cg.width > 0 && cg.height > 0 {
            return cg
        }
        if let nsImg = NSImage(contentsOf: url) {
            var rect = NSRect(origin: .zero, size: nsImg.size)
            if let cg = nsImg.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                return cg
            }
        }
        ToastHUD.show("无法读取图片", symbol: "exclamationmark.triangle.fill", tint: .systemOrange)
        return nil
    }

    public static func presentSaveDialog(
        for cgImage: CGImage,
        config: inout AirSnipConfig,
        parentWindow: NSWindow? = nil,
        onFinalCompressed: (@MainActor @Sendable (URL, PngCompressionResult) -> Void)? = nil
    ) -> URL? {
        let _ = parentWindow
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "保存截图"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        var chosenFormat = config.lastSaveFormat
        var chosenSmartCompress = config.smartPngCompression
        var chosenQuality = config.pngCompressionQuality

        let baseName = config.nameStyle.formatBaseName()
        panel.nameFieldStringValue = "\(baseName).\(chosenFormat.fileExtension)"

        if let lastDir = config.lastSaveDirectory {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: lastDir, isDirectory: &isDir), isDir.boolValue {
                panel.directoryURL = URL(fileURLWithPath: lastDir, isDirectory: true)
            }
        }
        if panel.directoryURL == nil {
            panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        }

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 344, height: 70))

        let fmtLabel = NSTextField(labelWithString: "格式：")
        fmtLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        fmtLabel.alignment = .right
        fmtLabel.frame = NSRect(x: 12, y: 40, width: 68, height: 20)

        let fmtPopup = NSPopUpButton(frame: NSRect(x: 84, y: 36, width: 124, height: 28), pullsDown: false)
        for fmt in ExportImageFormat.allCases {
            fmtPopup.addItem(withTitle: fmt.displayName)
        }
        if let idx = ExportImageFormat.allCases.firstIndex(of: chosenFormat) {
            fmtPopup.selectItem(at: idx)
        }

        let compLabel = NSTextField(labelWithString: "无损压缩：")
        compLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        compLabel.alignment = .right
        compLabel.frame = NSRect(x: 12, y: 10, width: 68, height: 20)

        let compSwitch = NSSwitch(frame: NSRect(x: 86, y: 8, width: 42, height: 24))
        compSwitch.state = chosenSmartCompress ? .on : .off

        let qualityPopup = NSPopUpButton(frame: NSRect(x: 138, y: 6, width: 148, height: 28), pullsDown: false)
        for q in PngCompressionQualityPreset.allCases {
            qualityPopup.addItem(withTitle: q.shortTitle)
        }
        if let qIdx = PngCompressionQualityPreset.allCases.firstIndex(of: chosenQuality) {
            qualityPopup.selectItem(at: qIdx)
        }

        func syncAccessoryStates() {
            let isPng = (chosenFormat == .png)
            compSwitch.isEnabled = isPng
            compLabel.alphaValue = isPng ? 1.0 : 0.45
            qualityPopup.isEnabled = isPng && chosenSmartCompress
        }
        syncAccessoryStates()

        @MainActor
        final class SaveAccessoryTarget: NSObject {
            let panel: NSSavePanel
            let compSwitch: NSSwitch
            let qualityPopup: NSPopUpButton
            var onFormatChange: (ExportImageFormat) -> Void
            var onCompressToggle: (Bool) -> Void
            var onQualityChange: (PngCompressionQualityPreset) -> Void

            init(
                panel: NSSavePanel,
                compSwitch: NSSwitch,
                qualityPopup: NSPopUpButton,
                onFormatChange: @escaping (ExportImageFormat) -> Void,
                onCompressToggle: @escaping (Bool) -> Void,
                onQualityChange: @escaping (PngCompressionQualityPreset) -> Void
            ) {
                self.panel = panel
                self.compSwitch = compSwitch
                self.qualityPopup = qualityPopup
                self.onFormatChange = onFormatChange
                self.onCompressToggle = onCompressToggle
                self.onQualityChange = onQualityChange
            }

            @objc func formatChanged(_ sender: NSPopUpButton) {
                let idx = max(0, min(ExportImageFormat.allCases.count - 1, sender.indexOfSelectedItem))
                let fmt = ExportImageFormat.allCases[idx]
                onFormatChange(fmt)
                let current = (panel.nameFieldStringValue as NSString).deletingPathExtension
                let stem = current.isEmpty ? "isnip" : current
                panel.nameFieldStringValue = "\(stem).\(fmt.fileExtension)"
            }

            @objc func compressToggled(_ sender: NSSwitch) {
                onCompressToggle(sender.state == .on)
            }

            @objc func qualityChanged(_ sender: NSPopUpButton) {
                let idx = max(0, min(PngCompressionQualityPreset.allCases.count - 1, sender.indexOfSelectedItem))
                onQualityChange(PngCompressionQualityPreset.allCases[idx])
            }
        }

        let helper = SaveAccessoryTarget(
            panel: panel,
            compSwitch: compSwitch,
            qualityPopup: qualityPopup,
            onFormatChange: { newFmt in
                chosenFormat = newFmt
                syncAccessoryStates()
            },
            onCompressToggle: { enabled in
                chosenSmartCompress = enabled
                syncAccessoryStates()
            },
            onQualityChange: { newQ in
                chosenQuality = newQ
            }
        )
        fmtPopup.target = helper
        fmtPopup.action = #selector(SaveAccessoryTarget.formatChanged(_:))
        compSwitch.target = helper
        compSwitch.action = #selector(SaveAccessoryTarget.compressToggled(_:))
        qualityPopup.target = helper
        qualityPopup.action = #selector(SaveAccessoryTarget.qualityChanged(_:))

        accessory.addSubview(fmtLabel)
        accessory.addSubview(fmtPopup)
        accessory.addSubview(compLabel)
        accessory.addSubview(compSwitch)
        accessory.addSubview(qualityPopup)
        panel.accessoryView = accessory

        let response = panel.runModal()
        _ = helper // keep alive during modal loop
        guard response == .OK, var url = panel.url else {
            return nil
        }
        if url.pathExtension.lowercased() != chosenFormat.fileExtension {
            url = url.deletingPathExtension().appendingPathExtension(chosenFormat.fileExtension)
        }

        do {
            if chosenFormat == .png && chosenSmartCompress {
                // Phase 1 (~200ms): immediate perceptual quantization write so file is ready & compact right away
                let stage1 = try ImageEncoder.encodePNGWithReport(
                    cgImage,
                    smartCompression: true,
                    quality: chosenQuality,
                    mode: .fastQuantizeOnly
                )
                try stage1.data.write(to: url, options: .atomic)
                let savedURL = url

                // Phase 2: atomic background `oxipng -o max` completion (`pngquant --speed 1 | oxipng -o max`)
                Task.detached(priority: .userInitiated) {
                    let finalRes = PngSmartCompressor.optimizeWithOxipng(
                        stage1.data,
                        originalBytes: stage1.originalBytes,
                        usedPngquant: stage1.usedPngquant,
                        oxipngMax: true
                    )
                    if finalRes.compressedBytes < stage1.compressedBytes {
                        try? finalRes.data.write(to: savedURL, options: .atomic)
                    }
                    await MainActor.run {
                        onFinalCompressed?(savedURL, finalRes)
                    }
                }
            } else {
                let encoded = try ImageEncoder.encode(cgImage, format: chosenFormat)
                try encoded.write(to: url, options: .atomic)
            }

            config.lastSaveFormat = chosenFormat
            config.smartPngCompression = chosenSmartCompress
            config.pngCompressionQuality = chosenQuality
            config.lastSaveDirectory = url.deletingLastPathComponent().path
            try? config.save()
            return url
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "保存失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return nil
        }
    }
}

@MainActor
public final class GlobalHotkeyManager {
    public enum Action: UInt32 {
        case screenshot = 1
        case pin = 2
        case pinBorderToggle = 3
        case ocrCapture = 4
    }

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var mouseMonitor: Any?
    private var boundMouseActions: [MouseExtraButton: Action] = [:]
    public var onTrigger: ((Action) -> Void)?

    nonisolated(unsafe) private static weak var sharedInstance: GlobalHotkeyManager?

    public init() {
        Self.sharedInstance = self
        installCarbonHandler()
    }

    private func installCarbonHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hkID
            )
            if status == noErr, let action = Action(rawValue: hkID.id) {
                Task { @MainActor in
                    GlobalHotkeyManager.sharedInstance?.onTrigger?(action)
                }
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, nil, &eventHandlerRef)
    }

    @discardableResult
    public func apply(hotkeys: HotkeyConfig) -> [String] {
        unregisterAll()
        var failures: [String] = []

        let items: [(Action, String, HotkeyBinding)] = [
            (.screenshot, "截图", hotkeys.screenshot),
            (.ocrCapture, "截图识字", hotkeys.ocrCapture),
            (.pin, "贴图", hotkeys.pin),
            (.pinBorderToggle, "贴图边框", hotkeys.pinBorderToggle),
        ]

        let signature = OSType(0x4153_4E50) // 'ASNP'
        for (action, title, binding) in items {
            if binding.isUnbound { continue }
            if let mb = binding.mouseButton {
                boundMouseActions[mb] = action
                continue
            }
            guard let kc = binding.keyCode else { continue }
            let hkID = EventHotKeyID(signature: signature, id: action.rawValue)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(kc),
                binding.modifiers.carbonFlags,
                hkID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                hotKeyRefs.append(ref)
            } else {
                failures.append("\(title)（\(binding.displayString)）已被占用")
            }
        }

        if !boundMouseActions.isEmpty {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown) { [weak self] ev in
                guard let btn = MouseExtraButton(rawValue: ev.buttonNumber) else { return }
                Task { @MainActor in
                    if let act = self?.boundMouseActions[btn] {
                        self?.onTrigger?(act)
                    }
                }
            }
        }
        return failures
    }

    public func unregisterAll() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        boundMouseActions.removeAll()
        if let mon = mouseMonitor {
            NSEvent.removeMonitor(mon)
            mouseMonitor = nil
        }
    }
}

public enum LaunchAtLoginManager {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    public static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return true
        } catch {
            return false
        }
    }
}

public struct UpdateReleaseInfo: Sendable {
    public let version: String
    public let htmlURL: URL
    public let downloadURL: URL?
    public let body: String
}

public enum UpdateChecker {
    public static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
    }

    public static var releaseRepo: String {
        (Bundle.main.infoDictionary?["AirSnipUpdateRepository"] as? String) ?? "zzusec/isnip-releases"
    }

    public static func checkLatest() async -> Result<UpdateReleaseInfo?, Error> {
        guard let apiURL = URL(string: "https://api.github.com/repos/\(releaseRepo)/releases/latest") else {
            return .success(nil)
        }
        var req = URLRequest(url: apiURL)
        req.timeoutInterval = 8
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 404 {
                return .success(nil)
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let htmlStr = json["html_url"] as? String,
                  let htmlURL = URL(string: htmlStr) else {
                return .success(nil)
            }
            let remoteVer = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard isVersionNewer(remoteVer, than: currentVersion) else {
                return .success(nil)
            }
            let notes = (json["body"] as? String) ?? ""
            var dmgURL: URL?
            if let assets = json["assets"] as? [[String: Any]] {
                for asset in assets {
                    if let name = asset["name"] as? String,
                       name.hasSuffix(".dmg"),
                       let dl = asset["browser_download_url"] as? String {
                        dmgURL = URL(string: dl)
                        break
                    }
                }
            }
            return .success(UpdateReleaseInfo(version: remoteVer, htmlURL: htmlURL, downloadURL: dmgURL, body: notes))
        } catch {
            return .failure(error)
        }
    }

    public static func isVersionNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").compactMap { Int($0) }
        let b = current.split(separator: ".").compactMap { Int($0) }
        let n = max(a.count, b.count)
        for i in 0..<n {
            let va = i < a.count ? a[i] : 0
            let vb = i < b.count ? b[i] : 0
            if va != vb { return va > vb }
        }
        return false
    }
}

@MainActor
public enum ToastHUD {
    private static var activeWindow: NSPanel?
    private static var dismissTask: Task<Void, Never>?

    public static func show(
        _ message: String,
        symbol: String = "checkmark.circle.fill",
        tint: NSColor = NSColor(srgbRed: 0.19, green: 0.82, blue: 0.48, alpha: 1.0),
        duration: Double = 1.45
    ) {
        dismissTask?.cancel()
        activeWindow?.orderOut(nil)

        let font = NSFont.monospacedDigitSystemFont(ofSize: 13.0, weight: .medium)
        let textWidth = ceil((message as NSString).size(withAttributes: [.font: font]).width)
        let w = max(168, textWidth + 56)
        let h: CGFloat = 36

        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let targetY = screenFrame.maxY - 58
        let startFrame = NSRect(
            x: screenFrame.midX - w * 0.5,
            y: targetY + 6,
            width: w,
            height: h
        )
        let finalFrame = NSRect(
            x: screenFrame.midX - w * 0.5,
            y: targetY,
            width: w,
            height: h
        )

        let panel = NSPanel(
            contentRect: startFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let visual = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        visual.appearance = NSAppearance(named: .vibrantDark)
        visual.material = .hudWindow
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.wantsLayer = true
        visual.layer?.cornerRadius = h * 0.5
        visual.layer?.cornerCurve = .continuous
        visual.layer?.masksToBounds = true
        visual.layer?.borderWidth = 0.8
        visual.layer?.borderColor = NSColor(calibratedWhite: 1.0, alpha: 0.16).cgColor

        let symCfg = NSImage.SymbolConfiguration(pointSize: 14.5, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        if let symImg = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(symCfg) {
            let iconView = NSImageView(image: symImg)
            iconView.frame = NSRect(x: 14, y: (h - 18) * 0.5, width: 18, height: 18)
            visual.addSubview(iconView)
        }

        let label = NSTextField(labelWithString: message)
        label.font = font
        label.textColor = NSColor(calibratedWhite: 0.98, alpha: 0.96)
        label.alignment = .left
        label.frame = NSRect(x: 37, y: (h - 19) * 0.5, width: w - 51, height: 19)
        visual.addSubview(label)

        panel.contentView = visual
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
            panel.animator().setFrame(finalFrame, display: true)
        }
        activeWindow = panel

        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor in
                    panel.orderOut(nil)
                }
            })
        }
    }
}
