//
//  RewindHistoryOption.swift
//  JustNow
//

import Foundation

nonisolated enum RewindHistoryOption: Double, CaseIterable, Identifiable {
    case thirtyMinutes = 1800
    case twoHours = 7200
    case eightHours = 28800
    case twentyFourHours = 86400

    static let defaultValue: Self = .twentyFourHours

    var id: Double { rawValue }

    var duration: TimeInterval { rawValue }

    /// Keep enough sparse archive for the dedicated 1-hour search scope even when the rewind window is shorter.
    var retainedDuration: TimeInterval {
        max(duration, 60 * 60)
    }

    var settingsLabel: String {
        switch self {
        case .thirtyMinutes:
            return "30 min"
        case .twoHours:
            return "2 hr"
        case .eightHours:
            return "8 hr"
        case .twentyFourHours:
            return "24 hr"
        }
    }

    var searchLabel: String {
        switch self {
        case .thirtyMinutes:
            return "Last 30m"
        case .twoHours:
            return "Last 2h"
        case .eightHours:
            return "Last 8h"
        case .twentyFourHours:
            return "Last 24h"
        }
    }

    var compactSearchLabel: String {
        switch self {
        case .thirtyMinutes:
            return "30m"
        case .twoHours:
            return "2h"
        case .eightHours:
            return "8h"
        case .twentyFourHours:
            return "24h"
        }
    }

    var retentionPolicy: RetentionPolicy {
        .rewindHistory(self)
    }

    static func resolved(from rawValue: Double) -> Self {
        Self(rawValue: rawValue) ?? .defaultValue
    }
}
