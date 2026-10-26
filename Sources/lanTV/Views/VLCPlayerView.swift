import SwiftUI
import VLCKit

struct VLCPlayerView: NSViewRepresentable {
    let url: URL
    let volume: Double
    var onPlaybackStateChange: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> VLCVideoContainerView {
        let view = VLCVideoContainerView()
        view.onPlaybackStateChange = onPlaybackStateChange
        view.setVolume(volume)
        view.play(url: url)
        return view
    }

    func updateNSView(_ nsView: VLCVideoContainerView, context: Context) {
        nsView.onPlaybackStateChange = onPlaybackStateChange
        nsView.setVolume(volume)
        if nsView.currentURL != url {
            nsView.play(url: url)
        }
    }

    static func dismantleNSView(_ nsView: VLCVideoContainerView, coordinator: ()) {
        nsView.teardown()
        nsView.stop()
    }
}

@MainActor
final class VLCVideoContainerView: VLCVideoView, @preconcurrency VLCMediaPlayerDelegate {
    var onPlaybackStateChange: ((Bool) -> Void)?
    private var player: VLCMediaPlayer!
    private(set) var currentURL: URL?
    private var hasConfiguredAudioTrack = false
    private var isInternalStop = false
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectAttempts = 0
    private var lastReconnectTime: Date = .distantPast
    private var watchdogTimer: Timer?
    private var lastProgressTime = Date()
    private var lastObservedPlayerTime: Int32 = -1
    private var userPaused = false
    private var lastReportedState: VLCMediaPlayerState = .stopped
    private var stopObserver: NSObjectProtocol?
    private var resumeObserver: NSObjectProtocol?
    private var adjustAudioDelayObserver: NSObjectProtocol?
    private var resetAudioDelayObserver: NSObjectProtocol?

    convenience init() {
        self.init(frame: .zero)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        backColor = .black
        fillScreen = true
        autoresizingMask = [.width, .height]
        
        player = VLCMediaPlayer(options: [])
        player.drawable = self
        player.scaleFactor = 0.0
        player.delegate = self
        
        stopObserver = NotificationCenter.default.addObserver(
            forName: .lanTVStopPlayback,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pause()
            }
        }

