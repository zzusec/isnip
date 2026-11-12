import Foundation
import CoreGraphics
import Vision

public struct OCRTextSegment: Equatable, Sendable {
    public var left: Double
    public var top: Double
    public var bottom: Double
    public var words: [String]

    public init(left: Double, top: Double, bottom: Double, words: [String]) {
        self.left = left
        self.top = top
        self.bottom = bottom
        self.words = words
    }

    public var centerY: Double { (top + bottom) * 0.5 }
    public var height: Double { max(1.0, bottom - top) }
}

public struct OCRRecognitionResult: Equatable, Sendable {
    public var rawText: String
    public var paragraphText: String
    public var barcodes: [String]

    public init(rawText: String, paragraphText: String, barcodes: [String] = []) {
        self.rawText = rawText
        self.paragraphText = paragraphText
        self.barcodes = barcodes
    }

    public var isEmpty: Bool {
        rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && barcodes.isEmpty
    }
}

public enum OCRLinesJoiner {
    public static func joinSegments(_ input: [OCRTextSegment]) -> String {
        let sorted = input.sorted { $0.centerY < $1.centerY }
        var rows: [[OCRTextSegment]] = []

        for seg in sorted {
            if let lastRow = rows.last, let head = lastRow.first,
               abs(seg.centerY - head.centerY) <= max(head.height, seg.height) * 0.5 {
                rows[rows.count - 1].append(seg)
            } else {
                rows.append([seg])
            }
        }

        var output = ""
        var prevBottom: Double?

        for var row in rows {
            row.sort { $0.left < $1.left }
            let words = row
                .flatMap { $0.words }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if words.isEmpty { continue }

            let rowTop = row.map(\.top).min() ?? 0
            let rowBottom = row.map(\.bottom).max() ?? rowTop
            let rowHeight = max(1.0, rowBottom - rowTop)

            if !output.isEmpty {
                if let pb = prevBottom, (rowTop - pb) > rowHeight * 0.95 {
                    output.append("\n\n")
                } else {
                    output.append("\n")
                }
            }
            prevBottom = rowBottom

            for (i, w) in words.enumerated() {
                if i > 0 && needSpace(between: words[i - 1], and: w) {
                    output.append(" ")
                }
                output.append(w)
            }
        }
        return stripCJKSpaces(output)
    }

    /// Merges single-line soft wraps within paragraphs while keeping blank-line paragraph breaks and bullet lists intact.
    public static func mergeWrappedParagraphs(_ raw: String) -> String {
        let lines = raw.components(separatedBy: "\n")
        var paragraphs: [String] = []
        var current = ""

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !current.isEmpty {
                    paragraphs.append(current)
                    current = ""
                }
                continue
            }

            if current.isEmpty {
                current = trimmed
            } else if isListItemStart(trimmed) || endsWithHardSentenceStopAndShort(current) {
                paragraphs.append(current)
                current = trimmed
            } else {
                if current.hasSuffix("-") && !current.hasSuffix("--"),
                   let beforeHyphen = current.dropLast().last,
                   beforeHyphen.isLetter && !isCJK(beforeHyphen),
                   let nextFirst = trimmed.first, nextFirst.isLowercase {
                    current.removeLast()
                    current.append(trimmed)
                } else {
                    if needSpace(between: current, and: trimmed) {
                        current.append(" ")
                    }
                    current.append(trimmed)
                }
            }
        }
        if !current.isEmpty {
            paragraphs.append(current)
        }
        return stripCJKSpaces(paragraphs.joined(separator: "\n\n"))
    }

    private static func isListItemStart(_ s: String) -> Bool {
        let bullets: [Character] = ["•", "·", "-", "*", "—", "▪", "▸"]
        if let first = s.first, bullets.contains(first) {
            return true
        }
        // e.g. "1. ", "2) ", "(1)"
        if s.range(of: #"^(\(?\d+[\.\)、\)]|[一二三四五六七八九十]+[、\.])\s*"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    private static func endsWithHardSentenceStopAndShort(_ s: String) -> Bool {
        false
    }

    public static func stripCJKSpaces(_ src: String) -> String {
        let scalars = Array(src)
        var out = ""
        out.reserveCapacity(src.count)
        for i in 0..<scalars.count {
            let c = scalars[i]
            if c == " " {
                if i > 0 && i + 1 < scalars.count && isCJK(scalars[i - 1]) && isCJK(scalars[i + 1]) {
                    continue
                }
            }
            out.append(c)
        }
        return out
    }

    public static func needSpace(between prev: String, and next: String) -> Bool {
        guard let a = prev.last, let b = next.first else { return false }
        return !(isCJK(a) || isCJK(b))
    }

    public static func isCJK(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        switch v {
        case 0x3000...0x303F, // CJK punctuation
             0x3040...0x30FF, // Hiragana & Katakana
             0x3400...0x4DBF, // CJK Extension A
             0x4E00...0x9FFF, // CJK Unified Ideographs
             0xAC00...0xD7AF, // Hangul Syllables
             0xF900...0xFAFF, // CJK Compatibility Ideographs
             0xFF00...0xFFEF: // Fullwidth forms
            return true
        default:
            return false
        }
    }
}

