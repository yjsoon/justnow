import XCTest
@testable import JustNow

final class AppSettingsMigrationTests: XCTestCase {
    func testReducedDiskWritesDefaultsOffForNewAndExistingPreferences() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "hiddenHybridRAMHistory")

        XCTAssertEqual(HistoryStorageMode.launchDefault(defaults: defaults), .allDisk)
        XCTAssertFalse(AppStorageDefault.reducedDiskWritesEnabled)
    }

    func testReducedDiskWritesResolvesEverySupportedMemoryLimit() {
        for limit in RecentDetailMemoryLimit.allCases {
            let defaults = makeDefaults()
            defaults.set(true, forKey: AppStorageKey.reducedDiskWritesEnabled)
            defaults.set(limit.rawValue, forKey: AppStorageKey.recentDetailMemoryMiB)

            XCTAssertEqual(
                HistoryStorageMode.launchDefault(defaults: defaults),
                .hybridRAM(byteCap: limit.byteCount)
            )
        }
    }

    func testReducedDiskWritesSanitisesMissingAndCorruptMemoryLimits() {
        for rawValue in [0, -1, 257, Int.max] {
            let defaults = makeDefaults()
            defaults.set(true, forKey: AppStorageKey.reducedDiskWritesEnabled)
            if rawValue != 0 {
                defaults.set(rawValue, forKey: AppStorageKey.recentDetailMemoryMiB)
            }

            XCTAssertEqual(
                HistoryStorageMode.launchDefault(defaults: defaults),
                .hybridRAM(byteCap: RecentDetailMemoryLimit.defaultValue.byteCount)
            )
        }
    }

    func testExistingInstallReceivesLegacyDefaultsWhenValuesWereNeverStored() {
        let defaults = makeDefaults()

        AppSettingsMigration.migrateIfNeeded(defaults: defaults, existingInstall: true)

        XCTAssertEqual(defaults.double(forKey: AppStorageKey.captureInterval), 0.5)
        XCTAssertEqual(defaults.double(forKey: AppStorageKey.recentTimelineWindowSeconds), 300)
        XCTAssertEqual(defaults.integer(forKey: AppStorageKey.settingsMigrationVersion), 1)
    }

    func testExistingInstallKeepsExplicitValues() {
        let defaults = makeDefaults()
        defaults.set(2.0, forKey: AppStorageKey.captureInterval)
        defaults.set(600.0, forKey: AppStorageKey.recentTimelineWindowSeconds)

        AppSettingsMigration.migrateIfNeeded(defaults: defaults, existingInstall: true)

        XCTAssertEqual(defaults.double(forKey: AppStorageKey.captureInterval), 2)
        XCTAssertEqual(defaults.double(forKey: AppStorageKey.recentTimelineWindowSeconds), 600)
    }

    func testNewInstallKeepsNewDefaultsUnstored() {
        let defaults = makeDefaults()

        AppSettingsMigration.migrateIfNeeded(defaults: defaults, existingInstall: false)

        XCTAssertNil(defaults.object(forKey: AppStorageKey.captureInterval))
        XCTAssertNil(defaults.object(forKey: AppStorageKey.recentTimelineWindowSeconds))
        XCTAssertEqual(defaults.integer(forKey: AppStorageKey.settingsMigrationVersion), 1)
    }

    func testMigrationOnlyRunsOnce() {
        let defaults = makeDefaults()
        AppSettingsMigration.migrateIfNeeded(defaults: defaults, existingInstall: false)

        AppSettingsMigration.migrateIfNeeded(defaults: defaults, existingInstall: true)

        XCTAssertNil(defaults.object(forKey: AppStorageKey.captureInterval))
        XCTAssertNil(defaults.object(forKey: AppStorageKey.recentTimelineWindowSeconds))
    }

    func testExistingInstallDetectionUsesPreferencesOrStorage() {
        XCTAssertFalse(
            AppSettingsMigration.isExistingInstall(
                persistentDomain: nil,
                storageDirectoryExists: false
            )
        )
        XCTAssertFalse(
            AppSettingsMigration.isExistingInstall(
                persistentDomain: [:],
                storageDirectoryExists: false
            )
        )
        XCTAssertTrue(
            AppSettingsMigration.isExistingInstall(
                persistentDomain: ["existingPreference": true],
                storageDirectoryExists: false
            )
        )
        XCTAssertTrue(
            AppSettingsMigration.isExistingInstall(
                persistentDomain: nil,
                storageDirectoryExists: true
            )
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AppSettingsMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
