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
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "iSnip 设置"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
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

public enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case captureAndPin
    case toolbar
    case hotkeys
    case editor
    case ocr
    case about

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .captureAndPin: return "截图"
        case .toolbar: return "工具栏"
        case .hotkeys: return "快捷键"
        case .editor: return "标注"
        case .ocr: return "OCR"
        case .about: return "关于"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .captureAndPin: return "viewfinder"
        case .toolbar: return "slider.horizontal.below.rectangle"
        case .hotkeys: return "command"
        case .editor: return "paintbrush.pointed.fill"
        case .ocr: return "text.viewfinder"
        case .about: return "info.circle.fill"
        }
    }

    var badgeGradient: [Color] {
        switch self {
        case .general:
            return [Color(red: 0.42, green: 0.48, blue: 0.58), Color(red: 0.30, green: 0.35, blue: 0.44)]
        case .captureAndPin:
            return [Color(red: 0.08, green: 0.58, blue: 0.98), Color(red: 0.04, green: 0.40, blue: 0.88)]
        case .toolbar:
            return [Color(red: 0.36, green: 0.42, blue: 0.95), Color(red: 0.26, green: 0.30, blue: 0.82)]
        case .hotkeys:
            return [Color(red: 0.98, green: 0.58, blue: 0.14), Color(red: 0.90, green: 0.42, blue: 0.08)]
        case .editor:
            return [Color(red: 0.96, green: 0.34, blue: 0.44), Color(red: 0.84, green: 0.20, blue: 0.34)]
        case .ocr:
            return [Color(red: 0.14, green: 0.76, blue: 0.54), Color(red: 0.08, green: 0.58, blue: 0.42)]
        case .about:
            return [Color(red: 0.22, green: 0.64, blue: 0.98), Color(red: 0.12, green: 0.36, blue: 0.86)]
        }
    }
}

private struct SidebarVisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

public struct SettingsRootView: View {
    @ObservedObject var app: AirSnipAppController
    @State private var selectedTab: SettingsTab

    public init(app: AirSnipAppController, initialTab: SettingsTab = .general) {
        self.app = app
        self._selectedTab = State(initialValue: initialTab)
    }

    public var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Spacer().frame(height: 24)

                HStack(spacing: 9) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 30, height: 30)
                        .shadow(color: .black.opacity(0.15), radius: 2.5, x: 0, y: 1)

                    Text("iSnip")
                        .font(.system(size: 14.5, weight: .bold))

                    Text("v\(UpdateChecker.currentVersion)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
                .padding(.horizontal, 9)
                .padding(.bottom, 12)

                ForEach(SettingsTab.allCases) { tab in
                    let isSelected = (selectedTab == tab)
                    Button {
                        withAnimation(.easeOut(duration: 0.14)) {
                            selectedTab = tab
                        }
                    } label: {
                        HStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: tab.badgeGradient,
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .frame(width: 22, height: 22)
                                    .shadow(color: tab.badgeGradient[1].opacity(0.22), radius: 2, x: 0, y: 1)

                                Image(systemName: tab.icon)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(.white)
                            }

                            Text(tab.title)
                                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.86))

                            Spacer()
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6.5)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isSelected ? Color.primary.opacity(0.10) : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding(13)
            .frame(width: 176)
            .background(SidebarVisualEffectView())

            Rectangle()
                .fill(Color.primary.opacity(0.09))
                .frame(width: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch selectedTab {
                    case .general:
                        GeneralSettingsPane(app: app)
                    case .captureAndPin:
                        CaptureAndPinPane(app: app)
                    case .toolbar:
                        ToolbarVisibilityPane(app: app)
                    case .hotkeys:
                        HotkeysSettingsPane(app: app)
                    case .editor:
                        EditorDefaultsPane(app: app)
                    case .ocr:
                        OCRSettingsPane(app: app)
                    case .about:
                        AboutSettingsPane(app: app)
                    }
                }
                .padding(.horizontal, 26)
                .padding(.top, 26)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 720, height: 520)
    }
}

// MARK: - Shared Components

