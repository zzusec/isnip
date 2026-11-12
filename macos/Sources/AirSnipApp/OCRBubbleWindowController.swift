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
    @Published public var barcodes: [String] = []
    @Published public var isRecognizing: Bool = false
    @Published public var errorMessage: String?
    @Published public var sourceImage: CGImage?
    @Published public var isPinnedOnTop: Bool = true {
        didSet {
            panel?.level = isPinnedOnTop ? .floating : .normal
        }
    }
    @Published public var autoCopy: Bool = false {
        didSet {
            guard !suppressCallback else { return }
            onConfigChanged?(selectedLanguage, autoCopy, mergeLineBreaks)
        }
    }
    @Published public var mergeLineBreaks: Bool = false {
        didSet {
            guard !suppressCallback else { return }
            applyLineBreakModeAfterToggle()
            onConfigChanged?(selectedLanguage, autoCopy, mergeLineBreaks)
        }
    }
    @Published public var selectedLanguage: String = "auto" {
        didSet {
            guard !suppressCallback, oldValue != selectedLanguage else { return }
            onConfigChanged?(selectedLanguage, autoCopy, mergeLineBreaks)
            rerunRecognitionIfPossible()
        }
    }
    @Published public var copiedFeedback: Bool = false

    private var rawRecognizedText: String = ""
    private var paragraphRecognizedText: String = ""
    private var detectBarcodesEnabled: Bool = true
    private var suppressCallback: Bool = false

    private var panel: KeyableBubblePanel?
    private var recognitionTask: Task<Void, Never>?
    public var onConfigChanged: ((_ language: String, _ autoCopy: Bool, _ mergeLineBreaks: Bool) -> Void)?

    public init() {}

    public func recognizeAndPresent(
        rawSelectionImage: CGImage,
        anchorScreenPoint: NSPoint?,
        config: AirSnipConfig
    ) {
        recognitionTask?.cancel()
        suppressCallback = true
        self.autoCopy = config.ocr.autoCopy
        self.mergeLineBreaks = config.ocr.mergeLineBreaks
        self.selectedLanguage = config.ocr.language
        self.detectBarcodesEnabled = config.ocr.detectBarcodes
        suppressCallback = false

        self.sourceImage = rawSelectionImage
        self.copiedFeedback = false
        ensurePanel(near: anchorScreenPoint, theme: config.theme)
        startRecognition(on: rawSelectionImage)
    }

    public func rerunRecognitionIfPossible() {
        guard let img = sourceImage else { return }
        recognitionTask?.cancel()
        startRecognition(on: img)
    }

    private func startRecognition(on image: CGImage) {
        self.isRecognizing = true
        self.errorMessage = nil
        self.text = ""
        self.barcodes = []
        self.rawRecognizedText = ""
        self.paragraphRecognizedText = ""

        let lang = selectedLanguage
        let wantBarcodes = detectBarcodesEnabled

        recognitionTask = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try LocalVisionOCR.recognizeDetailed(
                        cgImage: image,
                        languagePreference: lang,
                        detectBarcodes: wantBarcodes
                    )
                }.value
                guard !Task.isCancelled, let self else { return }
                self.isRecognizing = false
                self.barcodes = result.barcodes
                self.rawRecognizedText = result.rawText
                self.paragraphRecognizedText = result.paragraphText

                if result.isEmpty {
                    self.errorMessage = "未在图像中识别到文字或二维码"
                } else {
                    let chosen: String
                    if result.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        chosen = result.barcodes.joined(separator: "\n")
                        self.rawRecognizedText = chosen
                        self.paragraphRecognizedText = chosen
                    } else {
                        chosen = self.mergeLineBreaks ? result.paragraphText : result.rawText
                    }
                    self.text = chosen
                    if self.autoCopy {
                        OutputService.copyStringToClipboard(chosen)
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

    private func applyLineBreakModeAfterToggle() {
        guard !rawRecognizedText.isEmpty else { return }
        if mergeLineBreaks {
            if text == rawRecognizedText {
                text = paragraphRecognizedText
            } else {
                text = OCRLinesJoiner.mergeWrappedParagraphs(text)
            }
        } else {
            if text == paragraphRecognizedText {
                text = rawRecognizedText
            }
        }
    }

    public func copyCurrentText() {
        guard !text.isEmpty else { return }
        OutputService.copyStringToClipboard(text)
        triggerCopiedFeedback()
    }

    public func copyBarcode(_ payload: String) {
        OutputService.copyStringToClipboard(payload)
        ToastHUD.show("已复制二维码/条码内容")
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
        let width: CGFloat = 480
        let height: CGFloat = 350
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
            existing.orderFrontRegardless()
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let newPanel = KeyableBubblePanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
            styleMask: [.titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        newPanel.hidesOnDeactivate = false
        newPanel.isFloatingPanel = isPinnedOnTop
        newPanel.titleVisibility = .hidden
        newPanel.titlebarAppearsTransparent = true
        newPanel.standardWindowButton(.closeButton)?.isHidden = true
        newPanel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        newPanel.standardWindowButton(.zoomButton)?.isHidden = true
        newPanel.isMovableByWindowBackground = true
        newPanel.level = isPinnedOnTop ? .floating : .normal
        newPanel.minSize = NSSize(width: 380, height: 250)
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.onEscape = { [weak self] in self?.dismiss() }
        applyTheme(theme, to: newPanel)

        newPanel.contentView = NSHostingView(rootView: OCRBubbleCardView(manager: self))
        self.panel = newPanel

        NSApp.activate(ignoringOtherApps: true)
        newPanel.orderFrontRegardless()
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

    private func webURL(from payload: String) -> URL? {
        guard let url = URL(string: payload),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    var body: some View {
        VStack(spacing: 10) {
            // Top bar
            HStack(spacing: 8) {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("OCR 文字识别")
                    .font(.system(size: 13, weight: .semibold))

                if let cg = manager.sourceImage {
                    Text("\(cg.width)×\(cg.height)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }

                Spacer(minLength: 4)

                Picker("", selection: $manager.selectedLanguage) {
                    ForEach(OcrConfig.compactOptions, id: \.tag) { opt in
                        Text(opt.shortLabel).tag(opt.tag)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 96)
                .help("切换识别语言并立即重新识别")

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

            // Detected QR / Barcodes banner (if any)
            if !manager.barcodes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(manager.barcodes, id: \.self) { code in
                        HStack(spacing: 6) {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                            Text(code)
                                .font(.system(size: 11.5, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            if let url = webURL(from: code) {
                                Button("打开链接") {
                                    NSWorkspace.shared.open(url)
                                }
                                .controlSize(.mini)
                            }
                            Button("复制") {
                                manager.copyBarcode(code)
                            }
                            .controlSize(.mini)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.10)))
                    }
                }
            }

            // Editable native text area
            ZStack {
                if manager.isRecognizing {
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在本地离线识别（图像不出本机）…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = manager.errorMessage {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Button("重新识别") {
                            manager.rerunRecognitionIfPossible()
                        }
                        .controlSize(.small)
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
                    let lineCount = manager.text.components(separatedBy: "\n").count
                    Text("\(manager.text.count) 字 · \(lineCount) 行")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                Toggle("合并换行", isOn: $manager.mergeLineBreaks)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .font(.system(size: 12))
                    .help("自动合并段落内的软换行，保留空行与列表项")

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
