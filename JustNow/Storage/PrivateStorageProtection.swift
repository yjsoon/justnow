import CoreServices
import Foundation

enum PrivateStorageProtection {
    static func apply(to directory: URL, fileManager: FileManager = .default) {
        guard !FrameStoreFile.isSymbolicLink(at: directory) else { return }

        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = directory
        try? mutableURL.setResourceValues(values)
        _ = CSBackupSetItemExcluded(directory as CFURL, true, false)
    }

    static func isExcludedFromTimeMachine(_ directory: URL) -> Bool {
        var excluded = DarwinBoolean(false)
        guard CSBackupIsItemExcluded(directory as CFURL, &excluded, nil) == noErr else {
            return false
        }
        return excluded.boolValue
    }
}
