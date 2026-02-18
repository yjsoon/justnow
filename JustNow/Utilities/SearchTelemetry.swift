//
//  SearchTelemetry.swift
//  JustNow
//

import Foundation

struct SearchTelemetrySnapshot: Sendable {
    let queueDepth: Int
    let queueCapacity: Int
    let ocrPerSecond: Double
    let averageOCRDuration: TimeInterval
    let p95OCRDuration: TimeInterval
    let averageIndexLag: TimeInterval
    let p95IndexLag: TimeInterval
    let warmSearchP50: TimeInterval
    let warmSearchCount: Int
    let coldSearchP50: TimeInterval
    let coldSearchCount: Int

    static let empty = SearchTelemetrySnapshot(
        queueDepth: 0,
        queueCapacity: 0,
        ocrPerSecond: 0,
        averageOCRDuration: 0,
        p95OCRDuration: 0,
        averageIndexLag: 0,
        p95IndexLag: 0,
        warmSearchP50: 0,
        warmSearchCount: 0,
        coldSearchP50: 0,
        coldSearchCount: 0
    )
}

actor SearchTelemetry {
    static let shared = SearchTelemetry()

    private let ocrWindow: TimeInterval = 60
    private let summaryInterval: TimeInterval = 30
    private let maxSamples: Int = 200

    private var queueDepth = 0
    private var queueCapacity = 0

    private var ocrCompletionTimestamps: [Date] = []
    private var ocrDurationSamples: [TimeInterval] = []
    private var indexLagSamples: [TimeInterval] = []

    private var warmSearchDurations: [TimeInterval] = []
    private var coldSearchDurations: [TimeInterval] = []

    private var lastSummaryLog: Date = .distantPast

    func snapshot() -> SearchTelemetrySnapshot {
        let now = Date()
        trimOldOCRCompletions(now: now)

        return SearchTelemetrySnapshot(
            queueDepth: queueDepth,
            queueCapacity: queueCapacity,
            ocrPerSecond: Double(ocrCompletionTimestamps.count) / ocrWindow,
            averageOCRDuration: average(ocrDurationSamples),
            p95OCRDuration: percentile(ocrDurationSamples, percentile: 0.95),
            averageIndexLag: average(indexLagSamples),
            p95IndexLag: percentile(indexLagSamples, percentile: 0.95),
            warmSearchP50: percentile(warmSearchDurations, percentile: 0.5),
            warmSearchCount: warmSearchDurations.count,
            coldSearchP50: percentile(coldSearchDurations, percentile: 0.5),
            coldSearchCount: coldSearchDurations.count
        )
    }

    func recordQueueDepth(depth: Int, capacity: Int) {
        queueDepth = max(0, depth)
        queueCapacity = max(0, capacity)
        maybeLogSummary(now: Date(), reason: "queue")
    }

    func recordBackgroundOCR(duration: TimeInterval, indexLag: TimeInterval) {
        let now = Date()

        ocrCompletionTimestamps.append(now)
        trimOldOCRCompletions(now: now)

        appendSample(max(duration, 0), to: &ocrDurationSamples)
        appendSample(max(indexLag, 0), to: &indexLagSamples)

        maybeLogSummary(now: now, reason: "index")
    }

    func recordSearch(
        duration: TimeInterval,
        wasCold: Bool,
        totalFrames: Int,
        uncachedFrames: Int,
        matches: Int,
        ocrRuns: Int,
        loadFailures: Int
    ) {
        let safeDuration = max(duration, 0)

        if wasCold {
            appendSample(safeDuration, to: &coldSearchDurations)
        } else {
            appendSample(safeDuration, to: &warmSearchDurations)
        }

        let mode = wasCold ? "cold" : "warm"
        print(
            String(
                format: "[SearchTelemetry] %@ search %.3fs (%d matches, %d/%d uncached, %d OCR runs, %d load failures)",
                mode,
                safeDuration,
                matches,
                uncachedFrames,
                totalFrames,
                ocrRuns,
                loadFailures
            )
        )

        maybeLogSummary(now: Date(), reason: "search")
    }

    private func appendSample(_ value: TimeInterval, to samples: inout [TimeInterval]) {
        samples.append(value)
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    private func trimOldOCRCompletions(now: Date) {
        let cutoff = now.addingTimeInterval(-ocrWindow)
        ocrCompletionTimestamps.removeAll { $0 < cutoff }
    }

    private func maybeLogSummary(now: Date, reason: String) {
        guard now.timeIntervalSince(lastSummaryLog) >= summaryInterval else { return }
        lastSummaryLog = now

        trimOldOCRCompletions(now: now)

        let ocrPerSecond = Double(ocrCompletionTimestamps.count) / ocrWindow
        let averageLag = average(indexLagSamples)
        let p95Lag = percentile(indexLagSamples, percentile: 0.95)

        let warmP50 = percentile(warmSearchDurations, percentile: 0.5)
        let coldP50 = percentile(coldSearchDurations, percentile: 0.5)

        print(
            String(
                format: "[SearchTelemetry] summary[%@] queue=%d/%d ocr=%.2f/s lag(avg=%.1fs p95=%.1fs) warm(p50=%.3fs n=%d) cold(p50=%.3fs n=%d)",
                reason,
                queueDepth,
                queueCapacity,
                ocrPerSecond,
                averageLag,
                p95Lag,
                warmP50,
                warmSearchDurations.count,
                coldP50,
                coldSearchDurations.count
            )
        )
    }

    private func average(_ values: [TimeInterval]) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func percentile(_ values: [TimeInterval], percentile: Double) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(max(Int((Double(sorted.count - 1) * percentile).rounded()), 0), sorted.count - 1)
        return sorted[index]
    }
}
