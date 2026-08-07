//
//  OverlayTimeline.swift
//  JustNow
//

import Foundation
import SwiftUI

private let barBackgroundColor = Color.black.opacity(0.85)
private let barBorderColor = Color.white.opacity(0.08)

private let clockTimeFormat: Date.FormatStyle = .dateTime
    .hour()
    .minute()
private let dayLabelTimeFormat: Date.FormatStyle = .dateTime
    .weekday(.abbreviated)
    .hour()
    .minute()
private let fullDateTimeFormat: Date.FormatStyle = .dateTime
    .day()
    .month(.abbreviated)
    .hour()
    .minute()
private let timelineMarkerTimeFormat: Date.FormatStyle = .dateTime
    .hour()
    .minute()

extension View {
    func darkBarBackground<S: InsettableShape>(in shape: S) -> some View {
        background(barBackgroundColor, in: shape)
            .overlay(shape.stroke(barBorderColor, lineWidth: 1))
    }
}

struct TimelineSlider: View {
    var viewModel: OverlayViewModel

    private var displayedEntries: [TimelineEntry] { viewModel.displayedEntries }
    private var frameCount: Int { displayedEntries.count }
    private var timelineMarkers: [TimelineMarker] {
        guard !(viewModel.isSearching && viewModel.hasSearchQuery) else { return [] }
        return timelineLandmarkMarkers(
            entries: displayedEntries,
            recentWindow: viewModel.recentTimelineWindow,
            now: viewModel.timelineReferenceDate
        )
    }

    private var colourSegments: [TimelineZoneFill] {
        guard !(viewModel.isSearching && viewModel.hasSearchQuery) else {
            return timelineColourSegments(entries: displayedEntries, borderPosition: nil)
        }

        let recentWindowPosition =
            timelineMarkers.first(where: { $0.targetAge == viewModel.recentTimelineWindow })?.position
            ?? resolveTimelineMarkerPosition(
                entries: displayedEntries,
                targetAge: viewModel.recentTimelineWindow,
                now: viewModel.timelineReferenceDate
            )
        return timelineColourSegments(
            entries: displayedEntries,
            borderPosition: recentWindowPosition
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            TimeLabels(
                entries: displayedEntries,
                referenceDate: viewModel.timelineReferenceDate
            )
                .offset(y: 19)

            SliderTrack(
                frameCount: frameCount,
                rangeStart: viewModel.timelineStartDate,
                rangeEnd: viewModel.timelineReferenceDate,
                selectedTimestamp: viewModel.selectedTimestamp,
                markers: timelineMarkers,
                colourSegments: colourSegments,
                accessibilityValue: viewModel.accessibilityTimelineValue,
                onTimestampChanged: viewModel.setSelectedTimestamp,
                onIncrement: viewModel.moveRight,
                onDecrement: viewModel.moveLeft
            )
            .frame(height: timelineMarkers.isEmpty ? 32 : 54)
            .padding(.horizontal, 8)
            .offset(y: 12)
        }
    }
}

struct TimelineFooter: View {
    var viewModel: OverlayViewModel
    let textGrabBannerState: TextGrabBannerState

    private var displayedEntries: [TimelineEntry] { viewModel.displayedEntries }
    private var frameCount: Int { displayedEntries.count }

