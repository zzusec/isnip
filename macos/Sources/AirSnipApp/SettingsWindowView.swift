import AppKit
import Carbon
import SwiftUI
import AirSnipCore

@MainActor
public final class SettingsWindowController {
    private var window: NSWindow?
    private let appController: AirSnipAppController

    public init(appController: AirSnipAppController) {
        self.appController = appController
    }

    public func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let win = window {
            applyTheme(appController.config.theme, to: win)
            win.orderFrontRegardless()
            win.makeKeyAndOrderFront(nil)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "AirSnip 设置"
        win.center()
        win.isReleasedWhenClosed = false
        applyTheme(appController.config.theme, to: win)
        win.contentView = NSHostingView(rootView: SettingsRootView(app: appController))
        self.window = win
        win.orderFrontRegardless()
        win.makeKeyAndOrderFront(nil)
    }

    public func hide() {
        window?.orderOut(nil)
    }

    public func refreshTheme() {
        if let win = window {
            applyTheme(appController.config.theme, to: win)
        }
    }

    private func applyTheme(_ theme: ThemeSetting, to win: NSWindow) {
        switch theme {
        case .follow: win.appearance = nil
        case .light: win.appearance = NSAppearance(named: .aqua)
        case .dark: win.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case toolbar
    case hotkeys
    case captureAndPin
    case editor
    case ocr
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .toolbar: return "工具栏"
        case .hotkeys: return "快捷键"
        case .captureAndPin: return "截图与贴图"
        case .editor: return "编辑默认"
        case .ocr: return "OCR 识别"
        case .about: return "关于"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .toolbar: return "slider.horizontal.below.rectangle"
        case .hotkeys: return "command"
        case .captureAndPin: return "crop"
        case .editor: return "paintbrush.pointed"
        case .ocr: return "text.viewfinder"
        case .about: return "info.circle"
        }
    }
}

private struct SettingsRootView: View {
    @ObservedObject var app: AirSnipAppController
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        HStack(spacing: 0) {
            // Left navigation sidebar
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("AirSnip")
                            .font(.system(size: 14, weight: .bold))
                        Text("轻截 · macOS")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)

                ForEach(SettingsTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 18)
                            Text(tab.title)
                                .font(.system(size: 13, weight: selectedTab == tab ? .semibold : .regular))
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(selectedTab == tab ? Color.accentColor.opacity(0.16) : Color.clear)
                        )
                        .foregroundStyle(selectedTab == tab ? Color.accentColor : Color.primary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding(14)
            .frame(width: 176)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))

            Divider()

            // Right detail pane
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch selectedTab {
                    case .general:
                        GeneralSettingsPane(app: app)
                    case .toolbar:
                        ToolbarVisibilityPane(app: app)
                    case .hotkeys:
                        HotkeysSettingsPane(app: app)
                    case .captureAndPin:
                        CaptureAndPinPane(app: app)
                    case .editor:
                        EditorDefaultsPane(app: app)
                    case .ocr:
                        OCRSettingsPane(app: app)
                    case .about:
                        AboutSettingsPane(app: app)
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 720, height: 500)
    }
}

private struct GeneralSettingsPane: View {
    @ObservedObject var app: AirSnipAppController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("通用设置")
                .font(.system(size: 17, weight: .bold))

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("登录 macOS 时自动启动 AirSnip", isOn: Binding(
                        get: { app.config.autoStart },
                        set: { val in
                            _ = LaunchAtLoginManager.setEnabled(val)
                            app.updateConfig { $0.autoStart = val }
                        }
                    ))

                    Divider()

