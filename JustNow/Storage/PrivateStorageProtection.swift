import CoreServices
import Foundation
import os.log

nonisolated enum PrivateStorageProtection {
    static var ownerOnlyDirectoryAttributes: [FileAttributeKey: Any] {
        [.posixPermissions: 0o700]
    }

    private static let logger = Logger(subsystem: "sg.tk.JustNow", category: "Storage")

    static func apply(to directory: URL, fileManager: FileManager = .default) {
        guard !FrameStoreFile.isSymbolicLink(at: directory) else { return }

        do {
            try fileManager.setAttributes(
                ownerOnlyDirectoryAttributes,
                ofItemAtPath: directory.path
            )
        } catch {
            logger.error(
                "Failed to set owner-only permissions: \(error.localizedDescription, privacy: .public)"
            )
        }

        do {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = directory
            try mutableURL.setResourceValues(values)
        } catch {
            logger.error(
                "Failed to exclude storage from app-data backups: \(error.localizedDescription, privacy: .public)"
            )
        }

        if CSBackupSetItemExcluded(directory as CFURL, true, false) != noErr {
            logger.error("Failed to exclude storage from Time Machine")
        }
    }

    static func isExcludedFromTimeMachine(_ directory: URL) -> Bool {
        var excludedByPath = DarwinBoolean(false)
        return CSBackupIsItemExcluded(directory as CFURL, &excludedByPath)
    }
}
