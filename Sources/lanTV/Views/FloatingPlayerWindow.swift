import AppKit
import Combine
import SwiftUI

@MainActor
final class FloatingPlayerWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var suppressCloseCallback = false
    private weak var viewModel: GuideViewModel?
    private(set) var isFullScreen = false
    var wasDockedBeforeFullScreen = false

    func show(viewModel: GuideViewModel) {
        self.viewModel = viewModel

        if let window {
            updateRootView(viewModel)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = FloatingPlayerWindowView(
            viewModel: viewModel,
            isFullScreen: isFullScreen,
            onToggleFullScreen: { [weak self] in
                self?.toggleFullScreen()
            }
        )

        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "lanTV Player"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary, .moveToActiveSpace]
        window.isMovableByWindowBackground = true
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.delegate = self
        window.setContentSize(NSSize(width: 900, height: 620))
        window.minSize = NSSize(width: 520, height: 380)

        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        guard let window else { return }
        suppressCloseCallback = true
        window.close()
        suppressCloseCallback = false
        self.window = nil
    }

    func toggleFullScreen() {
        guard let window else { return }
        window.toggleFullScreen(nil)
    }

    func enterFullScreen(fromDocked: Bool = false) {
        wasDockedBeforeFullScreen = fromDocked
        guard let window else { return }
        if !window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    func exitFullScreen() {
        guard let window else { return }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
    }

    // MARK: - NSWindowDelegate Full Screen

    func windowWillEnterFullScreen(_ notification: Notification) {
        window?.level = .normal
        isFullScreen = true
        if let viewModel {
            updateRootView(viewModel)
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        isFullScreen = true
        if let viewModel {
            updateRootView(viewModel)
        }
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        isFullScreen = false
        if let viewModel {
            updateRootView(viewModel)
        }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        window?.level = .floating
        isFullScreen = false
        if let viewModel {
            updateRootView(viewModel)
            if wasDockedBeforeFullScreen {
                wasDockedBeforeFullScreen = false
                viewModel.dockPlayer()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        let shouldNotify = !suppressCloseCallback
        window = nil
        isFullScreen = false
        if shouldNotify {
            viewModel?.floatingPlayerWindowDidClose()
        }
    }

    private func updateRootView(_ viewModel: GuideViewModel) {
        guard let hostingController = window?.contentViewController as? NSHostingController<FloatingPlayerWindowView> else {
            return
        }
        hostingController.rootView = FloatingPlayerWindowView(
            viewModel: viewModel,
            isFullScreen: isFullScreen,
            onToggleFullScreen: { [weak self] in
                self?.toggleFullScreen()
            }
        )
    }
}

private struct FloatingPlayerWindowView: View {
    @Bindable var viewModel: GuideViewModel
    let isFullScreen: Bool
    let onToggleFullScreen: () -> Void

    @Environment(\.openWindow) private var openWindow
    @State private var currentTime = Date()
    @State private var areControlsVisible = true
    @State private var hideControlsTask: Task<Void, Never>?
    private let clock = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // Background
            if isFullScreen {
                Color.black.ignoresSafeArea()
            } else {
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
            }

            if let channel = viewModel.selectedChannel {
                unifiedPlayerContent(channel: channel)
            } else {
                ContentUnavailableView("No Channel Selected", systemImage: "tv")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: isFullScreen ? nil : 520, minHeight: isFullScreen ? nil : 380)
        .onReceive(clock) { now in
            currentTime = now
        }
    }

    // MARK: - Unified Player Content (Preserves single video surface across transitions)

    @ViewBuilder
    private func unifiedPlayerContent(channel: GuideChannel) -> some View {
        ZStack {
            // The single persistent video surface
            SharedPlayerSurfaceView(viewModel: viewModel, channel: channel)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: isFullScreen ? 0 : 14))
                .padding(isFullScreen ? 0 : 10)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    onToggleFullScreen()
                }
                .onTapGesture(count: 1) {
                    viewModel.togglePlayPause()
                    if isFullScreen {
                        showControlsBriefly()
                    }
                }

            // Big Play Button when paused
            if !viewModel.isPlaying {
                Button {
                    viewModel.resumePlayback()
                } label: {
                    ZStack {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: isFullScreen ? 80 : 68, height: isFullScreen ? 80 : 68)
                            .overlay {
                                Circle()
                                    .strokeBorder(Color.white.opacity(0.3), lineWidth: 1.5)
                            }
                            .shadow(color: .black.opacity(0.6), radius: 14, x: 0, y: 6)

                        Image(systemName: "play.fill")
                            .font(.system(size: isFullScreen ? 34 : 28, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: 2)
                    }
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }

            // Controls & Overlays
            if isFullScreen {
                if areControlsVisible || !viewModel.isPlaying {
                    VStack(spacing: 0) {
                        fullScreenTopBar(channel: channel)
                            .transition(.move(edge: .top).combined(with: .opacity))

                        Spacer()

                        fullScreenBottomBar(channel: channel)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    .ignoresSafeArea()
                }
            } else {
                // Floating mode overlay
                VStack {
                    floatingHeader(channel: channel)
                    Spacer()
                }
                .padding(14)
            }
        }
        .onContinuousHover { phase in
            if isFullScreen {
                switch phase {
                case .active:
                    showControlsBriefly()
                case .ended:
                    break
                }
            }
        }
        // Keyboard Shortcuts
        .overlay {
            Group {
                Button {
                    onToggleFullScreen()
                } label: { EmptyView() }
                .keyboardShortcut("f", modifiers: [])

                if isFullScreen {
                    Button {
                        onToggleFullScreen()
                    } label: { EmptyView() }
                    .keyboardShortcut(.escape, modifiers: [])
                }

                Button {
                    viewModel.togglePlayPause()
                } label: { EmptyView() }
                .keyboardShortcut(.space, modifiers: [])

                Button {
                    viewModel.adjustAudioDelay(byMilliseconds: -50)
                } label: { EmptyView() }
                .keyboardShortcut("[", modifiers: [])

                Button {
                    viewModel.adjustAudioDelay(byMilliseconds: 50)
                } label: { EmptyView() }
                .keyboardShortcut("]", modifiers: [])

                Button {
                    viewModel.resetAudioDelay()
                } label: { EmptyView() }
                .keyboardShortcut("\\", modifiers: [])
            }
            .frame(width: 0, height: 0)
            .opacity(0)
        }
    }

    // MARK: - Floating Mode Header Overlay

    private func floatingHeader(channel: GuideChannel) -> some View {
        let nowPlaying = channel.programmes.first { $0.start <= currentTime && currentTime < $0.stop }
        let supportsAirPlay = !viewModel.usesVLCPlayback(for: channel)

        return HStack(alignment: .center, spacing: 14) {
            HStack(spacing: 8) {
                if channel.hasDisplayNumber {
                    Text(channel.displayNumber)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(channel.name)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .lineLimit(1)

                    Text(channel.sourceID)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            if let nowPlaying {
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("NOW")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .tracking(0.8)

                        Text(nowPlaying.title)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                    }

                    HStack(spacing: 5) {
                        if let se = nowPlaying.formattedSeasonEpisode {
                            Text(se)
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.blue.opacity(0.25))
                                .foregroundStyle(.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                        }

                        Text(programmeTimeLabel(nowPlaying))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .frame(maxWidth: 240, alignment: .trailing)
            }

            HStack(spacing: 8) {
                FloatingChromeIconButton(
                    systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill",
                    isEnabled: true
                ) {
                    viewModel.togglePlayPause()
                }
                .help(viewModel.isPlaying ? "Pause (Space)" : "Play (Space)")

                RecordBadgeButton(
                    isRecording: viewModel.isCurrentChannelRecording,
                    durationText: viewModel.currentChannelRecordingItem?.formattedDuration
                ) {
                    viewModel.toggleRecordingCurrentShow()
                }

                if let recording = viewModel.playingRecording {
                    RecordingPlaybackChip(title: recording.programmeTitle) {
                        viewModel.stopRecordingPlayback()
                    }
                }

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
                    systemImage: "pip.exit",
                    isEnabled: true
                ) {
                    openWindow(id: "guide")
                    viewModel.dockPlayer()
                }
                .help("Dock player in main window")

                FloatingChromeIconButton(
                    systemImage: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left",
                    isEnabled: true
                ) {
                    onToggleFullScreen()
                }
                .help("Full Screen (F)")
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.75), Color.black.opacity(0.35)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Full Screen Top Bar HUD

    private func fullScreenTopBar(channel: GuideChannel) -> some View {
        let nowPlaying = channel.programmes.first { $0.start <= currentTime && currentTime < $0.stop }

        return HStack(alignment: .center, spacing: 16) {
            HStack(spacing: 10) {
                if channel.hasDisplayNumber {
                    Text(channel.displayNumber)
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Capsule())
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text(channel.sourceID)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            Spacer()

            if let nowPlaying {
                VStack(alignment: .trailing, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("NOW PLAYING")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.accentColor)
                            .tracking(0.8)

                        Text(nowPlaying.title)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }

                    HStack(spacing: 6) {
                        if let se = nowPlaying.formattedSeasonEpisode {
                            Text(se)
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.25))
                                .foregroundStyle(.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }

                        Text(programmeTimeLabel(nowPlaying))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                            .monospacedDigit()
                    }
                }
            }

            Button(action: onToggleFullScreen) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.14))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Exit Full Screen (Esc / F)")
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 36)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.85), Color.black.opacity(0.4), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - Full Screen Bottom Bar HUD

    private func fullScreenBottomBar(channel: GuideChannel) -> some View {
        let supportsAirPlay = !viewModel.usesVLCPlayback(for: channel)

        return HStack(spacing: 12) {
            FloatingChromeIconButton(
                systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill",
                isEnabled: true
            ) {
                viewModel.togglePlayPause()
                showControlsBriefly()
            }
            .help(viewModel.isPlaying ? "Pause (Space)" : "Play (Space)")

            RecordBadgeButton(
                isRecording: viewModel.isCurrentChannelRecording,
                durationText: viewModel.currentChannelRecordingItem?.formattedDuration
            ) {
                viewModel.toggleRecordingCurrentShow()
                showControlsBriefly()
            }

            if let recording = viewModel.playingRecording {
                RecordingPlaybackChip(title: recording.programmeTitle) {
                    viewModel.stopRecordingPlayback()
                }
            }

            if viewModel.isLiveStream {
                LiveBadgeButton(
                    isAtLiveEdge: viewModel.isAtLiveEdge,
                    secondsBehindLive: viewModel.secondsBehindLive
                ) {
                    viewModel.seekToLive()
                    showControlsBriefly()
                }
            }

            CompactVolumeControl(volume: $viewModel.volume)

            if viewModel.audioDelayMs != 0 {
                Button {
                    viewModel.resetAudioDelay()
                } label: {
                    Text(String(format: "Sync: %+dms", viewModel.audioDelayMs))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.28))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Click to reset audio delay (Keys: [ / ] adjust, \\ reset)")
            }

            Spacer()

            AirPlayChromeControl(isEnabled: supportsAirPlay)
                .help(supportsAirPlay ? "AirPlay" : "AirPlay is only available for AVPlayer-backed streams")

            FloatingChromeIconButton(
                systemImage: "arrow.down.right.and.arrow.up.left",
                isEnabled: true
            ) {
                onToggleFullScreen()
            }
            .help("Exit Full Screen (Esc / F)")
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .padding(.top, 36)
        .background(
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.4), Color.black.opacity(0.85)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func showControlsBriefly() {
        withAnimation(.easeInOut(duration: 0.2)) {
            areControlsVisible = true
        }
        hideControlsTask?.cancel()
        hideControlsTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            if viewModel.isPlaying {
                withAnimation(.easeInOut(duration: 0.4)) {
                    areControlsVisible = false
                }
            }
        }
    }

    private func programmeTimeLabel(_ programme: GuideProgramme) -> String {
        let start = programme.start.formatted(date: .omitted, time: .shortened)
        let stop = programme.stop.formatted(date: .omitted, time: .shortened)
        return "\(start) - \(stop)"
    }
}