                    HStack {
                        Text("界面主题")
                        Spacer()
                        Picker("", selection: Binding(
                            get: { app.config.theme },
                            set: { t in
                                app.updateConfig { $0.theme = t }
                                app.settingsController?.refreshTheme()
                            }
                        )) {
                            ForEach(ThemeSetting.allCases, id: \.self) { t in
                                Text(t.title).tag(t)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 240)
                    }

                    Divider()

                    HStack {
                        Text("覆盖层工具栏缩放")
                        Spacer()
                        Picker("", selection: Binding(
                            get: { app.config.uiScale },
                            set: { s in app.updateConfig { $0.uiScale = s } }
                        )) {
                            ForEach(UiScaleSetting.allCases, id: \.self) { s in
                                Text(s.title).tag(s)
                            }
                        }
                        .frame(width: 160)
                    }

                    Divider()

                    Toggle("已有未保存标注时，连按两次 Esc 才退出截图（防误触）", isOn: Binding(
                        get: { app.config.confirmCancel },
                        set: { v in app.updateConfig { $0.confirmCancel = v } }
                    ))

                    Toggle("复制或保存截图后显示顶部轻提示气泡", isOn: Binding(
                        get: { app.config.showCompletionToast },
                        set: { v in app.updateConfig { $0.showCompletionToast = v } }
                    ))
                }
                .padding(6)
            }

            GroupBox {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("屏幕录制权限状态")
                            .font(.system(size: 13, weight: .medium))
                        Text(ScreenCaptureService.hasScreenCapturePermission() ? "已授权，可正常抓屏与离线识别" : "尚未授权，首次触发截图时系统会提示授权")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !ScreenCaptureService.hasScreenCapturePermission() {
                        Button("请求授权") {
                            _ = ScreenCaptureService.requestScreenCapturePermissionIfNeeded()
                        }
                    } else {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                }
                .padding(6)
            }
        }
    }
}

private struct ToolbarVisibilityPane: View {
    @ObservedObject var app: AirSnipAppController
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("工具栏定制（24 项）")
                        .font(.system(size: 17, weight: .bold))
                    Text("把截图工具栏收成自己常用的那一小块。隐藏仅影响按钮绘制，快捷键与功能照常可用。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("全部显示") {
                    app.updateConfig { $0.toolbar.hidden.removeAll() }
                }
                .controlSize(.small)
            }

            ForEach(ToolbarGroup.allCases, id: \.rawValue) { group in
                let state = app.config.toolbar.groupState(group)
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button {
                                let turnOn = (state == .none)
                                app.updateConfig { $0.toolbar.setGroupVisible(group, turnOn) }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: state == .all ? "checkmark.square.fill" : (state == .partial ? "minus.square.fill" : "square"))
                                        .foregroundStyle(state == .none ? Color.secondary : Color.accentColor)
                                    Text(group.title)
                                        .font(.system(size: 13, weight: .semibold))
                                }
                            }
                            .buttonStyle(.plain)

                            Spacer()
                            Text("\(app.config.toolbar.visibleCount(in: group)) / \(group.slots.count) 可见")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                            ForEach(group.slots, id: \.key) { slot in
                                Toggle(slot.label, isOn: Binding(
                                    get: { app.config.toolbar.isVisible(slot) },
                                    set: { on in app.updateConfig { $0.toolbar.setVisible(slot, on) } }
                                ))
                                .toggleStyle(.checkbox)
                                .font(.system(size: 12))
                            }
                        }
                    }
                    .padding(6)
                }
            }
        }
    }
}

