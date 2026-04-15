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
    let textGrabBannerState: TextGrabBannerState

    private var displayedFrames: [StoredFrame] { viewModel.displayedFrames }
    private var frameCount: Int { displayedFrames.count }
    private var timelineMarkers: [TimelineMarker] {
        guard !(viewModel.isSearching && viewModel.hasSearchQuery) else { return [] }
        return timelineLandmarkMarkers(
            frames: displayedFrames,
            recentWindow: viewModel.recentTimelineWindow,
            now: viewModel.timelineReferenceDate
        )
    }

    private var colourSegments: [TimelineZoneFill] {
        guard !(viewModel.isSearching && viewModel.hasSearchQuery) else {
            return timelineColourSegments(frames: displayedFrames, borderPosition: nil)
        }

        let recentWindowPosition =
            timelineMarkers.first(where: { $0.targetAge == viewModel.recentTimelineWindow })?.position
            ?? resolveTimelineMarkerPosition(
                frames: displayedFrames,
                targetAge: viewModel.recentTimelineWindow,
                now: viewModel.timelineReferenceDate
            )
        return timelineColourSegments(
            frames: displayedFrames,
            borderPosition: recentWindowPosition
        )
    }

    private var currentFrame: StoredFrame? {
        displayedFrames[safe: viewModel.selectedIndex]
    }

    var body: some View {
        VStack(spacing: 12) {
            TimeLabels(frames: displayedFrames)

            SliderTrack(
                frameCount: frameCount,
                selectedIndex: viewModel.selectedIndex,
                markers: timelineMarkers,
                colourSegments: colourSegments,
                onIndexChanged: { viewModel.selectedIndex = $0 }
            )
            .frame(height: timelineMarkers.isEmpty ? 32 : 54)
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
            .darkBarBackground(in: RoundedRectangle(cornerRadius: 20, style: .continuous))

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
            if let frame = currentFrame {
                Text("·")
                    .foregroundStyle(.white.opacity(0.4))
                Text(formatRelativeTime(frame.timestamp))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .font(.system(size: 13, design: .monospaced))
        .foregroundStyle(.white.opacity(0.7))
    }

    private var framePositionLabel: String {
        guard frameCount > 0 else { return "0 / 0" }
        return "\(viewModel.selectedIndex + 1) / \(frameCount)"
    }
}

struct TimeLabels: View {
    let frames: [StoredFrame]

    var body: some View {
        HStack {
            if let oldest = frames.first {
                Text(formatRelativeTime(oldest.timestamp))
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

func formatRelativeTime(_ date: Date) -> String {
    let seconds = Int(Date().timeIntervalSince(date))

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

    if calendar.isDateInToday(date) {
        return date.formatted(clockTimeFormat)
    }
    if calendar.isDateInYesterday(date) {
        return "Yesterday \(date.formatted(clockTimeFormat))"
    }

    let daysAgo = calendar.dateComponents([.day], from: date, to: Date()).day ?? 0
    if daysAgo < 7 {
        return date.formatted(dayLabelTimeFormat)
    }
    return date.formatted(fullDateTimeFormat)
}

private struct SliderTrack: View {
    let frameCount: Int
    let selectedIndex: Int
    let markers: [TimelineMarker]
    let colourSegments: [TimelineZoneFill]
    let onIndexChanged: (Int) -> Void

    private let trackHeight: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let visibleMarkers = visibleMarkers(in: width)

            VStack(spacing: visibleMarkers.isEmpty ? 0 : 8) {
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
                            .frame(width: progressWidth(in: width), height: trackHeight)
                    }

                    if !visibleMarkers.isEmpty {
                        ForEach(visibleMarkers) { marker in
                            Rectangle()
                                .fill(marker.tint)
                                .frame(width: 3, height: trackHeight)
                                .offset(x: (width * marker.position) - 1.5)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous))
                    }

                    Circle()
                        .fill(.white)
                        .frame(width: 24, height: 24)
                        .shadow(color: .black.opacity(0.3), radius: 4)
                        .offset(x: thumbOffset(in: width))
                }
                .frame(height: 24)

                if !visibleMarkers.isEmpty {
                    ZStack(alignment: .leading) {
                        ForEach(labelPlacements(for: visibleMarkers, in: width)) { placement in
                            Text(placement.marker.label)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.45))
                                .fixedSize()
                                .position(x: placement.x, y: 6)
                        }
                    }
                    .frame(height: 12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard frameCount > 0 else { return }
                        let percent = max(0, min(1, value.location.x / width))
                        let newIndex = Int(percent * CGFloat(frameCount - 1))
                        onIndexChanged(newIndex)
                    }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timeline")
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                adjustSelection(by: 1)
            case .decrement:
                adjustSelection(by: -1)
            @unknown default:
                break
            }
        }
    }

    private func progressWidth(in totalWidth: CGFloat) -> CGFloat {
        guard frameCount > 1 else { return 0 }
        let percent = CGFloat(selectedIndex) / CGFloat(frameCount - 1)
        return totalWidth * percent
    }

    private func thumbOffset(in totalWidth: CGFloat) -> CGFloat {
        guard frameCount > 1 else { return 0 }
        let percent = CGFloat(selectedIndex) / CGFloat(frameCount - 1)
        return (totalWidth - 24) * percent
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

    private var accessibilityValue: String {
        guard frameCount > 0 else { return "No frames" }
        return "Frame \(selectedIndex + 1) of \(frameCount)"
    }

    private func adjustSelection(by delta: Int) {
        guard frameCount > 0 else { return }
        let nextIndex = max(0, min(frameCount - 1, selectedIndex + delta))
        guard nextIndex != selectedIndex else { return }
        onIndexChanged(nextIndex)
    }
}

