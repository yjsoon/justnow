//
//  AppRelaunchCoordinator.swift
//  JustNow
//

import Foundation

@MainActor
final class AppRelaunchCoordinator {
    typealias SuccessorLauncher = @MainActor (_ processIdentifier: Int32, _ bundleURL: URL) throws -> Void

    private let launchSuccessor: SuccessorLauncher
    private(set) var isPending = false

    init(launchSuccessor: @escaping SuccessorLauncher = AppRelaunchCoordinator.launchSuccessor) {
        self.launchSuccessor = launchSuccessor
    }

    @discardableResult
    func prepareRelaunch(
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        bundleURL: URL = Bundle.main.bundleURL
    ) throws -> Bool {
        guard !isPending else { return false }

        try launchSuccessor(processIdentifier, bundleURL)
        isPending = true
        return true
    }

    static func makeSuccessorProcess(processIdentifier: Int32, bundleURL: URL) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open -n \"$2\"",
            "justnow-relaunch",
            String(processIdentifier),
            bundleURL.path
        ]
        return process
    }

    private static func launchSuccessor(processIdentifier: Int32, bundleURL: URL) throws {
        let process = makeSuccessorProcess(
            processIdentifier: processIdentifier,
            bundleURL: bundleURL
        )
        try process.run()
    }
}
