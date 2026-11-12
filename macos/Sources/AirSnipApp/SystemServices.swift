import AppKit
import Carbon
import CoreGraphics
import ImageIO
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

    public static func showPermissionGuidanceAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "需要开启「屏幕录制」权限"
        alert.informativeText = "AirSnip 需要屏幕录制权限才能冻结画面并进行框选截图、长截图与离线 OCR。\n\n所有图像仅在本机内存中处理，绝不联网上传。授权后请重新触发截图。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Queries on-screen application windows via CoreGraphics (top-down global coordinates).
    public static func queryOnScreenWindowsGlobalTopDown(excludingPID: pid_t = ProcessInfo.processInfo.processIdentifier) -> [ASRect] {
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var rects: [ASRect] = []
        for entry in infoList {
            if let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t, ownerPID == excludingPID {
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

            let localWinRects: [ASRect] = globalWinRects.compactMap { wr in
                let ix0 = max(screenTopDown.minX, wr.minX)
                let iy0 = max(screenTopDown.minY, wr.minY)
                let ix1 = min(screenTopDown.maxX, wr.maxX)
                let iy1 = min(screenTopDown.maxY, wr.maxY)
                guard ix1 - ix0 >= 16 && iy1 - iy0 >= 16 else { return nil }
                return ASRect(
                    x: ix0 - screenTopDown.minX,
                    y: iy0 - screenTopDown.minY,
                    width: ix1 - ix0,
                    height: iy1 - iy0
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
    public static func copyImageToClipboard(_ cgImage: CGImage, backingScale: Double = 2.0) {
        let pb = NSPasteboard.general
        pb.clearContents()

        let pointSize = NSSize(
            width: CGFloat(Double(cgImage.width) / max(1.0, backingScale)),
            height: CGFloat(Double(cgImage.height) / max(1.0, backingScale))
        )
        let nsImage = NSImage(cgImage: cgImage, size: pointSize)

        if let pngData = try? ImageEncoder.encode(cgImage, format: .png) {
            let item = NSPasteboardItem()
            item.setData(pngData, forType: .png)
            if let tiffData = nsImage.tiffRepresentation {
                item.setData(tiffData, forType: .tiff)
            }
            pb.writeObjects([item])
        } else {
            pb.writeObjects([nsImage])
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
        panel.title = "选择要识别文字的图片"
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
        ToastHUD.show("无法读取该图片文件")
        return nil
    }

    public static func presentSaveDialog(
        for cgImage: CGImage,
        config: inout AirSnipConfig,
        parentWindow: NSWindow? = nil
    ) -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.title = "保存截图"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        var chosenFormat = config.lastSaveFormat
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

        // Format accessory bar (PNG / JPEG / Lossless WebP)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 38))
        let label = NSTextField(labelWithString: "图像格式：")
        label.frame = NSRect(x: 12, y: 9, width: 72, height: 20)
        let popup = NSPopUpButton(frame: NSRect(x: 84, y: 5, width: 216, height: 28), pullsDown: false)
        for fmt in ExportImageFormat.allCases {
            popup.addItem(withTitle: fmt.displayName)
        }
        if let idx = ExportImageFormat.allCases.firstIndex(of: chosenFormat) {
            popup.selectItem(at: idx)
        }

        @MainActor
        final class FormatChangedTarget: NSObject {
            let panel: NSSavePanel
            var onFormatChange: (ExportImageFormat) -> Void
            init(panel: NSSavePanel, onFormatChange: @escaping (ExportImageFormat) -> Void) {
                self.panel = panel
                self.onFormatChange = onFormatChange
            }
            @objc func changed(_ sender: NSPopUpButton) {
                let idx = max(0, min(ExportImageFormat.allCases.count - 1, sender.indexOfSelectedItem))
                let fmt = ExportImageFormat.allCases[idx]
                onFormatChange(fmt)
                let current = (panel.nameFieldStringValue as NSString).deletingPathExtension
                let stem = current.isEmpty ? "airsnip" : current
                panel.nameFieldStringValue = "\(stem).\(fmt.fileExtension)"
            }
        }

        let helper = FormatChangedTarget(panel: panel) { newFmt in
            chosenFormat = newFmt
        }
        popup.target = helper
        popup.action = #selector(FormatChangedTarget.changed(_:))
        accessory.addSubview(label)
        accessory.addSubview(popup)
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
            let encoded = try ImageEncoder.encode(cgImage, format: chosenFormat)
            try encoded.write(to: url, options: .atomic)
            config.lastSaveFormat = chosenFormat
            config.lastSaveDirectory = url.deletingLastPathComponent().path
            try? config.save()
            return url
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "保存图片失败"
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
            (.ocrCapture, "截图 OCR 识别", hotkeys.ocrCapture),
            (.pin, "贴图", hotkeys.pin),
            (.pinBorderToggle, "贴图边框开关", hotkeys.pinBorderToggle),
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
                failures.append("\(title)（\(binding.displayString)）已被系统或其他应用占用")
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
        (Bundle.main.infoDictionary?["AirSnipUpdateRepository"] as? String) ?? "zzusec/airsnip-releases"
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

    public static func show(_ message: String, duration: Double = 1.15) {
        dismissTask?.cancel()
        activeWindow?.orderOut(nil)

        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let textWidth = ceil((message as NSString).size(withAttributes: [.font: font]).width)
        let w = max(140, textWidth + 36)
        let h: CGFloat = 34

        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let frame = NSRect(
            x: screenFrame.midX - w * 0.5,
            y: screenFrame.maxY - 56,
            width: w,
            height: h
        )

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let visual = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        visual.material = .hudWindow
        visual.state = .active
        visual.wantsLayer = true
        visual.layer?.cornerRadius = h * 0.5
        visual.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: message)
        label.font = font
        label.textColor = .labelColor
        label.alignment = .center
        label.frame = NSRect(x: 12, y: (h - 19) * 0.5, width: w - 24, height: 19)
        visual.addSubview(label)

        panel.contentView = visual
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1.0
        }
        activeWindow = panel

        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor in
                    panel.orderOut(nil)
                }
            })
        }
    }
}