private struct SettingsPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing()
        }
    }
}

private struct SettingsSectionCard<Content: View>: View {
    let header: String?
    @ViewBuilder var content: () -> Content

    init(_ header: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.header = header
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header {
                Text(header)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
            )
            .shadow(color: .black.opacity(0.03), radius: 4, x: 0, y: 1)
        }
    }
}

private struct SettingsRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.065))
            .frame(height: 1)
            .padding(.leading, 14)
    }
}

private struct SettingsSwitchRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct SettingsControlRow<Control: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9.5)
    }
}

// MARK: - 1. General

private struct GeneralSettingsPane: View {
    @ObservedObject var app: AirSnipAppController
    @State private var hasScreenCapture = ScreenCaptureService.hasScreenCapturePermission()
    @State private var hasAccessibility = AccessibilityService.hasPermission()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsPageHeader("通用")

            SettingsSectionCard("常规") {
                SettingsSwitchRow(
                    title: "开机自动启动",
                    isOn: Binding(
                        get: { app.config.autoStart },
                        set: { val in
                            _ = LaunchAtLoginManager.setEnabled(val)
                            app.updateConfig { $0.autoStart = val }
                        }
                    )
                )

                SettingsRowDivider()

                SettingsControlRow(title: "外观") {
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
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 204)
                }

                SettingsRowDivider()

                SettingsControlRow(title: "工具栏缩放") {
                    Picker("", selection: Binding(
                        get: { app.config.uiScale },
                        set: { s in app.updateConfig { $0.uiScale = s } }
                    )) {
                        ForEach(UiScaleSetting.allCases, id: \.self) { s in
                            Text(s.title).tag(s)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }
            }

            SettingsSectionCard("偏好") {
                SettingsSwitchRow(
                    title: "无损压缩",
                    subtitle: "自动压缩保存与复制的 PNG",
                    isOn: Binding(
                        get: { app.config.smartPngCompression },
                        set: { v in app.updateConfig { $0.smartPngCompression = v } }
                    )
                )

                SettingsRowDivider()

                SettingsSwitchRow(
                    title: "防误触退出",
                    subtitle: "有标注时连按两次 Esc 退出",
                    isOn: Binding(
                        get: { app.config.confirmCancel },
                        set: { v in app.updateConfig { $0.confirmCancel = v } }
                    )
                )

                SettingsRowDivider()

                SettingsSwitchRow(
                    title: "操作完成提示",
                    isOn: Binding(
                        get: { app.config.showCompletionToast },
                        set: { v in app.updateConfig { $0.showCompletionToast = v } }
                    )
                )
            }

            SettingsSectionCard("权限") {
                SettingsControlRow(
                    title: "屏幕录制",
                    subtitle: hasScreenCapture ? nil : "用于截取屏幕画面"
                ) {
                    if hasScreenCapture {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("已授权")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.green)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(Color.green.opacity(0.12)))
                    } else {
                        HStack(spacing: 8) {
                            Button("打开设置") {
                                ScreenCaptureService.openScreenCaptureSystemSettings()
                            }
                            .controlSize(.small)

                            Button("重置权限") {
                                ScreenCaptureService.resetScreenCapturePermissionAndRelaunch()
                            }
                            .controlSize(.small)
                        }
                    }
                }

                SettingsRowDivider()