        resumeObserver = NotificationCenter.default.addObserver(
            forName: .lanTVResumePlayback,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.resume()
            }
        }

        adjustAudioDelayObserver = NotificationCenter.default.addObserver(
            forName: .lanTVAdjustAudioDelay,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let delta = notif.userInfo?["delta"] as? Int else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.player.currentAudioPlaybackDelay += delta
                let ms = self.player.currentAudioPlaybackDelay / 1000
                NSLog("[VLCKit] Audio delay adjusted to %ld ms", ms)
            }
        }

        resetAudioDelayObserver = NotificationCenter.default.addObserver(
            forName: .lanTVResetAudioDelay,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.player.currentAudioPlaybackDelay = 0
                NSLog("[VLCKit] Audio delay reset to 0 ms")
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func startWatchdog() {
        guard watchdogTimer == nil else { return }
        lastProgressTime = Date()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForStall() }
        }
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    /// Detects streams that silently freeze (no .ended/.error event from libVLC).
    private func checkForStall() {
        guard currentURL != nil, window != nil, !userPaused else { return }
        let state = player.state
        let time = player.time.intValue
        // libVLC often leaves state at .buffering/.esAdded while video plays, so judge by clock movement.
        if time != lastObservedPlayerTime {
            lastObservedPlayerTime = time
            lastProgressTime = Date()
            return
        }
        let limit: TimeInterval = 15
        if Date().timeIntervalSince(lastProgressTime) > limit {
            NSLog("[VLCKit] Stall detected (state %@, no progress for %.0fs), reconnecting", VLCMediaPlayerStateToString(state), Date().timeIntervalSince(lastProgressTime))
            lastProgressTime = Date()
            scheduleAutoReconnect()
        }
    }

    func teardown() {
        stopWatchdog()
        onPlaybackStateChange = nil
        cancelAutoReconnect()
        if let stopObserver {
            NotificationCenter.default.removeObserver(stopObserver)
            self.stopObserver = nil
        }
        if let resumeObserver {
            NotificationCenter.default.removeObserver(resumeObserver)
            self.resumeObserver = nil
        }
        if let adjustAudioDelayObserver {
            NotificationCenter.default.removeObserver(adjustAudioDelayObserver)
            self.adjustAudioDelayObserver = nil
        }
        if let resetAudioDelayObserver {
            NotificationCenter.default.removeObserver(resetAudioDelayObserver)
            self.resetAudioDelayObserver = nil
        }
    }

    override func layout() {
        super.layout()
        updateVideoLayerBounds()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateVideoLayerBounds()
    }

    private func updateVideoLayerBounds() {
        player?.scaleFactor = 0.0
        if let sublayers = layer?.sublayers {
            for sublayer in sublayers {
                sublayer.frame = bounds
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        guard window != nil else {
            return
        }

        player.drawable = self
        player.scaleFactor = 0.0
        updateVideoLayerBounds()
    }

    func play(url: URL, forceReload: Bool = false) {
        cancelAutoReconnect()
        userPaused = false
        lastProgressTime = Date()
        lastObservedPlayerTime = -1
        startWatchdog()

        let isSameURL = (currentURL == url)
        let state = player.state

        if isSameURL && !forceReload {
            player.drawable = self
            player.scaleFactor = 0.0
            if player.isPlaying || state == .buffering || state == .opening {
                updateVideoLayerBounds()
                return
            }
            if state != .ended && state != .error && state != .stopped {
                player.play()
                updateVideoLayerBounds()
                return
            }
        }

        currentURL = url
        lastReportedState = .stopped
        hasConfiguredAudioTrack = false
        isInternalStop = true
        player.stop()
        isInternalStop = false
        
        let media = VLCMedia(url: url)
        // LibVLC caching and resiliency options for live HLS streams
        media.addOption(":network-caching=2000")
        media.addOption(":live-caching=2000")
        media.addOption(":http-reconnect=true")
        media.addOption(":avcodec-hw=none")
        
        player.currentAudioPlaybackDelay = 0
        player.media = media
        player.drawable = self
        player.scaleFactor = 0.0
        player.play()
        updateVideoLayerBounds()
    }

    func pause() {
        cancelAutoReconnect()
        userPaused = true
        if player.isPlaying {
            player.pause()
        }
    }

    func resume() {
        if player.isPlaying || player.state == .buffering || player.state == .opening {
            return
        }
        if let url = currentURL {
            play(url: url, forceReload: true)
        }
    }

    func stop() {
        cancelAutoReconnect()
        stopWatchdog()
        currentURL = nil
        isInternalStop = true
        player.stop()
        player.media = nil
        isInternalStop = false
    }

    private func cancelAutoReconnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
    }

    private func scheduleAutoReconnect() {
        cancelAutoReconnect()
        guard currentURL != nil, window != nil else { return }

        let now = Date()
        let elapsed = now.timeIntervalSince(lastReconnectTime)
        if elapsed < 3.0 {
            let remaining = 3.0 - elapsed
            let item = DispatchWorkItem { [weak self] in
                self?.scheduleAutoReconnect()
            }
            reconnectWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: item)
            return
        }

        reconnectAttempts += 1
        guard reconnectAttempts <= 4 else {
            NSLog("[VLCKit] Max reconnect attempts reached, waiting 15s...")
            reconnectAttempts = 0
            lastReconnectTime = now.addingTimeInterval(15.0)
            return
        }

        lastReconnectTime = now
        let delay: Double = reconnectAttempts > 1 ? 2.5 : 1.0
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.currentURL != nil, self.window != nil else { return }
            NSLog("[VLCKit] Reconnecting live stream with fresh token (attempt %d)...", self.reconnectAttempts)
            NotificationCenter.default.post(name: .lanTVReconnectLiveStream, object: nil)
        }
        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func setVolume(_ value: Double) {
        player.audio?.volume = Int32(max(0, min(200, Int(value * 100))))
    }

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard !isInternalStop else { return }
        let state = player.state
        // libVLC fires hundreds of identical .buffering notifications; only react to transitions.
        guard state != lastReportedState else { return }
        lastReportedState = state
        NSLog("[VLCKit] State changed: %@", VLCMediaPlayerStateToString(state))
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isInternalStop else { return }
            self.updateVideoLayerBounds()
            self.ensureStandardAudioTrack()
            switch state {
            case .playing:
                self.reconnectAttempts = 0
                self.cancelAutoReconnect()
                self.onPlaybackStateChange?(true)
            case .paused:
                self.onPlaybackStateChange?(false)
            case .stopped:
                self.onPlaybackStateChange?(false)
                if !self.userPaused { self.scheduleAutoReconnect() }
            case .ended, .error:
                self.onPlaybackStateChange?(false)
                self.scheduleAutoReconnect()
            case .buffering, .opening, .esAdded:
                // Buffer transitions do not toggle isPlaying
                break
            @unknown default:
                break
            }
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        if !hasConfiguredAudioTrack {
            ensureStandardAudioTrack()
        }
    }

    private func ensureStandardAudioTrack() {
        // Select once per playback; later ES changes (ad breaks) must not touch the audio decoder.
        guard !hasConfiguredAudioTrack else { return }
        guard let names = player.audioTrackNames as? [String],
              let indexes = player.audioTrackIndexes as? [Int32],
              names.count == indexes.count, names.count > 1 else {
            return
        }

        // Certain IPTV providers label the Audio Description track with "English"
        // and the main audio track with "Original".
        var originalTrackIndex: Int32?
        var descriptiveTrackIndex: Int32?

        for (i, name) in names.enumerated() {
            let lower = name.lowercased()
            if lower.contains("original") {
                originalTrackIndex = indexes[i]
            } else if lower.contains("description") || lower.contains("descriptive") {
                descriptiveTrackIndex = indexes[i]
            } else if lower.contains("english") && names.contains(where: { $0.lowercased().contains("original") }) {
                descriptiveTrackIndex = indexes[i]
            }
        }

        if let target = originalTrackIndex {
            // Re-selecting on every ES change (ad breaks append new "Original" tracks) restarts the audio
            // decoder and stalls the live stream, so leave an already-selected Original track alone.
            let currentName = indexes.firstIndex(of: player.currentAudioTrackIndex).map { names[$0].lowercased() }
            if currentName?.contains("original") == true {
                hasConfiguredAudioTrack = true
                return
            }
            if player.currentAudioTrackIndex != target {
                NSLog("[VLCKit] Selecting standard audio track %d instead of Audio Description (tracks: %@)", target, names)
                player.currentAudioTrackIndex = target
            }
            hasConfiguredAudioTrack = true
        } else if let desc = descriptiveTrackIndex, player.currentAudioTrackIndex == desc {
            for idx in indexes where idx != -1 && idx != desc {
                player.currentAudioTrackIndex = idx
                hasConfiguredAudioTrack = true
                break
            }
        }
    }
}