    var body: some View {
        ZStack {
            footerMetadata
                .opacity(textGrabBannerState == .hint ? 1 : 0)

            if textGrabBannerState != .hint {
                TextGrabToast(state: textGrabBannerState)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(minHeight: 44)
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: textGrabBannerState)
    }

    @ViewBuilder
    private var footerMetadata: some View {
        HStack(spacing: 6) {
            if viewModel.isSearching && viewModel.hasSearchQuery {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Text(framePositionLabel)
                .fontWeight(.medium)
            if viewModel.currentEntry != nil {
                Text("·")
                    .foregroundStyle(.white.opacity(0.4))
                Text(formatRelativeTime(
                    viewModel.selectedTimestamp,
                    now: viewModel.timelineReferenceDate
                ))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .font(.system(size: 13, design: .monospaced))
        .foregroundStyle(.white.opacity(0.7))
    }

    private var framePositionLabel: String {
        guard frameCount > 0 else { return "0 / 0" }
        return "Span \(viewModel.selectedIndex + 1) / \(frameCount)"
    }
}

struct TimeLabels: View {
    let entries: [TimelineEntry]
    let referenceDate: Date

    var body: some View {
        HStack {
            if let oldest = entries.map({ timelineSpanBounds(for: $0).start }).min() {
                Text(formatRelativeTime(oldest, now: referenceDate))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Text("Now")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}

func formatRelativeTime(_ date: Date, now: Date = Date()) -> String {
    // Clamp to zero so a frame timestamp slightly ahead of the wall clock
    // (clock adjustments, cross-machine manifests) reads "0s ago" instead of
    // a negative age.
    let seconds = max(0, Int(now.timeIntervalSince(date)))

    if seconds < 60 {
        return "\(seconds)s ago"
    }
    if seconds < 3600 {
        return "\(seconds / 60)m \(seconds % 60)s ago"
    }
    if seconds < 7200 {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return "\(h)h \(m)m \(s)s ago"
    }

    let calendar = Calendar.current

    // Compare against the injected now rather than the wall clock so the
    // day-boundary branches agree with the seconds/daysAgo maths above.
    if calendar.isDate(date, inSameDayAs: now) {
        return date.formatted(clockTimeFormat)
    }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
       calendar.isDate(date, inSameDayAs: yesterday) {
        return "Yesterday \(date.formatted(clockTimeFormat))"
    }

    let daysAgo = calendar.dateComponents([.day], from: date, to: now).day ?? 0
    if daysAgo < 7 {
        return date.formatted(dayLabelTimeFormat)
    }
    return date.formatted(fullDateTimeFormat)
}

private struct SliderTrack: View {
    let frameCount: Int
    let rangeStart: Date?
    let rangeEnd: Date
    let selectedTimestamp: Date
    let markers: [TimelineMarker]
    let colourSegments: [TimelineZoneFill]
    let accessibilityValue: String
    let onTimestampChanged: (Date) -> Void
    let onIncrement: () -> Void
    let onDecrement: () -> Void

    private let trackHeight: CGFloat = 10
    private let thumbDiameter: CGFloat = 24

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let labelledMarkers = visibleMarkers(in: width)

            VStack(spacing: labelledMarkers.isEmpty ? 0 : 8) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous)
                        .fill(Color(red: 0.19, green: 0.19, blue: 0.21))
                        .frame(height: trackHeight)

                    if colourSegments.isEmpty {
                        RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                            .frame(height: trackHeight)
                    } else {
                        ZStack(alignment: .leading) {
                            ForEach(colourSegments) { fill in
                                if fill.start > 0 {
                                    RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous)
                                        .fill(fill.color.opacity(0.88))
                                        .frame(
                                            width: max(0, width - fill.start * width),
                                            height: trackHeight
                                        )
                                        .offset(x: fill.start * width)
                                } else {
                                    Rectangle()
                                        .fill(fill.color.opacity(0.88))
                                        .frame(height: trackHeight)
                                }
                            }
                        }
                        .frame(width: width, height: trackHeight)
                        .clipShape(RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous))

                        RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.05),
                                        Color.white.opacity(0.01)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: trackHeight)
                    }

                    if colourSegments.isEmpty {
                        RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous)
                            .fill(Color.white.opacity(0.55))
                            .frame(width: width * selectedPosition, height: trackHeight)
                    }

                    if !markers.isEmpty {
                        ForEach(markers) { marker in
                            Rectangle()
                                .fill(marker.tint)
                                .frame(width: 3, height: trackHeight)
                                .offset(x: (width * marker.position) - 1.5)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous))
                    }

