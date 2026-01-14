//
//  TextRecognitionManager.swift
//  JustNow
//

import Vision
import os.log

private let logger = Logger(subsystem: "sg.tk.JustNow", category: "TextRecognition")

/// Performs on-demand OCR using Vision framework
enum TextRecognitionManager {

    /// Extracts text from a CGImage using VNRecognizeTextRequest
    @concurrent
    static func extractText(from image: CGImage) async -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast  // Much faster than .accurate
        request.usesLanguageCorrection = false  // Skip for speed

        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        do {
            try handler.perform([request])
        } catch {
            logger.error("Vision request failed: \(error.localizedDescription)")
            return ""
        }

        guard let observations = request.results else {
            logger.debug("No observations returned")
            return ""
        }

        // Combine all recognized text
        let text = observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")

        logger.debug("Extracted \(text.count) chars from image")
        print("[JustNow OCR] Extracted \(text.count) chars")
        if !text.isEmpty {
            print("[JustNow OCR] Sample: \(String(text.prefix(100)))")
        }
        return text
    }

    /// Searches for text in a frame, returns true if found
    static func frameContainsText(_ searchText: String, in image: CGImage) async -> Bool {
        let extractedText = await extractText(from: image)
        let contains = extractedText.localizedCaseInsensitiveContains(searchText)
        if contains {
            logger.info("Found '\(searchText)' in frame")
        }
        return contains
    }
}
