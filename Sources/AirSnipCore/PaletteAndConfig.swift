import Foundation
import Carbon

public enum AnnotationTool: Int, Codable, CaseIterable, Sendable {
    case rect = 0
    case arrow = 1
    case text = 2
    case highlight = 3
    case blur = 4
    case glow = 5
    case number = 6
    case line = 7
    case ellipse = 8
    case freehand = 9

    public static let allOrdered: [AnnotationTool] = [
        .rect, .arrow, .text, .highlight, .blur, .glow, .number, .line, .ellipse, .freehand
    ]

    public var displayName: String {
        switch self {
        case .rect: return "矩形"
        case .arrow: return "箭头"
        case .text: return "文本"
        case .highlight: return "荧光笔"
        case .blur: return "模糊"
        case .glow: return "聚光灯"
        case .number: return "序号"
        case .line: return "直线"
        case .ellipse: return "椭圆"
        case .freehand: return "手绘"
        }
    }

    public var shortLabel: String {
        switch self {
        case .rect: return "矩形"
        case .arrow: return "箭头"
        case .text: return "文本"
        case .highlight: return "荧光笔"
        case .blur: return "模糊"
        case .glow: return "聚光灯"
        case .number: return "序号"
        case .line: return "直线"
        case .ellipse: return "椭圆"
        case .freehand: return "手绘"
        }
    }

    public var sfSymbolName: String {
        switch self {
        case .rect: return "rectangle"
        case .arrow: return "arrow.up.right"
        case .text: return "textformat"
        case .highlight: return "highlighter"
        case .blur: return "aqi.medium"
        case .glow: return "flashlight.on.fill"
        case .number: return "1.circle"
        case .line: return "line.diagonal"
        case .ellipse: return "circle"
        case .freehand: return "scribble"
        }
    }

    public var defaultShortcutDigit: String {
        switch self {
        case .rect: return "1"
        case .arrow: return "2"
        case .text: return "3"
        case .highlight: return "4"
        case .blur: return "5"
        case .glow: return "6"
        case .number: return "7"
        case .line: return "8"
        case .ellipse: return "9"
        case .freehand: return "0"
        }
    }
}

public enum ColorPalette {
    public static let swatchCount = 5

    public static let defaultSwatches: [RGBAColor] = [
        RGBAColor(r: 255, g: 255, b: 255),
        RGBAColor(r: 255, g: 0, b: 0),
        RGBAColor(r: 251, g: 140, b: 0),
        RGBAColor(r: 67, g: 160, b: 71),
        RGBAColor(r: 30, g: 136, b: 229),
    ]

    public static let quickColors: [RGBAColor] = [
        RGBAColor(r: 255, g: 255, b: 255),
        RGBAColor(r: 0, g: 0, b: 0),
        RGBAColor(r: 158, g: 158, b: 158),
        RGBAColor(r: 255, g: 0, b: 0),
        RGBAColor(r: 251, g: 140, b: 0),
        RGBAColor(r: 253, g: 216, b: 53),
        RGBAColor(r: 67, g: 160, b: 71),
        RGBAColor(r: 0, g: 172, b: 193),
        RGBAColor(r: 30, g: 136, b: 229),
        RGBAColor(r: 142, g: 36, b: 170),
        RGBAColor(r: 216, g: 27, b: 96),
        RGBAColor(r: 109, g: 76, b: 65),
    ]

    public static func hsvToRGB(h: Double, s: Double, v: Double) -> RGBAColor {
        var hue = h.truncatingRemainder(dividingBy: 360.0)
        if hue < 0 { hue += 360.0 }
        let sector = hue / 60.0
        let sat = max(0.0, min(1.0, s))
        let val = max(0.0, min(1.0, v))
        let c = val * sat
        let x = c * (1.0 - abs(sector.truncatingRemainder(dividingBy: 2.0) - 1.0))
        let (r1, g1, b1): (Double, Double, Double)
        switch Int(sector) {
        case 0: (r1, g1, b1) = (c, x, 0)
        case 1: (r1, g1, b1) = (x, c, 0)
        case 2: (r1, g1, b1) = (0, c, x)
        case 3: (r1, g1, b1) = (0, x, c)
        case 4: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        let m = val - c
        func byte(_ f: Double) -> UInt8 {
            UInt8(max(0, min(255, Int(((f + m) * 255.0).rounded()))))
        }
        return RGBAColor(r: byte(r1), g: byte(g1), b: byte(b1), a: 255)
    }

    public static func rgbToHSV(_ c: RGBAColor) -> (h: Double, s: Double, v: Double) {
        let r = Double(c.r) / 255.0
        let g = Double(c.g) / 255.0
        let b = Double(c.b) / 255.0
        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let d = maxC - minC
        var h: Double
        if d < 1e-6 {
            h = 0
        } else if maxC == r {
            h = 60.0 * (((g - b) / d).truncatingRemainder(dividingBy: 6.0))
        } else if maxC == g {
            h = 60.0 * (((b - r) / d) + 2.0)
        } else {
            h = 60.0 * (((r - g) / d) + 4.0)
        }
        if h < 0 { h += 360.0 }
        let s = maxC < 1e-6 ? 0.0 : (d / maxC)
        return (h, s, maxC)
    }
}

public enum ToolbarGroup: String, CaseIterable, Sendable {
    case tools
    case colors
    case edit
    case output
    case file

