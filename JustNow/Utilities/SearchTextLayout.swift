//
//  SearchTextLayout.swift
//  JustNow
//

import CoreGraphics
import Foundation

nonisolated enum SearchQueryTokeniser {
    static func tokens(from query: String) -> [String] {
        query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

nonisolated struct SearchTextLayout: Codable, Sendable {
    let lines: [SearchTextLine]

    var isEmpty: Bool {
        lines.isEmpty
    }

    func highlightRects(matching query: String) -> [CGRect] {
        let queryTokens = SearchQueryTokeniser.tokens(from: query)
        let lowercasedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !queryTokens.isEmpty else {
            guard !lowercasedQuery.isEmpty else { return [] }
            return lines.compactMap { line in
                line.text.lowercased().contains(lowercasedQuery) ? line.rect : nil
            }
        }

        var rects: [CGRect] = []
        rects.reserveCapacity(lines.count)

        // Single pass: collect word-level rects when we can, fall back to the
        // line rect when the query matches the line as a whole. Each word and
        // line is tokenised at most once per call.
        for line in lines {
            var lineHasWordHit = false
            for word in line.words {
                let wordTokens = SearchQueryTokeniser.tokens(from: word.text)
                guard tokensMatch(wordTokens, anyOf: queryTokens) else { continue }
                rects.append(word.rect)
                lineHasWordHit = true
            }

            if lineHasWordHit {
                continue
            }

            let lineTokens = SearchQueryTokeniser.tokens(from: line.text)
            if tokensMatch(lineTokens, anyOf: queryTokens) {
                rects.append(line.rect)
            }
        }

        if !rects.isEmpty {
            return rects
        }

        // Last-resort substring match (catches queries that tokenise empty,
        // e.g. punctuation-only or whitespace-only highlights from FTS).
        guard !lowercasedQuery.isEmpty else { return [] }

        return lines.compactMap { line in
            line.text.lowercased().contains(lowercasedQuery) ? line.rect : nil
        }
    }

    private func tokensMatch(_ candidateTokens: [String], anyOf queryTokens: [String]) -> Bool {
        for candidate in candidateTokens {
            for query in queryTokens where candidate.hasPrefix(query) {
                return true
            }
        }
        return false
    }
}

nonisolated struct SearchTextLine: Codable, Sendable {
    let text: String
    let rect: CGRect
    let words: [SearchTextWord]
}

nonisolated struct SearchTextWord: Codable, Sendable {
    let text: String
    let rect: CGRect
}
