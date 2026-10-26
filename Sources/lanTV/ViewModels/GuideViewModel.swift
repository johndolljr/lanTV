import AVFoundation
import Foundation
import IOKit.pwr_mgt
import LocalAuthentication
import Observation

extension Notification.Name {
    static let lanTVStopPlayback = Notification.Name("lanTVStopPlayback")
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
    var isGuideWindowVisible = false
    var areAdultChannelsUnlocked = false
    var vlcPlaybackGeneration = 0
    let player = AVPlayer()
    var volume: Double = 0.8 {
        didSet {
            player.volume = Float(volume)
            settingsStore.update { $0.volume = volume }
        }
    }

    private let repository: GuideRepository
    let settingsStore: AppSettingsStore
    private let cacheStore: GuideCacheStore
    private let localAPIServer: LocalAPIServer
    private let displaySleepPreventer = DisplaySleepPreventer()
    private var playbackStalledObserver: NSObjectProtocol?
    private var timeControlStatusObserver: NSKeyValueObservation?
    private var playerRateObserver: NSKeyValueObservation?
    private var playerTimeObserver: Any?
    private var lastKnownBehindLive: Double?
    private var currentItemObservers: [NSKeyValueObservation] = []
    private var autoRefreshTask: Task<Void, Never>?
    private(set) var hasPerformedInitialRefresh = false
    private let floatingPlayerWindowController = FloatingPlayerWindowController()
    private let settingsWindowController = SettingsWindowController()

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
        self.selectedChannelID = settingsStore.settings.lastSelectedChannelID
        self.volume = settingsStore.settings.volume
        configurePlayer()
        player.volume = Float(volume)
        localAPIServer.updatePort(settingsStore.settings.localAPIPort)
        localAPIServer.start()
        loadCachedGuide()
        configureAutoRefresh()
        publishLocalAPIState()
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
        selectedChannelID = channel.id
        settingsStore.update { $0.lastSelectedChannelID = channel.id }
        playSelectedChannel()
        if isPlayerDetached {
            floatingPlayerWindowController.show(viewModel: self)
        }
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
            vlcPlaybackGeneration += 1
            isPlaying = true
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
            stopPlayback()
        } else {
            player.pause()
            isPlaying = false
        }
        publishLocalAPIState()
    }

    func stopPlayback() {
        stopNativePlayback()
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
            vlcPlaybackGeneration += 1
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
        guard let selectedChannel else { return }
        isPlayerDetached = true
        floatingPlayerWindowController.show(viewModel: self)
        publishLocalAPIState()
        if usesVLCPlayback(for: selectedChannel) {
            vlcPlaybackGeneration += 1
            isPlaying = true
        } else {
            player.play()
            isPlaying = true
        }
    }

    func dockPlayer() {
        guard let selectedChannel else { return }
        isPlayerDetached = false
        floatingPlayerWindowController.close()
        publishLocalAPIState()
        if usesVLCPlayback(for: selectedChannel) {
            vlcPlaybackGeneration += 1
            isPlaying = true
        } else {
            player.play()
            isPlaying = true
        }
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

    func floatingPlayerWindowDidClose() {
        isPlayerDetached = false
        stopPlayback()
        publishLocalAPIState()
    }

    func usesVLCPlayback(for channel: GuideChannel) -> Bool {
        let pathExtension = channel.streamURL.pathExtension.lowercased()
        if ["m3u8", "mp4", "m4v", "mov"].contains(pathExtension) {
            return false
        }

        let path = channel.streamURL.path.lowercased()
        if pathExtension == "ts" || path.contains("/auto/") {
            return true
        }

        if channel.streamURL.query?.lowercased().contains("channel=") == true {
            return true
        }

        return true
    }

    private func loadCachedGuide() {
        guard let cachedGuide = cacheStore.load() else { return }
        allChannels = cachedGuide.channels
        channels = filterChannels(allChannels)
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
        guard let selectedChannel else { return }
        if usesVLCPlayback(for: selectedChannel) {
            vlcPlaybackGeneration += 1
            isPlaying = true
            isAtLiveEdge = true
            secondsBehindLive = 0
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
        guard !usesVLCPlayback(for: selectedChannel) else {
            stopNativePlayback()
            vlcPlaybackGeneration += 1
            isPlaying = true
            isLiveStream = true
            isAtLiveEdge = true
            secondsBehindLive = 0
            publishLocalAPIState()
            return
        }

        NotificationCenter.default.post(name: .lanTVStopPlayback, object: nil)
        isLiveStream = false
        isAtLiveEdge = true
        secondsBehindLive = 0
        lastKnownBehindLive = nil
        let asset = AVURLAsset(url: selectedChannel.streamURL)
        let item = AVPlayerItem(asset: asset)
        configureItem(item)
        player.replaceCurrentItem(with: item)
        player.play()
        isPlaying = true
        publishLocalAPIState()
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

            if self.isLiveStream && self.secondsBehindLive > 8 {
                self.seekToLive()
            } else {
                self.player.play()
            }
        }
    }

    private func configureItem(_ item: AVPlayerItem) {
        currentItemObservers = []

        item.preferredForwardBufferDuration = 0
        item.automaticallyPreservesTimeOffsetFromLive = true
        item.configuredTimeOffsetFromLive = CMTime(seconds: 4, preferredTimescale: 1)
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        item.preferredMaximumResolution = CGSize(width: 1280, height: 720)

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
        let atLive = behind <= 10.0
        if isAtLiveEdge != atLive {
            isAtLiveEdge = atLive
        }

        // Auto-recover if playback unexpectedly jumped backwards in time while playing.
        // e.g. a stream discontinuity jumping back into earlier segments.
        if isPlaying {
            if let prev = lastKnownBehindLive, prev <= 15.0, behind >= 45.0 {
                seekToLive()
                return
            }
            lastKnownBehindLive = behind
        } else {
            lastKnownBehindLive = behind
        }
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
