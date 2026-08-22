import Foundation

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