    public var title: String {
        switch self {
        case .tools: return "工具"
        case .colors: return "颜色"
        case .edit: return "编辑"
        case .output: return "输出"
        case .file: return "文件"
        }
    }

    public var slots: [ToolbarSlot] {
        switch self {
        case .tools:
            return AnnotationTool.allOrdered.map { .tool($0) }
        case .colors:
            return (0..<ColorPalette.swatchCount).map { .color($0) }
        case .edit:
            return [.fill, .undo, .redo, .textRow]
        case .output:
            return [.pin, .longshot, .ocr]
        case .file:
            return [.copy, .save]
        }
    }
}

public enum ToolbarSlot: Equatable, Hashable, Sendable {
    case tool(AnnotationTool)
    case color(Int)
    case fill
    case undo
    case redo
    case textRow
    case pin
    case longshot
    case ocr
    case copy
    case save

    public static var allOrdered: [ToolbarSlot] {
        ToolbarGroup.allCases.flatMap { $0.slots }
    }

    public var key: String {
        switch self {
        case .tool(.rect): return "tool.rect"
        case .tool(.arrow): return "tool.arrow"
        case .tool(.text): return "tool.text"
        case .tool(.highlight): return "tool.highlight"
        case .tool(.blur): return "tool.blur"
        case .tool(.glow): return "tool.glow"
        case .tool(.number): return "tool.number"
        case .tool(.line): return "tool.line"
        case .tool(.ellipse): return "tool.ellipse"
        case .tool(.freehand): return "tool.freehand"
        case .color(let idx) where (0..<ColorPalette.swatchCount).contains(idx):
            return "color.\(idx + 1)"
        case .color:
            return "color.unused"
        case .fill: return "edit.fill"
        case .undo: return "edit.undo"
        case .redo: return "edit.redo"
        case .textRow: return "edit.text_row"
        case .pin: return "output.pin"
        case .longshot: return "output.longshot"
        case .ocr: return "output.ocr"
        case .copy: return "file.copy"
        case .save: return "file.save"
        }
    }

    public var label: String {
        switch self {
        case .tool(let t): return t.shortLabel
        case .color(let idx) where (0..<ColorPalette.swatchCount).contains(idx):
            return "颜色\(idx + 1)"
        case .color: return "颜色"
        case .fill: return "填充"
        case .undo: return "撤销"
        case .redo: return "重做"
        case .textRow: return "字体行"
        case .pin: return "贴图"
        case .longshot: return "长截图"
        case .ocr: return "OCR"
        case .copy: return "复制"
        case .save: return "保存"
        }
    }

    public var group: ToolbarGroup {
        switch self {
        case .tool: return .tools
        case .color: return .colors
        case .fill, .undo, .redo, .textRow: return .edit
        case .pin, .longshot, .ocr: return .output
        case .copy, .save: return .file
        }
    }
}

public enum ToolbarGroupState: Equatable, Sendable {
    case all
    case partial
    case none
}

public struct ToolbarVisibilityConfig: Codable, Equatable, Sendable {
    public var hidden: [String]

    public init(hidden: [String] = []) {
        self.hidden = hidden
    }

    public func isVisible(_ slot: ToolbarSlot) -> Bool {
        !hidden.contains(slot.key)
    }

    public mutating func setVisible(_ slot: ToolbarSlot, _ visible: Bool) {
        let k = slot.key
        if visible {
            hidden.removeAll { $0 == k }
        } else if isVisible(slot) {
            hidden.append(k)
        }
    }

    public func visibleCount(in group: ToolbarGroup) -> Int {
        group.slots.filter { isVisible($0) }.count
    }

    public func groupState(_ group: ToolbarGroup) -> ToolbarGroupState {
        let c = visibleCount(in: group)
        if c == 0 { return .none }
        if c == group.slots.count { return .all }
        return .partial
    }

    public mutating func setGroupVisible(_ group: ToolbarGroup, _ visible: Bool) {
        for s in group.slots {
            setVisible(s, visible)
        }
    }

