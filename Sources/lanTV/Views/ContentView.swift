import AVKit
import AppKit
import Combine
import SwiftUI

struct ContentView: View {
    @Bindable var viewModel: GuideViewModel
    @State private var currentTime = Date()
    @FocusState private var isFilterFieldFocused: Bool

    private let rowHeight: CGFloat = 56
    private let channelColumnWidth: CGFloat = 240
    private let minuteWidth: CGFloat = 6
    private let clock = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.02, green: 0.04, blue: 0.08),
                    Color(red: 0.04, green: 0.07, blue: 0.12),
                    Color(red: 0.03, green: 0.06, blue: 0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 16) {
                topBar

                if viewModel.isGuideWindowVisible, !viewModel.isPlayerDetached, let channel = viewModel.selectedChannel {
                    selectedChannelPanel(channel: channel)
                }

                guideContent
            }
            .padding(18)
        }
        .task {
            guard !viewModel.hasPerformedInitialRefresh else { return }
            await viewModel.load()
        }
        .onAppear {
            viewModel.guideWindowDidAppear()
        }
        .onReceive(clock) { now in
            currentTime = now
        }
        .onDisappear {
            viewModel.guideWindowDidDisappear()
        }
    }

    private var topBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("lanTV")
                    .font(.system(size: 34, weight: .bold, design: .rounded))

                if let generatedAt = viewModel.generatedAt {
                    Text("Guide updated \(generatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                if !viewModel.sourceStatusSummary.isEmpty {
                    Text(viewModel.sourceStatusSummary)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            filterBar

            Button {
                viewModel.refresh()
            } label: {
                if viewModel.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14, height: 14)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .keyboardShortcut("r", modifiers: [.command])
            .buttonStyle(ChromeButtonStyle(kind: .secondary))
            .disabled(viewModel.isRefreshing)

            Button {
                viewModel.openSettingsWindow()
            } label: {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
            .keyboardShortcut(",", modifiers: [.command])
            .buttonStyle(ChromeButtonStyle(kind: .primary))

            Button {
                viewModel.toggleAdultLock()
            } label: {
                Label(
                    viewModel.adultLockButtonTitle,
                    systemImage: viewModel.areAdultChannelsUnlocked ? "lock.open.fill" : "lock.fill"
                )
            }
            .buttonStyle(ChromeButtonStyle(kind: .secondary))

            if viewModel.isPlayerDetached {
                Button {
                    viewModel.focusDetachedPlayerWindow()
                } label: {
                    Label("Player Window", systemImage: "macwindow.on.rectangle")
                }
                .buttonStyle(ChromeButtonStyle(kind: .secondary))
            }

            if case .loading = viewModel.state {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .overlay {
            RoundedRectangle(cornerRadius: 26)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
        .background {
            Button("") {
                isFilterFieldFocused = true
            }
            .keyboardShortcut("f", modifiers: [.command])
            .opacity(0)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Filter channels & shows...", text: Binding(
                get: { viewModel.filterText },
                set: { viewModel.updateFilterText($0) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($isFilterFieldFocused)
            .onExitCommand {
                if !viewModel.filterText.isEmpty {
                    viewModel.updateFilterText("")
                } else {
                    isFilterFieldFocused = false
                }
            }

            if !viewModel.filterText.isEmpty {
                Text("\(viewModel.channels.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())

                Button {
                    viewModel.updateFilterText("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.07),
                    Color.white.opacity(0.03)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .strokeBorder(isFilterFieldFocused ? Color.accentColor.opacity(0.5) : Color.white.opacity(0.08), lineWidth: 1)
        }
        .frame(minWidth: 200, maxWidth: 280)
    }

    @ViewBuilder
    private func selectedChannelPanel(channel: GuideChannel) -> some View {
        SelectedChannelPlayerPanel(
            viewModel: viewModel,
            channel: channel,
            currentTime: currentTime,
            dockMode: .docked,
            onDockToggle: { viewModel.togglePlayerDocking() }
        )
    }

    fileprivate var compactVolumeControl: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Slider(value: $viewModel.volume, in: 0...1)
                .frame(width: 150)
                .controlSize(.small)

            Text("\(Int(viewModel.volume * 100))%")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.07),
                    Color.white.opacity(0.03)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var guideContent: some View {
        switch viewModel.state {
        case .idle, .loading:
            if viewModel.channels.isEmpty {
                ContentUnavailableView("Loading Guide", systemImage: "dot.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                guideGrid
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Guide Load Failed", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") {
                    viewModel.refresh()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if viewModel.channels.isEmpty {
                if !viewModel.filterText.isEmpty {
                    ContentUnavailableView {
                        Label("No Matching Channels or Shows", systemImage: "magnifyingglass")
                    } description: {
                        Text("No channels or upcoming shows matched “\(viewModel.filterText)”.")
                    } actions: {
                        Button("Clear Filter") {
                            viewModel.updateFilterText("")
                        }
                        .buttonStyle(ChromeButtonStyle(kind: .primary))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("No Channels", systemImage: "tv")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                guideGrid
            }
        }
    }

    private var guideGrid: some View {
        let timeline = guideTimeline(now: currentTime)

        return ScrollViewReader { scrollProxy in
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    guideHeader(timeline: timeline, scrollProxy: scrollProxy)

                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                        ForEach(viewModel.channels) { channel in
                            GuideChannelRow(
                                channel: channel,
                                timeline: timeline,
                                rowHeight: rowHeight,
                                channelColumnWidth: channelColumnWidth,
                                minuteWidth: minuteWidth,
                                currentTime: currentTime,
                                isSelected: channel.id == viewModel.selectedChannelID
                            ) { selectedChannel in
                                viewModel.selectChannel(selectedChannel)
                            }
                            .contextMenu {
                                Button("Hide Channel") {
                                    viewModel.hideChannel(channel)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 20)
            }
            .background(panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: 26))
            .overlay {
                RoundedRectangle(cornerRadius: 26)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            }
            .onChange(of: viewModel.selectedChannelID) { _, newID in
                guard let newID else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    scrollProxy.scrollTo(newID, anchor: .leading)
                }
            }
            .onAppear {
                if let selectedID = viewModel.selectedChannelID {
                    DispatchQueue.main.async {
                        scrollProxy.scrollTo(selectedID, anchor: .leading)
                    }
                }
            }
        }
    }

    private func guideHeader(timeline: GuideTimeline, scrollProxy: ScrollViewProxy) -> some View {
        HStack(spacing: 0) {
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                HStack {
                    Text("Channels")
                        .font(.system(size: 15, weight: .bold, design: .rounded))

                    Spacer()

                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            if let selectedID = viewModel.selectedChannelID {
                                scrollProxy.scrollTo(selectedID, anchor: .leading)
                            } else if let firstID = viewModel.channels.first?.id {
                                scrollProxy.scrollTo(firstID, anchor: .leading)
                            }
                        }
                    } label: {
                        Label("Now", systemImage: "clock")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())
                }
                .padding(.horizontal, 12)
            }
            .frame(width: channelColumnWidth, height: 44)

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color(nsColor: .controlBackgroundColor))

                ForEach(timeline.hourMarks, id: \.self) { mark in
                    let x = timeline.xOffset(for: mark, minuteWidth: minuteWidth)

                    VStack(alignment: .leading, spacing: 0) {
                        Rectangle()
                            .fill(Color.white.opacity(0.18))
                            .frame(width: 1, height: 44)
                            .offset(x: x)
                    }

                    Text(mark.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute()))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .offset(x: x + 8, y: 10)
                }
            }
            .frame(width: timeline.width(minuteWidth: minuteWidth), height: 44)
        }
    }

    private func guideTimeline(now: Date) -> GuideTimeline {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        components.minute = ((components.minute ?? 0) / 30) * 30
        components.second = 0
        let roundedNow = calendar.date(from: components) ?? now
        let guideHours = viewModel.settingsStore.settings.guideVisibleHours
        let end = calendar.date(byAdding: .hour, value: guideHours, to: roundedNow) ?? roundedNow.addingTimeInterval(Double(guideHours) * 3600)
        return GuideTimeline(start: roundedNow, end: end)
    }

    fileprivate func liveProgramme(for channel: GuideChannel) -> GuideProgramme? {
        channel.programmes.first { $0.start <= currentTime && currentTime < $0.stop }
    }

    fileprivate func programmeTimeLabel(_ programme: GuideProgramme) -> String {
        "\(programme.start.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute())) - \(programme.stop.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute()))"
    }

    fileprivate var panelBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                Color.white.opacity(0.08),
                Color.white.opacity(0.04)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct SelectedChannelPlayerPanel: View {
    enum DockMode {
        case docked
        case floating
    }

    @Bindable var viewModel: GuideViewModel
    let channel: GuideChannel
    let currentTime: Date
    let dockMode: DockMode
    let onDockToggle: () -> Void

    private var nowPlaying: GuideProgramme? {
        channel.programmes.first { $0.start <= currentTime && currentTime < $0.stop }
    }

    private var supportsAirPlay: Bool {
        !viewModel.usesVLCPlayback(for: channel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                HStack(alignment: .center, spacing: 10) {
                    if channel.hasDisplayNumber {
                        Text(channel.displayNumber)
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.05))
                            .clipShape(Capsule())
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(channel.name)
                            .font(.system(size: dockMode == .floating ? 22 : 24, weight: .bold, design: .rounded))
                            .lineLimit(1)

                        Text(channel.sourceID)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 12)

                if let nowPlaying {
                    VStack(alignment: .trailing, spacing: 3) {
                        HStack(spacing: 5) {
                            Text("NOW")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .tracking(0.8)

                            Text(nowPlaying.title)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(.primary.opacity(0.9))
                                .lineLimit(1)
                        }

                        Text(programmeTimeLabel(nowPlaying))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: 240, alignment: .trailing)
                    .layoutPriority(0)
                }

                HStack(spacing: 8) {
                    FloatingChromeIconButton(
                        systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill",
                        isEnabled: true
                    ) {
                        viewModel.togglePlayPause()
                    }
                    .help(viewModel.isPlaying ? "Pause (Space)" : "Play (Space)")
                    .keyboardShortcut(.space, modifiers: [])

                    if viewModel.isLiveStream {
                        LiveBadgeButton(
                            isAtLiveEdge: viewModel.isAtLiveEdge,
                            secondsBehindLive: viewModel.secondsBehindLive
                        ) {
                            viewModel.seekToLive()
                        }
                    }

                    CompactVolumeControl(volume: $viewModel.volume)

                    AirPlayChromeControl(isEnabled: supportsAirPlay)
                        .help(supportsAirPlay ? "AirPlay" : "AirPlay is only available for AVPlayer-backed streams")

                    FloatingChromeIconButton(
                        systemImage: dockMode == .floating ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                        isEnabled: true
                    ) {
                        onDockToggle()
                    }
                    .help(dockMode == .floating ? "Dock player in main window" : "Open player in floating window")
                }
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
            }

            ZStack {
                playerSurface
                    .frame(maxWidth: .infinity, maxHeight: dockMode == .floating ? .infinity : nil)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.togglePlayPause()
                    }

                if !viewModel.isPlaying {
                    Button {
                        viewModel.resumePlayback()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(.ultraThinMaterial)
                                .frame(width: 68, height: 68)
                                .overlay {
                                    Circle()
                                        .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                                }
                                .shadow(color: .black.opacity(0.45), radius: 10, x: 0, y: 4)

                            Image(systemName: "play.fill")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(.white)
                                .offset(x: 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Resume Playback (Space)")
                    .transition(.opacity)
                }
            }
        }
        .padding(dockMode == .floating ? 14 : 20)
        .frame(maxWidth: .infinity, maxHeight: dockMode == .floating ? .infinity : nil)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: dockMode == .floating ? 18 : 26))
        .overlay {
            RoundedRectangle(cornerRadius: dockMode == .floating ? 18 : 26)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var playerSurface: some View {
        Group {
            if viewModel.usesVLCPlayback(for: channel) {
                VLCPlayerView(url: channel.streamURL, volume: viewModel.volume) { isPlaying in
                    viewModel.setVLCPlaybackState(isPlaying: isPlaying)
                }
                .id(viewModel.vlcPlaybackGeneration)
            } else {
                PlayerContainerView(player: viewModel.player)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16 / 9, contentMode: dockMode == .floating ? .fit : .fill)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func programmeTimeLabel(_ programme: GuideProgramme) -> String {
        "\(programme.start.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute())) - \(programme.stop.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute()))"
    }

    private var panelBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                Color.white.opacity(0.08),
                Color.white.opacity(0.04)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct CompactVolumeControl: View {
    @Binding var volume: Double

    private var volumeIcon: String {
        if volume <= 0.01 {
            return "speaker.slash.fill"
        } else if volume < 0.33 {
            return "speaker.wave.1.fill"
        } else if volume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: volumeIcon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            Slider(value: $volume, in: 0...1)
                .frame(width: 90)
                .controlSize(.small)

            Text("\(Int(volume * 100))%")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.07),
                    Color.white.opacity(0.03)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct LiveBadgeButton: View {
    let isAtLiveEdge: Bool
    let secondsBehindLive: Double
    let action: () -> Void

    private var formattedBehind: String {
        let totalSeconds = Int(secondsBehindLive.rounded())
        if totalSeconds < 60 {
            return "-\(totalSeconds)s"
        }
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "-%d:%02d", minutes, seconds)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isAtLiveEdge ? Color.red : Color.orange)
                    .frame(width: 7, height: 7)

                Text(isAtLiveEdge ? "LIVE" : "LIVE \(formattedBehind)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(isAtLiveEdge ? Color.white : Color.orange)
                    .lineLimit(1)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(
                LinearGradient(
                    colors: [
                        isAtLiveEdge ? Color.white.opacity(0.12) : Color.orange.opacity(0.20),
                        isAtLiveEdge ? Color.white.opacity(0.06) : Color.orange.opacity(0.10)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isAtLiveEdge ? Color.white.opacity(0.12) : Color.orange.opacity(0.4), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .help(isAtLiveEdge ? "At Live Edge (Click or ⌘L to re-sync)" : "Behind Live (\(formattedBehind)). Click or ⌘L to jump to live edge")
        .keyboardShortcut("l", modifiers: [.command])
    }
}

private struct FloatingChromeIconButton: View {
    let systemImage: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 36, height: 36)
                .foregroundStyle(isEnabled ? Color.white : Color.white.opacity(0.45))
        }
        .buttonStyle(.plain)
        .background(
            LinearGradient(
                colors: [
                    Color.white.opacity(isEnabled ? 0.12 : 0.06),
                    Color.white.opacity(isEnabled ? 0.06 : 0.03)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
        .disabled(!isEnabled)
    }
}

private struct AirPlayChromeControl: View {
    let isEnabled: Bool

    var body: some View {
        AirPlayPickerView()
            .frame(width: 36, height: 36)
            .background(
                LinearGradient(
                    colors: [
                        Color.white.opacity(isEnabled ? 0.12 : 0.06),
                        Color.white.opacity(isEnabled ? 0.06 : 0.03)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            }
            .opacity(isEnabled ? 1.0 : 0.45)
            .allowsHitTesting(isEnabled)
    }
}

private struct GuideChannelRow: View {
    let channel: GuideChannel
    let timeline: GuideTimeline
    let rowHeight: CGFloat
    let channelColumnWidth: CGFloat
    let minuteWidth: CGFloat
    let currentTime: Date
    let isSelected: Bool
    let onSelect: (GuideChannel) -> Void

    var body: some View {
        HStack(spacing: 0) {
            channelCell
                .id(channel.id)
            programmeLane
        }
        .frame(height: rowHeight)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    private var channelCell: some View {
        Button {
            onSelect(channel)
        } label: {
            HStack(spacing: 10) {
                if let logoURL = channel.logoURL {
                    AsyncImage(url: logoURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFit()
                        case .failure:
                            Image(systemName: "tv")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        case .empty:
                            Color.white.opacity(0.04)
                        @unknown default:
                            EmptyView()
                        }
                    }
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if channel.hasDisplayNumber {
                            Text(channel.displayNumber)
                                .font(.caption.monospacedDigit().weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                        Text(channel.name)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .lineLimit(1)
                    }

                    if let nowPlaying = liveProgramme {
                        Text(nowPlaying.title)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
        }
        .buttonStyle(.plain)
        .background(
            LinearGradient(
                colors: isSelected
                    ? [Color.white.opacity(0.14), Color.white.opacity(0.08)]
                    : [Color.white.opacity(0.08), Color.white.opacity(0.04)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .frame(width: channelColumnWidth, height: rowHeight)
    }

    private var programmeLane: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color(nsColor: .textBackgroundColor))

            ForEach(timeline.hourMarks, id: \.self) { mark in
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1)
                    .offset(x: timeline.xOffset(for: mark, minuteWidth: minuteWidth))
            }

            Rectangle()
                .fill(Color.red.opacity(0.7))
                .frame(width: 2)
                .offset(x: timeline.xOffset(for: currentTime, minuteWidth: minuteWidth))

            ForEach(programmesInTimeline) { programme in
                GuideProgrammeBlock(
                    programme: programme,
                    xOffset: timeline.xOffset(for: max(programme.start, timeline.start), minuteWidth: minuteWidth),
                    width: timeline.width(for: programme, minuteWidth: minuteWidth),
                    isCurrent: programme.start <= currentTime && currentTime < programme.stop
                ) {
                    onSelect(channel)
                }
            }
        }
        .frame(width: timeline.width(minuteWidth: minuteWidth), height: rowHeight)
    }

    private var programmesInTimeline: [GuideProgramme] {
        channel.programmes.filter { $0.stop > timeline.start && $0.start < timeline.end }
    }

    private var liveProgramme: GuideProgramme? {
        channel.programmes.first { $0.start <= currentTime && currentTime < $0.stop }
    }
}

private struct GuideProgrammeBlock: View {
    let programme: GuideProgramme
    let xOffset: CGFloat
    let width: CGFloat
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(programme.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(timeLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(width: max(width, 44), height: 44, alignment: .leading)
            .background(background)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isCurrent ? Color.white.opacity(0.75) : Color.white.opacity(0.12), lineWidth: isCurrent ? 1.5 : 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .offset(x: xOffset, y: 6)
    }

    private var background: some ShapeStyle {
        LinearGradient(
            colors: isCurrent
                ? [Color(red: 0.20, green: 0.47, blue: 1.0), Color(red: 0.46, green: 0.24, blue: 1.0)]
                : [Color(red: 0.07, green: 0.45, blue: 0.62), Color(red: 0.05, green: 0.27, blue: 0.40)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var timeLabel: String {
        "\(programme.start.formatted(date: .omitted, time: .shortened)) - \(programme.stop.formatted(date: .omitted, time: .shortened))"
    }
}

private struct ChromeButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
    }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(background(isPressed: configuration.isPressed))
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            }
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private func background(isPressed: Bool) -> some ShapeStyle {
        switch kind {
        case .primary:
            return LinearGradient(
                colors: [
                    Color(red: 0.13, green: 0.53, blue: 1.0).opacity(isPressed ? 0.75 : 1),
                    Color(red: 0.42, green: 0.22, blue: 1.0).opacity(isPressed ? 0.70 : 0.92)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        case .secondary:
            return LinearGradient(
                colors: [
                    Color.white.opacity(isPressed ? 0.10 : 0.14),
                    Color.white.opacity(isPressed ? 0.04 : 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

private struct GuideTimeline {
    let start: Date
    let end: Date

    var totalMinutes: Double {
        end.timeIntervalSince(start) / 60
    }

    var hourMarks: [Date] {
        let calendar = Calendar.current
        let firstHour = calendar.dateInterval(of: .hour, for: start)?.start ?? start
        var marks: [Date] = []
        var cursor = firstHour

        while cursor <= end {
            if cursor >= start {
                marks.append(cursor)
            }
            cursor = calendar.date(byAdding: .hour, value: 1, to: cursor) ?? end.addingTimeInterval(1)
        }

        return marks
    }

    func width(minuteWidth: CGFloat) -> CGFloat {
        totalMinutes * minuteWidth
    }

    func xOffset(for date: Date, minuteWidth: CGFloat) -> CGFloat {
        let clamped = min(max(date, start), end)
        let minutes = clamped.timeIntervalSince(start) / 60
        return minutes * minuteWidth
    }

    func width(for programme: GuideProgramme, minuteWidth: CGFloat) -> CGFloat {
        let visibleStart = max(programme.start, start)
        let visibleEnd = min(programme.stop, end)
        return max(visibleEnd.timeIntervalSince(visibleStart) / 60 * minuteWidth, 8)
    }
}

private struct PlayerContainerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}