                SettingsControlRow(
                    title: "辅助功能",
                    subtitle: hasAccessibility ? nil : "用于页面长截图自动翻页"
                ) {
                    if hasAccessibility {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("已授权")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.green)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(Color.green.opacity(0.12)))
                    } else {
                        HStack(spacing: 8) {
                            Button("授权") {
                                _ = AccessibilityService.requestPermissionPrompt()
                                hasAccessibility = AccessibilityService.hasPermission()
                            }
                            .controlSize(.small)

                            Button("打开设置") {
                                AccessibilityService.openSystemSettings()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .onAppear {
            hasScreenCapture = ScreenCaptureService.hasScreenCapturePermission()
            hasAccessibility = AccessibilityService.hasPermission()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasScreenCapture = ScreenCaptureService.hasScreenCapturePermission()
            hasAccessibility = AccessibilityService.hasPermission()
        }
    }
}

// MARK: - 2. Capture, Compression & Pin

private struct CaptureAndPinPane: View {
    @ObservedObject var app: AirSnipAppController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsPageHeader("截图")

            SettingsSectionCard("PNG 压缩") {
                SettingsSwitchRow(
                    title: "无损压缩",
                    subtitle: "pngquant + oxipng",
                    isOn: Binding(
                        get: { app.config.smartPngCompression },
                        set: { v in app.updateConfig { $0.smartPngCompression = v } }
                    )
                )

                SettingsRowDivider()

                SettingsControlRow(title: "压缩档位") {
                    Picker("", selection: Binding(
                        get: { app.config.pngCompressionQuality },
                        set: { q in app.updateConfig { $0.pngCompressionQuality = q } }
                    )) {
                        ForEach(PngCompressionQualityPreset.allCases, id: \.self) { q in
                            Text(q.title).tag(q)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 172)
                    .disabled(!app.config.smartPngCompression)
                }

                SettingsRowDivider()

                SettingsSwitchRow(
                    title: "压缩剪贴板图片",
                    isOn: Binding(
                        get: { app.config.compressClipboardPng },
                        set: { v in app.updateConfig { $0.compressClipboardPng = v } }
                    )
                )
                .disabled(!app.config.smartPngCompression)
                .opacity(app.config.smartPngCompression ? 1.0 : 0.5)

                if !PngSmartCompressor.hasBundledOrSystemTools {
                    SettingsRowDivider()
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.orange)
                        Text("未检测到压缩组件，已回退系统编码")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }

            SettingsSectionCard("保存与选区") {
                let saveDirURL = OutputService.defaultSaveDirectoryURL(for: app.config)
                SettingsControlRow(title: "保存位置") {
                    HStack(spacing: 6) {
                        Text(OutputService.displayPath(for: saveDirURL))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 190, alignment: .trailing)

                        Button {
                            try? FileManager.default.createDirectory(at: saveDirURL, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(saveDirURL)
                        } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .controlSize(.small)
                        .help("打开目录")

                        Button("更改…") {
                            if let chosen = OutputService.chooseSaveDirectory(initial: saveDirURL) {
                                app.updateConfig { $0.lastSaveDirectory = chosen.path }
                            }
                        }
                        .controlSize(.small)
                    }
                }

                SettingsRowDivider()

                SettingsSwitchRow(
                    title: "每次询问保存位置",
                    isOn: Binding(
                        get: { app.config.askBeforeSave },
                        set: { v in app.updateConfig { $0.askBeforeSave = v } }
                    )
                )

                SettingsRowDivider()

                SettingsControlRow(title: "默认格式") {
                    Picker("", selection: Binding(
                        get: { app.config.lastSaveFormat },
                        set: { f in app.updateConfig { $0.lastSaveFormat = f } }
                    )) {
                        ForEach(ExportImageFormat.allCases, id: \.self) { f in
                            Text(f.displayName).tag(f)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 108)
                }

                SettingsRowDivider()

                SettingsControlRow(title: "文件命名") {
                    Picker("", selection: Binding(
                        get: { app.config.nameStyle },
                        set: { s in app.updateConfig { $0.nameStyle = s } }
                    )) {
                        ForEach(NameStyle.allCases, id: \.self) { s in
                            Text(s.title).tag(s)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 124)
                }

                SettingsRowDivider()

                SettingsSwitchRow(
                    title: "自动识别窗口",
                    isOn: Binding(
                        get: { app.config.windowSnap },
                        set: { v in app.updateConfig { $0.windowSnap = v } }
                    )
                )
            }

            SettingsSectionCard("页面长截图") {
                SettingsSwitchRow(
                    title: "自动翻页",
                    isOn: Binding(
                        get: { app.config.longshotAutoScroll },
                        set: { v in app.updateConfig { $0.longshotAutoScroll = v } }
                    )
                )

                SettingsRowDivider()

                SettingsControlRow(title: "翻页速度") {
                    Picker("", selection: Binding(
                        get: { app.config.longshotScrollSpeed },
                        set: { s in app.updateConfig { $0.longshotScrollSpeed = s } }
                    )) {
                        ForEach(LongshotScrollSpeed.allCases, id: \.self) { s in
                            Text(s.title).tag(s)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 172)
                }

                SettingsRowDivider()

                SettingsControlRow(title: "高度上限") {
                    Stepper(
                        "\(app.config.longshotMaxHeight) px",
                        value: Binding(
                            get: { app.config.longshotMaxHeight },
                            set: { h in app.updateConfig { $0.longshotMaxHeight = h } }
                        ),
                        in: 5000...60000,
                        step: 5000
                    )
                    .font(.system(size: 12.5, design: .monospaced))
                }
            }

            SettingsSectionCard("贴图") {
                SettingsControlRow(title: "初始位置") {
                    Picker("", selection: Binding(
                        get: { app.config.pinPosition },
                        set: { p in app.updateConfig { $0.pinPosition = p } }
                    )) {
                        ForEach(PinPosition.allCases, id: \.self) { p in
                            Text(p.title).tag(p)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 172)
                }

                SettingsRowDivider()

                SettingsSwitchRow(
                    title: "显示边框",
                    isOn: Binding(
                        get: { app.config.pinBorder },
                        set: { b in app.updateConfig { $0.pinBorder = b } }
                    )
                )

                SettingsRowDivider()

                SettingsControlRow(title: "数量上限") {
                    Stepper(
                        "\(app.config.pinMaxCount) 张",
                        value: Binding(
                            get: { app.config.pinMaxCount },
                            set: { n in app.updateConfig { $0.pinMaxCount = n } }
                        ),
                        in: 5...50,
                        step: 5
                    )
                    .font(.system(size: 12.5, design: .monospaced))
                }
            }
        }
    }
}

// MARK: - 3. Toolbar

private struct ToolbarVisibilityPane: View {
    @ObservedObject var app: AirSnipAppController
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsPageHeader("工具栏", subtitle: "隐藏按钮不影响快捷键") {
                Button("全部显示") {
                    app.updateConfig { $0.toolbar.hidden.removeAll() }
                }
                .controlSize(.small)
            }

            ForEach(ToolbarGroup.allCases, id: \.rawValue) { group in
                let state = app.config.toolbar.groupState(group)
                SettingsSectionCard {
                    VStack(alignment: .leading, spacing: 11) {
                        HStack {
                            Button {
                                let turnOn = (state == .none)
                                app.updateConfig { $0.toolbar.setGroupVisible(group, turnOn) }
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: state == .all ? "checkmark.circle.fill" : (state == .partial ? "minus.circle.fill" : "circle"))
                                        .font(.system(size: 13.5, weight: .semibold))
                                        .foregroundStyle(state == .none ? Color.secondary : Color.accentColor)
                                    Text(group.title)
                                        .font(.system(size: 13, weight: .semibold))
                                }
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            Text("\(app.config.toolbar.visibleCount(in: group))/\(group.slots.count)")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                            ForEach(group.slots, id: \.key) { slot in
                                let visible = app.config.toolbar.isVisible(slot)
                                Button {
                                    app.updateConfig { $0.toolbar.setVisible(slot, !visible) }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: visible ? "checkmark" : "plus")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(visible ? Color.accentColor : Color.secondary)
                                        Text(slot.label)
                                            .font(.system(size: 12, weight: visible ? .medium : .regular))
                                            .foregroundStyle(visible ? Color.primary : Color.secondary)
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6.5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .fill(visible ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .strokeBorder(visible ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08), lineWidth: 0.8)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(14)
                }
            }
        }
    }
}

// MARK: - 4. Hotkeys

private struct HotkeysSettingsPane: View {
    @ObservedObject var app: AirSnipAppController
    @State private var recordingSlot: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsPageHeader("快捷键", subtitle: "点击键帽录制，支持鼠标中键与侧键") {
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
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(conflicts, id: \.self) { msg in
                        Label(msg, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.orange.opacity(0.11))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.28), lineWidth: 0.75)
                )
            }

            SettingsSectionCard("全局") {
                HotkeyRow(title: "截图", slotID: "global.screenshot", binding: app.config.hotkeys.screenshot, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.screenshot = b }
                }
                SettingsRowDivider()
                HotkeyRow(title: "页面长截图", slotID: "global.longshotCapture", binding: app.config.hotkeys.longshotCapture, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.longshotCapture = b }
                }
                SettingsRowDivider()
                HotkeyRow(title: "截图识字", slotID: "global.ocrCapture", binding: app.config.hotkeys.ocrCapture, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.ocrCapture = b }
                }
                SettingsRowDivider()
                HotkeyRow(title: "剪贴板贴图", slotID: "global.pin", binding: app.config.hotkeys.pin, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.pin = b }
                }
                SettingsRowDivider()
                HotkeyRow(title: "切换贴图边框", slotID: "global.pinBorder", binding: app.config.hotkeys.pinBorderToggle, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.pinBorderToggle = b }
                }
            }

            SettingsSectionCard("截图内") {
                HotkeyRow(title: "重新抓屏", slotID: "ov.recapture", binding: app.config.hotkeys.recapture, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.recapture = b }
                }
                SettingsRowDivider()
                HotkeyRow(title: "长截图", slotID: "ov.longshot", binding: app.config.hotkeys.longshot, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.longshot = b }
                }
                SettingsRowDivider()
                HotkeyRow(title: "OCR 识字", slotID: "ov.ocr", binding: app.config.hotkeys.ocr, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.ocr = b }
                }
            }

            SettingsSectionCard("标注工具") {
                ForEach(Array(AnnotationTool.allOrdered.enumerated()), id: \.element.rawValue) { idx, tool in
                    if idx > 0 {
                        SettingsRowDivider()
                    }
                    HotkeyRow(
                        title: tool.shortLabel,
                        slotID: "tool.\(tool.rawValue)",
                        binding: app.config.toolKeys.binding(for: tool),
                        recordingSlot: $recordingSlot
                    ) { b in
                        app.updateConfig { $0.toolKeys.setBinding(b, for: tool) }
                    }
                }
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
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 13))
            Spacer()

            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                Text(isRecording ? "按下快捷键…" : binding.displayString)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isRecording ? Color.accentColor : (binding.isUnbound ? Color.secondary : Color.primary))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .frame(minWidth: 118)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isRecording ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(isRecording ? Color.accentColor : Color.primary.opacity(0.13), lineWidth: isRecording ? 1.2 : 0.8)
                    )
            }
            .buttonStyle(.plain)

            if !binding.isUnbound {
                Button {
                    stopRecording()
                    onUpdate(.unbound)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary.opacity(0.75))
                }
                .buttonStyle(.plain)
                .help("清除")
            } else {
                Spacer().frame(width: 13)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8.5)
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