    public var isEntireToolbarHidden: Bool {
        ToolbarSlot.allOrdered.allSatisfy { !isVisible($0) }
    }

    public func settleTool(_ preferred: AnnotationTool) -> AnnotationTool {
        if isVisible(.tool(preferred)) { return preferred }
        return AnnotationTool.allOrdered.first(where: { isVisible(.tool($0)) }) ?? preferred
    }

    public func settleColorIndex(_ preferred: Int) -> Int {
        if isVisible(.color(preferred)) { return preferred }
        return (0..<ColorPalette.swatchCount).first(where: { isVisible(.color($0)) }) ?? preferred
    }
}

public enum MouseExtraButton: Int, Codable, Equatable, Hashable, Sendable {
    case middle = 2
    case side1 = 3
    case side2 = 4

    public var displayName: String {
        switch self {
        case .middle: return "鼠标中键"
        case .side1: return "鼠标侧键 1"
        case .side2: return "鼠标侧键 2"
        }
    }
}

public struct HotkeyModifiers: OptionSet, Codable, Equatable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = HotkeyModifiers(rawValue: 1 << 0)
    public static let control = HotkeyModifiers(rawValue: 1 << 1)
    public static let option  = HotkeyModifiers(rawValue: 1 << 2)
    public static let shift   = HotkeyModifiers(rawValue: 1 << 3)

    public var isEmptyModifiers: Bool { rawValue == 0 }