private struct HotkeysSettingsPane: View {
    @ObservedObject var app: AirSnipAppController
    @State private var recordingSlot: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("快捷键")
                        .font(.system(size: 17, weight: .bold))
                    Text("点击键帽后按下新快捷键（或鼠标中键 / 侧键）即可改键；点 ✕ 清空为「未设置」。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("恢复默认") {
                    app.updateConfig {
                        $0.hotkeys = HotkeyConfig()
                        $0.toolKeys = ToolKeysConfig()
                    }
                }
                .controlSize(.small)
            }

            let conflicts = app.config.hotkeyConflicts() + app.hotkeyRegistrationErrors
            if !conflicts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(conflicts, id: \.self) { msg in
                        Label(msg, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.orange)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.12)))
            }

            if app.config.hotkeys.screenshot.hasNoModifierWarning
                || app.config.hotkeys.ocrCapture.hasNoModifierWarning
                || app.config.hotkeys.pin.hasNoModifierWarning {
                Label("提示：全局热键使用单键（如 F1 / F2 / F3）会拦截其他软件的同名按键；如需避免冲突可改为 ⌃A / ⌥S 等修饰键组合。", systemImage: "info.circle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            GroupBox("全局热键") {
                VStack(spacing: 8) {
                    HotkeyRow(title: "触发截图", slotID: "global.screenshot", binding: app.config.hotkeys.screenshot, recordingSlot: $recordingSlot) { b in
                        app.updateConfig { $0.hotkeys.screenshot = b }
                    }
                    Divider()
                    HotkeyRow(title: "直接截图 OCR 识别（松手即提取文字）", slotID: "global.ocrCapture", binding: app.config.hotkeys.ocrCapture, recordingSlot: $recordingSlot) { b in
                        app.updateConfig { $0.hotkeys.ocrCapture = b }
                    }
                    Divider()
                    HotkeyRow(title: "贴图（选区或剪贴板）", slotID: "global.pin", binding: app.config.hotkeys.pin, recordingSlot: $recordingSlot) { b in
                        app.updateConfig { $0.hotkeys.pin = b }
                    }
                    Divider()
                    HotkeyRow(title: "切换贴图边框", slotID: "global.pinBorder", binding: app.config.hotkeys.pinBorderToggle, recordingSlot: $recordingSlot) { b in
                        app.updateConfig { $0.hotkeys.pinBorderToggle = b }
                    }
                }
                .padding(6)
            }

            GroupBox("截图覆盖层内快捷键") {
                VStack(spacing: 8) {
                    HotkeyRow(title: "再次截图（截取软件自身界面）", slotID: "ov.recapture", binding: app.config.hotkeys.recapture, recordingSlot: $recordingSlot) { b in
                        app.updateConfig { $0.hotkeys.recapture = b }
                    }
                    Divider()
                    HotkeyRow(title: "进入长截图模式", slotID: "ov.longshot", binding: app.config.hotkeys.longshot, recordingSlot: $recordingSlot) { b in
                        app.updateConfig { $0.hotkeys.longshot = b }
                    }
                    Divider()
                    HotkeyRow(title: "OCR 文字识别", slotID: "ov.ocr", binding: app.config.hotkeys.ocr, recordingSlot: $recordingSlot) { b in
                        app.updateConfig { $0.hotkeys.ocr = b }
                    }
                    ForEach(AnnotationTool.allOrdered, id: \.rawValue) { tool in
                        Divider()
                        HotkeyRow(
                            title: "切换工具 · \(tool.displayName)",
                            slotID: "tool.\(tool.rawValue)",
                            binding: app.config.toolKeys.binding(for: tool),
                            recordingSlot: $recordingSlot
                        ) { b in
                            app.updateConfig { $0.toolKeys.setBinding(b, for: tool) }
                        }
                    }
                }
                .padding(6)
            }
        }
    }
}

private struct HotkeyRow: View {
    let title: String
    let slotID: String
    let binding: HotkeyBinding
    @Binding var recordingSlot: String?
    let onUpdate: (HotkeyBinding) -> Void

    @State private var eventMonitor: Any?

    private var isRecording: Bool { recordingSlot == slotID }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12.5))
            Spacer()

            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                Text(isRecording ? "请按键（Esc 取消）…" : binding.displayString)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .frame(minWidth: 128)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isRecording ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(isRecording ? Color.accentColor : Color.primary.opacity(0.14), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            if !binding.isUnbound {
                Button {
                    stopRecording()
                    onUpdate(.unbound)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清空为未设置")
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private func startRecording() {
        recordingSlot = slotID
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown]) { ev in
            if ev.type == .otherMouseDown, let mb = MouseExtraButton(rawValue: ev.buttonNumber) {
                onUpdate(HotkeyBinding(keyCode: nil, modifiers: [], mouseButton: mb))
                stopRecording()
                return nil
            }
            if ev.type == .keyDown {
                let kc = Int(ev.keyCode)
                if kc == kVK_Escape {
                    stopRecording()
                    return nil
                }
                let mods = HotkeyModifiers.fromNSEventFlags(ev.modifierFlags.intersection(.deviceIndependentFlagsMask))
                onUpdate(HotkeyBinding(keyCode: kc, modifiers: mods, mouseButton: nil))
                stopRecording()
                return nil
            }
            return ev
        }
    }

    private func stopRecording() {
        if recordingSlot == slotID { recordingSlot = nil }
        if let m = eventMonitor {
            NSEvent.removeMonitor(m)
            eventMonitor = nil
        }
    }
}

private struct CaptureAndPinPane: View {
    @ObservedObject var app: AirSnipAppController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("截图、保存与贴图")
                .font(.system(size: 17, weight: .bold))

            GroupBox("截图与文件输出") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("悬停自动识别并吸附桌面窗口（单击直接选中窗口）", isOn: Binding(
                        get: { app.config.windowSnap },
                        set: { v in app.updateConfig { $0.windowSnap = v } }
                    ))

                    Divider()

                    HStack {
                        Text("保存文件名模板")
                        Spacer()
                        Picker("", selection: Binding(
                            get: { app.config.nameStyle },
                            set: { s in app.updateConfig { $0.nameStyle = s } }
                        )) {
                            ForEach(NameStyle.allCases, id: \.self) { s in
                                Text(s.title).tag(s)
                            }
                        }
                        .frame(width: 280)
                    }

