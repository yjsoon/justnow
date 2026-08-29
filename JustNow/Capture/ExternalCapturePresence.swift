import Foundation

enum ExternalCaptureKind: Hashable, Sendable {
    case simulator

    var diagnosticsName: String {
        switch self {
        case .simulator:
            return "Simulator"
        }
    }
}

struct ExternalCapturePresence: Equatable, Sendable {
    var kinds: Set<ExternalCaptureKind>
    var isPresent: Bool { !kinds.isEmpty }
}

struct RunningAppDescriptor: Equatable, Sendable {
    var bundleIdentifier: String?
}

enum ExternalCaptureMatcher {
    static let rules: [(kind: ExternalCaptureKind, bundleIdentifiers: Set<String>)] = [
        (.simulator, ["com.apple.iphonesimulator"])
    ]

    static func presence(in apps: [RunningAppDescriptor]) -> ExternalCapturePresence {
        let identifiers = Set(apps.compactMap(\.bundleIdentifier))
        var kinds = Set<ExternalCaptureKind>()
        for rule in rules where !rule.bundleIdentifiers.isDisjoint(with: identifiers) {
            kinds.insert(rule.kind)
        }
        return ExternalCapturePresence(kinds: kinds)
    }
}

enum CaptureStatusCopy {
    static let screenInUse = "Paused (Screen in use)"
}