// MARK: - 5. Editor Defaults

private struct EditorDefaultsPane: View {
    @ObservedObject var app: AirSnipAppController

    private func swiftUIColor(_ c: RGBAColor) -> Color {
        Color(.sRGB, red: Double(c.r) / 255.0, green: Double(c.g) / 255.0, blue: Double(c.b) / 255.0, opacity: 1.0)
    }

    private func rgbaFromNSColor(_ ns: NSColor) -> RGBAColor {
        let conv = ns.usingColorSpace(.sRGB) ?? ns
        return RGBAColor(
            r: UInt8(max(0, min(255, Int((conv.redComponent * 255.0).rounded())))),
            g: UInt8(max(0, min(255, Int((conv.greenComponent * 255.0).rounded())))),
            b: UInt8(max(0, min(255, Int((conv.blueComponent * 255.0).rounded()))))
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsPageHeader("标注")

            SettingsSectionCard("默认样式") {
                HStack(spacing: 14) {
                    Text("线宽")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 76, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { app.config.defaultLineWidth },
                            set: { v in app.updateConfig { $0.defaultLineWidth = v.rounded() } }
                        ),
                        in: 1...20,
                        step: 1
                    )
                    Text("\(Int(app.config.defaultLineWidth)) px")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

                SettingsRowDivider()

                HStack(spacing: 14) {
                    Text("模糊强度")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 76, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { app.config.defaultBlurRadius },
                            set: { v in app.updateConfig { $0.defaultBlurRadius = v.rounded() } }
                        ),
                        in: 4...48,
                        step: 2
                    )
                    Text("\(Int(app.config.defaultBlurRadius))")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

                SettingsRowDivider()

                HStack(spacing: 14) {
                    Text("字号")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 76, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { app.config.defaultFontSize },
                            set: { v in app.updateConfig { $0.defaultFontSize = v.rounded() } }
                        ),
                        in: 12...72,
                        step: 2
                    )
                    Text("\(Int(app.config.defaultFontSize)) pt")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                SettingsRowDivider()

