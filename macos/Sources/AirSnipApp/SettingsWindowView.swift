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
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
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
        case .captureAndPin: return "截图与压缩"
        case .toolbar: return "工具栏定制"
        case .hotkeys: return "快捷键"
        case .editor: return "标注样式"
        case .ocr: return "OCR 识别"
        case .about: return "关于 iSnip"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape.fill"
        case .captureAndPin: return "sparkles.rectangle.stack.fill"
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
            // Left translucent macOS sidebar
            VStack(alignment: .leading, spacing: 4) {
                // Leave room for macOS traffic-light window buttons
                Spacer().frame(height: 24)

                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 34, height: 34)
                        .shadow(color: .black.opacity(0.16), radius: 3, x: 0, y: 1.5)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("iSnip")
                                .font(.system(size: 15, weight: .bold))
                            Text("v\(UpdateChecker.currentVersion)")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(
                                    Capsule()
                                        .fill(Color.primary.opacity(0.07))
                                )
                        }
                        Text("极速截图 · 智能压缩")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 10)
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
                                    .shadow(color: tab.badgeGradient[1].opacity(0.24), radius: 2, x: 0, y: 1)

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

                // Compact compression status pill in sidebar footer
                HStack(spacing: 6) {
                    Circle()
                        .fill(app.config.smartPngCompression ? Color.green : Color.secondary.opacity(0.45))
                        .frame(width: 6.5, height: 6.5)
                    Text(app.config.smartPngCompression ? "无损压缩已开启" : "无损压缩已关闭")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
            }
            .padding(14)
            .frame(width: 204)
            .background(SidebarVisualEffectView())

            Rectangle()
                .fill(Color.primary.opacity(0.09))
                .frame(width: 1)

            // Right studio detail canvas
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
                .padding(.top, 28)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 760, height: 540)
    }
}

// MARK: - Shared Studio Settings Components

private struct SettingsPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, subtitle: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 19, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 7) {
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
            .fill(Color.primary.opacity(0.07))
            .frame(height: 0.75)
            .padding(.leading, 14)
    }
}

private struct SettingsSwitchRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2.5) {
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
        .padding(.vertical, 10.5)
    }
}

private struct SettingsControlRow<Control: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2.5) {
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
        .padding(.vertical, 10)
    }
}

// MARK: - 1. General Settings

private struct GeneralSettingsPane: View {
    @ObservedObject var app: AirSnipAppController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsPageHeader("通用", subtitle: "管理 iSnip 启动方式、界面外观、无损压缩快捷开关与系统权限")

