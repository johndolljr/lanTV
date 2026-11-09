import AVKit
import SwiftUI
import MobileVLCKit

struct MobilePlayerView: View {
    @Bindable var store: MobileStore
    @State private var isFullscreen = false
    @StateObject private var vlc = MobileVLCController()

    var body: some View {
        ZStack(alignment: .bottom) {
            MobilePlaybackSurface(store: store, vlc: vlc)
            if store.isPlaying {
                MobilePlaybackControls(store: store, vlc: vlc, isFullscreen: false) {
                    isFullscreen = true
                }
                .padding(10)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .accessibilityIdentifier("mobile-player")
        .fullScreenCover(isPresented: $isFullscreen) {
            MobileFullscreenPlayer(store: store, vlc: vlc)
        }
        .onChange(of: store.playbackGeneration) { _, _ in
            guard store.isPlaying, !store.usesNativePlayer, let url = store.selectedChannel?.streamURL else {
                vlc.stop()
                return
            }
            vlc.play(url) { message in
                guard store.isPlaying else { return }
                store.playerError = message
                store.stopPlayback()
            }
        }
        .onChange(of: store.isPlaying) { _, playing in
            if !playing && !store.isPaused { vlc.stop() }
        }
    }
}

private struct MobilePlaybackSurface: View {
    @Bindable var store: MobileStore
    let vlc: MobileVLCController

    var body: some View {
        ZStack {
            Color.black
            if store.isPlaying, let channel = store.selectedChannel, let url = channel.streamURL {
                if store.usesNativePlayer {
                    VideoPlayer(player: store.player)
                } else {
                    let token = store.playbackGeneration
                    VLCMobileSurface(url: url, vlc: vlc, onError: { message in
                        guard store.playbackGeneration == token else { return }
                        store.playerError = message
                        store.stopPlayback()
                    }).id(token)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "play.tv").font(.system(size: 38)).foregroundStyle(.blue)
                    Text("Choose a channel").font(.headline)
                    Text("Streams play directly from your source.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct MobileFullscreenPlayer: View {
    @Bindable var store: MobileStore
    @ObservedObject var vlc: MobileVLCController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MobilePlaybackSurface(store: store, vlc: vlc)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.black.opacity(0.65), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Exit Full Screen Video")
                    .accessibilityIdentifier("exit-fullscreen-video")
                }
                Spacer()
                MobilePlaybackControls(store: store, vlc: vlc, isFullscreen: true) { dismiss() }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("fullscreen-player")
    }
}

private struct MobilePlaybackControls: View {
    @Bindable var store: MobileStore
    let vlc: MobileVLCController
    let isFullscreen: Bool
    let onFullscreen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: togglePlayback) {
                Label(store.isPaused ? "Play" : "Pause", systemImage: store.isPaused ? "play.fill" : "pause.fill")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.isPaused ? "Resume Playback" : "Pause Playback")
            .accessibilityIdentifier("playback-toggle")

            VStack(alignment: .leading, spacing: 2) {
                Text(store.selectedChannel?.name ?? "Live TV").font(.caption.weight(.semibold)).lineLimit(1)
                Text(store.selectedChannel?.nowPlaying?.title ?? (store.isPaused ? "Paused" : "Playing live"))
                    .font(.caption2).foregroundStyle(.white.opacity(0.72)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isFullscreen {
                Button(action: onFullscreen) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 15, weight: .semibold)).frame(width: 42, height: 42)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Exit Full Screen Video")
            } else {
                Button(action: onFullscreen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 15, weight: .semibold)).frame(width: 42, height: 42)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Full Screen Video")
                .accessibilityIdentifier("fullscreen-video")
            }

            Button {
                store.stopPlayback()
                vlc.stop()
            } label: {
                Image(systemName: "stop.fill").font(.system(size: 14, weight: .bold)).frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop Playback")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .background(.black.opacity(0.76), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
    }

    private func togglePlayback() {
        if store.isPaused {
            store.isPaused = false
            if store.usesNativePlayer { store.player.play() } else { vlc.resume() }
        } else {
            store.isPaused = true
            if store.usesNativePlayer { store.player.pause() } else { vlc.pause() }
        }
    }
}

private struct VLCMobileSurface: UIViewRepresentable {
    let url: URL
    let vlc: MobileVLCController
    let onError: @MainActor @Sendable (String) -> Void
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.backgroundColor = .black
        vlc.attach(view)
        vlc.play(url, onError: onError)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) { vlc.attach(uiView) }
}

@MainActor
private final class MobileVLCController: NSObject, ObservableObject {
    private let player = VLCMediaPlayer()
    private let delegate = MobileVLCDelegate()
    private var activeURL: URL?

    override init() {
        super.init()
        delegate.player = player
        player.delegate = delegate
    }

    func attach(_ view: UIView) { player.drawable = view }

    func play(_ url: URL, onError: @escaping @MainActor @Sendable (String) -> Void) {
        delegate.onError = onError
        guard activeURL != url else {
            if !player.isPlaying { player.play() }
            return
        }
        player.stop()
        activeURL = url
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=1000")
        player.media = media
        player.play()
    }

    func pause() { if player.isPlaying { player.pause() } }
    func resume() { if !player.isPlaying { player.play() } }

    func stop() {
        player.stop()
        activeURL = nil
        delegate.onError = nil
    }
}

private final class MobileVLCDelegate: NSObject, VLCMediaPlayerDelegate {
    weak var player: VLCMediaPlayer?
    var onError: (@MainActor @Sendable (String) -> Void)?

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard player?.state == .error, let callback = onError else { return }
        Task { @MainActor in
            callback("The source could not play this stream. Check that it is reachable from this device.")
        }
    }
}