                SettingsSwitchRow(
                    title: "实心填充",
                    isOn: Binding(
                        get: { app.config.defaultFillEnabled },
                        set: { v in app.updateConfig { $0.defaultFillEnabled = v } }
                    )
                )
            }

            SettingsSectionCard("预设颜色") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 16) {
                        ForEach(0..<ColorPalette.swatchCount, id: \.self) { idx in
                            let c = idx < app.config.swatchColors.count ? app.config.swatchColors[idx] : ColorPalette.defaultSwatches[idx]
                            let isActive = (app.config.activeColorIndex == idx)

                            VStack(spacing: 6) {
                                Button {
                                    app.updateConfig { $0.activeColorIndex = idx }
                                } label: {
                                    Circle()
                                        .fill(swiftUIColor(c))
                                        .frame(width: 26, height: 26)
                                        .overlay(
                                            Circle()
                                                .strokeBorder(Color.primary.opacity(0.20), lineWidth: 1)
                                        )
                                        .overlay(
                                            Circle()
                                                .strokeBorder(Color.accentColor, lineWidth: isActive ? 2.2 : 0)
                                                .padding(-3.5)
                                        )
                                }
                                .buttonStyle(.plain)

                                ColorPicker("", selection: Binding(
                                    get: { swiftUIColor(c) },
                                    set: { newCol in
                                        let ns = NSColor(newCol)
                                        let rgba = rgbaFromNSColor(ns)
                                        app.updateConfig {
                                            if idx < $0.swatchColors.count {
                                                $0.swatchColors[idx] = rgba
                                            }
                                            $0.activeColorIndex = idx
                                        }
                                    }
                                ), supportsOpacity: false)
                                .labelsHidden()
                                .scaleEffect(0.82)
                            }
                        }

                        Spacer()

                        Button("恢复默认") {
                            app.updateConfig {
                                $0.swatchColors = ColorPalette.defaultSwatches
                                $0.activeColorIndex = 1
                                $0.defaultLineWidth = 2.0
                                $0.defaultFillEnabled = false
                            }
                        }
                        .controlSize(.small)
                        .fixedSize()
                    }

                    let activeRGB = app.config.swatchColors[max(0, min(app.config.swatchColors.count - 1, app.config.activeColorIndex))]
                    HStack(spacing: 16) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(swiftUIColor(activeRGB), lineWidth: max(1.5, min(8, app.config.defaultLineWidth * 0.6)))
                            .frame(width: 52, height: 28)

                        Capsule()
                            .fill(swiftUIColor(activeRGB))
                            .frame(width: 72, height: max(2, min(16, app.config.defaultLineWidth)))

                        Text("Aa 预览")
                            .font(.system(size: max(12, min(24, app.config.defaultFontSize * 0.72)), weight: .semibold))
                            .foregroundStyle(swiftUIColor(activeRGB))

                        Spacer()

                        Text(activeRGB.hexString)
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
                }
                .padding(14)
            }
        }
    }
}