                    HStack {
                        Text("默认保存格式")
                        Spacer()
                        Picker("", selection: Binding(
                            get: { app.config.lastSaveFormat },
                            set: { f in app.updateConfig { $0.lastSaveFormat = f } }
                        )) {
                            ForEach(ExportImageFormat.allCases, id: \.self) { f in
                                Text(f.displayName).tag(f)
                            }
                        }
                        .frame(width: 200)
                    }

                    HStack {
                        Text("长截图拼接高度上限")
                        Spacer()
                        Stepper(
                            "\(app.config.longshotMaxHeight) px",
                            value: Binding(
                                get: { app.config.longshotMaxHeight },
                                set: { h in app.updateConfig { $0.longshotMaxHeight = h } }
                            ),
                            in: 5000...60000,
                            step: 5000
                        )
                    }
                }
                .padding(6)
            }

            GroupBox("贴图（Pin）") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("选区贴图初始位置")
                        Spacer()
                        Picker("", selection: Binding(
                            get: { app.config.pinPosition },
                            set: { p in app.updateConfig { $0.pinPosition = p } }
                        )) {
                            ForEach(PinPosition.allCases, id: \.self) { p in
                                Text(p.title).tag(p)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }

                    Toggle("显示贴图 1px 蓝色边框", isOn: Binding(
                        get: { app.config.pinBorder },
                        set: { b in app.updateConfig { $0.pinBorder = b } }
                    ))

                    HStack {
                        Text("同时贴图数量上限")
                        Spacer()
                        Stepper(
                            "\(app.config.pinMaxCount) 张",
                            value: Binding(
                                get: { app.config.pinMaxCount },
                                set: { n in app.updateConfig { $0.pinMaxCount = n } }
                            ),
                            in: 5...50,
                            step: 5
                        )
                    }
                }
                .padding(6)
            }
        }
    }
}

private struct EditorDefaultsPane: View {
    @ObservedObject var app: AirSnipAppController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("编辑默认样式")
                .font(.system(size: 17, weight: .bold))

            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("默认描边线宽：\(Int(app.config.defaultLineWidth)) px")
                            .frame(width: 170, alignment: .leading)
                        Slider(
                            value: Binding(
                                get: { app.config.defaultLineWidth },
                                set: { v in app.updateConfig { $0.defaultLineWidth = v.rounded() } }
                            ),
                            in: 1...20,
                            step: 1
                        )
                    }

                    HStack {
                        Text("默认模糊强度：\(Int(app.config.defaultBlurRadius))")
                            .frame(width: 170, alignment: .leading)
                        Slider(
                            value: Binding(
                                get: { app.config.defaultBlurRadius },
                                set: { v in app.updateConfig { $0.defaultBlurRadius = v.rounded() } }
                            ),
                            in: 4...48,
                            step: 2
                        )
                    }

                    HStack {
                        Text("默认文本字号：\(Int(app.config.defaultFontSize)) px")
                            .frame(width: 170, alignment: .leading)
                        Slider(
                            value: Binding(
                                get: { app.config.defaultFontSize },
                                set: { v in app.updateConfig { $0.defaultFontSize = v.rounded() } }
                            ),
                            in: 12...72,
                            step: 2
                        )
                    }

                    Divider()

                    HStack {
                        Text("工具栏 5 色调色板（截图中双击色块可自由取色）")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("重置预设 5 色") {
                            app.updateConfig { $0.swatchColors = ColorPalette.defaultSwatches }
                        }
                        .controlSize(.small)
                    }
                }
                .padding(6)
            }
        }
    }
}

private struct OCRSettingsPane: View {
    @ObservedObject var app: AirSnipAppController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("本地离线 OCR 识别")
                .font(.system(size: 17, weight: .bold))

