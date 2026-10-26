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
        nsView.play(url: url)
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
    private var currentURL: URL?
    private var pendingReplayTasks: [DispatchWorkItem] = []
    private var stopObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        backColor = .black
        fillScreen = true
        autoresizingMask = [.width, .height]
        player = VLCMediaPlayer(videoView: self)
        player.scaleFactor = 0.0
        player.delegate = self
        stopObserver = NotificationCenter.default.addObserver(
            forName: .lanTVStopPlayback,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stop()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func teardown() {
        onPlaybackStateChange = nil
        cancelPendingReplays()
        if let stopObserver {
            NotificationCenter.default.removeObserver(stopObserver)
            self.stopObserver = nil
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
            onPlaybackStateChange = nil
            stop()
            return
        }

        guard let media = player.media else { return }
        player.drawable = self
        player.scaleFactor = 0.0
        if !player.isPlaying {
            player.media = media
            player.play()
        }
        updateVideoLayerBounds()
        scheduleReplayChecks()
        onPlaybackStateChange?(true)
    }

    func play(url: URL) {
        if currentURL == url {
            player.drawable = self
            player.scaleFactor = 0.0
            if !player.isPlaying {
                player.play()
            }
            updateVideoLayerBounds()
            scheduleReplayChecks()
            onPlaybackStateChange?(true)
            return
        }

        cancelPendingReplays()
        currentURL = url
        player.stop()
        player.media = nil
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=500")
        media.addOption(":live-caching=500")
        media.addOption(":http-reconnect=true")
        media.addOption(":demux=any")
        player.media = media
        player.drawable = self
        player.scaleFactor = 0.0
        player.play()
        updateVideoLayerBounds()
        scheduleReplayChecks()
        onPlaybackStateChange?(true)
    }

    func stop() {
        cancelPendingReplays()
        currentURL = nil
        player.stop()
        player.media = nil
    }

    func setVolume(_ value: Double) {
        player.audio?.volume = Int32(max(0, min(200, Int(value * 100))))
    }

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        NSLog("VLCKit state changed: %@", VLCMediaPlayerStateToString(player.state))
        if player.state == .playing || player.state == .esAdded {
            DispatchQueue.main.async { [weak self] in
                self?.updateVideoLayerBounds()
                self?.onPlaybackStateChange?(true)
            }
        } else if player.state == .paused || player.state == .stopped || player.state == .ended || player.state == .error {
            DispatchQueue.main.async { [weak self] in
                self?.onPlaybackStateChange?(false)
            }
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        if player.time.intValue == 0 {
            return
        }
    }

    private func scheduleReplayChecks() {
        cancelPendingReplays()

        for delay in [1.0, 3.0, 6.0] {
            let task = DispatchWorkItem { [weak self] in
                guard let self, self.window != nil, self.currentURL != nil else { return }
                self.player.drawable = self
                self.player.scaleFactor = 0.0
                if !self.player.isPlaying {
                    self.player.stop()
                    if let media = self.player.media {
                        self.player.media = media
                    }
                    self.player.play()
                }
                self.updateVideoLayerBounds()
            }
            pendingReplayTasks.append(task)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
        }
    }

    private func cancelPendingReplays() {
        pendingReplayTasks.forEach { $0.cancel() }
        pendingReplayTasks.removeAll()
    }
}
