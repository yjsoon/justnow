import Foundation
import XCTest
@testable import JustNow

final class PrivateStorageProtectionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateStorageProtectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testApplySetsOwnerOnlyPermissionsAndExcludesFromBackup() throws {
        PrivateStorageProtection.apply(to: directory)

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue, 0o700)

        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        XCTAssertTrue(PrivateStorageProtection.isExcludedFromTimeMachine(directory))
    }

    func testApplyIsIdempotentOnAnExistingPrivateDirectory() throws {
        PrivateStorageProtection.apply(to: directory)
        PrivateStorageProtection.apply(to: directory)

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue, 0o700)

        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        XCTAssertTrue(PrivateStorageProtection.isExcludedFromTimeMachine(directory))
    }

    func testApplyRepairsWorldReadableDirectory() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: directory.path
        )

        PrivateStorageProtection.apply(to: directory)

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue, 0o700)
    }

    func testApplyDoesNotFollowSymbolicLink() throws {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateStorageProtectionTarget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: target.path
        )
        defer { try? FileManager.default.removeItem(at: target) }

        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: target)

        PrivateStorageProtection.apply(to: directory)

        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue, 0o755)
        XCTAssertFalse(PrivateStorageProtection.isExcludedFromTimeMachine(target))
    }
}