public enum LocalVisionOCR {
    public static func recognize(cgImage: CGImage, languagePreference: String = "auto") throws -> String {
        let detailed = try recognizeDetailed(
            cgImage: cgImage,
            languagePreference: languagePreference,
            detectBarcodes: false
        )
        return detailed.rawText
    }

    public static func recognizeDetailed(
        cgImage: CGImage,
        languagePreference: String = "auto",
        detectBarcodes: Bool = true
    ) throws -> OCRRecognitionResult {
        let width = Double(cgImage.width)
        let height = Double(cgImage.height)

        var collectedSegments: [OCRTextSegment] = []
        var capturedError: Error?
        var detectedPayloads: [String] = []

        let textRequest = VNRecognizeTextRequest { req, err in
            if let err {
                capturedError = err
                return
            }
            guard let observations = req.results as? [VNRecognizedTextObservation] else { return }
            for obs in observations {
                guard let candidate = obs.topCandidates(1).first else { continue }
                let str = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !str.isEmpty else { continue }
                // Vision normalized bbox has origin at bottom-left (0..1)
                let box = obs.boundingBox
                let left = box.minX * width
                let top = (1.0 - box.maxY) * height
                let bottom = (1.0 - box.minY) * height
                collectedSegments.append(OCRTextSegment(left: left, top: top, bottom: bottom, words: [str]))
            }
        }
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true

        if languagePreference == "auto" || languagePreference.isEmpty {
            textRequest.automaticallyDetectsLanguage = true
            textRequest.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]
        } else {
            textRequest.automaticallyDetectsLanguage = false
            switch languagePreference {
            case "zh-Hans":
                textRequest.recognitionLanguages = ["zh-Hans", "en-US"]
            case "zh-Hant":
                textRequest.recognitionLanguages = ["zh-Hant", "en-US"]
            default:
                textRequest.recognitionLanguages = [languagePreference, "en-US"]
            }
        }

        var requests: [VNRequest] = [textRequest]

        if detectBarcodes {
            let barcodeRequest = VNDetectBarcodesRequest { req, _ in
                guard let results = req.results as? [VNBarcodeObservation] else { return }
                for item in results {
                    if let payload = item.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !payload.isEmpty,
                       !detectedPayloads.contains(payload) {
                        detectedPayloads.append(payload)
                    }
                }
            }
            requests.append(barcodeRequest)
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform(requests)
        if let capturedError {
            throw capturedError
        }

        let rawText = OCRLinesJoiner.joinSegments(collectedSegments)
        let paragraphText = OCRLinesJoiner.mergeWrappedParagraphs(rawText)
        return OCRRecognitionResult(
            rawText: rawText,
            paragraphText: paragraphText,
            barcodes: detectedPayloads
        )
    }
}
