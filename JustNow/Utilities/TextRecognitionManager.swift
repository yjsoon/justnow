//
//  TextRecognitionManager.swift
//  JustNow
//

import Foundation
import ImageIO
import Vision
import VisionKit
import os.log

enum TextRecognitionMode: Sendable {
    case searchIndex
    case selection
}

/// Performs OCR for both background search indexing and user-driven text grabs.
nonisolated enum TextRecognitionManager {
    private static let logger = Logger(subsystem: "sg.tk.JustNow", category: "TextRecognition")

    /// Fast OCR used for background indexing.
    @concurrent
    @Sendable
    static func extractText(from image: CGImage) async -> String {
        await extractText(from: image, mode: .searchIndex)
    }

    @concurrent
    @Sendable
    static func extractText(from image: CGImage, mode: TextRecognitionMode) async -> String {
        guard !Task.isCancelled else { return "" }

        switch mode {
        case .searchIndex:
            let text = await extractVisionText(
                from: image,
                recognitionLevel: .fast,
                usesLanguageCorrection: false,
                automaticallyDetectsLanguage: false
            )
            return collapseInlineWhitespace(text)
        case .selection:
            if let transcript = await extractImageAnalyzerTranscript(from: image) {
                let normalisedTranscript = normaliseClipboardText(transcript)
                if !normalisedTranscript.isEmpty {
                    Self.logger.debug("Selection OCR resolved via ImageAnalyzer")
                    return normalisedTranscript
                }
            }

            let text = await extractVisionText(
                from: image,
                recognitionLevel: .accurate,
                usesLanguageCorrection: true,
                automaticallyDetectsLanguage: true
            )
            return normaliseClipboardText(text)
        }
    }

    @concurrent
    @Sendable
    static func extractSearchLayout(from image: CGImage) async -> SearchTextLayout? {
        guard !Task.isCancelled else { return nil }

        let request = makeRecogniseTextRequest(
            recognitionLevel: .accurate,
            usesLanguageCorrection: true,
            automaticallyDetectsLanguage: true
        )
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        do {
            try handler.perform([request])
        } catch {
            Self.logger.error("Search layout Vision request failed: \(error.localizedDescription)")
            return nil
        }

        guard !Task.isCancelled else { return nil }

        let lines = request.results?.compactMap { observation in
            makeSearchTextLine(from: observation)
        } ?? []

        guard !lines.isEmpty else { return nil }
        return SearchTextLayout(lines: lines)
    }

    static func normaliseClipboardText(_ text: String) -> String {
        let normalisedLineEndings = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let rawLines = normalisedLineEndings.components(separatedBy: "\n")
        var result = ""
        var previousLine = ""
        var shouldPreserveParagraphBreak = false

        for rawLine in rawLines {
            let line = collapseInlineWhitespace(rawLine)

            if line.isEmpty {
                shouldPreserveParagraphBreak = !result.isEmpty
                continue
            }

            if result.isEmpty {
                result = line
                previousLine = line
                shouldPreserveParagraphBreak = false
                continue
            }

            if previousLine.hasSuffix("-"), line.first?.isLetter == true {
                result.removeLast()
                result.append(contentsOf: line)
            } else if shouldPreserveParagraphBreak || shouldKeepLineBreak(between: previousLine, and: line) {
                result.append("\n")
                result.append(contentsOf: line)
            } else {
                result.append(" ")
                result.append(contentsOf: line)
            }

            previousLine = line
            shouldPreserveParagraphBreak = false
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Searches for text in a frame, returns true if found.
    @concurrent
    static func frameContainsText(_ searchText: String, in image: CGImage) async -> Bool {
        let extractedText = await extractText(from: image)
        let contains = extractedText.localizedCaseInsensitiveContains(searchText)
        if contains {
            Self.logger.info("Found '\(searchText)' in frame")
        }
        return contains
    }

    private static func collapseInlineWhitespace(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func shouldKeepLineBreak(between previousLine: String, and nextLine: String) -> Bool {
        looksLikeListItem(previousLine) || looksLikeListItem(nextLine) || previousLine.hasSuffix(":")
    }

    private static func looksLikeListItem(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return false }

        if ["•", "-", "*"].contains(first) {
            return trimmed.dropFirst().first?.isWhitespace == true
        }

        let digits = trimmed.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return false }
        let suffix = trimmed.dropFirst(digits.count)
        guard let marker = suffix.first else { return false }
        return [".", ")"].contains(marker) && suffix.dropFirst().first?.isWhitespace == true
    }

    private static func extractImageAnalyzerTranscript(from image: CGImage) async -> String? {
        guard ImageAnalyzer.isSupported else { return nil }

        var configuration = ImageAnalyzer.Configuration([.text])
        configuration.locales = Locale.preferredLanguages
        let analyzer = ImageAnalyzer()

        do {
            let analysis = try await analyzer.analyze(
                image,
                orientation: .up,
                configuration: configuration
            )
            let transcript = analysis.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else { return nil }
            return transcript
        } catch {
            Self.logger.error("ImageAnalyzer request failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func extractVisionText(
        from image: CGImage,
        recognitionLevel: VNRequestTextRecognitionLevel,
        usesLanguageCorrection: Bool,
        automaticallyDetectsLanguage: Bool
    ) async -> String {
        guard !Task.isCancelled else { return "" }

        let request = makeRecogniseTextRequest(
            recognitionLevel: recognitionLevel,
            usesLanguageCorrection: usesLanguageCorrection,
            automaticallyDetectsLanguage: automaticallyDetectsLanguage
        )
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        do {
            try handler.perform([request])
        } catch {
            Self.logger.error("Vision request failed: \(error.localizedDescription)")
            return ""
        }

        guard !Task.isCancelled else { return "" }

        guard let observations = request.results else {
            Self.logger.debug("No observations returned")
            return ""
        }

        let text = observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        Self.logger.debug("Extracted \(text.count) chars from image")
        if !text.isEmpty {
            Self.logger.debug("OCR sample: \(String(text.prefix(120)))")
        }
        return text
    }

    private static func makeRecogniseTextRequest(
        recognitionLevel: VNRequestTextRecognitionLevel,
        usesLanguageCorrection: Bool,
        automaticallyDetectsLanguage: Bool
    ) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = recognitionLevel
        request.usesLanguageCorrection = usesLanguageCorrection
        request.automaticallyDetectsLanguage = automaticallyDetectsLanguage
        request.recognitionLanguages = Locale.preferredLanguages
        return request
    }

    private static func makeSearchTextLine(from observation: VNRecognizedTextObservation) -> SearchTextLine? {
        guard let candidate = observation.topCandidates(1).first else { return nil }

        let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let rect = clampNormalisedRect(observation.boundingBox)
        guard !text.isEmpty, rect.width > 0, rect.height > 0 else { return nil }

        return SearchTextLine(
            text: text,
            rect: rect,
            words: makeSearchTextWords(from: candidate)
        )
    }

    private static func makeSearchTextWords(from candidate: VNRecognizedText) -> [SearchTextWord] {
        let text = candidate.string
        let ranges = tokenRanges(in: text)
        guard !ranges.isEmpty else { return [] }

        var words: [SearchTextWord] = []
        words.reserveCapacity(ranges.count)

        for range in ranges {
            let wordText = String(text[range])
            guard !wordText.isEmpty else { continue }

            do {
                guard let box = try candidate.boundingBox(for: range) else { continue }
                let rect = clampNormalisedRect(box.boundingBox)
                guard rect.width > 0, rect.height > 0 else { continue }
                words.append(SearchTextWord(text: wordText, rect: rect))
            } catch {
                continue
            }
        }

        return words
    }

    private static func tokenRanges(in text: String) -> [Range<String.Index>] {
        guard !text.isEmpty else { return [] }

        var ranges: [Range<String.Index>] = []
        var tokenStart: String.Index?
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character.isNumber {
                tokenStart = tokenStart ?? index
            } else if let start = tokenStart {
                ranges.append(start..<index)
                tokenStart = nil
            }
            index = text.index(after: index)
        }

        if let tokenStart {
            ranges.append(tokenStart..<text.endIndex)
        }

        return ranges
    }

    private static func clampNormalisedRect(_ rect: CGRect) -> CGRect {
        let maxX = min(max(rect.maxX, 0), 1)
        let maxY = min(max(rect.maxY, 0), 1)
        let minX = min(max(rect.minX, 0), maxX)
        let minY = min(max(rect.minY, 0), maxY)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