            GroupBox("识别行为与排版") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("识别语言偏好")
                        Spacer()
                        Picker("", selection: Binding(
                            get: { app.config.ocr.language },
                            set: { lang in app.updateConfig { $0.ocr.language = lang } }
                        )) {
                            ForEach(OcrConfig.supportedOptions, id: \.tag) { opt in
                                Text(opt.label).tag(opt.tag)
                            }
                        }
                        .frame(width: 230)
                    }

                    Divider()

                    Toggle("识别完成后自动将文字复制到剪贴板", isOn: Binding(
                        get: { app.config.ocr.autoCopy },
                        set: { ac in app.updateConfig { $0.ocr.autoCopy = ac } }
                    ))

                    Toggle("默认合并段落内的软换行（保留空行与列表项）", isOn: Binding(
                        get: { app.config.ocr.mergeLineBreaks },
                        set: { mb in app.updateConfig { $0.ocr.mergeLineBreaks = mb } }
                    ))

                    Toggle("同时识别图片中的二维码与条形码", isOn: Binding(
                        get: { app.config.ocr.detectBarcodes },
                        set: { db in app.updateConfig { $0.ocr.detectBarcodes = db } }
                    ))
                }
                .padding(6)
            }

            GroupBox("快捷触发入口") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            app.settingsController?.hide()
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 180_000_000)
                                app.triggerDirectOCRCapture()
                            }
                        } label: {
                            Label("立即框选识别文字", systemImage: "text.viewfinder")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            app.triggerOCRFromClipboard()
                        } label: {
                            Label("识别剪贴板图片", systemImage: "doc.on.clipboard")
                        }

                        Button {
                            app.triggerOCRFromFile()
                        } label: {
                            Label("选择图片文件…", systemImage: "photo")
                        }
                    }

                    Text("支持 5 种触发方式：① 全局快捷键 \(app.config.hotkeys.ocrCapture.displayString) 框选松手即识别；② 常规截图（\(app.config.hotkeys.screenshot.displayString)）中按 \(app.config.hotkeys.ocr.displayString) 或点工具栏 OCR 图标；③ 贴图窗口按 T 或右键菜单识别；④ 长截图控制栏点击 OCR；⑤ 菜单栏直接识别剪贴板或本地图片。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .padding(6)
            }

            Label("隐私承诺：OCR 采用 macOS 原生 Vision 离线神经网络引擎，仅识别不含标注涂抹的选区原图，图像与文字全程不出本机、无需联网、无需 API Key。", systemImage: "lock.shield")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

private struct AboutSettingsPane: View {
    @ObservedObject var app: AirSnipAppController
    @State private var checkingUpdate = false
    @State private var updateStatusText = ""
    @State private var latestRelease: UpdateReleaseInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: 4) {
                    Text("AirSnip（轻截）for macOS")
                        .font(.system(size: 18, weight: .bold))
                    Text("版本 v\(UpdateChecker.currentVersion) · 原生纯 Swift 极速轻量截图标注工具")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox("核心设计") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("• 待机 0% CPU、无 Electron / WebView 运行时，常驻菜单栏秒级响应")
                    Text("• 10 种专业矢量标注工具（含三次贝塞尔曲线箭头、圆角手柄、聚光灯、盒式高斯模糊、序号徽标）")
                    Text("• 手动滚动长截图（行哈希重叠检验 + 固定页眉页脚自动剥离 + 实时缩略预览）")
                    Text("• 置顶贴图（滚轮缩放、⌘+滚轮透明度、Space 原地补画标注）与原生离线 Vision OCR")
                    Text("• 纯 Swift 无损 WebP (VP8L) / PNG / JPEG 多格式导出")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(6)
            }

            GroupBox("版本更新") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("启动后静默检查一次新版本", isOn: Binding(
                        get: { app.config.autoCheckUpdate },
                        set: { v in app.updateConfig { $0.autoCheckUpdate = v } }
                    ))

                    HStack(spacing: 10) {
                        Button(checkingUpdate ? "正在检查…" : "检查更新") {
                            checkingUpdate = true
                            updateStatusText = ""
                            Task { @MainActor in
                                let res = await UpdateChecker.checkLatest()
                                checkingUpdate = false
                                switch res {
                                case .success(let info?):
                                    latestRelease = info
                                    updateStatusText = "发现新版本 v\(info.version)"
                                case .success(nil):
                                    latestRelease = nil
                                    updateStatusText = "当前已是最新版本（v\(UpdateChecker.currentVersion)）"
                                case .failure(let err):
                                    updateStatusText = "检查失败：\(err.localizedDescription)"
                                }
                            }
                        }
                        .disabled(checkingUpdate)

                        if let rel = latestRelease {
                            Button("前往下载 v\(rel.version)") {
                                NSWorkspace.shared.open(rel.downloadURL ?? rel.htmlURL)
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        if !updateStatusText.isEmpty {
                            Text(updateStatusText)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(6)
            }

            Text("开源许可：GPL-3.0-only · 致敬开源项目 bd-dxg/airsnip")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }
}
