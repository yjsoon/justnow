//
//  DiagnosticsLog.swift
//  JustNow
//

import CoreGraphics
import Foundation

/// Pure formatting and rotation decisions for the diagnostics log.
enum DiagnosticsLogFormat {
    static let maximumFileSize = 2 * 1024 * 1024

    static func line(timestamp: String, category: String, message: String) -> String {
        "\(timestamp) [\(category)] \(message)\n"
    }

    static func shouldRotate(fileSize: Int, maximumSize: Int = maximumFileSize) -> Bool {
        fileSize >= maximumSize
    }

    /// os_log lines only carry `localizedDescription`, which for ScreenCaptureKit
    /// TCC failures hides the error domain/code needed to tell transient OS
    /// denials apart from real permission revocations.
    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.localizedDescription) [\(nsError.domain) code=\(nsError.code)]"
    }
}

/// Snapshot of the system conditions that matter when screenshot capture fails,
/// so a failure line records whether TCC actually said no and whether the screen
/// was locked at that moment.
enum CaptureSystemState {
    static func summary() -> String {
        let preflight = CGPreflightScreenCaptureAccess()
        let locked = isScreenLocked()
        let thermal = thermalLabel(ProcessInfo.processInfo.thermalState)
        return "tccPreflight=\(preflight) screenLocked=\(locked) thermal=\(thermal)"
    }

    static func isScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

/// Appends timestamped lines to ~/Library/Logs/JustNow/diagnostics.log so capture
/// stops and permission churn can be reviewed after the fact. os_log info lines
/// are not reliably persisted, and OS betas are exactly when we need a durable
/// record that survives log rotation.
final class DiagnosticsLog: @unchecked Sendable {
    static let shared = DiagnosticsLog()

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/JustNow", isDirectory: true)
    }

    private let queue = DispatchQueue(label: "sg.tk.JustNow.diagnostics", qos: .utility)
    private let fileURL: URL
    private let rotatedFileURL: URL
    private let dateFormatter: DateFormatter

    init(directory: URL = DiagnosticsLog.defaultDirectory) {
        fileURL = directory.appendingPathComponent("diagnostics.log")
        rotatedFileURL = directory.appendingPathComponent("diagnostics.log.1")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter = formatter
    }

    func log(_ category: String, _ message: String) {
        let timestamp = Date()
        queue.async { [self] in
            append(
                DiagnosticsLogFormat.line(
                    timestamp: dateFormatter.string(from: timestamp),
                    category: category,
                    message: message
                )
            )
        }
    }

    func logSessionStart() {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        log("App", "JustNow \(version) (\(build)) launched on macOS \(os); \(CaptureSystemState.summary())")
    }

    // MARK: - Private (file IO, always on `queue`)

    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            rotateIfNeeded(fileManager: fileManager)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: fileURL)
            }
        } catch {
            // Diagnostics must never take the app down; drop the line.
        }
    }

    private func rotateIfNeeded(fileManager: FileManager) {
        let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path)
        guard let size = attributes?[.size] as? Int,
              DiagnosticsLogFormat.shouldRotate(fileSize: size) else { return }
        try? fileManager.removeItem(at: rotatedFileURL)
        try? fileManager.moveItem(at: fileURL, to: rotatedFileURL)
    }
}