                    Circle()
                        .fill(.white)
                        .frame(width: thumbDiameter, height: thumbDiameter)
                        .shadow(color: .black.opacity(0.3), radius: 4)
                        .offset(x: timelineThumbOffset(
                            totalWidth: width,
                            thumbDiameter: thumbDiameter,
                            position: selectedPosition
                        ))
                }
                .frame(height: 24)

                if !labelledMarkers.isEmpty {
                    ZStack(alignment: .leading) {
                        ForEach(labelPlacements(for: labelledMarkers, in: width)) { placement in
                            Text(placement.marker.label)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.45))
                                .fixedSize()
                                .position(x: placement.x, y: 6)
                        }
                    }
                    .frame(height: 12)
                    .offset(y: -4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard frameCount > 0, width > 0, let rangeStart else { return }
                        let position = max(0, min(1, value.location.x / width))
                        onTimestampChanged(timelineDate(
                            at: position,
                            start: rangeStart,
                            end: rangeEnd
                        ))
                    }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timeline")
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                onIncrement()
            case .decrement:
                onDecrement()
            @unknown default:
                break
            }
        }
    }

    private var selectedPosition: CGFloat {
        guard frameCount > 0, let rangeStart else { return 0 }
        return timelinePosition(for: selectedTimestamp, start: rangeStart, end: rangeEnd)
    }

    private func visibleMarkers(in width: CGFloat) -> [TimelineMarker] {
        let inset: CGFloat = 34
        let minimumSpacing: CGFloat = 56
        let basePlacements = markers.map { marker in
            let x = min(max(width * marker.position, inset), max(inset, width - inset))
            return TimelineLabelPlacement(marker: marker, x: x)
        }

        guard basePlacements.count > 1 else { return basePlacements.map(\.marker) }

        var kept: [TimelineLabelPlacement] = []
        let prioritized = basePlacements.sorted { lhs, rhs in
            if lhs.marker.priority != rhs.marker.priority {
                return lhs.marker.priority < rhs.marker.priority
            }
            if lhs.marker.targetAge != rhs.marker.targetAge {
                return lhs.marker.targetAge < rhs.marker.targetAge
            }
            return lhs.marker.position > rhs.marker.position
        }

        for candidate in prioritized {
            let overlapsExisting = kept.contains { abs($0.x - candidate.x) < minimumSpacing }
            if !overlapsExisting {
                kept.append(candidate)
            }
        }

        return kept
            .map(\.marker)
            .sorted { $0.position < $1.position }
    }

    private func labelPlacements(for markers: [TimelineMarker], in width: CGFloat) -> [TimelineLabelPlacement] {
        let inset: CGFloat = 34

        return markers.map { marker in
            let x = min(max(width * marker.position, inset), max(inset, width - inset))
            return TimelineLabelPlacement(marker: marker, x: x)
        }
    }

}

struct TimelineMarker: Identifiable {
    let targetAge: TimeInterval
    let targetDate: Date
    let label: String
    let position: CGFloat
    let priority: Int
    let tint: Color = Color(red: 1.0, green: 0.86, blue: 0.12)

    var id: TimeInterval { targetDate.timeIntervalSinceReferenceDate }
}

private struct TimelineMarkerTarget: Identifiable {
    let targetAge: TimeInterval
    let targetDate: Date
    let label: String
    let priority: Int

    var id: String { "\(priority)-\(targetDate.timeIntervalSinceReferenceDate)" }
}

struct TimelineZoneFill: Identifiable {
    let start: CGFloat
    let end: CGFloat
    let color: Color

    var id: String { "\(start)-\(end)" }
}

private struct TimelineLabelPlacement: Identifiable {
    let marker: TimelineMarker
    var x: CGFloat

    var id: TimeInterval { marker.id }
}

func resolveTimelineMarkerPosition(
    entries: [TimelineEntry],
    targetAge: TimeInterval,
    now: Date = Date()
) -> CGFloat? {
    guard let oldest = entries.map({ timelineSpanBounds(for: $0).start }).min() else {
        return nil
    }
    let reference = clampedTimelineReferenceDate(requested: now, entries: entries)
    return timelinePosition(
        for: reference.addingTimeInterval(-targetAge),
        start: oldest,
        end: reference
    )
}

func timelineLandmarkMarkers(
    entries: [TimelineEntry],
    recentWindow: TimeInterval,
    now: Date = Date()
) -> [TimelineMarker] {
    guard let oldest = entries.map({ timelineSpanBounds(for: $0).start }).min() else { return [] }
    let reference = clampedTimelineReferenceDate(requested: now, entries: entries)

    let oldestAge = reference.timeIntervalSince(oldest)
    let targets = timelineMarkerTargets(
        upTo: oldestAge,
        recentWindow: recentWindow,
        now: reference
    )
    return targets.map { target in
        TimelineMarker(
            targetAge: target.targetAge,
            targetDate: target.targetDate,
            label: target.label,
            position: timelinePosition(for: target.targetDate, start: oldest, end: reference),
            priority: target.priority
        )
    }
    .sorted { $0.position < $1.position }
}

func timelinePosition(for date: Date, start: Date, end: Date) -> CGFloat {
    let duration = end.timeIntervalSince(start)
    guard duration > 0 else { return 1 }
    return CGFloat(max(0, min(1, date.timeIntervalSince(start) / duration)))
}

