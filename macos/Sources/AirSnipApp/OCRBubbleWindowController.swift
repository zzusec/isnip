import AppKit
import SwiftUI
import AirSnipCore

private final class KeyableBubblePanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

@MainActor
public final class OCRBubbleManager: ObservableObject {
    @Published public var text: String = ""
    @Published public var isRecognizing: Bool = false
    @Published public var errorMessage: String?
    @Published public var isPinnedOnTop: Bool = true {
        didSet {
            panel?.level = isPinnedOnTop ? .floating : .normal
        }
    }
    @Published public var autoCopy: Bool = false {
        didSet {
            onAutoCopyChanged?(autoCopy)
        }
    }
    @Published public var copiedFeedback: Bool = false
    @Published public var languageLabel: String = "自动识别"

    private var panel: KeyableBubblePanel?
    private var recognitionTask: Task<Void, Never>?
    public var onAutoCopyChanged: ((Bool) -> Void)?

    public init() {}

    public func recognizeAndPresent(
        rawSelectionImage: CGImage,
        anchorScreenPoint: NSPoint?,
        config: AirSnipConfig
    ) {
        recognitionTask?.cancel()
        self.autoCopy = config.ocr.autoCopy
        self.languageLabel = OcrConfig.supportedOptions.first(where: { $0.tag == config.ocr.language })?.label ?? "自动识别"
        self.isRecognizing = true
        self.errorMessage = nil
        self.text = ""
        self.copiedFeedback = false

        ensurePanel(near: anchorScreenPoint, theme: config.theme)

        let lang = config.ocr.language
        recognitionTask = Task { [weak self] in
            do {
                let extracted = try await Task.detached(priority: .userInitiated) {
                    try LocalVisionOCR.recognize(cgImage: rawSelectionImage, languagePreference: lang)
                }.value
                guard !Task.isCancelled, let self else { return }
                self.isRecognizing = false
                if extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.errorMessage = "未在选区内识别到文字"
                } else {
                    self.text = extracted
                    if self.autoCopy {
                        OutputService.copyStringToClipboard(extracted)
                        self.triggerCopiedFeedback()
                    }
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.isRecognizing = false
                self.errorMessage = "识别失败：\(error.localizedDescription)"
            }
        }
    }

    public func copyCurrentText() {
        guard !text.isEmpty else { return }
        OutputService.copyStringToClipboard(text)
        triggerCopiedFeedback()
    }

    private func triggerCopiedFeedback() {
        copiedFeedback = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            self?.copiedFeedback = false
        }
    }

    public func dismiss() {
        recognitionTask?.cancel()
        panel?.orderOut(nil)
    }

    private func ensurePanel(near anchor: NSPoint?, theme: ThemeSetting) {
        let width: CGFloat = 440
        let height: CGFloat = 310
        let screen = NSScreen.main ?? NSScreen.screens.first
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let origin: NSPoint
        if let anchor {
            let x = max(vis.minX + 12, min(vis.maxX - width - 12, anchor.x - width * 0.5))
            let y = max(vis.minY + 12, min(vis.maxY - height - 12, anchor.y - height * 0.5))
            origin = NSPoint(x: x, y: y)
        } else {
            origin = NSPoint(x: vis.midX - width * 0.5, y: vis.midY - height * 0.5)
        }

        if let existing = panel {
            applyTheme(theme, to: existing)
            existing.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let newPanel = KeyableBubblePanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
            styleMask: [.titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        newPanel.titleVisibility = .hidden
        newPanel.titlebarAppearsTransparent = true
        newPanel.standardWindowButton(.closeButton)?.isHidden = true
        newPanel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        newPanel.standardWindowButton(.zoomButton)?.isHidden = true
        newPanel.isMovableByWindowBackground = true
        newPanel.level = isPinnedOnTop ? .floating : .normal
        newPanel.minSize = NSSize(width: 340, height: 220)
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.onEscape = { [weak self] in self?.dismiss() }
        applyTheme(theme, to: newPanel)

        newPanel.contentView = NSHostingView(rootView: OCRBubbleCardView(manager: self))
        self.panel = newPanel

        NSApp.activate(ignoringOtherApps: true)
        newPanel.makeKeyAndOrderFront(nil)
    }

    private func applyTheme(_ theme: ThemeSetting, to win: NSWindow) {
        switch theme {
        case .follow: win.appearance = nil
        case .light: win.appearance = NSAppearance(named: .aqua)
        case .dark: win.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

private struct OCRBubbleCardView: View {
    @ObservedObject var manager: OCRBubbleManager
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            // Top bar
            HStack(spacing: 8) {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("OCR 文字识别")
                    .font(.system(size: 13, weight: .semibold))
                Text("· \(manager.languageLabel)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    manager.isPinnedOnTop.toggle()
                } label: {
                    Image(systemName: manager.isPinnedOnTop ? "pin.fill" : "pin.slash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(manager.isPinnedOnTop ? Color.accentColor : Color.secondary)
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(manager.isPinnedOnTop ? Color.accentColor.opacity(0.14) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help(manager.isPinnedOnTop ? "已置顶（点击取消置顶）" : "置顶窗口")

                Button {
                    manager.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("关闭 (Esc)")
            }

            // Editable native text area
            ZStack {
                if manager.isRecognizing {
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在本地识别文字（图片不出本机）…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = manager.errorMessage {
                    VStack(spacing: 6) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TextEditor(text: $manager.text)
                        .font(.system(size: 14))
                        .focused($editorFocused)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .onAppear {
                            editorFocused = true
                        }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(editorFocused ? Color.accentColor : Color.primary.opacity(0.14), lineWidth: 1)
            )

            // Bottom bar
            HStack(spacing: 12) {
                Button {
                    manager.copyCurrentText()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: manager.copiedFeedback ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                        Text(manager.copiedFeedback ? "已复制" : "复制全文")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor)
                    )
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(manager.text.isEmpty || manager.isRecognizing)

                if !manager.text.isEmpty {
                    Text("\(manager.text.count) 字")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("自动复制", isOn: $manager.autoCopy)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 12))
            }
        }
        .padding(14)
        .background(.regularMaterial)
    }
}