// MARK: - 6. OCR

private struct OCRSettingsPane: View {
    @ObservedObject var app: AirSnipAppController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsPageHeader("OCR")

            SettingsSectionCard("识别") {
                SettingsControlRow(title: "识别语言") {
                    Picker("", selection: Binding(
                        get: { app.config.ocr.language },
                        set: { lang in app.updateConfig { $0.ocr.language = lang } }
                    )) {
                        ForEach(OcrConfig.supportedOptions, id: \.tag) { opt in
                            Text(opt.label).tag(opt.tag)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 136)
                }

                SettingsRowDivider()

                SettingsSwitchRow(
                    title: "自动复制结果",
                    isOn: Binding(
                        get: { app.config.ocr.autoCopy },
                        set: { ac in app.updateConfig { $0.ocr.autoCopy = ac } }
                    )
                )

                SettingsRowDivider()

                SettingsSwitchRow(
                    title: "合并段落换行",
                    isOn: Binding(
                        get: { app.config.ocr.mergeLineBreaks },
                        set: { mb in app.updateConfig { $0.ocr.mergeLineBreaks = mb } }
                    )
                )

                SettingsRowDivider()

                SettingsSwitchRow(
                    title: "识别二维码与条码",
                    isOn: Binding(
                        get: { app.config.ocr.detectBarcodes },
                        set: { db in app.updateConfig { $0.ocr.detectBarcodes = db } }
                    )
                )
            }

            SettingsSectionCard("快捷识别") {
                HStack(spacing: 10) {
                    Button {
                        app.settingsController?.hide()
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 180_000_000)
                            app.triggerDirectOCRCapture()
                        }
                    } label: {
                        Label("框选识字", systemImage: "text.viewfinder")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        app.triggerOCRFromClipboard()
                    } label: {
                        Label("剪贴板识字", systemImage: "doc.on.clipboard")
                    }

                    Button {
                        app.triggerOCRFromFile()
                    } label: {
                        Label("选择图片…", systemImage: "photo")
                    }

                    Spacer()
                }
                .padding(14)
            }

            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.green)
                Text("本地离线识别，图片不上传")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 4)
        }
    }
}

