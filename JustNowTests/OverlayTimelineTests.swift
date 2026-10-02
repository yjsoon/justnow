import CoreGraphics
import Observation
import SQLite3
import XCTest
@testable import JustNow

@MainActor
final class OverlayTimelineTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        try super.tearDownWithError()
    }

    func testTimelineGeometryUsesEntryIndexRatherThanElapsedTime() {
        XCTAssertEqual(timelineEntryPosition(index: 1, count: 11), 0.1, accuracy: 0.000_1)
        XCTAssertEqual(timelineEntryPosition(index: 9, count: 11), 0.9, accuracy: 0.000_1)
        XCTAssertEqual(timelineEntryIndex(at: 0.73, count: 11), 7)
    }

    func testTimelineGeometryClampsAndHandlesSingleEntry() {
        XCTAssertEqual(timelineEntryPosition(index: -1, count: 10), 0)
        XCTAssertEqual(timelineEntryPosition(index: 11, count: 10), 1)
        XCTAssertEqual(timelineEntryPosition(index: 0, count: 1), 0)
        XCTAssertEqual(timelineEntryIndex(at: -0.5, count: 10), 0)
        XCTAssertEqual(timelineEntryIndex(at: 1.5, count: 10), 9)
        XCTAssertEqual(timelineEntryIndex(at: 0.5, count: 1), 0)
    }

    func testPayloadLeaseReleaseGateFinishesLeaseBeforeCaptureCanResume() async {
        let gate = OverlayPayloadLeaseReleaseGate()
        let lease = BlockingPayloadLease()
        let resumed = expectation(description: "capture resumes after lease release")
        var didResumeCapture = false
        let generation = gate.becameVisible()

        gate.release(lease, generation: generation) {
            didResumeCapture = true
            resumed.fulfill()
        }

        await lease.waitUntilReleaseRequested()
        XCTAssertFalse(didResumeCapture)

        await lease.permitRelease()
        await fulfillment(of: [resumed], timeout: 1)
        XCTAssertTrue(didResumeCapture)
    }

    func testPayloadLeaseReleaseGateIgnoresOlderReleaseAfterNewPresentation() async {
        let gate = OverlayPayloadLeaseReleaseGate()
        let staleRelease = expectation(description: "stale release must not resume capture")
        staleRelease.isInverted = true
        let currentRelease = expectation(description: "current release resumes capture")
        let olderGeneration = gate.becameVisible()
        let newerGeneration = gate.becameVisible()

        gate.release(nil, generation: olderGeneration) {
            staleRelease.fulfill()
        }
        gate.release(nil, generation: newerGeneration) {
            currentRelease.fulfill()
        }

        await fulfillment(of: [currentRelease, staleRelease], timeout: 0.2)
    }

    func testOverlayPausesForcedRetentionBeforeSuspendedSnapshotUntilLeaseRelease() async throws {
        let now = Date()
        let entry = makeEntry(
            start: now.addingTimeInterval(-120),
            end: now.addingTimeInterval(-120)
        )
        let lease = BlockingPayloadLease()
        let repository = OverlayTimelineRepositoryProbe(
            entries: [entry],
            image: try XCTUnwrap(TestImageFactory.makeSolidImage(width: 8, height: 8, level: 80)),
            currentTimelineLease: lease
        )
        await repository.suspendNextCurrentTimelineSnapshot()
        let buffer = try await makeBuffer(repository: repository)
        let controller = OverlayWindowController(
            frameBuffer: buffer,
            dismissShortcutKeyCode: 0,
            dismissShortcutModifiers: 0,
            onOpenSettings: {}
        )

        let showTask = Task { @MainActor in
            await controller.showOverlay(
                recentTimelineWindow: 300,
                rewindHistoryOption: .twentyFourHours,
                activeDisplay: nil,
                availableDisplays: []
            )
        }
        await repository.waitUntilCurrentTimelineSnapshotRequested()

        XCTAssertTrue(buffer.isPruningPaused)
        await buffer.updateRetentionPolicy(RetentionPolicy(tiers: []))
        let timelineWhileSnapshotSuspended = await repository.orderedTimeline()
        XCTAssertEqual(timelineWhileSnapshotSuspended, [entry])

        await repository.resumeCurrentTimelineSnapshot()
        await showTask.value
        XCTAssertTrue(controller.isVisible)
        controller.hideOverlay()
        await lease.waitUntilReleaseRequested()

        await buffer.updateRetentionPolicy(RetentionPolicy(tiers: []))
        let timelineWhileLeaseReleases = await repository.orderedTimeline()
        XCTAssertEqual(timelineWhileLeaseReleases, [entry])

        await lease.permitRelease()
        try await waitUntil { !buffer.isPruningPaused }
        await buffer.updateRetentionPolicy(RetentionPolicy(tiers: []))
        let finalTimeline = await repository.orderedTimeline()
        XCTAssertTrue(finalTimeline.isEmpty)
    }

    func testCancelledPendingOverlaySnapshotUnwindsOnlyAfterLeaseRelease() async throws {
        let now = Date()
        let entry = makeEntry(start: now, end: now)
        let lease = BlockingPayloadLease()
        let repository = OverlayTimelineRepositoryProbe(
            entries: [entry],
            image: try XCTUnwrap(TestImageFactory.makeSolidImage(width: 8, height: 8, level: 81)),
            currentTimelineLease: lease
        )
        await repository.suspendNextCurrentTimelineSnapshot()
        let buffer = try await makeBuffer(repository: repository)
        var visibilityTransitions: [Bool] = []
        let controller = OverlayWindowController(
            frameBuffer: buffer,
            dismissShortcutKeyCode: 0,
            dismissShortcutModifiers: 0,
            onVisibilityChanged: { visibilityTransitions.append($0) },
            onOpenSettings: {}
        )

        let showTask = Task { @MainActor in
            await controller.showOverlay(
                recentTimelineWindow: 300,
                rewindHistoryOption: .twentyFourHours,
                activeDisplay: nil,
                availableDisplays: []
            )
        }
        await repository.waitUntilCurrentTimelineSnapshotRequested()
        showTask.cancel()
        await repository.resumeCurrentTimelineSnapshot()
        await lease.waitUntilReleaseRequested()

        XCTAssertTrue(buffer.isPruningPaused)
        XCTAssertTrue(visibilityTransitions.isEmpty)
        await lease.permitRelease()
        await showTask.value
        try await waitUntil { !buffer.isPruningPaused }

        XCTAssertFalse(controller.isVisible)
        XCTAssertTrue(visibilityTransitions.isEmpty)
    }

    func testCancelledReopenRetainsPriorCaptureResumeObligation() async throws {
        let now = Date()
        let entry = makeEntry(start: now, end: now)
        let firstLease = BlockingPayloadLease()
        let repository = OverlayTimelineRepositoryProbe(
            entries: [entry],
            image: try XCTUnwrap(TestImageFactory.makeSolidImage(width: 8, height: 8, level: 84)),
            currentTimelineLease: firstLease,
            subsequentTimelineLeases: [NoopFrameRepositoryPayloadLease()]
        )
        let buffer = try await makeBuffer(repository: repository)
        var visibilityTransitions: [Bool] = []
        let controller = OverlayWindowController(
            frameBuffer: buffer,
            dismissShortcutKeyCode: 0,
            dismissShortcutModifiers: 0,
            onVisibilityChanged: { visibilityTransitions.append($0) },
            onOpenSettings: {}
        )

        await controller.showOverlay(
            recentTimelineWindow: 300,
            rewindHistoryOption: .twentyFourHours,
            activeDisplay: nil,
            availableDisplays: []
        )
        XCTAssertEqual(visibilityTransitions, [true])

        controller.hideOverlay()
        await firstLease.waitUntilReleaseRequested()
        await repository.suspendNextCurrentTimelineSnapshot()
        let reopenTask = Task { @MainActor in
            await controller.showOverlay(
                recentTimelineWindow: 300,
                rewindHistoryOption: .twentyFourHours,
                activeDisplay: nil,
                availableDisplays: []
            )
        }
        await repository.waitUntilCurrentTimelineSnapshotRequested()
        controller.hideOverlay()
        await repository.resumeCurrentTimelineSnapshot()

        XCTAssertEqual(visibilityTransitions, [true])
        await firstLease.permitRelease()
        await reopenTask.value
        try await waitUntil { visibilityTransitions == [true, false] }

        XCTAssertEqual(visibilityTransitions, [true, false])
        XCTAssertFalse(buffer.isPruningPaused)
        XCTAssertFalse(controller.isVisible)
    }

    func testCriticalDismissalWaitsForVisibleLeaseAndMaintenanceBeforeCaptureResumes() async throws {
        let now = Date()
        let entry = makeEntry(start: now, end: now)
        let lease = BlockingPayloadLease()
        let repository = OverlayTimelineRepositoryProbe(
            entries: [entry],
            image: try XCTUnwrap(TestImageFactory.makeSolidImage(width: 8, height: 8, level: 82)),
            currentTimelineLease: lease
        )
        await repository.suspendNextPressure()
        let buffer = try await makeBuffer(repository: repository)
        var visibilityTransitions: [Bool] = []
        let controller = OverlayWindowController(
            frameBuffer: buffer,
            dismissShortcutKeyCode: 0,
            dismissShortcutModifiers: 0,
            onVisibilityChanged: { visibilityTransitions.append($0) },
            onOpenSettings: {}
        )
        await controller.showOverlay(
            recentTimelineWindow: 300,
            rewindHistoryOption: .twentyFourHours,
            activeDisplay: nil,
            availableDisplays: []
        )
        XCTAssertTrue(controller.isVisible)
        XCTAssertEqual(visibilityTransitions, [true])

        let handling = Task { @MainActor in
            _ = await controller.dismissForMemoryPressure()
            _ = await buffer.respondToMemoryPressure(.critical)
            controller.completeMemoryPressureDismissal()
        }
        await lease.waitUntilReleaseRequested()
        XCTAssertFalse(controller.isVisible)
        XCTAssertTrue(buffer.isPruningPaused)
        XCTAssertEqual(visibilityTransitions, [true])

        await controller.showOverlay(
            recentTimelineWindow: 300,
            rewindHistoryOption: .twentyFourHours,
            activeDisplay: nil,
            availableDisplays: []
        )
        XCTAssertFalse(controller.isVisible)
        await lease.permitRelease()
        await repository.waitUntilPressureRequested()
        XCTAssertTrue(buffer.isPruningPaused)
        XCTAssertEqual(visibilityTransitions, [true])

        await repository.resumePressure()
        await handling.value
        XCTAssertFalse(buffer.isPruningPaused)
        XCTAssertEqual(visibilityTransitions, [true, false])
    }

    func testCriticalDismissalKeepsLeaseUntilSuspendedScreenshotExportFinishes() async throws {
        let now = Date()
        let entry = makeEntry(start: now, end: now)
        let lease = BlockingPayloadLease()
        let repository = OverlayTimelineRepositoryProbe(
            entries: [entry],
            image: try XCTUnwrap(TestImageFactory.makeSolidImage(width: 8, height: 8, level: 85)),
            currentTimelineLease: lease
        )
        await repository.suspendNextExport()
        let buffer = try await makeBuffer(repository: repository)
        var visibilityTransitions: [Bool] = []
        let controller = OverlayWindowController(
            frameBuffer: buffer,
            dismissShortcutKeyCode: 0,
            dismissShortcutModifiers: 0,
            onVisibilityChanged: { visibilityTransitions.append($0) },
            onOpenSettings: {}
        )
        let defaults = UserDefaults.standard
        let keys = [
            AppStorageKey.screenshotSaveToFolder,
            AppStorageKey.screenshotSaveToClipboard,
            AppStorageKey.saveScreenshotSoundEnabled,
            AppStorageKey.hasSeenSaveQualityInfo
        ]
        let priorValues = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            defaults.object(forKey: key).map { (key, $0) }
        })
        defer {
            for key in keys {
                if let priorValue = priorValues[key] {
                    defaults.set(priorValue, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        defaults.set(true, forKey: AppStorageKey.screenshotSaveToFolder)
        defaults.set(false, forKey: AppStorageKey.screenshotSaveToClipboard)
        defaults.set(false, forKey: AppStorageKey.saveScreenshotSoundEnabled)
        defaults.set(true, forKey: AppStorageKey.hasSeenSaveQualityInfo)

        await controller.showOverlay(
            recentTimelineWindow: 300,
            rewindHistoryOption: .twentyFourHours,
            activeDisplay: nil,
            availableDisplays: []
        )
        try XCTUnwrap(controller.viewModel).saveCurrentFrameToScreenshotsLocation()
        await repository.waitUntilExportRequested()

        let handling = Task { @MainActor in
            _ = await controller.dismissForMemoryPressure()
            _ = await buffer.respondToMemoryPressure(.critical)
            controller.completeMemoryPressureDismissal()
        }
        try await waitUntil { !controller.isVisible }

        let releasedWhileExportSuspended = await lease.hasReleaseBeenRequested()
        let eventsWhileExportSuspended = await repository.operationEvents()
        XCTAssertFalse(releasedWhileExportSuspended)
        XCTAssertEqual(eventsWhileExportSuspended, [.exportStarted])

        await repository.resumeExport()
        await lease.waitUntilReleaseRequested()
        let eventsBeforeLeaseRelease = await repository.operationEvents()
        XCTAssertEqual(eventsBeforeLeaseRelease, [.exportStarted, .exportFinished])
        await lease.permitRelease()
        await handling.value

        let finalEvents = await repository.operationEvents()
        XCTAssertEqual(finalEvents, [.exportStarted, .exportFinished, .memoryPressure])
        XCTAssertEqual(visibilityTransitions, [true, false])
    }

    func testCriticalDismissalCancelsPendingPresentationWithoutOpeningOrResumingEarly() async throws {
        let now = Date()
        let entry = makeEntry(start: now, end: now)
        let lease = BlockingPayloadLease()
        let repository = OverlayTimelineRepositoryProbe(
            entries: [entry],
            image: try XCTUnwrap(TestImageFactory.makeSolidImage(width: 8, height: 8, level: 83)),
            currentTimelineLease: lease
        )
        await repository.suspendNextCurrentTimelineSnapshot()
        await repository.suspendNextPressure()
        let buffer = try await makeBuffer(repository: repository)
        var visibilityTransitions: [Bool] = []
        let controller = OverlayWindowController(
            frameBuffer: buffer,
            dismissShortcutKeyCode: 0,
            dismissShortcutModifiers: 0,
            onVisibilityChanged: { visibilityTransitions.append($0) },
            onOpenSettings: {}
        )
        let showTask = Task { @MainActor in
            await controller.showOverlay(
                recentTimelineWindow: 300,
                rewindHistoryOption: .twentyFourHours,
                activeDisplay: nil,
                availableDisplays: []
            )
        }
        await repository.waitUntilCurrentTimelineSnapshotRequested()
        showTask.cancel()

        let handling = Task { @MainActor in
            _ = await controller.dismissForMemoryPressure()
            await showTask.value
            _ = await controller.dismissForMemoryPressure()
            _ = await buffer.respondToMemoryPressure(.critical)
            controller.completeMemoryPressureDismissal()
        }
        await repository.resumeCurrentTimelineSnapshot()
        await lease.waitUntilReleaseRequested()
        XCTAssertFalse(controller.isVisible)
        XCTAssertTrue(buffer.isPruningPaused)
        XCTAssertTrue(visibilityTransitions.isEmpty)

        await lease.permitRelease()
        await repository.waitUntilPressureRequested()
        XCTAssertFalse(controller.isVisible)
        XCTAssertTrue(buffer.isPruningPaused)
        XCTAssertTrue(visibilityTransitions.isEmpty)

        await repository.resumePressure()
        await handling.value
        XCTAssertFalse(controller.isVisible)
        XCTAssertFalse(buffer.isPruningPaused)
        XCTAssertTrue(visibilityTransitions.isEmpty)
    }

    func testTimelineThumbOffsetStaysFullyInsideTrackAtBothEnds() {
        XCTAssertEqual(timelineThumbOffset(totalWidth: 100, thumbDiameter: 24, position: 0), 0)
        XCTAssertEqual(timelineThumbOffset(totalWidth: 100, thumbDiameter: 24, position: 1), 76)
        XCTAssertEqual(timelineThumbOffset(totalWidth: 10, thumbDiameter: 24, position: 1), 0)
    }

    func testResolverPreservesTargetInsideSpan() throws {
        let base = Date(timeIntervalSinceReferenceDate: 10_000)
        let entry = makeEntry(start: base, end: base.addingTimeInterval(20))
        let target = base.addingTimeInterval(7.25)

        let selection = try XCTUnwrap(resolveTimelineSelection(entries: [entry], target: target))

        XCTAssertEqual(selection.spanID, entry.span.id)
        XCTAssertEqual(selection.timestamp, target)
    }

    func testResolverUsesNearestGapEndpointAndTiesOlder() throws {
        let base = Date(timeIntervalSinceReferenceDate: 10_000)
        let older = makeEntry(start: base, end: base.addingTimeInterval(10))
        let newer = makeEntry(start: base.addingTimeInterval(20), end: base.addingTimeInterval(30))

        let nearerNewer = try XCTUnwrap(resolveTimelineSelection(
            entries: [older, newer],
            target: base.addingTimeInterval(18)
        ))
        XCTAssertEqual(nearerNewer.spanID, newer.span.id)
        XCTAssertEqual(nearerNewer.timestamp, base.addingTimeInterval(20))

        let tied = try XCTUnwrap(resolveTimelineSelection(
            entries: [older, newer],
            target: base.addingTimeInterval(15)
        ))
        XCTAssertEqual(tied.spanID, older.span.id)
        XCTAssertEqual(tied.timestamp, base.addingTimeInterval(10))
    }

    func testResolverOverlapAndEqualBoundaryChooseLaterDurableEntry() throws {
        let base = Date(timeIntervalSinceReferenceDate: 10_000)
        let first = makeEntry(start: base, end: base.addingTimeInterval(20))
        let second = makeEntry(start: base.addingTimeInterval(10), end: base.addingTimeInterval(30))
        let boundary = makeEntry(start: base.addingTimeInterval(30), end: base.addingTimeInterval(35))

        let overlap = try XCTUnwrap(resolveTimelineSelection(
            entries: [first, second, boundary],
            target: base.addingTimeInterval(15)
        ))
        XCTAssertEqual(overlap.spanID, second.span.id)

        let equalBoundary = try XCTUnwrap(resolveTimelineSelection(
            entries: [first, second, boundary],
            target: base.addingTimeInterval(30)
        ))
        XCTAssertEqual(equalBoundary.spanID, boundary.span.id)
    }

    func testResolverEqualTimestampEntriesUseLaterDurableOrder() throws {
        let date = Date(timeIntervalSinceReferenceDate: 10_000)
        let first = makeEntry(start: date, end: date)
        let second = makeEntry(start: date, end: date)

        let selection = try XCTUnwrap(resolveTimelineSelection(entries: [first, second], target: date))

        XCTAssertEqual(selection.spanID, second.span.id)
        XCTAssertEqual(selection.entryIndex, 1)
    }

    func testResolverHandlesEmptySingleFutureAndClockRollback() throws {
        let reference = Date(timeIntervalSinceReferenceDate: 10_000)
        XCTAssertNil(resolveTimelineSelection(entries: [], target: reference))

        let future = makeEntry(
            start: reference.addingTimeInterval(30),
            end: reference.addingTimeInterval(30)
        )
        let futureSelection = try XCTUnwrap(resolveTimelineSelection(entries: [future], target: reference))
        XCTAssertEqual(futureSelection.timestamp, future.span.startedAt)
        XCTAssertEqual(clampedTimelineReferenceDate(requested: reference, entries: [future]), future.span.startedAt)

        let rollback = makeEntry(
            start: reference.addingTimeInterval(20),
            end: reference.addingTimeInterval(10)
        )
        let rollbackSelection = try XCTUnwrap(resolveTimelineSelection(
            entries: [rollback],
            target: reference.addingTimeInterval(15)
        ))
        XCTAssertEqual(rollbackSelection.timestamp, reference.addingTimeInterval(15))
    }

    func testTimelineMarkerAndRecentBorderUseExactTargetTime() throws {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let entries = [
            makeEntry(start: now.addingTimeInterval(-1_000), end: now.addingTimeInterval(-990)),
            makeEntry(start: now.addingTimeInterval(-101), end: now.addingTimeInterval(-100)),
            makeEntry(start: now.addingTimeInterval(-2), end: now.addingTimeInterval(-1))
        ]

        let position = try XCTUnwrap(resolveTimelineMarkerPosition(
            entries: entries,
            targetAge: 300,
            now: now
        ))
        XCTAssertEqual(position, 0.5, accuracy: 0.000_1)

        let marker = try XCTUnwrap(timelineLandmarkMarkers(
            entries: entries,
            recentWindow: 300,
            now: now
        ).first { $0.targetAge == 300 })
        XCTAssertEqual(marker.targetDate, now.addingTimeInterval(-300))
        XCTAssertEqual(marker.position, 0.5, accuracy: 0.000_1)
        XCTAssertEqual(marker.id, marker.targetDate.timeIntervalSinceReferenceDate)
    }

    func testTimelineDecorationDoesNotInvalidateWhenScrubbingOrSearching() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let entries = [
            makeEntry(start: now.addingTimeInterval(-1_000), end: now.addingTimeInterval(-990)),
            makeEntry(start: now.addingTimeInterval(-101), end: now.addingTimeInterval(-100)),
            makeEntry(start: now.addingTimeInterval(-2), end: now.addingTimeInterval(-1))
        ]
        let viewModel = try await makeViewModel(entries: entries, referenceDate: now)
        let marker = try XCTUnwrap(viewModel.timelineMarkers.first { $0.targetAge == 300 })
        XCTAssertEqual(marker.position, 0.5, accuracy: 0.000_1)
        XCTAssertEqual(viewModel.timelineZoneFills.map(\.start), [0, 0.5])
        XCTAssertEqual(viewModel.timelineZoneFills.map(\.end), [0.5, 1])

        let invalidated = expectation(description: "Static decoration must not observe selection or search")
        invalidated.isInverted = true
        withObservationTracking {
            _ = viewModel.timelineMarkers
            _ = viewModel.timelineZoneFills
        } onChange: {
            invalidated.fulfill()
        }

        viewModel.selectedIndex = 0
        viewModel.setSelectedTimestamp(now.addingTimeInterval(-100))
        viewModel.isSearching = true
        viewModel.searchQuery = "needle"
        viewModel.searchResults = [entries[1]]
        XCTAssertEqual(viewModel.displayedFrameCount, 1)
        viewModel.clearSearch()
        XCTAssertEqual(viewModel.displayedFrameCount, 3)

        await fulfillment(of: [invalidated], timeout: 0.05)
    }

    func testTimelineDecorationRebuildsWhenSwitchingDisplayAndReferenceDate() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let displayA = DisplayInfo(id: UUID(), displayID: 1, name: "A")
        let displayB = DisplayInfo(id: UUID(), displayID: 2, name: "B")
        let entriesA = [
            makeEntry(start: now.addingTimeInterval(-1_000), end: now.addingTimeInterval(-990), displayID: displayA.id),
            makeEntry(start: now.addingTimeInterval(-101), end: now.addingTimeInterval(-100), displayID: displayA.id),
            makeEntry(start: now.addingTimeInterval(-2), end: now.addingTimeInterval(-1), displayID: displayA.id)
        ]
        let futureB = makeEntry(
            start: now.addingTimeInterval(600),
            end: now.addingTimeInterval(610),
            displayID: displayB.id
        )
        let buffer = try await makeBuffer(repository: nil)
        let viewModel = OverlayViewModel(
            timelineEntries: entriesA,
            leasedTimelineEntries: entriesA + [futureB],
            frameBuffer: buffer,
            recentTimelineWindow: 300,
            rewindHistoryOption: .twentyFourHours,
            availableDisplays: [displayA, displayB],
            activeDisplay: displayA,
            primaryDisplayID: displayA.id,
            timelineReferenceDate: now,
            onDismiss: {},
            onOpenSettings: {}
        )
        XCTAssertEqual(viewModel.timelineMarkers.first { $0.targetAge == 300 }?.position, 0.5)

        viewModel.switchDisplay(to: displayB)
        XCTAssertEqual(viewModel.timelineReferenceDate, now.addingTimeInterval(610))
        XCTAssertTrue(viewModel.timelineMarkers.isEmpty)
        XCTAssertEqual(viewModel.timelineZoneFills.map(\.start), [0])
        XCTAssertEqual(viewModel.timelineZoneFills.map(\.end), [1])

        viewModel.switchDisplay(to: displayA)
        XCTAssertEqual(viewModel.timelineReferenceDate, now)
        let marker = try XCTUnwrap(viewModel.timelineMarkers.first { $0.targetAge == 300 })
        XCTAssertEqual(marker.targetDate, now.addingTimeInterval(-300))
        XCTAssertEqual(marker.position, 0.5)
        XCTAssertEqual(viewModel.timelineZoneFills.map(\.start), [0, 0.5])
        XCTAssertEqual(viewModel.timelineZoneFills.map(\.end), [0.5, 1])
    }

    func testTimelineColourSegmentsSplitAtExactBorder() {
        let entry = makeEntry(
            start: Date(timeIntervalSinceReferenceDate: 1_000),
            end: Date(timeIntervalSinceReferenceDate: 1_010)
        )
        let segments = timelineColourSegments(entries: [entry], borderPosition: 0.25)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].start, 0, accuracy: 0.000_1)
        XCTAssertEqual(segments[0].end, 0.25, accuracy: 0.000_1)
        XCTAssertEqual(segments[1].start, 0.25, accuracy: 0.000_1)
        XCTAssertEqual(segments[1].end, 1, accuracy: 0.000_1)
        XCTAssertTrue(timelineColourSegments(entries: [], borderPosition: 0.5).isEmpty)
    }

    func testViewModelNavigationUsesSpanEndpointsAndElapsedJumps() async throws {
        let base = Date(timeIntervalSinceReferenceDate: 10_000)
        let entries = [
            makeEntry(start: base, end: base.addingTimeInterval(5)),
            makeEntry(start: base.addingTimeInterval(20), end: base.addingTimeInterval(30)),
            makeEntry(start: base.addingTimeInterval(70), end: base.addingTimeInterval(90))
        ]
        let viewModel = try await makeViewModel(entries: entries, referenceDate: base.addingTimeInterval(100))

        viewModel.goToStart()
        XCTAssertEqual(viewModel.selectedSpanID, entries[0].span.id)
        XCTAssertEqual(viewModel.selectedTimestamp, base)

        viewModel.moveRight()
        XCTAssertEqual(viewModel.selectedSpanID, entries[1].span.id)
        XCTAssertEqual(viewModel.selectedTimestamp, base.addingTimeInterval(20))

        viewModel.moveLeft()
        XCTAssertEqual(viewModel.selectedSpanID, entries[0].span.id)
        XCTAssertEqual(viewModel.selectedTimestamp, base.addingTimeInterval(5))

        viewModel.jumpRight()
        XCTAssertEqual(viewModel.selectedSpanID, entries[1].span.id)
        XCTAssertEqual(viewModel.selectedTimestamp, base.addingTimeInterval(20))

        viewModel.scrollBy(-4)
        XCTAssertEqual(viewModel.selectedSpanID, entries[2].span.id)
        XCTAssertEqual(viewModel.selectedTimestamp, base.addingTimeInterval(70))

        viewModel.goToEnd()
        XCTAssertEqual(viewModel.selectedSpanID, entries[2].span.id)
        XCTAssertEqual(viewModel.selectedTimestamp, base.addingTimeInterval(90))
    }

    func testRollbackSpanHomeAndEndUseNormalisedBounds() async throws {
        let base = Date(timeIntervalSinceReferenceDate: 10_000)
        let rollback = makeEntry(
            start: base.addingTimeInterval(20),
            end: base.addingTimeInterval(10)
        )
        let viewModel = try await makeViewModel(
            entries: [rollback],
            referenceDate: base.addingTimeInterval(30)
        )

        viewModel.goToStart()
        XCTAssertEqual(viewModel.selectedTimestamp, base.addingTimeInterval(10))

        viewModel.goToEnd()
        XCTAssertEqual(viewModel.selectedTimestamp, base.addingTimeInterval(20))
    }

    func testViewModelSelectionIsTimestampAuthoritativeAndAccessibilityIsSpanAware() async throws {
        let base = Date(timeIntervalSinceReferenceDate: 10_000)
        let entry = makeEntry(start: base, end: base.addingTimeInterval(30))
        let viewModel = try await makeViewModel(entries: [entry], referenceDate: base.addingTimeInterval(40))

        viewModel.setSelectedTimestamp(base.addingTimeInterval(12.5))

        XCTAssertEqual(viewModel.selectedTimestamp, base.addingTimeInterval(12.5))
        XCTAssertEqual(viewModel.selectedIndex, 0)
        XCTAssertTrue(viewModel.accessibilityTimelineValue.contains("Span 1 of 1"))
        XCTAssertFalse(viewModel.accessibilityTimelineValue.contains("Frame"))
    }

    func testScrollCrossesSparseHistoryGapsInBothDirections() async throws {
        let base = Date(timeIntervalSinceReferenceDate: 10_000)
        let older = makeEntry(
            start: base,
            end: base.addingTimeInterval(10)
        )
        let newer = makeEntry(
            start: base.addingTimeInterval(70),
            end: base.addingTimeInterval(90)
        )
        let viewModel = try await makeViewModel(
            entries: [older, newer],
            referenceDate: base.addingTimeInterval(100)
        )

        viewModel.setSelectedTimestamp(base.addingTimeInterval(80))
        viewModel.scrollBy(1)
        XCTAssertEqual(viewModel.selectedSpanID, older.span.id)
        XCTAssertEqual(viewModel.selectedTimestamp, base.addingTimeInterval(10))

        viewModel.scrollBy(-1)
        XCTAssertEqual(viewModel.selectedSpanID, newer.span.id)
        XCTAssertEqual(viewModel.selectedTimestamp, base.addingTimeInterval(70))
    }

    func testScrollNeverMovesAgainstRequestedDirectionAcrossOverlappingSpans() async throws {
        let base = Date(timeIntervalSinceReferenceDate: 10_000)
        let first = makeEntry(
            start: base,
            end: base.addingTimeInterval(20)
        )
        let second = makeEntry(
            start: base.addingTimeInterval(10),
            end: base.addingTimeInterval(30)
        )
        let viewModel = try await makeViewModel(
            entries: [first, second],
            referenceDate: base.addingTimeInterval(40)
        )

        viewModel.setSelectedTimestamp(base.addingTimeInterval(10))
        XCTAssertEqual(viewModel.selectedSpanID, second.span.id)
        viewModel.scrollBy(1)
        XCTAssertEqual(viewModel.selectedSpanID, first.span.id)
        XCTAssertEqual(viewModel.selectedTimestamp, base)

        let forward = try XCTUnwrap(adjacentTimelineSelection(
            in: [first, second],
            excludingSpanID: first.span.id,
            from: base.addingTimeInterval(20),
            rewinding: false
        ))
        XCTAssertEqual(forward.spanID, second.span.id)
        XCTAssertEqual(forward.timestamp, base.addingTimeInterval(30))
    }

    func testScrollIgnoresNonFiniteDelta() async throws {
        let base = Date(timeIntervalSinceReferenceDate: 10_000)
        let entries = [
            makeEntry(start: base, end: base.addingTimeInterval(10)),
            makeEntry(start: base.addingTimeInterval(20), end: base.addingTimeInterval(30))
        ]
        let viewModel = try await makeViewModel(
            entries: entries,
            referenceDate: base.addingTimeInterval(40)
        )
        let originalSpanID = viewModel.selectedSpanID
        let originalTimestamp = viewModel.selectedTimestamp

        viewModel.scrollBy(.nan)

        XCTAssertEqual(viewModel.selectedSpanID, originalSpanID)
        XCTAssertEqual(viewModel.selectedTimestamp, originalTimestamp)
    }

    func testSearchSelectionPreservesLogicalSpanIDAndTimestamp() throws {
        let base = Date(timeIntervalSinceReferenceDate: 10_000)
        let sharedFrameID = UUID()
        let first = makeEntry(
            frameID: sharedFrameID,
            start: base,
            end: base.addingTimeInterval(10)
        )
        let second = makeEntry(
            frameID: sharedFrameID,
            start: base.addingTimeInterval(30),
            end: base.addingTimeInterval(40)
        )
        let selectedTime = base.addingTimeInterval(6)

        let preserved = try XCTUnwrap(preservingTimelineSelection(
            in: [first, second],
            preferredSpanID: first.span.id,
            target: selectedTime,
            preferLatestWhenMissing: false
        ))

        XCTAssertEqual(preserved.spanID, first.span.id)
        XCTAssertEqual(preserved.timestamp, selectedTime)
        XCTAssertEqual(first.frame.id, second.frame.id, "Physical identity must remain separate from span identity")
    }

    func testPendingEmptySearchProjectionDoesNotEraseAuthoritativeSelection() async throws {
        let base = Date(timeIntervalSinceReferenceDate: 10_000)
        let entry = makeEntry(start: base, end: base.addingTimeInterval(20))
        let viewModel = try await makeViewModel(entries: [entry], referenceDate: base.addingTimeInterval(30))
        let selectedTime = base.addingTimeInterval(7)
        viewModel.setSelectedTimestamp(selectedTime)

        viewModel.isSearching = true
        viewModel.searchQuery = "not resolved yet"
        viewModel.prefetchImagesNearSelection()

        XCTAssertTrue(viewModel.displayedEntries.isEmpty)
        XCTAssertEqual(viewModel.selectedSpanID, entry.span.id)
        XCTAssertEqual(viewModel.selectedTimestamp, selectedTime)
    }

    func testDisplayFallbackSelectsLatestObservation() throws {
        let base = Date(timeIntervalSinceReferenceDate: 10_000)
        let laterInArrayButOlder = makeEntry(
            start: base.addingTimeInterval(50),
            end: base.addingTimeInterval(55)
        )
        let latestObservation = makeEntry(
            start: base.addingTimeInterval(10),
            end: base.addingTimeInterval(80)
        )

        let selection = try XCTUnwrap(preservingTimelineSelection(
            in: [latestObservation, laterInArrayButOlder],
            preferredSpanID: UUID(),
            target: base,
            preferLatestWhenMissing: true
        ))

        XCTAssertEqual(selection.spanID, latestObservation.span.id)
        XCTAssertEqual(selection.timestamp, latestObservation.span.observedThroughAt)
    }

    func testPrefetchUsesThreeNeighbourRadiusAndDeduplicatesPhysicalFrames() {
        let base = Date(timeIntervalSinceReferenceDate: 10_000)
        let sharedFrameID = UUID()
        var entries: [TimelineEntry] = []
        for index in 0..<9 {
            let frameID = index == 3 || index == 4 ? sharedFrameID : UUID()
            let start = base.addingTimeInterval(TimeInterval(index * 10))
            entries.append(makeEntry(
                frameID: frameID,
                start: start,
                end: start.addingTimeInterval(1)
            ))
        }

        let prefetched = timelinePrefetchFrames(entries: entries, selectedIndex: 4, radius: 3)

        XCTAssertEqual(
            prefetched.map { $0.id },
            [entries[1].frame.id, entries[2].frame.id, entries[5].frame.id, entries[6].frame.id, entries[7].frame.id]
        )
    }

    func testPrefetchKeyChangesWhenSameCountProjectionChangesNeighbours() {
        let base = Date(timeIntervalSinceReferenceDate: 10_000)
        let selected = makeEntry(start: base.addingTimeInterval(10), end: base.addingTimeInterval(11))
        let firstProjection = [
            makeEntry(start: base, end: base.addingTimeInterval(1)),
            selected,
            makeEntry(start: base.addingTimeInterval(20), end: base.addingTimeInterval(21))
        ]
        let secondProjection = [
            firstProjection[0],
            selected,
            makeEntry(start: base.addingTimeInterval(22), end: base.addingTimeInterval(23))
        ]

        let firstKey = timelinePrefetchProjectionKey(
            entries: firstProjection,
            selectedSpanID: selected.span.id,
            radius: 3
        )
        let secondKey = timelinePrefetchProjectionKey(
            entries: secondProjection,
            selectedSpanID: selected.span.id,
            radius: 3
        )

        XCTAssertNotEqual(firstKey, secondKey)
        XCTAssertEqual(
            firstKey,
            timelinePrefetchProjectionKey(
                entries: firstProjection,
                selectedSpanID: selected.span.id,
                radius: 3
            )
        )
    }

    func testExportSelectionUsesLogicalTimestampAndPhysicalFrame() async throws {
        let base = Date(timeIntervalSinceReferenceDate: 10_000)
        let entry = makeEntry(start: base, end: base.addingTimeInterval(30))
        let viewModel = try await makeViewModel(entries: [entry], referenceDate: base.addingTimeInterval(40))
        let selectedTime = base.addingTimeInterval(17)

        viewModel.setSelectedTimestamp(selectedTime)
        let export = try XCTUnwrap(viewModel.currentExportSelection)

        XCTAssertEqual(export.frame.id, entry.frame.id)
        XCTAssertEqual(export.timestamp, selectedTime)
        XCTAssertNotEqual(export.timestamp, entry.frame.timestamp)
    }

    func testFutureSpanDoesNotShiftFiveMinuteSearchCutoff() async throws {
        let semanticNow = Date(timeIntervalSinceReferenceDate: 10_000)
        let future = makeEntry(
            start: semanticNow.addingTimeInterval(600),
            end: semanticNow.addingTimeInterval(610)
        )
        let recent = makeEntry(
            start: semanticNow.addingTimeInterval(-220),
            end: semanticNow.addingTimeInterval(-200)
        )
        let image = try XCTUnwrap(TestImageFactory.makeSolidImage(width: 8, height: 8, level: 90))
        let repository = OverlayTimelineRepositoryProbe(entries: [recent, future], image: image)
        let buffer = try await makeBuffer(repository: repository)
        await buffer.textCache.setText(
            "future-safe needle",
            for: recent.frame.id,
            timestamp: timelineSpanBounds(for: recent).end
        )
        let viewModel = makeViewModel(
            entries: [recent, future],
            buffer: buffer,
            referenceDate: semanticNow
        )

        XCTAssertEqual(viewModel.semanticReferenceDate, semanticNow)
        XCTAssertEqual(viewModel.timelineReferenceDate, timelineSpanBounds(for: future).end)

        viewModel.isSearching = true
        viewModel.searchTimeScope = .fiveMinutes
        viewModel.searchQuery = "needle"
        viewModel.performSearch(immediately: true)
        try await waitUntil { !viewModel.isSearchLoading }

        XCTAssertEqual(viewModel.searchResults.map(\.span.id), [recent.span.id])
    }

    /// Search must filter the immutable leased snapshot after collecting all
    /// matching IDs. More than the former 10,000-row global cap from another
    /// display cannot hide the selected display's matching timeline spans.
    func testSearchSelectedDisplayIsNotTruncatedByMoreThanTenThousandOtherDisplayMatches() async throws {
        let base = Date(timeIntervalSinceReferenceDate: 10_000)
        let displayA = DisplayInfo(id: UUID(), displayID: 1, name: "A")
        let displayB = DisplayInfo(id: UUID(), displayID: 2, name: "B")
        let image = try XCTUnwrap(TestImageFactory.makeSolidImage(width: 8, height: 8, level: 97))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverlayTimelineTests-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        let otherEntries = (0...10_000).map { index in
            makeEntry(
                start: base.addingTimeInterval(TimeInterval(20_000 + index)),
                end: base.addingTimeInterval(TimeInterval(20_000 + index)),
                displayID: displayA.id
            )
        }
        let selectedEntries = (0..<40).map { index in
            makeEntry(
                start: base.addingTimeInterval(TimeInterval(index)),
                end: base.addingTimeInterval(TimeInterval(index)),
                displayID: displayB.id
            )
        }
        let allEntries = otherEntries + selectedEntries
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: OverlayTimelineRepositoryProbe(entries: allEntries, image: image)
        )
        try seedSearchRows(
            allEntries,
            text: "display-cap-regression",
            in: directory
        )
        let viewModel = OverlayViewModel(
            timelineEntries: selectedEntries,
            leasedTimelineEntries: allEntries,
            frameBuffer: buffer,
            recentTimelineWindow: 300,
            rewindHistoryOption: .twentyFourHours,
            availableDisplays: [displayA, displayB],
            activeDisplay: displayB,
            primaryDisplayID: displayA.id,
            timelineReferenceDate: base.addingTimeInterval(40_000),
            onDismiss: {},
            onOpenSettings: {}
        )

        viewModel.isSearching = true
        viewModel.searchQuery = "display-cap"
        viewModel.performSearch(immediately: true)
        try await waitUntil { !viewModel.isSearchLoading }

        XCTAssertEqual(viewModel.searchResults.map(\.span.id), selectedEntries.map(\.span.id))
    }

    func testFutureSpanDoesNotShiftOtherDisplayRetentionOnSwitch() async throws {
        let semanticNow = Date(timeIntervalSinceReferenceDate: 10_000)
        let displayA = DisplayInfo(id: UUID(), displayID: 1, name: "A")
        let displayB = DisplayInfo(id: UUID(), displayID: 2, name: "B")
        let futureA = makeEntry(
            start: semanticNow.addingTimeInterval(1_000),
            end: semanticNow.addingTimeInterval(1_010),
            displayID: displayA.id
        )
        let retainedB = makeEntry(
            start: semanticNow.addingTimeInterval(-1_010),
            end: semanticNow.addingTimeInterval(-1_000),
            displayID: displayB.id
        )
        let expiredB = makeEntry(
            start: semanticNow.addingTimeInterval(-2_010),
            end: semanticNow.addingTimeInterval(-2_000),
            displayID: displayB.id
        )
        let image = try XCTUnwrap(TestImageFactory.makeSolidImage(width: 8, height: 8, level: 91))
        let repository = OverlayTimelineRepositoryProbe(
            entries: [expiredB, retainedB, futureA],
            image: image
        )
        let buffer = try await makeBuffer(repository: repository)
        let viewModel = OverlayViewModel(
            timelineEntries: [futureA],
            frameBuffer: buffer,
            recentTimelineWindow: 300,
            rewindHistoryOption: .thirtyMinutes,
            availableDisplays: [displayA, displayB],
            activeDisplay: displayA,
            primaryDisplayID: displayA.id,
            timelineReferenceDate: semanticNow,
            onDismiss: {},
            onOpenSettings: {}
        )

        viewModel.switchDisplay(to: displayB)

        XCTAssertEqual(viewModel.semanticReferenceDate, semanticNow)
        XCTAssertEqual(viewModel.timelineReferenceDate, semanticNow)
        XCTAssertEqual(viewModel.timelineEntries.map(\.span.id), [retainedB.span.id])
        XCTAssertEqual(viewModel.selectedSpanID, retainedB.span.id)

        viewModel.switchDisplay(to: displayA)

        XCTAssertEqual(viewModel.timelineReferenceDate, timelineSpanBounds(for: futureA).end)
        XCTAssertEqual(viewModel.timelineEntries.map(\.span.id), [futureA.span.id])
        XCTAssertEqual(viewModel.selectedSpanID, futureA.span.id)
    }

    func testCroppedExportSnapshotsSelectedLogicalTimestamp() async throws {
        let base = Date(timeIntervalSinceReferenceDate: 10_000)
        let entry = makeEntry(start: base, end: base.addingTimeInterval(30))
        let image = try XCTUnwrap(TestImageFactory.makeSolidImage(width: 8, height: 8, level: 92))
        let repository = OverlayTimelineRepositoryProbe(entries: [entry], image: image)
        let buffer = try await makeBuffer(repository: repository)
        let viewModel = makeViewModel(
            entries: [entry],
            buffer: buffer,
            referenceDate: base.addingTimeInterval(40)
        )
        let defaults = UserDefaults.standard
        let keys = [
            AppStorageKey.screenshotSaveToFolder,
            AppStorageKey.screenshotSaveToClipboard,
            AppStorageKey.saveScreenshotSoundEnabled,
            AppStorageKey.hasSeenSaveQualityInfo
        ]
        var priorValues: [String: Any] = [:]
        var missingKeys: Set<String> = []
        for key in keys {
            if let value = defaults.object(forKey: key) {
                priorValues[key] = value
            } else {
                missingKeys.insert(key)
            }
        }
        defer {
            for key in keys {
                if missingKeys.contains(key) {
                    defaults.removeObject(forKey: key)
                } else if let value = priorValues[key] {
                    defaults.set(value, forKey: key)
                }
            }
        }
        defaults.set(true, forKey: AppStorageKey.screenshotSaveToFolder)
        defaults.set(false, forKey: AppStorageKey.screenshotSaveToClipboard)
        defaults.set(false, forKey: AppStorageKey.saveScreenshotSoundEnabled)
        defaults.set(true, forKey: AppStorageKey.hasSeenSaveQualityInfo)

        let exportTimestamp = base.addingTimeInterval(7)
        viewModel.setSelectedTimestamp(exportTimestamp)
        viewModel.saveCroppedScreenshot(image: image)
        viewModel.setSelectedTimestamp(base.addingTimeInterval(18))
        try await waitUntil { await repository.croppedExportTimestamps().count == 1 }

        let croppedExportTimestamps = await repository.croppedExportTimestamps()
        XCTAssertEqual(croppedExportTimestamps, [exportTimestamp])
    }

    func testFormatRelativeTimeClampsFutureTimestampsToZero() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        XCTAssertEqual(formatRelativeTime(now.addingTimeInterval(30), now: now), "0s ago")
    }

    func testFormatRelativeTimeBoundaries() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        XCTAssertEqual(formatRelativeTime(now, now: now), "0s ago")
        XCTAssertEqual(formatRelativeTime(now.addingTimeInterval(-59), now: now), "59s ago")
        XCTAssertEqual(formatRelativeTime(now.addingTimeInterval(-60), now: now), "1m 0s ago")
        XCTAssertEqual(formatRelativeTime(now.addingTimeInterval(-3_599), now: now), "59m 59s ago")
        XCTAssertEqual(formatRelativeTime(now.addingTimeInterval(-3_600), now: now), "1h 0m 0s ago")
    }

    // MARK: - Search failure state

    /// A cache-level search failure must not read as "no matches": the error
    /// state shows, no-results stays hidden, and the diagnostics sink gets a
    /// content-free failure line so reports can tell failure from a true
    /// empty match.
    func testSearchStoreFailureShowsErrorInsteadOfNoResults() async throws {
        let base = Date(timeIntervalSinceReferenceDate: 10_000)
        let entry = makeEntry(start: base, end: base.addingTimeInterval(30))
        let diagnostics = InMemoryDiagnosticsLog()
        let buffer = try await makeBufferWithSymlinkedTextCache(
            repository: OverlayTimelineRepositoryProbe(
                entries: [entry],
                image: try XCTUnwrap(TestImageFactory.makeSolidImage(width: 8, height: 8, level: 93))
            ),
            diagnosticsLog: diagnostics
        )
        let viewModel = makeViewModel(
            entries: [entry],
            buffer: buffer,
            referenceDate: base.addingTimeInterval(40)
        )

        viewModel.isSearching = true
        viewModel.searchQuery = "needle"
        viewModel.performSearch(immediately: true)
        try await waitUntil { !viewModel.isSearchLoading }

        XCTAssertTrue(viewModel.shouldShowSearchFailure)
        XCTAssertFalse(viewModel.shouldShowNoSearchResults)
        XCTAssertTrue(viewModel.searchResults.isEmpty)

        let failureLines = diagnostics.entries.filter {
            $0.category == "Search" && $0.message.contains("outcome=failed")
        }
        XCTAssertEqual(failureLines.count, 1)
        XCTAssertFalse(failureLines[0].message.contains("needle"))
    }

    /// After the trigger is removed, a deliberate retry on the same view
    /// model clears the error and returns the previously indexed rows.
    func testSearchRetryAfterTriggerRemovedShowsResults() async throws {
        let base = Date(timeIntervalSinceReferenceDate: 10_000)
        let frameID = UUID()
        let entry = makeEntry(frameID: frameID, start: base, end: base.addingTimeInterval(30))
        let repository = OverlayTimelineRepositoryProbe(
            entries: [entry],
            image: try XCTUnwrap(TestImageFactory.makeSolidImage(width: 8, height: 8, level: 94))
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverlayTimelineTests-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        do {
            let seed = TextCache(directory: directory)
            await seed.setText("recovery needle", for: frameID, timestamp: base)
        }

        let databaseURL = directory.appendingPathComponent("text_cache.sqlite")
        let quarantine = directory.appendingPathComponent("quarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        for url in [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try FileManager.default.moveItem(at: url, to: quarantine.appendingPathComponent(url.lastPathComponent))
        }
        let externalURL = directory.appendingPathComponent("external.sqlite")
        try Data("sentinel".utf8).write(to: externalURL)
        try FileManager.default.createSymbolicLink(at: databaseURL, withDestinationURL: externalURL)

        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository
        )
        let viewModel = makeViewModel(
            entries: [entry],
            buffer: buffer,
            referenceDate: base.addingTimeInterval(40)
        )

        viewModel.isSearching = true
        viewModel.searchQuery = "recovery"
        viewModel.performSearch(immediately: true)
        try await waitUntil { !viewModel.isSearchLoading }
        XCTAssertTrue(viewModel.shouldShowSearchFailure)

        try FileManager.default.removeItem(at: databaseURL)
        for name in try FileManager.default.contentsOfDirectory(atPath: quarantine.path) {
            try FileManager.default.moveItem(
                at: quarantine.appendingPathComponent(name),
                to: directory.appendingPathComponent(name)
            )
        }

        // Just over the cache's actor-local reconnect interval.
        try await Task.sleep(for: .milliseconds(1_200))
        viewModel.retrySearch()
        try await waitUntil { !viewModel.isSearchLoading }

        XCTAssertFalse(viewModel.shouldShowSearchFailure)
        XCTAssertEqual(viewModel.searchResults.map(\.span.id), [entry.span.id])
    }

    /// The failure marker belongs to the request that produced it: changing
    /// the query or clearing search must never show a stale error.
    func testSearchErrorDoesNotLeakAcrossRequestChanges() async throws {
        let base = Date(timeIntervalSinceReferenceDate: 10_000)
        let entry = makeEntry(start: base, end: base.addingTimeInterval(30))
        let buffer = try await makeBufferWithSymlinkedTextCache(
            repository: OverlayTimelineRepositoryProbe(
                entries: [entry],
                image: try XCTUnwrap(TestImageFactory.makeSolidImage(width: 8, height: 8, level: 95))
            )
        )
        let viewModel = makeViewModel(
            entries: [entry],
            buffer: buffer,
            referenceDate: base.addingTimeInterval(40)
        )

        viewModel.isSearching = true
        viewModel.searchQuery = "first"
        viewModel.performSearch(immediately: true)
        try await waitUntil { !viewModel.isSearchLoading }
        XCTAssertTrue(viewModel.shouldShowSearchFailure)

        viewModel.searchQuery = "second"
        XCTAssertFalse(viewModel.shouldShowSearchFailure)

        viewModel.searchTimeScope = .fiveMinutes
        viewModel.performSearch(immediately: true)
        try await waitUntil { !viewModel.isSearchLoading }
        XCTAssertTrue(viewModel.shouldShowSearchFailure)

        viewModel.clearSearch()
        XCTAssertFalse(viewModel.shouldShowSearchFailure)
    }

    /// A healthy store with a genuine empty match still shows "no matches"
    /// and must not be reported as a failure.
    func testHealthyNoMatchShowsNoResultsNotError() async throws {
        let base = Date(timeIntervalSinceReferenceDate: 10_000)
        let entry = makeEntry(start: base, end: base.addingTimeInterval(30))
        let repository = OverlayTimelineRepositoryProbe(
            entries: [entry],
            image: try XCTUnwrap(TestImageFactory.makeSolidImage(width: 8, height: 8, level: 96))
        )
        let buffer = try await makeBuffer(repository: repository)
        let viewModel = makeViewModel(
            entries: [entry],
            buffer: buffer,
            referenceDate: base.addingTimeInterval(40)
        )

        viewModel.isSearching = true
        viewModel.searchQuery = "absent"
        viewModel.performSearch(immediately: true)
        try await waitUntil { !viewModel.isSearchLoading }

        XCTAssertTrue(viewModel.shouldShowNoSearchResults)
        XCTAssertFalse(viewModel.shouldShowSearchFailure)
    }

    /// Each completed search writes one no-content diagnostics line with the
    /// boundary counts a report needs: index hits, matches inside the leased
    /// timeline, and matches after the scope/display filters.
    func testCompletedSearchLogsBoundaryCounts() async throws {
        let base = Date(timeIntervalSinceReferenceDate: 10_000)
        let matching = makeEntry(start: base, end: base.addingTimeInterval(30))
        // Recent OCR text on a span that ends before the search cutoff:
        // hits the index and the leased set but is dropped by the scope filter.
        let stale = makeEntry(
            start: base.addingTimeInterval(-500),
            end: base.addingTimeInterval(-400)
        )
        let ghostFrameID = UUID()
        let diagnostics = InMemoryDiagnosticsLog()
        let repository = OverlayTimelineRepositoryProbe(
            entries: [stale, matching],
            image: try XCTUnwrap(TestImageFactory.makeSolidImage(width: 8, height: 8, level: 97))
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverlayTimelineTests-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        let buffer = try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: diagnostics,
            frameRepository: repository
        )
        await buffer.textCache.setText("alpha needle", for: matching.frame.id, timestamp: base)
        await buffer.textCache.setText("stale needle", for: stale.frame.id, timestamp: base)
        await buffer.textCache.setText("ghost needle", for: ghostFrameID, timestamp: base)
        let viewModel = makeViewModel(
            entries: [stale, matching],
            buffer: buffer,
            referenceDate: base.addingTimeInterval(80)
        )

        viewModel.isSearching = true
        viewModel.searchTimeScope = .fiveMinutes
        viewModel.searchQuery = "needle"
        viewModel.performSearch(immediately: true)
        try await waitUntil { !viewModel.isSearchLoading }

        XCTAssertFalse(viewModel.shouldShowSearchFailure)
        XCTAssertEqual(viewModel.searchResults.map(\.span.id), [matching.span.id])

        let searchLines = diagnostics.entries.filter { $0.category == "Search" }
        XCTAssertEqual(searchLines.count, 1)
        let message = searchLines[0].message
        XCTAssertTrue(message.contains("outcome=ok"))
        XCTAssertTrue(message.contains("scope=fiveMinutes"))
        XCTAssertTrue(message.contains("activeDisplay=false"))
        XCTAssertTrue(message.contains("indexHits=3"))
        XCTAssertTrue(message.contains("leasedMatches=2"))
        XCTAssertTrue(message.contains("filteredMatches=1"))
        XCTAssertTrue(message.contains("unleasedHits=1"))
        XCTAssertTrue(message.contains("timeDropped=1"))
        XCTAssertTrue(message.contains("displayDropped=0"))
        XCTAssertTrue(message.contains("cacheMs="))
        XCTAssertTrue(message.contains("filterMs="))
        XCTAssertFalse(message.contains("needle"))
        XCTAssertFalse(message.contains(ghostFrameID.uuidString))
        XCTAssertFalse(message.contains(directory.path))
    }

    private func makeBufferWithSymlinkedTextCache(
        repository: any FrameRepository,
        diagnosticsLog: CaptureInstrumentationLogSink? = nil
    ) async throws -> FrameBuffer {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverlayTimelineTests-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let externalURL = directory.appendingPathComponent("external.sqlite")
        try Data("sentinel".utf8).write(to: externalURL)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("text_cache.sqlite"),
            withDestinationURL: externalURL
        )
        return try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: diagnosticsLog,
            frameRepository: repository
        )
    }

    private func makeViewModel(
        entries: [TimelineEntry],
        referenceDate: Date
    ) async throws -> OverlayViewModel {
        let buffer = try await makeBuffer(repository: nil)
        return makeViewModel(entries: entries, buffer: buffer, referenceDate: referenceDate)
    }

    private func makeBuffer(repository: (any FrameRepository)?) async throws -> FrameBuffer {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverlayTimelineTests-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        return try await FrameBuffer(
            retentionPolicy: .default24Hours,
            storageDirectory: directory,
            diagnosticsLog: nil,
            frameRepository: repository
        )
    }

    private func makeViewModel(
        entries: [TimelineEntry],
        buffer: FrameBuffer,
        referenceDate: Date
    ) -> OverlayViewModel {
        OverlayViewModel(
            timelineEntries: entries,
            frameBuffer: buffer,
            recentTimelineWindow: 300,
            rewindHistoryOption: .twentyFourHours,
            availableDisplays: [],
            activeDisplay: nil,
            primaryDisplayID: nil,
            timelineReferenceDate: referenceDate,
            onDismiss: {},
            onOpenSettings: {}
        )
    }

    private func seedSearchRows(_ entries: [TimelineEntry], text: String, in directory: URL) throws {
        var connection: OpaquePointer?
        let url = directory.appendingPathComponent("text_cache.sqlite")
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let connection else {
            throw TextCacheError.sqlite("Failed to open synthetic search store")
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 2_000)
        XCTAssertEqual(sqlite3_exec(connection, "BEGIN IMMEDIATE;", nil, nil, nil), SQLITE_OK)
        defer { _ = sqlite3_exec(connection, "ROLLBACK;", nil, nil, nil) }
        var primary: OpaquePointer?
        var fts: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(connection, "INSERT INTO frame_text(frame_id, timestamp, text) VALUES (?, ?, ?);", -1, &primary, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_prepare_v2(connection, "INSERT INTO frame_text_fts(frame_id, text) VALUES (?, ?);", -1, &fts, nil), SQLITE_OK)
        defer { sqlite3_finalize(primary); sqlite3_finalize(fts) }
        for entry in entries {
            let id = entry.frame.id.uuidString
            sqlite3_bind_text(primary, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_double(primary, 2, timelineSpanBounds(for: entry).end.timeIntervalSince1970)
            sqlite3_bind_text(primary, 3, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            XCTAssertEqual(sqlite3_step(primary), SQLITE_DONE)
            sqlite3_reset(primary); sqlite3_clear_bindings(primary)
            sqlite3_bind_text(fts, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(fts, 2, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            XCTAssertEqual(sqlite3_step(fts), SQLITE_DONE)
            sqlite3_reset(fts); sqlite3_clear_bindings(fts)
        }
        XCTAssertEqual(sqlite3_exec(connection, "COMMIT;", nil, nil, nil), SQLITE_OK)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for asynchronous operation")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeEntry(
        id: UUID = UUID(),
        frameID: UUID = UUID(),
        start: Date,
        end: Date,
        hash: UInt64 = 0,
        displayID: UUID? = nil
    ) -> TimelineEntry {
        let frame = StoredFrame(
            id: frameID,
            timestamp: start,
            hash: hash,
            displayID: displayID,
            displayName: nil
        )
        return TimelineEntry(
            span: TimelineSpan(
                id: id,
                frameID: frameID,
                sessionID: UUID(),
                startedAt: start,
                observedThroughAt: end,
                observationCount: 1,
                displayID: displayID,
                displayName: nil
            ),
            frame: frame
        )
    }
}

/// No-content diagnostics sink for asserting the Search category lines the
/// overlay emits per completed search.
private final class InMemoryDiagnosticsLog: CaptureInstrumentationLogSink {
    private(set) var entries: [(category: String, message: String)] = []

    func log(_ category: String, _ message: String) {
        entries.append((category, message))
    }
}

private actor BlockingPayloadLease: FrameRepositoryPayloadLease {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var releaseRequestWaiters: [CheckedContinuation<Void, Never>] = []

    func release() async -> FrameRepositoryMaintenanceResult {
        let waiters = releaseRequestWaiters
        releaseRequestWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return .noOp
    }

    func waitUntilReleaseRequested() async {
        guard releaseContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            releaseRequestWaiters.append(continuation)
        }
    }

    func hasReleaseBeenRequested() -> Bool {
        releaseContinuation != nil
    }

    func permitRelease() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor OverlayTimelineRepositoryProbe: FrameRepository {
    enum OperationEvent: Equatable {
        case exportStarted
        case exportFinished
        case memoryPressure
    }

    private var entries: [TimelineEntry]
    private let image: CGImage
    private var currentTimelineLeases: [any FrameRepositoryPayloadLease]
    private var croppedTimestampValues: [Date] = []
    private var shouldSuspendNextCurrentTimelineSnapshot = false
    private var currentTimelineSnapshotContinuation: CheckedContinuation<Void, Never>?
    private var currentTimelineSnapshotWaiters: [CheckedContinuation<Void, Never>] = []
    private var shouldSuspendNextPressure = false
    private var pressureContinuation: CheckedContinuation<Void, Never>?
    private var pressureWaiters: [CheckedContinuation<Void, Never>] = []
    private var shouldSuspendNextExport = false
    private var exportContinuation: CheckedContinuation<Void, Never>?
    private var exportWaiters: [CheckedContinuation<Void, Never>] = []
    private var operationEventValues: [OperationEvent] = []

    init(
        entries: [TimelineEntry],
        image: CGImage,
        currentTimelineLease: any FrameRepositoryPayloadLease = NoopFrameRepositoryPayloadLease(),
        subsequentTimelineLeases: [any FrameRepositoryPayloadLease] = []
    ) {
        self.entries = entries
        self.image = image
        self.currentTimelineLeases = [currentTimelineLease] + subsequentTimelineLeases
    }

    func cleanupOrphans() {}

    func orderedFrames() -> [StoredFrame] {
        var seen: Set<UUID> = []
        return entries.compactMap { entry in
            seen.insert(entry.frame.id).inserted ? entry.frame : nil
        }
    }

    func orderedTimeline() -> [TimelineEntry] {
        entries
    }

    func acquireCurrentTimelineSnapshotLease() async -> FrameRepositoryLeasedTimelineSnapshot {
        if shouldSuspendNextCurrentTimelineSnapshot {
            shouldSuspendNextCurrentTimelineSnapshot = false
            let waiters = currentTimelineSnapshotWaiters
            currentTimelineSnapshotWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                currentTimelineSnapshotContinuation = continuation
            }
        }
        let lease: any FrameRepositoryPayloadLease
        if currentTimelineLeases.count > 1 {
            lease = currentTimelineLeases.removeFirst()
        } else {
            lease = currentTimelineLeases[0]
        }
        return FrameRepositoryLeasedTimelineSnapshot(
            entries: entries,
            lease: lease
        )
    }

    func beginCaptureSession(at startedAt: Date) -> CaptureSession {
        CaptureSession(id: UUID(), startedAt: startedAt, endedAt: nil, endReason: nil)
    }

    func endCaptureSession(
        id: UUID,
        reason: CaptureSessionEndReason
    ) -> FrameRepositoryEffects { .empty }

    func recordEncodedCapture(
        _ frame: StoredFrame,
        jpegData: Data
    ) -> FrameRepositorySaveResult {
        let entry = TimelineEntry(
            span: TimelineSpan(
                id: UUID(),
                frameID: frame.id,
                sessionID: UUID(),
                startedAt: frame.timestamp,
                observedThroughAt: frame.timestamp,
                observationCount: 1,
                displayID: frame.displayID,
                displayName: frame.displayName
            ),
            frame: frame
        )
        entries.append(entry)
        return FrameRepositorySaveResult(mutation: .inserted(entry), outcome: .volatileFrame)
    }

    func loadFullImage(id: UUID) -> CGImage {
        image
    }

    func loadThumbnail(id: UUID) -> CGImage? {
        image
    }

    func loadSearchIndexImage(id: UUID, maxPixelSize: Int) -> CGImage {
        image
    }

    func exportFrame(id: UUID, timestamp: Date) async -> URL {
        operationEventValues.append(.exportStarted)
        if shouldSuspendNextExport {
            shouldSuspendNextExport = false
            let waiters = exportWaiters
            exportWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                exportContinuation = continuation
            }
        }
        operationEventValues.append(.exportFinished)
        return FileManager.default.temporaryDirectory.appendingPathComponent("overlay-timeline-export.png")
    }

    func exportCroppedImage(_ image: CGImage, timestamp: Date) -> URL {
        croppedTimestampValues.append(timestamp)
        return FileManager.default.temporaryDirectory.appendingPathComponent("overlay-timeline-crop.png")
    }

    func pruneSpans(ids: Set<UUID>) -> FrameRepositoryInvalidation {
        let candidateFrameIDs = Set(entries.lazy.filter { ids.contains($0.span.id) }.map(\.frame.id))
        entries.removeAll { ids.contains($0.span.id) }
        return FrameRepositoryInvalidation(
            spanIDs: ids,
            finalPhysicalFrameIDs: candidateFrameIDs.subtracting(entries.map(\.frame.id))
        )
    }

    func respondToMemoryPressure(
        _ level: FrameMemoryPressureLevel
    ) async -> FrameRepositoryMaintenanceResult {
        operationEventValues.append(.memoryPressure)
        if shouldSuspendNextPressure {
            shouldSuspendNextPressure = false
            let waiters = pressureWaiters
            pressureWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                pressureContinuation = continuation
            }
        }
        return .noOp
    }

    func clear() {
        entries.removeAll()
    }

    func durableJPEGPayloadBytes() -> Int64 { 0 }

    func storageStatistics() -> FrameStorageStatistics { .empty }

    func flush() {}

    func croppedExportTimestamps() -> [Date] {
        croppedTimestampValues
    }

    func suspendNextCurrentTimelineSnapshot() {
        shouldSuspendNextCurrentTimelineSnapshot = true
    }

    func waitUntilCurrentTimelineSnapshotRequested() async {
        guard currentTimelineSnapshotContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            currentTimelineSnapshotWaiters.append(continuation)
        }
    }

    func resumeCurrentTimelineSnapshot() {
        currentTimelineSnapshotContinuation?.resume()
        currentTimelineSnapshotContinuation = nil
    }

    func suspendNextPressure() {
        shouldSuspendNextPressure = true
    }

    func waitUntilPressureRequested() async {
        guard shouldSuspendNextPressure else { return }
        await withCheckedContinuation { continuation in
            pressureWaiters.append(continuation)
        }
    }

    func resumePressure() {
        pressureContinuation?.resume()
        pressureContinuation = nil
    }

    func suspendNextExport() {
        shouldSuspendNextExport = true
    }

    func waitUntilExportRequested() async {
        guard exportContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            exportWaiters.append(continuation)
        }
    }

    func resumeExport() {
        exportContinuation?.resume()
        exportContinuation = nil
    }

    func operationEvents() -> [OperationEvent] {
        operationEventValues
    }
}