            SettingsSectionCard("启动与外观") {
                SettingsSwitchRow(
                    title: "登录 macOS 时自动启动 iSnip",
                    subtitle: "常驻顶部菜单栏，空闲 0% CPU 占用，随时按键瞬时抓屏",
                    isOn: Binding(
                        get: { app.config.autoStart },
                        set: { val in
                            _ = LaunchAtLoginManager.setEnabled(val)
                            app.updateConfig { $0.autoStart = val }
                        }
                    )
                )

                SettingsRowDivider()

                SettingsControlRow(
                    title: "界面主题",
                    subtitle: "应用于设置窗口、截图悬浮工具栏与识别气泡"
                ) {
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
                    .frame(width: 210)
                }

                SettingsRowDivider()

                SettingsControlRow(
                    title: "覆盖层工具栏缩放",
                    subtitle: "调整高分屏下截图工具条与二级参数面板尺寸"
                ) {
                    Picker("", selection: Binding(
                        get: { app.config.uiScale },
                        set: { s in app.updateConfig { $0.uiScale = s } }
                    )) {
                        ForEach(UiScaleSetting.allCases, id: \.self) { s in
                            Text(s.title).tag(s)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
            }

            SettingsSectionCard("交互与输出体验") {
                SettingsSwitchRow(
                    title: "PNG 无损压缩（pngquant + oxipng）",
                    subtitle: "默认开启。保存与复制截图时自动将 1.2 MB 级高清截图压缩至约 0.3 MB，肉眼几乎无变化",
                    isOn: Binding(
                        get: { app.config.smartPngCompression },
                        set: { v in app.updateConfig { $0.smartPngCompression = v } }
                    )
                )

                SettingsRowDivider()

                SettingsSwitchRow(
                    title: "防误触取消保护",
                    subtitle: "画布已有未保存标注时，需连按两次 Esc 才退出截图",
                    isOn: Binding(
                        get: { app.config.confirmCancel },
                        set: { v in app.updateConfig { $0.confirmCancel = v } }
                    )
                )

                SettingsRowDivider()

                SettingsSwitchRow(
                    title: "完成操作后显示顶部轻提示",
                    subtitle: "复制或保存后展示胶囊提示（含压缩后体积与节省比例）",
                    isOn: Binding(
                        get: { app.config.showCompletionToast },
                        set: { v in app.updateConfig { $0.showCompletionToast = v } }
                    )
                )
            }

            SettingsSectionCard("系统权限") {
                let authorized = ScreenCaptureService.hasScreenCapturePermission()
                SettingsControlRow(
                    title: "屏幕录制与离线抓屏权限",
                    subtitle: authorized
                        ? "已授权生效 · 所有图像仅在本机内存中处理，绝不联网上传"
                        : "尚未授权，点击右侧按钮前往「系统设置 → 录屏与系统录音」开启 iSnip"
                ) {
                    if authorized {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                            Text("已授权")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.green)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.green.opacity(0.12)))
                    } else {
                        HStack(spacing: 8) {
                            Button("打开系统设置") {
                                ScreenCaptureService.openScreenCaptureSystemSettings()
                            }
                            .controlSize(.small)

                            Button("重置权限并重开") {
                                ScreenCaptureService.resetScreenCapturePermissionAndRelaunch()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 2. Capture, Compression & Pin

private struct CaptureAndPinPane: View {
    @ObservedObject var app: AirSnipAppController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsPageHeader("截图、无损压缩与贴图", subtitle: "配置内置 pngquant + oxipng 智能压缩管线、文件命名与置顶贴图行为")

            SettingsSectionCard("PNG 无损压缩（pngquant + oxipng）") {
                SettingsSwitchRow(
                    title: "开启无损压缩",
                    subtitle: "采用 pngquant --speed 1 视觉量化 + oxipng -o max 极限无损重编码，大幅降低 PNG 体积",
                    isOn: Binding(
                        get: { app.config.smartPngCompression },
                        set: { v in app.updateConfig { $0.smartPngCompression = v } }
                    )
                )

                SettingsRowDivider()

                SettingsControlRow(
                    title: "压缩质量档位（--quality）",
                    subtitle: "默认不限窄色深上限（肉眼无感），也可进一步指定 --quality 压低体积"
                ) {
                    Picker("", selection: Binding(
                        get: { app.config.pngCompressionQuality },
                        set: { q in app.updateConfig { $0.pngCompressionQuality = q } }
                    )) {
                        ForEach(PngCompressionQualityPreset.allCases, id: \.self) { q in
                            Text(q.title).tag(q)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 248)
                    .disabled(!app.config.smartPngCompression)
                }

                SettingsRowDivider()

                SettingsSwitchRow(
                    title: "复制到剪贴板时同步压缩",
                    subtitle: "按 Enter 零延迟关闭选区，后台自动将剪贴板替换为压缩后轻量 PNG（粘贴到网页/聊天更省体积）",
                    isOn: Binding(
                        get: { app.config.compressClipboardPng },
                        set: { v in app.updateConfig { $0.compressClipboardPng = v } }
                    )
                )
                .disabled(!app.config.smartPngCompression)
                .opacity(app.config.smartPngCompression ? 1.0 : 0.5)

                SettingsRowDivider()

                HStack(spacing: 8) {
                    Image(systemName: PngSmartCompressor.hasBundledOrSystemTools ? "bolt.badge.checkmark.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(PngSmartCompressor.hasBundledOrSystemTools ? .green : .orange)
                    Text(PngSmartCompressor.hasBundledOrSystemTools
                         ? "内置引擎已就绪 · pngquant --speed 1 | oxipng -o max"
                         : "未检测到压缩引擎，将回退至系统原生 PNG 编码")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.primary.opacity(0.025))
            }

            SettingsSectionCard("截图与文件保存") {
                SettingsSwitchRow(
                    title: "智能识别桌面窗口",
                    subtitle: "悬停在独立应用窗口上时高亮边界（自动忽略最大化背景窗，避免全屏抖动）",
                    isOn: Binding(
                        get: { app.config.windowSnap },
                        set: { v in app.updateConfig { $0.windowSnap = v } }
                    )
                )

                SettingsRowDivider()

                SettingsControlRow(
                    title: "默认保存格式",
                    subtitle: "可在每次保存面板底部随时切换"
                ) {
                    Picker("", selection: Binding(
                        get: { app.config.lastSaveFormat },
                        set: { f in app.updateConfig { $0.lastSaveFormat = f } }
                    )) {
                        ForEach(ExportImageFormat.allCases, id: \.self) { f in
                            Text(f.displayName).tag(f)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }

                SettingsRowDivider()

                SettingsControlRow(
                    title: "保存文件名模板"
                ) {
                    Picker("", selection: Binding(
                        get: { app.config.nameStyle },
                        set: { s in app.updateConfig { $0.nameStyle = s } }
                    )) {
                        ForEach(NameStyle.allCases, id: \.self) { s in
                            Text(s.title).tag(s)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 268)
                }

                SettingsRowDivider()

                SettingsControlRow(
                    title: "长截图拼接高度上限",
                    subtitle: "达到像素上限后自动停止采样并可正常导出"
                ) {
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

            SettingsSectionCard("置顶贴图（Pin）") {
                SettingsControlRow(
                    title: "选区贴图初始位置"
                ) {
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
                    .frame(width: 200)
                }

                SettingsRowDivider()

                SettingsSwitchRow(
                    title: "显示贴图精细发光边框",
                    subtitle: "在深浅色窗口背景上清晰区分贴图边界，可按快捷键随时开闭",
                    isOn: Binding(
                        get: { app.config.pinBorder },
                        set: { b in app.updateConfig { $0.pinBorder = b } }
                    )
                )

                SettingsRowDivider()

                SettingsControlRow(
                    title: "同时贴图数量上限"
                ) {
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

// MARK: - 3. Toolbar Customization

private struct ToolbarVisibilityPane: View {
    @ObservedObject var app: AirSnipAppController
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsPageHeader(
                "工具栏定制",
                subtitle: "点选胶囊即可显隐对应按钮。隐藏仅精简视觉面板，对应数字键与快捷键依旧可用"
            ) {
                Button("恢复全部显示") {
                    app.updateConfig { $0.toolbar.hidden.removeAll() }
                }
                .controlSize(.small)
            }

            ForEach(ToolbarGroup.allCases, id: \.rawValue) { group in
                let state = app.config.toolbar.groupState(group)
                SettingsSectionCard {
                    VStack(alignment: .leading, spacing: 12) {
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

                            Text("\(app.config.toolbar.visibleCount(in: group)) / \(group.slots.count) 项开启")
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
            SettingsPageHeader(
                "快捷键",
                subtitle: "点击键帽即可录制新组合键（支持鼠标中键与侧键），点右侧 ✕ 可清空"
            ) {
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

            if app.config.hotkeys.screenshot.hasNoModifierWarning
                || app.config.hotkeys.ocrCapture.hasNoModifierWarning
                || app.config.hotkeys.pin.hasNoModifierWarning {
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.yellow)
                    Text("单键热键（如 F1 / F2 / F3）响应最快；若与其他软件功能键冲突，建议录制为 ⌃1 / ⌥A 等修饰键组合。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
            }

            SettingsSectionCard("全局热键（在任意应用中随时触发）") {
                HotkeyRow(title: "区域截图与标注", slotID: "global.screenshot", binding: app.config.hotkeys.screenshot, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.screenshot = b }
                }
                SettingsRowDivider()
                HotkeyRow(title: "截图文字识别（框选松手即 OCR）", slotID: "global.ocrCapture", binding: app.config.hotkeys.ocrCapture, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.ocrCapture = b }
                }
                SettingsRowDivider()
                HotkeyRow(title: "从剪贴板置顶贴图", slotID: "global.pin", binding: app.config.hotkeys.pin, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.pin = b }
                }
                SettingsRowDivider()
                HotkeyRow(title: "切换所有贴图边框显示", slotID: "global.pinBorder", binding: app.config.hotkeys.pinBorderToggle, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.pinBorderToggle = b }
                }
            }

            SettingsSectionCard("截图覆盖层内快捷键") {
                HotkeyRow(title: "再次截图（截取菜单或软件自身界面）", slotID: "ov.recapture", binding: app.config.hotkeys.recapture, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.recapture = b }
                }
                SettingsRowDivider()
                HotkeyRow(title: "切换滚动长截图模式", slotID: "ov.longshot", binding: app.config.hotkeys.longshot, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.longshot = b }
                }
                SettingsRowDivider()
                HotkeyRow(title: "对当前选区执行 OCR 识别", slotID: "ov.ocr", binding: app.config.hotkeys.ocr, recordingSlot: $recordingSlot) { b in
                    app.updateConfig { $0.hotkeys.ocr = b }
                }
                ForEach(AnnotationTool.allOrdered, id: \.rawValue) { tool in
                    SettingsRowDivider()
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
                Text(isRecording ? "请按下快捷键…" : binding.displayString)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isRecording ? Color.accentColor : (binding.isUnbound ? Color.secondary : Color.primary))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .frame(minWidth: 128)
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
                .help("清空为未设置")
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
            SettingsPageHeader("标注默认样式", subtitle: "定制矩形、箭头、马赛克模糊与文字标注的初始线宽、字号及预设调色板")

            SettingsSectionCard("画笔与模糊参数") {
                HStack(spacing: 14) {
                    Text("默认描边线宽")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 110, alignment: .leading)
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
                    Text("默认模糊半径")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 110, alignment: .leading)
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
                    Text("默认文本字号")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 110, alignment: .leading)
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
            }

            SettingsSectionCard("5 色快捷调色板与实时预览") {
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

                        Button("重置预设 5 色") {
                            app.updateConfig {
                                $0.swatchColors = ColorPalette.defaultSwatches
                                $0.activeColorIndex = 1
                            }
                        }
                        .controlSize(.small)
                        .fixedSize()
                    }

                    // Live stroke & typography preview strip
                    let activeRGB = app.config.swatchColors[max(0, min(app.config.swatchColors.count - 1, app.config.activeColorIndex))]
                    HStack(spacing: 16) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(swiftUIColor(activeRGB), lineWidth: max(1.5, min(8, app.config.defaultLineWidth * 0.6)))
                            .frame(width: 52, height: 28)

                        Capsule()
                            .fill(swiftUIColor(activeRGB))
                            .frame(width: 72, height: max(2, min(16, app.config.defaultLineWidth)))

                        Text("Aa 标注预览")
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

// MARK: - 6. Offline Vision OCR

private struct OCRSettingsPane: View {
    @ObservedObject var app: AirSnipAppController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsPageHeader("本地离线 OCR 识别", subtitle: "基于 macOS 原生 Vision 神经网络引擎，零联网、零延迟提取中英日韩文字与二维码")

            SettingsSectionCard("识别语言与智能排版") {
                SettingsControlRow(
                    title: "识别语言偏好",
                    subtitle: "默认自动混合识别简体中文与英文代码/数字"
                ) {
                    Picker("", selection: Binding(
                        get: { app.config.ocr.language },
                        set: { lang in app.updateConfig { $0.ocr.language = lang } }
                    )) {
                        ForEach(OcrConfig.supportedOptions, id: \.tag) { opt in
                            Text(opt.label).tag(opt.tag)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }

                SettingsRowDivider()

                SettingsSwitchRow(
                    title: "识别完成后自动复制全文",
                    subtitle: "框选松手即写入剪贴板，可直接 ⌘V 粘贴",
                    isOn: Binding(
                        get: { app.config.ocr.autoCopy },
                        set: { ac in app.updateConfig { $0.ocr.autoCopy = ac } }
                    )
                )

                SettingsRowDivider()

                SettingsSwitchRow(
                    title: "智能合并段落内软换行",
                    subtitle: "自动拼接同一自然段的折行，同时保留空行与列表项结构",
                    isOn: Binding(
                        get: { app.config.ocr.mergeLineBreaks },
                        set: { mb in app.updateConfig { $0.ocr.mergeLineBreaks = mb } }
                    )
                )

                SettingsRowDivider()

                SettingsSwitchRow(
                    title: "同时检测图片中的二维码与条形码",
                    subtitle: "识别结果自动追加在气泡底部，支持一键打开链接或复制内容",
                    isOn: Binding(
                        get: { app.config.ocr.detectBarcodes },
                        set: { db in app.updateConfig { $0.ocr.detectBarcodes = db } }
                    )
                )
            }

            SettingsSectionCard("立即体验 OCR") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            app.settingsController?.hide()
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 180_000_000)
                                app.triggerDirectOCRCapture()
                            }
                        } label: {
                            Label("框选屏幕文字识别", systemImage: "text.viewfinder")
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
                            Label("选择本地图片…", systemImage: "photo")
                        }
                    }

                    Text("快捷方式：全局按 \(app.config.hotkeys.ocrCapture.displayString) 框选即识别；常规截图中按 \(app.config.hotkeys.ocr.displayString) 或点击工具栏 OCR 徽标；贴图窗口内按 T 键即可提取文字。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .padding(14)
            }

            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.green)
                Text("端侧隐私保护：所有画面与文字均由 Apple Neural Engine 在本机离线推理完成，无需 API Key，绝不上传云端。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - 7. About iSnip

private struct AboutFeatureTile: View {
    let icon: String
    let tint: Color
    let title: String
    let desc: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.opacity(0.13))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(desc)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.75)
        )
    }
}

private struct AboutSettingsPane: View {
    @ObservedObject var app: AirSnipAppController
    @State private var checkingUpdate = false
    @State private var updateStatusText = ""
    @State private var latestRelease: UpdateReleaseInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Studio Hero Card
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 68, height: 68)
                    .shadow(color: .black.opacity(0.20), radius: 6, x: 0, y: 3)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("iSnip")
                            .font(.system(size: 22, weight: .bold))
                        Text("for macOS")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("v\(UpdateChecker.currentVersion)")
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    }
                    Text("原生纯 Swift 打造的专业级轻量截图标注、智能无损压缩与离线 OCR 工具")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
            )

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                AboutFeatureTile(
                    icon: "bolt.fill",
                    tint: .blue,
                    title: "原生极速响应",
                    desc: "无 Electron / WebView 负担，常驻待机 0% CPU，快捷键零抖动瞬时冻结屏幕"
                )
                AboutFeatureTile(
                    icon: "arrow.down.right.and.arrow.up.left",
                    tint: .green,
                    title: "pngquant + oxipng 无损压缩",
                    desc: "内置双引擎管线，高清 Retina 截图体积直降 60%~75%，视觉几无差异"
                )
                AboutFeatureTile(
                    icon: "scribble.variable",
                    tint: .pink,
                    title: "10 种矢量标注 & 贴图",
                    desc: "矩形、贝塞尔箭头、高斯模糊、聚光灯、序号徽标及置顶缩放贴图"
                )
                AboutFeatureTile(
                    icon: "text.viewfinder",
                    tint: .teal,
                    title: "离线 Vision OCR & 长截图",
                    desc: "本机神经网络秒级提取多国文字与二维码，支持滚动无缝拼接长图"
                )
            }

            SettingsSectionCard("版本检查与更新") {
                SettingsSwitchRow(
                    title: "启动后静默检查一次新版本",
                    subtitle: "仅单次轻量请求 GitHub Releases，无后台轮询定时器",
                    isOn: Binding(
                        get: { app.config.autoCheckUpdate },
                        set: { v in app.updateConfig { $0.autoCheckUpdate = v } }
                    )
                )

                SettingsRowDivider()

                HStack(spacing: 10) {
                    Button(checkingUpdate ? "正在检查…" : "立即检查更新") {
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
                    .controlSize(.small)
                    .disabled(checkingUpdate)

                    if let rel = latestRelease {
                        Button("下载 v\(rel.version)") {
                            NSWorkspace.shared.open(rel.downloadURL ?? rel.htmlURL)
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    }

                    if !updateStatusText.isEmpty {
                        Text(updateStatusText)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            Text("开源许可：GPL-3.0-only · 灵感致敬开源项目 bd-dxg/airsnip")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
    }
}