struct TimelineMarker: Identifiable {
    let targetAge: TimeInterval
    let targetDate: Date
    let label: String
    let position: CGFloat
    let frameIndex: Int
    let priority: Int
    let tint: Color = Color(red: 1.0, green: 0.86, blue: 0.12)

    var id: Int { frameIndex }
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

    var id: Int { marker.id }
}

private func resolveTimelineMarkerFrameIndex(
    frames: [StoredFrame],
    targetDate: Date
) -> Int? {
    guard frames.count > 1 else { return nil }

    let olderIndex = frames.lastIndex(where: { $0.timestamp <= targetDate })
    let newerIndex = frames.firstIndex(where: { $0.timestamp >= targetDate })

    switch (olderIndex, newerIndex) {
    case let (.some(older), .some(newer)):
        let olderDistance = abs(frames[older].timestamp.timeIntervalSince(targetDate))
        let newerDistance = abs(frames[newer].timestamp.timeIntervalSince(targetDate))
        return olderDistance <= newerDistance ? older : newer
    case let (.some(older), nil):
        return older
    case let (nil, .some(newer)):
        return newer
    case (nil, nil):
        return nil
    }
}

func resolveTimelineMarkerPosition(
    frames: [StoredFrame],
    targetAge: TimeInterval,
    now: Date = Date()
) -> CGFloat? {
    guard frames.count > 1 else { return nil }

    let targetDate = now.addingTimeInterval(-targetAge)
    guard let frameIndex = resolveTimelineMarkerFrameIndex(
        frames: frames,
        targetDate: targetDate
    ) else { return nil }

    return CGFloat(frameIndex) / CGFloat(frames.count - 1)
}

func timelineLandmarkMarkers(
    frames: [StoredFrame],
    recentWindow: TimeInterval,
    now: Date = Date()
) -> [TimelineMarker] {
    guard frames.count > 1, let oldest = frames.first?.timestamp else { return [] }

    let oldestAge = now.timeIntervalSince(oldest)
    let targets = timelineMarkerTargets(
        upTo: oldestAge,
        recentWindow: recentWindow,
        now: now
    )
    var markersByFrameIndex: [Int: TimelineMarker] = [:]

    for target in targets {
        guard let frameIndex = resolveTimelineMarkerFrameIndex(
            frames: frames,
            targetDate: target.targetDate
        ) else { continue }

        let frame = frames[frameIndex]
        guard isTimelineMarkerRepresentative(
            targetAge: target.targetAge,
            targetDate: target.targetDate,
            frameDate: frame.timestamp
        ) else { continue }

        let position = CGFloat(frameIndex) / CGFloat(frames.count - 1)
        let marker = TimelineMarker(
            targetAge: target.targetAge,
            targetDate: target.targetDate,
            label: target.label,
            position: position,
            frameIndex: frameIndex,
            priority: target.priority
        )

        if let existing = markersByFrameIndex[frameIndex] {
            markersByFrameIndex[frameIndex] = existing.priority <= marker.priority ? existing : marker
        } else {
            markersByFrameIndex[frameIndex] = marker
        }
    }

    return markersByFrameIndex.values.sorted { $0.position < $1.position }
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

private func isTimelineMarkerRepresentative(
    targetAge: TimeInterval,
    targetDate: Date,
    frameDate: Date
) -> Bool {
    let tolerance: TimeInterval

    if targetAge < 15 * 60 {
        tolerance = 5 * 60
    } else if targetAge < 45 * 60 {
        tolerance = 15 * 60
    } else if targetAge < 2 * 60 * 60 {
        tolerance = 30 * 60
    } else {
        tolerance = 90 * 60
    }

    return abs(frameDate.timeIntervalSince(targetDate)) <= tolerance
}

func timelineColourSegments(
    frames: [StoredFrame],
    borderPosition: CGFloat?
) -> [TimelineZoneFill] {
    guard frames.count > 1 else { return [] }

    let olderColor = Color(red: 0.30, green: 0.28, blue: 0.31)
    let newerColor = Color(red: 0.55, green: 0.52, blue: 0.56)

    var segments: [TimelineZoneFill] = []

    if let borderPosition, borderPosition > 0 {
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
    } else {
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