    public var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.command) { flags |= UInt32(cmdKey) }
        if contains(.control) { flags |= UInt32(controlKey) }
        if contains(.option)  { flags |= UInt32(optionKey) }
        if contains(.shift)   { flags |= UInt32(shiftKey) }
        return flags
    }

    public var displayPrefix: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option)  { s += "⌥" }
        if contains(.shift)   { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

public struct HotkeyBinding: Codable, Equatable, Hashable, Sendable {
    public var keyCode: Int? // Carbon virtual key code, nil if unbound or mouse button
    public var modifiers: HotkeyModifiers
    public var mouseButton: MouseExtraButton?

    public init(keyCode: Int? = nil, modifiers: HotkeyModifiers = [], mouseButton: MouseExtraButton? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.mouseButton = mouseButton
    }

    public static let unbound = HotkeyBinding(keyCode: nil, modifiers: [], mouseButton: nil)

    public var isUnbound: Bool {
        keyCode == nil && mouseButton == nil
    }

    public var hasNoModifierWarning: Bool {
        guard let kc = keyCode, mouseButton == nil else { return false }
        let _ = kc
        return modifiers.isEmptyModifiers
    }

    public var displayString: String {
        if let mb = mouseButton {
            return mb.displayName
        }
        guard let kc = keyCode else {
            return "未设置"
        }
        return modifiers.displayPrefix + KeyCodeLabels.name(for: kc)
    }
}

public enum KeyCodeLabels {
    public static func name(for keyCode: Int) -> String {
        switch keyCode {
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Return: return "Enter"
        case kVK_Escape: return "Esc"
        case kVK_Tab: return "Tab"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_Grave: return "`"
        default: return "Key(\(keyCode))"
        }
    }
}

public struct HotkeyConfig: Codable, Equatable, Sendable {
    public var screenshot: HotkeyBinding
    public var longshotCapture: HotkeyBinding
    public var ocrCapture: HotkeyBinding
    public var pin: HotkeyBinding
    public var pinBorderToggle: HotkeyBinding
    public var recapture: HotkeyBinding
    public var longshot: HotkeyBinding
    public var ocr: HotkeyBinding

    public init(
        screenshot: HotkeyBinding = HotkeyBinding(keyCode: kVK_F1, modifiers: []),
        longshotCapture: HotkeyBinding = HotkeyBinding(keyCode: kVK_F4, modifiers: []),
        ocrCapture: HotkeyBinding = HotkeyBinding(keyCode: kVK_F2, modifiers: []),
        pin: HotkeyBinding = HotkeyBinding(keyCode: kVK_F3, modifiers: []),
        pinBorderToggle: HotkeyBinding = HotkeyBinding(keyCode: kVK_F3, modifiers: [.control]),
        recapture: HotkeyBinding = HotkeyBinding(keyCode: kVK_F1, modifiers: [.shift]),
        longshot: HotkeyBinding = HotkeyBinding(keyCode: kVK_ANSI_S, modifiers: []),
        ocr: HotkeyBinding = HotkeyBinding(keyCode: kVK_ANSI_T, modifiers: [])
    ) {
        self.screenshot = screenshot
        self.longshotCapture = longshotCapture
        self.ocrCapture = ocrCapture
        self.pin = pin
        self.pinBorderToggle = pinBorderToggle
        self.recapture = recapture
        self.longshot = longshot
        self.ocr = ocr
    }

    private enum CodingKeys: String, CodingKey {
        case screenshot, longshotCapture, ocrCapture, pin, pinBorderToggle, recapture, longshot, ocr
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = HotkeyConfig()
        let ss = try c.decodeIfPresent(HotkeyBinding.self, forKey: .screenshot) ?? defaults.screenshot
        let oc = try c.decodeIfPresent(HotkeyBinding.self, forKey: .ocrCapture) ?? defaults.ocrCapture
        let pn = try c.decodeIfPresent(HotkeyBinding.self, forKey: .pin) ?? defaults.pin
        let pb = try c.decodeIfPresent(HotkeyBinding.self, forKey: .pinBorderToggle) ?? defaults.pinBorderToggle
        self.screenshot = ss
        self.ocrCapture = oc
        self.pin = pn
        self.pinBorderToggle = pb
        if let decodedLS = try c.decodeIfPresent(HotkeyBinding.self, forKey: .longshotCapture) {
            self.longshotCapture = decodedLS
        } else {
            let existingGlobals = [ss, oc, pn, pb]
            self.longshotCapture = existingGlobals.contains(defaults.longshotCapture) ? .unbound : defaults.longshotCapture
        }
        self.recapture = try c.decodeIfPresent(HotkeyBinding.self, forKey: .recapture) ?? defaults.recapture
        self.longshot = try c.decodeIfPresent(HotkeyBinding.self, forKey: .longshot) ?? defaults.longshot
        self.ocr = try c.decodeIfPresent(HotkeyBinding.self, forKey: .ocr) ?? defaults.ocr
    }
}

public enum LongshotScrollSpeed: String, Codable, CaseIterable, Sendable {
    case slow = "slow"
    case normal = "normal"
    case fast = "fast"

    public var title: String {
        switch self {
        case .slow: return "慢"
        case .normal: return "标准"
        case .fast: return "快"
        }
    }

    public var viewportStepFraction: Double {
        switch self {
        case .slow: return 0.20
        case .normal: return 0.30
        case .fast: return 0.40
        }
    }

    public var settleMilliseconds: UInt64 {
        switch self {
        case .slow: return 190
        case .normal: return 155
        case .fast: return 130
        }
    }

    public var next: LongshotScrollSpeed {
        switch self {
        case .slow: return .normal
        case .normal: return .fast
        case .fast: return .slow
        }
    }
}

public struct ToolKeysConfig: Codable, Equatable, Sendable {
    public var keys: [Int: HotkeyBinding]

    public init() {
        self.keys = [
            AnnotationTool.rect.rawValue: HotkeyBinding(keyCode: kVK_ANSI_1),
            AnnotationTool.arrow.rawValue: HotkeyBinding(keyCode: kVK_ANSI_2),
            AnnotationTool.text.rawValue: HotkeyBinding(keyCode: kVK_ANSI_3),
            AnnotationTool.highlight.rawValue: HotkeyBinding(keyCode: kVK_ANSI_4),
            AnnotationTool.blur.rawValue: HotkeyBinding(keyCode: kVK_ANSI_5),
            AnnotationTool.glow.rawValue: HotkeyBinding(keyCode: kVK_ANSI_6),
            AnnotationTool.number.rawValue: HotkeyBinding(keyCode: kVK_ANSI_7),
            AnnotationTool.line.rawValue: HotkeyBinding(keyCode: kVK_ANSI_8),
            AnnotationTool.ellipse.rawValue: HotkeyBinding(keyCode: kVK_ANSI_9),
            AnnotationTool.freehand.rawValue: HotkeyBinding(keyCode: kVK_ANSI_0),
        ]
    }

    public func binding(for tool: AnnotationTool) -> HotkeyBinding {
        keys[tool.rawValue] ?? .unbound
    }

    public mutating func setBinding(_ binding: HotkeyBinding, for tool: AnnotationTool) {
        keys[tool.rawValue] = binding
    }
}

public enum ThemeSetting: String, Codable, CaseIterable, Sendable {
    case follow
    case light
    case dark

    public var title: String {
        switch self {
        case .follow: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

public enum PinPosition: String, Codable, CaseIterable, Sendable {
    case original
    case center

    public var title: String {
        switch self {
        case .original: return "原位置"
        case .center: return "屏幕居中"
        }
    }
}

public enum NameStyle: String, Codable, CaseIterable, Sendable {
    case datetime
    case timestamp
    case date

    public var title: String {
        switch self {
        case .datetime: return "日期时间"
        case .timestamp: return "时间戳"
        case .date: return "仅日期"
        }
    }

    public func formatBaseName(date: Date = Date()) -> String {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let y = comps.year ?? 2026
        let m = comps.month ?? 1
        let d = comps.day ?? 1
        let hh = comps.hour ?? 0
        let mm = comps.minute ?? 0
        let ss = comps.second ?? 0
        switch self {
        case .datetime:
            return String(format: "isnip-%04d%02d%02d-%02d%02d%02d", y, m, d, hh, mm, ss)
        case .timestamp:
            return "\(Int64(date.timeIntervalSince1970 * 1000.0))"
        case .date:
            return String(format: "isnip-%04d%02d%02d", y, m, d)
        }
    }
}

public enum PngCompressionQualityPreset: String, Codable, CaseIterable, Sendable {
    case visuallyLossless = "default"
    case balanced = "65-90"
    case compact = "45-75"

    public var title: String {
        switch self {
        case .visuallyLossless: return "视觉无损（默认）"
        case .balanced: return "均衡（65–90）"
        case .compact: return "高压缩（45–75）"
        }
    }

    public var shortTitle: String {
        switch self {
        case .visuallyLossless: return "视觉无损"
        case .balanced: return "均衡 65–90"
        case .compact: return "高压缩 45–75"
        }
    }

    public var qualityArgument: String? {
        switch self {
        case .visuallyLossless: return nil
        case .balanced: return "65-90"
        case .compact: return "45-75"
        }
    }
}

public enum UiScaleSetting: String, Codable, CaseIterable, Sendable {
    case auto = "auto"
    case p100 = "100"
    case p125 = "125"
    case p150 = "150"

    public var title: String {
        switch self {
        case .auto: return "自动"
        case .p100: return "100%"
        case .p125: return "125%"
        case .p150: return "150%"
        }
    }

    public var factor: Double {
        switch self {
        case .auto, .p100: return 1.0
        case .p125: return 1.25
        case .p150: return 1.5
        }
    }
}

public struct OcrConfig: Codable, Equatable, Sendable {
    public var autoCopy: Bool
    public var language: String // "auto", "zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"
    public var mergeLineBreaks: Bool
    public var detectBarcodes: Bool

    public init(
        autoCopy: Bool = false,
        language: String = "auto",
        mergeLineBreaks: Bool = false,
        detectBarcodes: Bool = true
    ) {
        self.autoCopy = autoCopy
        self.language = language
        self.mergeLineBreaks = mergeLineBreaks
        self.detectBarcodes = detectBarcodes
    }

    private enum CodingKeys: String, CodingKey {
        case autoCopy, language, mergeLineBreaks, detectBarcodes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.autoCopy = try c.decodeIfPresent(Bool.self, forKey: .autoCopy) ?? false
        self.language = try c.decodeIfPresent(String.self, forKey: .language) ?? "auto"
        self.mergeLineBreaks = try c.decodeIfPresent(Bool.self, forKey: .mergeLineBreaks) ?? false
        self.detectBarcodes = try c.decodeIfPresent(Bool.self, forKey: .detectBarcodes) ?? true
    }

    public static let supportedOptions: [(tag: String, label: String)] = [
        ("auto", "自动"),
        ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁体中文"),
        ("en-US", "English"),
        ("ja-JP", "日本語"),
        ("ko-KR", "한국어"),
    ]

    public static let compactOptions: [(tag: String, shortLabel: String)] = [
        ("auto", "自动"),
        ("zh-Hans", "简中"),
        ("zh-Hant", "繁中"),
        ("en-US", "English"),
        ("ja-JP", "日本語"),
        ("ko-KR", "한국어"),
    ]
}

public struct AirSnipConfig: Codable, Equatable, Sendable {
    public var autoStart: Bool
    public var theme: ThemeSetting
    public var hotkeys: HotkeyConfig
    public var toolKeys: ToolKeysConfig
    public var pinPosition: PinPosition
    public var pinBorder: Bool
    public var pinMaxCount: Int
    public var uiScale: UiScaleSetting
    public var swatchColors: [RGBAColor]
    public var activeColorIndex: Int
    public var lastTool: AnnotationTool
    public var defaultLineWidth: Double
    public var defaultFillEnabled: Bool
    public var defaultBlurRadius: Double
    public var defaultFontSize: Double
    public var defaultFontFamily: String
    public var defaultFontBold: Bool
    public var defaultFontItalic: Bool
    public var defaultNumberFontSize: Double
    public var styleDefaultsMigratedV2: Bool
    public var windowSnap: Bool
    public var confirmCancel: Bool
    public var showCompletionToast: Bool
    public var toolbar: ToolbarVisibilityConfig
    public var nameStyle: NameStyle
    public var lastSaveFormat: ExportImageFormat
    public var lastSaveDirectory: String?
    public var askBeforeSave: Bool
    public var smartPngCompression: Bool
    public var pngCompressionQuality: PngCompressionQualityPreset
    public var compressClipboardPng: Bool
    public var longshotMaxHeight: Int
    public var longshotAutoScroll: Bool
    public var longshotScrollSpeed: LongshotScrollSpeed
    public var autoCheckUpdate: Bool
    public var skippedVersion: String?
    public var ocr: OcrConfig

    public init(
        autoStart: Bool = false,
        theme: ThemeSetting = .follow,
        hotkeys: HotkeyConfig = HotkeyConfig(),
        toolKeys: ToolKeysConfig = ToolKeysConfig(),
        pinPosition: PinPosition = .original,
        pinBorder: Bool = true,
        pinMaxCount: Int = 20,
        uiScale: UiScaleSetting = .auto,
        swatchColors: [RGBAColor] = ColorPalette.defaultSwatches,
        activeColorIndex: Int = 1,
        lastTool: AnnotationTool = .rect,
        defaultLineWidth: Double = 2.0,
        defaultFillEnabled: Bool = false,
        defaultBlurRadius: Double = 16.0,
        defaultFontSize: Double = 24.0,
        defaultFontFamily: String = "PingFang SC",
        defaultFontBold: Bool = false,
        defaultFontItalic: Bool = false,
        defaultNumberFontSize: Double = 20.0,
        styleDefaultsMigratedV2: Bool = true,
        windowSnap: Bool = true,
        confirmCancel: Bool = true,
        showCompletionToast: Bool = true,
        toolbar: ToolbarVisibilityConfig = ToolbarVisibilityConfig(),
        nameStyle: NameStyle = .datetime,
        lastSaveFormat: ExportImageFormat = .png,
        lastSaveDirectory: String? = nil,
        askBeforeSave: Bool = false,
        smartPngCompression: Bool = true,
        pngCompressionQuality: PngCompressionQualityPreset = .visuallyLossless,
        compressClipboardPng: Bool = true,
        longshotMaxHeight: Int = 30000,
        longshotAutoScroll: Bool = true,
        longshotScrollSpeed: LongshotScrollSpeed = .normal,
        autoCheckUpdate: Bool = true,
        skippedVersion: String? = nil,
        ocr: OcrConfig = OcrConfig()
    ) {
        self.autoStart = autoStart
        self.theme = theme
        self.hotkeys = hotkeys
        self.toolKeys = toolKeys
        self.pinPosition = pinPosition
        self.pinBorder = pinBorder
        self.pinMaxCount = pinMaxCount
        self.uiScale = uiScale
        self.swatchColors = swatchColors.count == ColorPalette.swatchCount ? swatchColors : ColorPalette.defaultSwatches
        self.activeColorIndex = max(0, min(ColorPalette.swatchCount - 1, activeColorIndex))
        self.lastTool = lastTool
        self.defaultLineWidth = defaultLineWidth
        self.defaultFillEnabled = defaultFillEnabled
        self.defaultBlurRadius = defaultBlurRadius
        self.defaultFontSize = defaultFontSize
        self.defaultFontFamily = defaultFontFamily
        self.defaultFontBold = defaultFontBold
        self.defaultFontItalic = defaultFontItalic
        self.defaultNumberFontSize = defaultNumberFontSize
        self.styleDefaultsMigratedV2 = styleDefaultsMigratedV2
        self.windowSnap = windowSnap
        self.confirmCancel = confirmCancel
        self.showCompletionToast = showCompletionToast
        self.toolbar = toolbar
        self.nameStyle = nameStyle
        self.lastSaveFormat = lastSaveFormat
        self.lastSaveDirectory = lastSaveDirectory
        self.askBeforeSave = askBeforeSave
        self.smartPngCompression = smartPngCompression
        self.pngCompressionQuality = pngCompressionQuality
        self.compressClipboardPng = compressClipboardPng
        self.longshotMaxHeight = max(2000, longshotMaxHeight)
        self.longshotAutoScroll = longshotAutoScroll
        self.longshotScrollSpeed = longshotScrollSpeed
        self.autoCheckUpdate = autoCheckUpdate
        self.skippedVersion = skippedVersion
        self.ocr = ocr
    }

    private enum CodingKeys: String, CodingKey {
        case autoStart, theme, hotkeys, toolKeys, pinPosition, pinBorder, pinMaxCount, uiScale
        case swatchColors, activeColorIndex, lastTool, defaultLineWidth, defaultFillEnabled
        case defaultBlurRadius, defaultFontSize, defaultFontFamily, defaultFontBold, defaultFontItalic, defaultNumberFontSize
        case styleDefaultsMigratedV2
        case windowSnap, confirmCancel, showCompletionToast
        case toolbar, nameStyle, lastSaveFormat, lastSaveDirectory, askBeforeSave
        case smartPngCompression, pngCompressionQuality, compressClipboardPng
        case longshotMaxHeight, longshotAutoScroll, longshotScrollSpeed
        case autoCheckUpdate, skippedVersion, ocr
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AirSnipConfig()
        self.autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? d.autoStart
        self.theme = try c.decodeIfPresent(ThemeSetting.self, forKey: .theme) ?? d.theme
        self.hotkeys = try c.decodeIfPresent(HotkeyConfig.self, forKey: .hotkeys) ?? d.hotkeys
        self.toolKeys = try c.decodeIfPresent(ToolKeysConfig.self, forKey: .toolKeys) ?? d.toolKeys
        self.pinPosition = try c.decodeIfPresent(PinPosition.self, forKey: .pinPosition) ?? d.pinPosition
        self.pinBorder = try c.decodeIfPresent(Bool.self, forKey: .pinBorder) ?? d.pinBorder
        self.pinMaxCount = try c.decodeIfPresent(Int.self, forKey: .pinMaxCount) ?? d.pinMaxCount
        self.uiScale = try c.decodeIfPresent(UiScaleSetting.self, forKey: .uiScale) ?? d.uiScale
        let alreadyMigratedV2 = try c.decodeIfPresent(Bool.self, forKey: .styleDefaultsMigratedV2) ?? false
        var decodedSwatches = try c.decodeIfPresent([RGBAColor].self, forKey: .swatchColors) ?? d.swatchColors
        if decodedSwatches.count != ColorPalette.swatchCount {
            decodedSwatches = ColorPalette.defaultSwatches
        } else if !alreadyMigratedV2 && decodedSwatches[1] == RGBAColor(r: 229, g: 57, b: 53) {
            decodedSwatches[1] = RGBAColor(r: 255, g: 0, b: 0)
        }
        self.swatchColors = decodedSwatches
        self.activeColorIndex = max(0, min(ColorPalette.swatchCount - 1, try c.decodeIfPresent(Int.self, forKey: .activeColorIndex) ?? d.activeColorIndex))
        self.lastTool = try c.decodeIfPresent(AnnotationTool.self, forKey: .lastTool) ?? d.lastTool
        let rawLineWidth = try c.decodeIfPresent(Double.self, forKey: .defaultLineWidth)
        if !alreadyMigratedV2 && rawLineWidth == 4.0 {
            self.defaultLineWidth = 2.0
        } else {
            self.defaultLineWidth = rawLineWidth ?? d.defaultLineWidth
        }
        self.defaultFillEnabled = try c.decodeIfPresent(Bool.self, forKey: .defaultFillEnabled) ?? d.defaultFillEnabled
        self.defaultBlurRadius = try c.decodeIfPresent(Double.self, forKey: .defaultBlurRadius) ?? d.defaultBlurRadius
        self.defaultFontSize = try c.decodeIfPresent(Double.self, forKey: .defaultFontSize) ?? d.defaultFontSize
        self.defaultFontFamily = try c.decodeIfPresent(String.self, forKey: .defaultFontFamily) ?? d.defaultFontFamily
        self.defaultFontBold = try c.decodeIfPresent(Bool.self, forKey: .defaultFontBold) ?? d.defaultFontBold
        self.defaultFontItalic = try c.decodeIfPresent(Bool.self, forKey: .defaultFontItalic) ?? d.defaultFontItalic
        self.defaultNumberFontSize = try c.decodeIfPresent(Double.self, forKey: .defaultNumberFontSize) ?? d.defaultNumberFontSize
        self.styleDefaultsMigratedV2 = true
        self.windowSnap = try c.decodeIfPresent(Bool.self, forKey: .windowSnap) ?? d.windowSnap
        self.confirmCancel = try c.decodeIfPresent(Bool.self, forKey: .confirmCancel) ?? d.confirmCancel
        self.showCompletionToast = try c.decodeIfPresent(Bool.self, forKey: .showCompletionToast) ?? d.showCompletionToast
        self.toolbar = try c.decodeIfPresent(ToolbarVisibilityConfig.self, forKey: .toolbar) ?? d.toolbar
        self.nameStyle = try c.decodeIfPresent(NameStyle.self, forKey: .nameStyle) ?? d.nameStyle
        self.lastSaveFormat = try c.decodeIfPresent(ExportImageFormat.self, forKey: .lastSaveFormat) ?? d.lastSaveFormat
        self.lastSaveDirectory = try c.decodeIfPresent(String.self, forKey: .lastSaveDirectory)
        self.askBeforeSave = try c.decodeIfPresent(Bool.self, forKey: .askBeforeSave) ?? false
        self.smartPngCompression = try c.decodeIfPresent(Bool.self, forKey: .smartPngCompression) ?? true
        self.pngCompressionQuality = try c.decodeIfPresent(PngCompressionQualityPreset.self, forKey: .pngCompressionQuality) ?? .visuallyLossless
        self.compressClipboardPng = try c.decodeIfPresent(Bool.self, forKey: .compressClipboardPng) ?? true
        self.longshotMaxHeight = max(2000, min(100000, try c.decodeIfPresent(Int.self, forKey: .longshotMaxHeight) ?? d.longshotMaxHeight))
        self.longshotAutoScroll = try c.decodeIfPresent(Bool.self, forKey: .longshotAutoScroll) ?? d.longshotAutoScroll
        self.longshotScrollSpeed = try c.decodeIfPresent(LongshotScrollSpeed.self, forKey: .longshotScrollSpeed) ?? d.longshotScrollSpeed
        self.autoCheckUpdate = try c.decodeIfPresent(Bool.self, forKey: .autoCheckUpdate) ?? d.autoCheckUpdate
        self.skippedVersion = try c.decodeIfPresent(String.self, forKey: .skippedVersion)
        self.ocr = try c.decodeIfPresent(OcrConfig.self, forKey: .ocr) ?? d.ocr
    }

    public static func defaultConfigFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("iSnip", isDirectory: true).appendingPathComponent("config.json")
    }

    public static func legacyConfigFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AirSnip", isDirectory: true).appendingPathComponent("config.json")
    }

    public static func load(from url: URL = defaultConfigFileURL()) -> AirSnipConfig {
        let fm = FileManager.default
        if url == defaultConfigFileURL(), !fm.fileExists(atPath: url.path) {
            let legacy = legacyConfigFileURL()
            if fm.fileExists(atPath: legacy.path) {
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.copyItem(at: legacy, to: url)
            }
        }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(AirSnipConfig.self, from: data) else {
            return AirSnipConfig()
        }
        var sanitized = decoded
        if sanitized.swatchColors.count != ColorPalette.swatchCount {
            sanitized.swatchColors = ColorPalette.defaultSwatches
        }
        sanitized.activeColorIndex = max(0, min(ColorPalette.swatchCount - 1, sanitized.activeColorIndex))
        sanitized.pinMaxCount = max(1, min(50, sanitized.pinMaxCount))
        sanitized.longshotMaxHeight = max(2000, min(100000, sanitized.longshotMaxHeight))
        if let rawObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (rawObj["styleDefaultsMigratedV2"] as? Bool) != true {
            try? sanitized.save(to: url)
        }
        return sanitized
    }

    public func save(to url: URL = Self.defaultConfigFileURL()) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    /// Detects duplicate bindings within global scope or within overlay scope.
    public func hotkeyConflicts() -> [String] {
        var conflicts: [String] = []
        let globalList: [(String, HotkeyBinding)] = [
            ("截图", hotkeys.screenshot),
            ("页面长截图", hotkeys.longshotCapture),
            ("截图识字", hotkeys.ocrCapture),
            ("贴图", hotkeys.pin),
            ("贴图边框", hotkeys.pinBorderToggle),
        ]
        for i in 0..<globalList.count {
            for j in (i + 1)..<globalList.count {
                if !globalList[i].1.isUnbound && globalList[i].1 == globalList[j].1 {
                    conflicts.append("\(globalList[i].0) 与 \(globalList[j].0) 冲突（\(globalList[i].1.displayString)）")
                }
            }
        }

        var overlayList: [(String, HotkeyBinding)] = [
            ("重新抓屏", hotkeys.recapture),
            ("长截图", hotkeys.longshot),
            ("OCR", hotkeys.ocr),
        ]
        for tool in AnnotationTool.allOrdered {
            overlayList.append((tool.shortLabel, toolKeys.binding(for: tool)))
        }
        for i in 0..<overlayList.count {
            for j in (i + 1)..<overlayList.count {
                if !overlayList[i].1.isUnbound && overlayList[i].1 == overlayList[j].1 {
                    conflicts.append("\(overlayList[i].0) 与 \(overlayList[j].0) 冲突（\(overlayList[i].1.displayString)）")
                }
            }
        }
        return conflicts
    }
}
