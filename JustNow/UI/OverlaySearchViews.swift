import SwiftUI

struct SearchBarView: View {
    var viewModel: OverlayViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.6))

            TextField("Search screen text...", text: Bindable(viewModel).searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .focused($isFocused)
                .onChange(of: viewModel.searchQuery) { _, _ in
                    viewModel.performSearch()
                }
                .onSubmit {
                    viewModel.performSearch(immediately: true)
                }

            if viewModel.isSearchLoading {
                SearchingStatusBadge()
            } else if !viewModel.searchResults.isEmpty {
                let status = viewModel.searchIndexStatus
                let indexPercent = status.totalFrames > 0
                    ? Int(round(Double(status.indexedFrames) / Double(status.totalFrames) * 100))
                    : 100
                if indexPercent < 100 {
                    Text("\(viewModel.searchResults.count) found · \(indexPercent)% indexed")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                } else {
                    Text("\(viewModel.searchResults.count) found")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            } else {
                let status = viewModel.searchIndexStatus
                let indexPercent = status.totalFrames > 0
                    ? Int(round(Double(status.indexedFrames) / Double(status.totalFrames) * 100))
                    : 100
                if indexPercent < 100 {
                    Text("\(indexPercent)% indexed")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                }
            }

            Button {
                viewModel.clearSearch()
            } label: {
                Label("Clear search", systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)

            Menu {
                ForEach(SearchTimeScope.allCases, id: \.self) { scope in
                    Button {
                        viewModel.searchTimeScope = scope
                        if viewModel.hasSearchQuery {
                            viewModel.performSearch(immediately: true)
                        }
                    } label: {
                        if scope == viewModel.searchTimeScope {
                            Label(scope.label(using: viewModel.rewindHistoryOption), systemImage: "checkmark")
                        } else {
                            Text(scope.label(using: viewModel.rewindHistoryOption))
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(viewModel.searchTimeScope.compactLabel(using: viewModel.rewindHistoryOption))
                        .font(.caption)
                        .fontWeight(.medium)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.white.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .darkBarBackground(in: Capsule())
        .onAppear { isFocused = true }
        .task {
            while !Task.isCancelled {
                await viewModel.refreshIndexStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

struct SearchSearchingStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            SearchingRippleBar(height: 16)
                .frame(width: 240)

            Text("Searching")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))

            Text("Looking through indexed screen text as you type")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.52))
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .darkBarBackground(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct SearchingStatusBadge: View {
    var body: some View {
        HStack(spacing: 8) {
            SearchingRippleBar(height: 10)
                .frame(width: 54)

            Text("Searching…")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.68))
        }
    }
}

private struct SearchingRippleBar: View {
    private let trackColor = Color.white.opacity(0.08)
    private let borderColor = Color.white.opacity(0.14)
    private let rippleColors = [
        Color(red: 0.36, green: 0.78, blue: 0.74).opacity(0.15),
        Color(red: 0.95, green: 0.77, blue: 0.43).opacity(0.34),
        Color(red: 0.45, green: 0.69, blue: 0.95).opacity(0.18),
    ]

    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                let duration = 3.8
                let progress = (context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: duration)) / duration
                let glowWidth = max(proxy.size.width * 0.72, 44)
                let travel = proxy.size.width + glowWidth
                let offset = -glowWidth + travel * progress

                Capsule(style: .continuous)
                    .fill(trackColor)
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(borderColor, lineWidth: 1)
                    }
                    .overlay(alignment: .leading) {
                        LinearGradient(colors: rippleColors, startPoint: .leading, endPoint: .trailing)
                            .frame(width: glowWidth)
                            .blur(radius: height * 0.75)
                            .offset(x: offset)
                            .blendMode(.screen)
                    }
                    .clipShape(Capsule(style: .continuous))
            }
        }
        .frame(height: height)
    }
}
