import Foundation

/// Owner-only permissions and Time Machine exclusion for screen-history
/// directories. Call after creating the directory so existing installs pick
/// this up on the next launch.
enum PrivateStorageProtection {
    static func apply(to directory: URL, fileManager: FileManager = .default) {
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = directory
        try? mutableURL.setResourceValues(values)
    }
}
