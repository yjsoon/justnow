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
        let tokens = SearchQueryTokeniser.tokens(from: query)
        guard !tokens.isEmpty else { return [] }

        var rects: [CGRect] = []
        rects.reserveCapacity(lines.count)

        for line in lines {
            let matchingWordRects = line.words.compactMap { word -> CGRect? in
                let wordTokens = SearchQueryTokeniser.tokens(from: word.text)
                guard wordTokens.contains(where: { token in
                    tokens.contains(where: { token.hasPrefix($0) })
                }) else {
                    return nil
                }
                return word.rect
            }

            if !matchingWordRects.isEmpty {
                rects.append(contentsOf: matchingWordRects)
                continue
            }

            let lineTokens = SearchQueryTokeniser.tokens(from: line.text)
            if lineTokens.contains(where: { token in
                tokens.contains(where: { token.hasPrefix($0) })
            }) {
                rects.append(line.rect)
            }
        }

        if !rects.isEmpty {
            return rects
        }

        let lowercasedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowercasedQuery.isEmpty else { return [] }

        return lines.compactMap { line in
            line.text.lowercased().contains(lowercasedQuery) ? line.rect : nil
        }
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
