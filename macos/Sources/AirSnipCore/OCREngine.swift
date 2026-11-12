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
        for var row in rows {
            row.sort { $0.left < $1.left }
            let words = row
                .flatMap { $0.words }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if words.isEmpty { continue }
            if !output.isEmpty { output.append("\n") }
            for (i, w) in words.enumerated() {
                if i > 0 && needSpace(between: words[i - 1], and: w) {
                    output.append(" ")
                }
                output.append(w)
            }
        }
        return stripCJKSpaces(output)
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
        let width = Double(cgImage.width)
        let height = Double(cgImage.height)

        var collectedSegments: [OCRTextSegment] = []
        var capturedError: Error?

        let request = VNRecognizeTextRequest { req, err in
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
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        if languagePreference == "auto" || languagePreference.isEmpty {
            request.automaticallyDetectsLanguage = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]
        } else {
            request.automaticallyDetectsLanguage = false
            switch languagePreference {
            case "zh-Hans":
                request.recognitionLanguages = ["zh-Hans", "en-US"]
            case "zh-Hant":
                request.recognitionLanguages = ["zh-Hant", "en-US"]
            default:
                request.recognitionLanguages = [languagePreference, "en-US"]
            }
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        if let capturedError {
            throw capturedError
        }
        return OCRLinesJoiner.joinSegments(collectedSegments)
    }
}