// MARK: - 7. About

private struct AboutSettingsPane: View {
    @ObservedObject var app: AirSnipAppController
    @State private var checkingUpdate = false
    @State private var updateStatusText = ""
    @State private var latestRelease: UpdateReleaseInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsPageHeader("关于")

            HStack(spacing: 15) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 60, height: 60)
                    .shadow(color: .black.opacity(0.18), radius: 5, x: 0, y: 2.5)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("iSnip")
                            .font(.system(size: 20, weight: .bold))
                        Text("v\(UpdateChecker.currentVersion)")
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    }
                    Text("截图标注 · 页面长截图 · 无损压缩 · 贴图 · 离线 OCR")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
            )

            SettingsSectionCard("更新") {
                SettingsSwitchRow(
                    title: "启动时自动检查更新",
                    isOn: Binding(
                        get: { app.config.autoCheckUpdate },
                        set: { v in app.updateConfig { $0.autoCheckUpdate = v } }
                    )
                )

                SettingsRowDivider()

                HStack(spacing: 10) {
                    Text(updateStatusText.isEmpty ? "当前版本 v\(UpdateChecker.currentVersion)" : updateStatusText)
                        .font(.system(size: 13))
                        .foregroundStyle(updateStatusText.isEmpty ? .secondary : .primary)

                    Spacer()

                    if let rel = latestRelease {
                        Button("下载 v\(rel.version)") {
                            NSWorkspace.shared.open(rel.downloadURL ?? rel.htmlURL)
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    }

                    Button(checkingUpdate ? "检查中…" : "检查更新") {
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
                                updateStatusText = "已是最新版本"
                            case .failure(let err):
                                updateStatusText = "检查失败：\(err.localizedDescription)"
                            }
                        }
                    }
                    .controlSize(.small)
                    .disabled(checkingUpdate)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9.5)
            }

            HStack(spacing: 6) {
                Text("GPL-3.0 ·")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Link("https://github.com/zzusec/isnip", destination: URL(string: "https://github.com/zzusec/isnip")!)
                    .font(.system(size: 11.5))
            }
            .padding(.leading, 4)
        }
    }
}
