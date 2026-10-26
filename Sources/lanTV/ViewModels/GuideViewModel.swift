import AVFoundation
import AVKit
import Foundation
import IOKit.pwr_mgt
import LocalAuthentication
import Observation

extension Notification.Name {
    static let lanTVStopPlayback = Notification.Name("lanTVStopPlayback")
    static let lanTVResumePlayback = Notification.Name("lanTVResumePlayback")
    static let lanTVAdjustAudioDelay = Notification.Name("lanTVAdjustAudioDelay")
    static let lanTVResetAudioDelay = Notification.Name("lanTVResetAudioDelay")
    static let lanTVReconnectLiveStream = Notification.Name("lanTVReconnectLiveStream")
}

@MainActor
@Observable
final class GuideViewModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    var channels: [GuideChannel] = []
    private var allChannels: [GuideChannel] = []
    var selectedChannelID: GuideChannel.ID?
    var generatedAt: Date?
    var state: LoadState = .idle
    var isRefreshing: Bool = false
    var isPlaying: Bool = false {
        didSet {
            updateDisplaySleepAssertion()
        }
    }
    var isLiveStream: Bool = false
    var isAtLiveEdge: Bool = true
    var secondsBehindLive: Double = 0
    var filterText: String = ""
    var sourceStatus: [String: String] = [:]
    var isPlayerDetached = false
    /// A saved recording taking over the player in place of the live channel.
    var playingRecording: RecordingItem?
    var isGuideWindowVisible = false
    var areAdultChannelsUnlocked = false
    var vlcPlaybackGeneration = 0
    var activeStreamURL: URL?
    var audioDelayMs: Int = 0
    let player = AVPlayer()
    let sharedVLCView = VLCVideoContainerView()
    let sharedAVPlayerView = AVPlayerView()
    private var volumeSaveTask: Task<Void, Never>?
    var volume: Double = 0.8 {
        didSet {
            player.volume = Float(volume)
            sharedVLCView.setVolume(volume)
            guard volume != settingsStore.settings.volume else { return }
            volumeSaveTask?.cancel()
            volumeSaveTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { return }
                self.settingsStore.update { $0.volume = self.volume }
            }
        }
    }

    private let repository: GuideRepository
    let settingsStore: AppSettingsStore
    private let cacheStore: GuideCacheStore
    private let localAPIServer: LocalAPIServer
    private let displaySleepPreventer = DisplaySleepPreventer()
    private var playbackStalledObserver: NSObjectProtocol?
    private var avWatchdogTimer: Timer?
    private var lastAVPlayheadSeconds: Double = -1
    private var lastAVProgressTime = Date()
    private var timeControlStatusObserver: NSKeyValueObservation?
    private var playerRateObserver: NSKeyValueObservation?
    private var playerTimeObserver: Any?
    private var lastKnownBehindLive: Double?
    private var currentItemObservers: [NSKeyValueObservation] = []
    private var autoRefreshTask: Task<Void, Never>?
    private(set) var hasPerformedInitialRefresh = false
    private let floatingPlayerWindowController = FloatingPlayerWindowController()
    private let settingsWindowController = SettingsWindowController()
    private let recordingsWindowController = RecordingsWindowController()
    let recordingManager: RecordingManager

    init(
        repository: GuideRepository = GuideRepository(),
        settingsStore: AppSettingsStore = AppSettingsStore(),
        cacheStore: GuideCacheStore = GuideCacheStore(),
        localAPIServer: LocalAPIServer = LocalAPIServer()
    ) {
        self.repository = repository
        self.settingsStore = settingsStore
        self.cacheStore = cacheStore
        self.localAPIServer = localAPIServer
        self.recordingManager = RecordingManager(settingsStore: settingsStore)
        self.selectedChannelID = settingsStore.settings.lastSelectedChannelID
        self.volume = settingsStore.settings.volume
        
        self.recordingManager.currentlyWatchingChannelID = { [weak self] in
            self?.selectedChannelID
        }
        self.recordingManager.currentProgrammeLookup = { [weak self] channelID in
            guard let self else { return nil }
            guard let channel = self.channels.first(where: { $0.id == channelID }) ?? self.allChannels.first(where: { $0.id == channelID }) else {
                return nil
            }
            let now = Date()
            let prog = channel.programmes.first(where: { $0.start <= now && $0.stop > now })
                ?? channel.programmes.first(where: { $0.start >= now })
                ?? GuideProgramme(
                    id: "\(channel.id)|\(now.timeIntervalSinceReferenceDate)",
                    channelID: channel.id,
                    start: now,
                    stop: now.addingTimeInterval(3600),
                    title: channel.name,
                    detail: nil,
                    iconURL: nil
                )
            return (channel, prog)
        }

        configurePlayer()
        player.volume = Float(volume)
        sharedVLCView.onPlaybackStateChange = { [weak self] isPlaying in
            self?.setVLCPlaybackState(isPlaying: isPlaying)
        }
        sharedVLCView.setVolume(volume)
        sharedAVPlayerView.controlsStyle = .none
        sharedAVPlayerView.videoGravity = .resizeAspect
        sharedAVPlayerView.player = player
        localAPIServer.updatePort(settingsStore.settings.localAPIPort)
        localAPIServer.start()
        loadCachedGuide()
        configureAutoRefresh()
        publishLocalAPIState()

        NotificationCenter.default.addObserver(
            forName: .lanTVReconnectLiveStream,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let selectedChannel = self.selectedChannel else { return }
                self.activeStreamURL = selectedChannel.streamURL
                if self.usesVLCPlayback(for: selectedChannel) {
                    self.sharedVLCView.play(url: selectedChannel.streamURL, forceReload: true)
                } else {
                    self.playSelectedChannel()
                }
            }
        }

        Task { [weak self] in
            await self?.load()
        }
    }

    var selectedChannel: GuideChannel? {
        get {
            channels.first(where: { $0.id == selectedChannelID }) ??
            allChannels.first(where: { $0.id == selectedChannelID })
        }
        set { selectedChannelID = newValue?.id }
    }

    var unlockedChannels: [GuideChannel] {
        allChannels.filter { channel in
            let excluded = Set(settingsStore.settings.excludedChannelIDsBySource[channel.sourceID] ?? [])
            let adult = Set(settingsStore.settings.adultChannelIDsBySource[channel.sourceID] ?? [])
            if excluded.contains(channel.rawChannelID) {
                return false
            }
            if !areAdultChannelsUnlocked && adult.contains(channel.rawChannelID) {
                return false
            }
            return true
        }
        .sorted(by: compareGuideChannelOrder)
    }

    var selectedProgrammes: [GuideProgramme] {
        selectedChannel?.programmes ?? []
    }

    var sourceStatusSummary: String {
        settingsStore.settings.sources.compactMap { source in
            guard let status = sourceStatus[source.id] else { return nil }
            return "\(source.displayName): \(status)"
        }
        .joined(separator: "  •  ")
    }

    var adultLockButtonTitle: String {
        areAdultChannelsUnlocked ? "Lock" : "Unlock"
    }

    var localAPIBaseURLString: String {
        localAPIServer.reachableBaseURLs.first?.absoluteString ?? localAPIServer.baseURL.absoluteString
    }

    var localAPIReachableURLs: [String] {
        localAPIServer.reachableBaseURLs.map(\.absoluteString)
    }

    func load() async {
        if isRefreshing {
            return
        }
        if case .loading = state {
            return
        }

        if case .loaded = state, hasPerformedInitialRefresh {
            isRefreshing = true
        } else {
            state = .loading
        }

        do {
            let cachedGuide = cacheStore.load()
            let mergedGuide = try await repository.load(settings: settingsStore.settings)
            allChannels = mergeWithCachedSourcesIfNeeded(freshGuide: mergedGuide, cachedGuide: cachedGuide).channels
            applyChannelFilters()
            recordingManager.syncScheduledRecordings(with: allChannels)
            generatedAt = mergedGuide.generatedAt
            sourceStatus = mergedGuide.sourceStatus
            state = .loaded
            isRefreshing = false
            cacheStore.save(MergedGuide(channels: allChannels, generatedAt: generatedAt, sourceStatus: sourceStatus))
            publishLocalAPIState()

            let targetID = selectedChannelID ?? settingsStore.settings.lastSelectedChannelID
            if let targetID, allChannels.contains(where: { $0.id == targetID }) {
                if selectedChannelID != targetID {
                    selectedChannelID = targetID
                    playSelectedChannel()
                } else if player.currentItem == nil {
                    playSelectedChannel()
                }
            } else if let firstChannel = channels.first {
                selectChannel(firstChannel)
            }
            hasPerformedInitialRefresh = true
        } catch {
            isRefreshing = false
            if !hasPerformedInitialRefresh {
                state = .failed(error.localizedDescription)
            }
            hasPerformedInitialRefresh = true
            publishLocalAPIState()
        }
    }

    func refresh() {
        Task {
            await load()
        }
    }

    func applySettings(_ mutate: (inout AppSettings) -> Void) {
        settingsStore.update(mutate)
        localAPIServer.updatePort(settingsStore.settings.localAPIPort)
        volume = settingsStore.settings.volume
        applyChannelFilters()
        configureAutoRefresh()
        publishLocalAPIState()
        refresh()
    }

    func openSettingsWindow() {
        settingsWindowController.show(viewModel: self)
    }

    func openRecordingsWindow() {
        recordingsWindowController.show(viewModel: self)
    }

    var isCurrentChannelRecording: Bool {
        guard let selectedChannelID else { return false }
        return recordingManager.activeRecording(for: selectedChannelID) != nil
    }

    var currentChannelRecordingItem: RecordingItem? {
        guard let selectedChannelID else { return nil }
        return recordingManager.activeRecording(for: selectedChannelID)
    }

    func toggleRecordingCurrentShow() {
        guard let selectedChannel else { return }
        if let active = recordingManager.activeRecording(for: selectedChannel.id) {
            recordingManager.stopRecording(id: active.id)
            return
        }

        let now = Date()
        let programme = selectedChannel.programmes.first(where: { $0.start <= now && $0.stop > now })
            ?? selectedChannel.programmes.first
            ?? GuideProgramme(
                id: "\(selectedChannel.id)|\(now.timeIntervalSinceReferenceDate)",
                channelID: selectedChannel.id,
                start: now,
                stop: now.addingTimeInterval(3600),
                title: selectedChannel.name,
                detail: nil,
                iconURL: nil
            )

        recordingManager.startRecording(
            channel: selectedChannel,
            programme: programme,
            isLiveRollOver: settingsStore.settings.autoRecordNextShowOnSameChannel
        )
    }

    func recordingItem(for programme: GuideProgramme) -> RecordingItem? {
        recordingManager.recordingItem(forProgrammeID: programme.id)
    }

    func toggleScheduleRecording(channel: GuideChannel, programme: GuideProgramme) {
        if let existing = recordingManager.recordingItem(forProgrammeID: programme.id) {
            if existing.status == .recording {
                recordingManager.stopRecording(id: existing.id)
            } else if existing.status == .scheduled {
                recordingManager.cancelRecording(id: existing.id)
            }
        } else {
            let now = Date()
            if programme.start <= now && programme.stop > now {
                recordingManager.startRecording(channel: channel, programme: programme)
            } else {
                recordingManager.scheduleRecording(channel: channel, programme: programme)
            }
        }
    }

    func fetchChannels(for source: GuideSource) async throws -> [GuideChannel] {
        try await repository.fetchChannels(for: source)
    }

    func hideChannel(_ channel: GuideChannel) {
        applySettings { settings in
            var hidden = Set(settings.excludedChannelIDsBySource[channel.sourceID] ?? [])
            hidden.insert(channel.rawChannelID)
            settings.excludedChannelIDsBySource[channel.sourceID] = Array(hidden).sorted()
        }
    }

    func selectChannel(_ channel: GuideChannel) {
        if selectedChannelID != channel.id {
            activeStreamURL = nil
            resetAudioDelay()
        }
        selectedChannelID = channel.id
        settingsStore.update { $0.lastSelectedChannelID = channel.id }
        playSelectedChannel()
        if isPlayerDetached {
            floatingPlayerWindowController.show(viewModel: self)
        }
    }

    func adjustAudioDelay(byMilliseconds deltaMs: Int) {
        audioDelayMs += deltaMs
        NotificationCenter.default.post(
            name: .lanTVAdjustAudioDelay,
            object: nil,
            userInfo: ["delta": deltaMs * 1000]
        )
    }

    func resetAudioDelay() {
        audioDelayMs = 0
        NotificationCenter.default.post(name: .lanTVResetAudioDelay, object: nil)
    }

    func togglePlayPause() {
        if isPlaying {
            pausePlayback()
        } else {
            resumePlayback()
        }
    }

    func resumePlayback() {
        guard let selectedChannel else { return }
        if usesVLCPlayback(for: selectedChannel) {
            isPlaying = true
            sharedVLCView.resume()
        } else {
            if player.currentItem == nil {
                playSelectedChannel()
            } else {
                player.play()
                isPlaying = true
            }
        }
        publishLocalAPIState()
    }

    func pausePlayback() {
        guard let selectedChannel else { return }
        if usesVLCPlayback(for: selectedChannel) {
            sharedVLCView.pause()
            isPlaying = false
        } else {
            player.pause()
            isPlaying = false
        }
        publishLocalAPIState()
    }

    func playRecording(_ recording: RecordingItem) {
        guard FileManager.default.fileExists(atPath: recording.outputFilePath) else { return }
        playingRecording = recording
        sharedVLCView.stop()
        NotificationCenter.default.post(name: .lanTVStopPlayback, object: nil)
        currentItemObservers = []
        isLiveStream = false
        isAtLiveEdge = true
        secondsBehindLive = 0
        lastKnownBehindLive = nil
        lastAVProgressTime = Date()
        lastAVPlayheadSeconds = -1
        player.replaceCurrentItem(with: AVPlayerItem(url: URL(fileURLWithPath: recording.outputFilePath)))
        player.play()
        isPlaying = true
        if isPlayerDetached {
            floatingPlayerWindowController.show(viewModel: self)
        }
        publishLocalAPIState()
    }

    func stopRecordingPlayback() {
        guard playingRecording != nil else { return }
        playingRecording = nil
        playSelectedChannel()
    }

    func stopPlayback() {
        playingRecording = nil
        stopNativePlayback()
        sharedVLCView.stop()
        isPlaying = false
        NotificationCenter.default.post(name: .lanTVStopPlayback, object: nil)
        publishLocalAPIState()
    }

    func setVLCPlaybackState(isPlaying: Bool) {
        guard let selectedChannel, usesVLCPlayback(for: selectedChannel) else { return }
        if self.isPlaying != isPlaying {
            self.isPlaying = isPlaying
        }
    }

    func guideWindowDidAppear() {
        isGuideWindowVisible = true
        guard !isPlayerDetached, let selectedChannel else { return }

        if usesVLCPlayback(for: selectedChannel) {
            isPlaying = true
            NotificationCenter.default.post(name: .lanTVResumePlayback, object: nil)
        } else {
            playSelectedChannel()
        }
    }

    func guideWindowDidDisappear() {
        isGuideWindowVisible = false
        guard !isPlayerDetached else { return }
        stopPlayback()
    }

    func toggleAdultLock() {
        if areAdultChannelsUnlocked {
            lockAdultChannels()
        } else {
            Task {
                await unlockAdultChannels()
            }
        }
    }

    func lockAdultChannels() {
        areAdultChannelsUnlocked = false
        applyChannelFilters()
        publishLocalAPIState()
    }

    func unlockAdultChannels() async {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var error: NSError?
        let policy: LAPolicy = .deviceOwnerAuthentication
        guard context.canEvaluatePolicy(policy, error: &error) else {
            return
        }

        let success = (try? await context.evaluatePolicy(
            policy,
            localizedReason: "Unlock protected channels in lanTV"
        )) ?? false

        guard success else { return }
        areAdultChannelsUnlocked = true
        applyChannelFilters()
        publishLocalAPIState()
    }

    func undockPlayer() {
        guard selectedChannel != nil else { return }
        isPlayerDetached = true
        floatingPlayerWindowController.show(viewModel: self)
        publishLocalAPIState()
    }

    func dockPlayer() {
        guard selectedChannel != nil else { return }
        isPlayerDetached = false
        floatingPlayerWindowController.close()
        publishLocalAPIState()
    }

    func togglePlayerDocking() {
        if isPlayerDetached {
            dockPlayer()
        } else {
            undockPlayer()
        }
    }

    func focusDetachedPlayerWindow() {
        guard isPlayerDetached else { return }
        floatingPlayerWindowController.show(viewModel: self)
    }

    var isFullScreen: Bool {
        isPlayerDetached && floatingPlayerWindowController.isFullScreen
    }

    func toggleFullScreen() {
        guard selectedChannel != nil else { return }
        if isPlayerDetached && floatingPlayerWindowController.isFullScreen {
            floatingPlayerWindowController.exitFullScreen()
        } else {
            enterFullScreen()
        }
    }

    func enterFullScreen() {
        guard selectedChannel != nil else { return }
        if !isPlayerDetached {
            undockPlayer()
            DispatchQueue.main.async { [weak self] in
                self?.floatingPlayerWindowController.enterFullScreen(fromDocked: true)
            }
        } else {
            floatingPlayerWindowController.enterFullScreen(fromDocked: false)
        }
    }

    func exitFullScreen() {
        floatingPlayerWindowController.exitFullScreen()
    }

    func floatingPlayerWindowDidClose() {
        isPlayerDetached = false
        stopPlayback()
        publishLocalAPIState()
    }

    /// VLCKit is only needed for raw MPEG-TS streams (e.g. HDHomeRun); everything else uses AVPlayer.
    func usesVLCPlayback(for channel: GuideChannel) -> Bool {
        if playingRecording != nil { return false }
        let pathExtension = channel.streamURL.pathExtension.lowercased()
        if ["m3u8", "mp4", "m4v", "mov"].contains(pathExtension) {
            return false
        }

        let path = channel.streamURL.path.lowercased()
        if pathExtension == "ts" || path.contains("/auto/") {
            return true
        }

        return channel.streamURL.query?.lowercased().contains("channel=") == true
    }

    private func loadCachedGuide() {
        guard let cachedGuide = cacheStore.load() else { return }
        allChannels = cachedGuide.channels
        channels = filterChannels(allChannels)
        recordingManager.syncScheduledRecordings(with: allChannels)
        generatedAt = cachedGuide.generatedAt
        sourceStatus = cachedGuide.sourceStatus
        state = .loaded
        let targetID = selectedChannelID ?? settingsStore.settings.lastSelectedChannelID
        if let targetID, channels.contains(where: { $0.id == targetID }) {
            selectedChannelID = targetID
            playSelectedChannel()
        } else if let firstChannel = channels.first {
            selectedChannelID = firstChannel.id
            playSelectedChannel()
        }
        publishLocalAPIState()
    }

    private func configureAutoRefresh() {
        autoRefreshTask?.cancel()
        let interval = settingsStore.settings.autoRefreshIntervalSeconds
        guard interval >= 30 else { return }

        autoRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await self.load()
            }
        }
    }

    func updateFilterText(_ text: String) {
        filterText = text
        channels = filterChannels(allChannels)
    }

    private func applyChannelFilters() {
        channels = filterChannels(allChannels)

        if let selectedChannelID, !unlockedChannels.contains(where: { $0.id == selectedChannelID }) {
            self.selectedChannelID = channels.first?.id
            if selectedChannel != nil {
                playSelectedChannel()
            } else {
                stopPlayback()
            }
        } else if selectedChannel != nil && player.currentItem == nil {
            playSelectedChannel()
        }
        publishLocalAPIState()
    }

    private func publishLocalAPIState() {
        localAPIServer.update(
            with: LocalAPIExportContext(
                baseURLs: localAPIServer.reachableBaseURLs,
                visibleChannels: unlockedChannels,
                generatedAt: generatedAt,
                sourceStatus: sourceStatus,
                settings: settingsStore.settings,
                areProtectedChannelsUnlocked: areAdultChannelsUnlocked,
                selectedChannelID: selectedChannelID,
                isPlayerDetached: isPlayerDetached
            )
        )
    }

    private func filterChannels(_ sourceChannels: [GuideChannel]) -> [GuideChannel] {
        let base = sourceChannels.filter { channel in
            let excluded = Set(settingsStore.settings.excludedChannelIDsBySource[channel.sourceID] ?? [])
            let adult = Set(settingsStore.settings.adultChannelIDsBySource[channel.sourceID] ?? [])
            if excluded.contains(channel.rawChannelID) {
                return false
            }
            if !areAdultChannelsUnlocked && adult.contains(channel.rawChannelID) {
                return false
            }
            return true
        }

        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return base.sorted(by: compareGuideChannelOrder)
        }

        let now = Date()
        let visibleHours = max(settingsStore.settings.guideVisibleHours, 4)
        let windowEnd = now.addingTimeInterval(Double(visibleHours) * 3600)

        return base.filter { channel in
            if channel.name.localizedCaseInsensitiveContains(query) {
                return true
            }
            if channel.displayNumber.localizedCaseInsensitiveContains(query) {
                return true
            }
            let matchesShow = channel.programmes.contains { programme in
                guard programme.stop > now && programme.start <= windowEnd else {
                    return false
                }
                if programme.title.localizedCaseInsensitiveContains(query) {
                    return true
                }
                if let detail = programme.detail, detail.localizedCaseInsensitiveContains(query) {
                    return true
                }
                return false
            }
            return matchesShow
        }
        .sorted(by: compareGuideChannelOrder)
    }

    private func mergeWithCachedSourcesIfNeeded(freshGuide: MergedGuide, cachedGuide: MergedGuide?) -> MergedGuide {
        guard let cachedGuide else { return freshGuide }

        let failedSourceIDs = freshGuide.sourceStatus.compactMap { sourceID, status in
            status.hasSuffix("channels") ? nil : sourceID
        }

        guard !failedSourceIDs.isEmpty else { return freshGuide }

        let cachedBySource = Dictionary(grouping: cachedGuide.channels, by: \.sourceID)
        let freshSourceIDs = Set(freshGuide.channels.map(\.sourceID))

        var recoveredChannels: [GuideChannel] = []
        for sourceID in failedSourceIDs where !freshSourceIDs.contains(sourceID) {
            recoveredChannels.append(contentsOf: cachedBySource[sourceID] ?? [])
        }

        guard !recoveredChannels.isEmpty else { return freshGuide }

        var recoveredStatus = freshGuide.sourceStatus
        for sourceID in failedSourceIDs where !freshSourceIDs.contains(sourceID) {
            if let count = cachedBySource[sourceID]?.count, count > 0 {
                recoveredStatus[sourceID] = "\(count) channels (cached)"
            }
        }

        let mergedChannels = (freshGuide.channels + recoveredChannels)
            .sorted(by: compareGuideChannelOrder)

        return MergedGuide(
            channels: mergedChannels,
            generatedAt: freshGuide.generatedAt ?? cachedGuide.generatedAt,
            sourceStatus: recoveredStatus
        )
    }

    func seekToLive() {
        if playingRecording != nil {
            stopRecordingPlayback()
            return
        }
        guard let selectedChannel else { return }
        if usesVLCPlayback(for: selectedChannel) {
            isPlaying = true
            isAtLiveEdge = true
            secondsBehindLive = 0
            NotificationCenter.default.post(name: .lanTVResumePlayback, object: nil)
            return
        }

        guard let item = player.currentItem else { return }
        player.seek(to: .positiveInfinity) { [weak self] _ in
            guard let self else { return }
            self.player.play()
            self.isPlaying = true
            self.isAtLiveEdge = true
            self.secondsBehindLive = 0
            self.lastKnownBehindLive = 0
        }
    }

    private func playSelectedChannel() {
        guard let selectedChannel else { return }
        playingRecording = nil
        self.activeStreamURL = selectedChannel.streamURL

        guard !self.usesVLCPlayback(for: selectedChannel) else {
            self.stopNativePlayback()
            self.isPlaying = true
            self.isLiveStream = true
            self.isAtLiveEdge = true
            self.secondsBehindLive = 0
            if self.sharedVLCView.currentURL != selectedChannel.streamURL {
                self.sharedVLCView.play(url: selectedChannel.streamURL)
            }
            self.publishLocalAPIState()
            return
        }

        self.sharedVLCView.stop()

        NotificationCenter.default.post(name: .lanTVStopPlayback, object: nil)
        self.isLiveStream = false
        self.isAtLiveEdge = true
        self.secondsBehindLive = 0
        self.lastKnownBehindLive = nil
        let asset = AVURLAsset(url: selectedChannel.streamURL)
        let item = AVPlayerItem(asset: asset)
        self.configureItem(item)
        NSLog("[AVPlayer] loading %@", selectedChannel.streamURL.host ?? "?")
        self.lastAVProgressTime = Date()
        self.lastAVPlayheadSeconds = -1
        self.player.replaceCurrentItem(with: item)
        self.player.play()
        self.isPlaying = true
        self.publishLocalAPIState()
    }

    private func stopNativePlayback() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentItemObservers = []
        isLiveStream = false
        isAtLiveEdge = true
        secondsBehindLive = 0
        lastKnownBehindLive = nil
    }

    private func configurePlayer() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = true
        player.audiovisualBackgroundPlaybackPolicy = .pauses

        let timeInterval = CMTime(seconds: 1, preferredTimescale: 600)
        playerTimeObserver = player.addPeriodicTimeObserver(forInterval: timeInterval, queue: .main) { [weak self] time in
            self?.updateLivePlaybackStatus(currentTime: time)
        }

        timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let selectedChannel = self.selectedChannel, !self.usesVLCPlayback(for: selectedChannel) else {
                    return
                }
                let active = player.timeControlStatus == .playing || player.timeControlStatus == .waitingToPlayAtSpecifiedRate || player.rate > 0
                if self.isPlaying != active {
                    self.isPlaying = active
                }
            }
        }

        playerRateObserver = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let selectedChannel = self.selectedChannel, !self.usesVLCPlayback(for: selectedChannel) else {
                    return
                }
                let active = player.timeControlStatus == .playing || player.timeControlStatus == .waitingToPlayAtSpecifiedRate || player.rate > 0
                if self.isPlaying != active {
                    self.isPlaying = active
                }
            }
        }

        avWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkNativePlaybackProgress() }
        }

        playbackStalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let self,
                let stalledItem = notification.object as? AVPlayerItem,
                stalledItem == self.player.currentItem
            else { return }

            // Resume playback smoothly when buffer refills without destroying the stream buffer by seeking
            self.player.play()
        }
    }

    /// AVPlayer can wedge on a live window it has fallen behind (neither LIVE nor play recovers it),
    /// so reload the stream when the playhead has not moved while playback is supposed to be running.
    private func checkNativePlaybackProgress() {
        guard playingRecording == nil, let selectedChannel, !usesVLCPlayback(for: selectedChannel),
              isPlaying, player.currentItem != nil else {
            lastAVProgressTime = Date()
            return
        }
        let now = player.currentTime().seconds
        if now.isFinite, abs(now - lastAVPlayheadSeconds) > 0.25 {
            lastAVPlayheadSeconds = now
            lastAVProgressTime = Date()
            return
        }
        if Date().timeIntervalSince(lastAVProgressTime) > 12 {
            NSLog("[AVPlayer] playhead stuck at %.1f for >12s, reloading stream", now)
            lastAVProgressTime = Date()
            lastAVPlayheadSeconds = -1
            playSelectedChannel()
        }
    }

    private func configureItem(_ item: AVPlayerItem) {
        currentItemObservers = []

        // Maintain a healthy forward buffer so that network latency and stream discontinuities don't starve playback
        item.preferredForwardBufferDuration = 0
        item.automaticallyPreservesTimeOffsetFromLive = false
        item.configuredTimeOffsetFromLive = CMTime(seconds: 4, preferredTimescale: 1)
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        item.preferredMaximumResolution = CGSize(width: 1920, height: 1080)

        currentItemObservers.append(
            item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
                guard let self else { return }
                if item.isPlaybackLikelyToKeepUp, self.player.timeControlStatus != .playing {
                    self.player.play()
                }
            }
        )

        currentItemObservers.append(
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard let self else { return }
                NSLog("[AVPlayer] item status=%ld error=%@ size=%@ rate=%f", item.status.rawValue, String(describing: item.error), NSStringFromSize(item.presentationSize), self.player.rate)
                if item.status == .readyToPlay {
                    if self.player.rate == 0 {
                        self.player.play()
                    }
                    self.isPlaying = true
                }
            }
        )
    }

    private func updateLivePlaybackStatus(currentTime: CMTime) {
        if playingRecording != nil {
            if isLiveStream { isLiveStream = false }
            return
        }
        guard let selectedChannel, !usesVLCPlayback(for: selectedChannel) else {
            if isLiveStream {
                isLiveStream = false
                isAtLiveEdge = true
                secondsBehindLive = 0
                lastKnownBehindLive = nil
            }
            return
        }

        guard let item = player.currentItem,
              let range = item.seekableTimeRanges.last?.timeRangeValue else {
            return
        }

        let liveEnd = CMTimeRangeGetEnd(range).seconds
        let currentSeconds = currentTime.seconds

        guard liveEnd.isFinite, currentSeconds.isFinite, liveEnd > 0 else {
            return
        }

        isLiveStream = true
        let behind = max(0, liveEnd - currentSeconds)
        secondsBehindLive = behind
        let atLive = behind <= 18.0
        if isAtLiveEdge != atLive {
            isAtLiveEdge = atLive
        }
        lastKnownBehindLive = behind
    }

    private func updateDisplaySleepAssertion() {
        displaySleepPreventer.setPreventSleep(isPlaying)
    }
}

final class DisplaySleepPreventer: @unchecked Sendable {
    private var assertionID: IOPMAssertionID = 0

    func setPreventSleep(_ prevent: Bool, reason: String = "lanTV Video Playback") {
        if prevent {
            guard assertionID == 0 else { return }
            let success = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &assertionID
            )
            if success != kIOReturnSuccess {
                assertionID = 0
            }
        } else {
            guard assertionID != 0 else { return }
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
    }

    deinit {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
        }
    }
}