func timelineDate(at position: CGFloat, start: Date, end: Date) -> Date {
    let clampedPosition = max(0, min(1, position))
    let duration = max(0, end.timeIntervalSince(start))
    return start.addingTimeInterval(TimeInterval(clampedPosition) * duration)
}

func timelineThumbOffset(
    totalWidth: CGFloat,
    thumbDiameter: CGFloat,
    position: CGFloat
) -> CGFloat {
    max(0, totalWidth - max(0, thumbDiameter)) * max(0, min(1, position))
}

private func timelineMarkerTargets(
    upTo oldestAge: TimeInterval,
    recentWindow: TimeInterval,
    now: Date
) -> [TimelineMarkerTarget] {
    guard oldestAge > 0 else { return [] }

    let markerAges = [5.0 * 60, 10.0 * 60, 30.0 * 60, 60.0 * 60, 2.0 * 60.0 * 60.0]
    let preferredAges = ([recentWindow] + markerAges)
        .filter { $0 <= oldestAge }

    var seenAges: Set<Int> = []
    let relativeAges = preferredAges.filter { seenAges.insert(Int($0)).inserted }
    var targets = relativeAges.enumerated().map { index, targetAge in
        TimelineMarkerTarget(
            targetAge: targetAge,
            targetDate: now.addingTimeInterval(-targetAge),
            label: formatTimelineMarkerLabel(targetAge: targetAge, targetDate: now.addingTimeInterval(-targetAge)),
            priority: index
        )
    }

    if oldestAge > 2 * 60 * 60 {
        let blockHours = [3, 4, 6, 8, 12, 16, 24]
        var priority = targets.count
        var seenDates: Set<TimeInterval> = Set(targets.map { $0.targetDate.timeIntervalSinceReferenceDate })
        for blockHour in blockHours {
            guard blockHour <= Int(oldestAge / 3600) else { continue }
            let rawTargetDate = now.addingTimeInterval(-TimeInterval(blockHour * 3600))
            let snappedTargetDate = snappedTimelineAbsoluteDate(rawTargetDate)
            let snappedAge = now.timeIntervalSince(snappedTargetDate)

            if snappedAge > 2 * 60 * 60,
               snappedAge <= oldestAge,
               seenDates.insert(snappedTargetDate.timeIntervalSinceReferenceDate).inserted {
                targets.append(
                    TimelineMarkerTarget(
                        targetAge: snappedAge,
                        targetDate: snappedTargetDate,
                        label: formatTimelineMarkerLabel(targetAge: snappedAge, targetDate: snappedTargetDate),
                        priority: priority
                    )
                )
                priority += 1
            }
        }
    }

    return targets
}

private func snappedTimelineAbsoluteDate(_ date: Date) -> Date {
    let interval = date.timeIntervalSinceReferenceDate
    let halfHour: TimeInterval = 30 * 60
    let snapped = (interval / halfHour).rounded() * halfHour
    return Date(timeIntervalSinceReferenceDate: snapped)
}

func timelineColourSegments(
    entries: [TimelineEntry],
    borderPosition: CGFloat?
) -> [TimelineZoneFill] {
    guard !entries.isEmpty else { return [] }

    let olderColor = Color(red: 0.30, green: 0.28, blue: 0.31)
    let newerColor = Color(red: 0.55, green: 0.52, blue: 0.56)

    var segments: [TimelineZoneFill] = []

    if let rawBorderPosition = borderPosition {
        let borderPosition = max(0, min(1, rawBorderPosition))
        if borderPosition > 0 {
            segments.append(
                TimelineZoneFill(
                    start: 0,
                    end: borderPosition,
                    color: olderColor
                )
            )
            segments.append(
                TimelineZoneFill(
                    start: borderPosition,
                    end: 1,
                    color: newerColor
                )
            )
        }
    }
    if segments.isEmpty {
        segments.append(
            TimelineZoneFill(
                start: 0,
                end: 1,
                color: newerColor
            )
        )
    }

    return segments.filter { $0.end > $0.start }
}

func formatTimelineMarkerLabel(targetAge: TimeInterval, targetDate: Date) -> String {
    if targetAge < 60 * 60 {
        let totalMinutes = Int(targetAge / 60)
        return "\(totalMinutes)min"
    }

    if targetAge <= 2 * 60 * 60 {
        let totalHours = Int(targetAge / 3600)
        return "\(totalHours)h"
    }

    return targetDate.formatted(timelineMarkerTimeFormat)
}
