import AVKit
import AVFAudio
import Foundation
import Observation
import UIKit
import Network
import Security

@MainActor @Observable
final class MobileStore {
    var sources: [MobileSource] = []
    var selectedSourceID: UUID?
    var channels: [MobileChannel] = []
    var selectedChannel: MobileChannel?
    var desktopState: DesktopState?
    private(set) var isUsingOfflineCache = false
    var status = "Add your desktop server or an XMLTV source to begin."
    var isLoading = false
    var isRequestingUnlock = false
    var isRequestingLock = false
    var unlockMessage: String?
    var isApprover = false
    var isRequestingApproverAccess = false
    var approverMessage: String?
    var pendingUnlockApproval: MobileUnlockApproval?
    private var pendingUnlockApprovalSourceID: UUID?
    var discoveredDesktop: MobileSource?
    var search = ""
    var playerError: String?
    var isPlaying = false
    var isPaused = false
    var playbackGeneration = UUID()
    let player = AVPlayer()
    private(set) var validatedAt: Date?
    private var itemObservation: NSKeyValueObservation?
    private var monitor: Task<Void, Never>?
    private var approvalMonitor: Task<Void, Never>?
    @ObservationIgnored private var serviceBrowser: NWBrowser?
    @ObservationIgnored private var discoveryConnections: [String: NWConnection] = [:]
    private var watchdog: Task<Void, Never>?
    private var generation = UUID()
    private var isForeground = true
    private var snapshotInvalidation = UUID()
    private var lastGuideRevision: String?
    private let session: URLSession
    private let defaults: UserDefaults
    private let deviceID: String
    let isFixture: Bool

    private struct ApproverStatusResponse: Decodable { let status: String }
    private struct ApproverEventsResponse: Decodable { let requests: [MobileUnlockApproval] }
    private struct UnlockRequestResponse: Decodable { let status: String; let requestID: String? }

    private enum ApproverCredentialStore {
        static let service = "com.ragingcoders.lanTV.mobile.approvers"
        static func account(_ sourceID: UUID) -> String { sourceID.uuidString }
        static func read(_ account: String) -> String? {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        static func write(_ value: String, account: String) {
            let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
            let data = Data(value.utf8)
            let status = SecItemUpdate(key as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var item = key
                item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                _ = SecItemAdd(item as CFDictionary, nil)
            }
        }
        static func delete(_ account: String) {
            _ = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
        }
    }

    private struct DesktopGuideCache: Codable {
        let sourceID: UUID
        let serverURL: String
        let revision: String
        let cachedAt: Date
        let channels: [MobileChannel]
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        #if DEBUG
        isFixture = ProcessInfo.processInfo.arguments.contains("--ui-fixture")
        #else
        isFixture = false
        #endif
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // A full desktop guide can take longer than a quick status poll to
        // transfer, especially over Wi-Fi. Short timeouts made every refresh
        // look like a desktop outage and sent the UI back to its offline cache.
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config)
        deviceID = defaults.string(forKey: "mobile-device-id") ?? UUID().uuidString
        if !isFixture { defaults.set(deviceID, forKey: "mobile-device-id") }
        if isFixture { loadFixture(); return }
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--test-desktop-url"), args.indices.contains(index + 1) {
            let source = MobileSource(name: "Integration Desktop", kind: .desktop, url: args[index + 1], streamTemplate: "")
            sources = [source]; selectedSourceID = source.id; startMonitoring(); return
        }
        #endif
        if let data = defaults.data(forKey: "mobile-sources"), let saved = try? JSONDecoder().decode([MobileSource].self, from: data) { sources = saved }
        selectedSourceID = defaults.string(forKey: "mobile-selected-source").flatMap(UUID.init(uuidString:)) ?? sources.first?.id
        startMonitoring()
        startDesktopDiscovery()
    }
    var selectedSource: MobileSource? { sources.first { $0.id == selectedSourceID } }
    var filteredChannels: [MobileChannel] {
        guard !search.isEmpty else { return channels }
        return channels.filter { $0.name.localizedCaseInsensitiveContains(search) || ($0.nowPlaying?.title.localizedCaseInsensitiveContains(search) ?? false) }
    }
    var usesNativePlayer: Bool {
        selectedChannel?.streamURL?.pathExtension.lowercased() == "m3u8" || selectedChannel?.streamURL?.pathExtension.lowercased() == "mp4"
    }
    var canRequestUnlock: Bool {
        selectedSource?.kind == .desktop && desktopState != nil && desktopState?.areProtectedChannelsUnlocked == false && (desktopState?.protectedChannelCount ?? 0) > 0
    }
    var canRequestLock: Bool {
        selectedSource?.kind == .desktop && isApprover && desktopState?.areProtectedChannelsUnlocked == true
    }
    var canRequestApproverRights: Bool { selectedSource?.kind == .desktop && !isApprover && !isRequestingApproverAccess }
    func saveSource(_ source: MobileSource) throws {
        let source = try source.validated()
        if let index = sources.firstIndex(where: { $0.id == source.id }) { sources[index] = source } else { sources.append(source) }
        persist()
        chooseSource(source.id)
    }
    func removeSource(_ id: UUID) {
        if let source = sources.first(where: { $0.id == id }), source.kind == .desktop {
            try? FileManager.default.removeItem(at: desktopCacheURL(for: id))
        }
        sources.removeAll { $0.id == id }
        persist()
        if selectedSourceID == id { chooseSource(sources.first?.id) }
    }
    func chooseSource(_ id: UUID?) {
        invalidateDesktopSnapshot(); unlockMessage = nil; isRequestingUnlock = false
        isApprover = false; isRequestingApproverAccess = false; approverMessage = nil
        selectedSourceID = id
        status = id == nil ? "Add your desktop server or an XMLTV source to begin." : "Connecting…"
        if !isFixture { defaults.set(id?.uuidString, forKey: "mobile-selected-source") }
        startMonitoring()
    }
    private func persist() {
        if !isFixture { defaults.set(try? JSONEncoder().encode(sources), forKey: "mobile-sources") }
    }
    private func desktopCacheURL(for sourceID: UUID) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lanTV-DesktopGuides", isDirectory: true)
            .appendingPathComponent("\(sourceID.uuidString).json")
    }
    private func cacheDesktopGuide(_ guide: MobileGuide, for source: MobileSource) {
        let safeChannels = guide.channels.filter { !$0.isProtected }
        let cache = DesktopGuideCache(
            sourceID: source.id,
            serverURL: source.url,
            revision: guide.revision ?? "",
            cachedAt: Date(),
            channels: safeChannels
        )
        let url = desktopCacheURL(for: source.id)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(cache).write(to: url, options: .atomic)
        } catch {
            NSLog("Could not cache the public desktop guide: %@", error.localizedDescription)
        }
    }
    @discardableResult
    private func restoreOfflineGuide(for source: MobileSource) -> Bool {
        guard source.kind == .desktop,
              let data = try? Data(contentsOf: desktopCacheURL(for: source.id)),
              let cache = try? JSONDecoder().decode(DesktopGuideCache.self, from: data),
              cache.sourceID == source.id,
              cache.serverURL == source.url,
              cache.channels.allSatisfy({ !$0.isProtected }) else { return false }

        let previouslySelected = selectedChannel
        let wasPlaying = isPlaying
        let restoredSelection = previouslySelected.flatMap { selected in
            cache.channels.first { $0.id == selected.id }
        }
        if previouslySelected?.isProtected == true {
            stopPlayback()
            selectedChannel = nil
        } else if wasPlaying,
                  let restoredSelection,
                  previouslySelected?.streamURL == restoredSelection.streamURL {
            // Keep a direct upstream stream running through a brief desktop outage.
            selectedChannel = restoredSelection
        } else {
            if wasPlaying { stopPlayback() }
            selectedChannel = restoredSelection
        }
        channels = cache.channels
        desktopState = nil
        validatedAt = nil
        lastGuideRevision = nil
        unlockMessage = nil
        isUsingOfflineCache = true
        status = "Desktop offline · \(channels.count) saved channels"
        return true
    }
    func foregroundChanged(_ active: Bool) {
        isForeground = active
        if isFixture { if active { loadFixture() }; return }
        if !active {
            monitor?.cancel(); approvalMonitor?.cancel(); watchdog?.cancel(); generation = UUID(); isLoading = false
            if let source = selectedSource, source.kind == .desktop, !restoreOfflineGuide(for: source) {
                invalidateDesktopSnapshot()
            }
        } else { startMonitoring(); startDesktopDiscovery() }
    }
    private func startDesktopDiscovery() {
        guard !isFixture, isForeground, serviceBrowser == nil else { return }
        if sources.isEmpty { status = "Looking for a lanTV desktop on this network…" }
        let browser = NWBrowser(for: .bonjour(type: "_lantv._tcp", domain: "local."), using: .tcp)
        serviceBrowser = browser
        browser.stateUpdateHandler = { [weak self] state in
            guard case let .failed(error) = state else { return }
            let message = error.localizedDescription
            Task { @MainActor [weak self] in
                self?.status = "Desktop discovery failed: \(message)"
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleDesktopBrowseResults(results)
                if results.isEmpty, self.sources.isEmpty {
                    self.status = "Searching for a lanTV desktop on this network…"
                }
            }
        }
        browser.start(queue: .main)
    }
    private func handleDesktopBrowseResults(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint,
                  discoveredDesktop?.name != name,
                  discoveryConnections[name] == nil else { continue }
            // Bonjour may resolve the service to an IPv6 link-local address first.
            // That address is not consistently usable by URLSession on iOS, so
            // resolve the advertised service over IPv4 before saving its URL.
            let parameters = NWParameters.tcp
            if let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ipOptions.version = .v4
            }
            let connection = NWConnection(to: result.endpoint, using: parameters)
            discoveryConnections[name] = connection
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                if case let .failed(error) = state {
                    let message = error.localizedDescription
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.discoveryConnections.removeValue(forKey: name)
                        self.status = "Found \(name), but couldn’t connect: \(message)"
                    }
                    return
                }
                guard case .ready = state, let connection else { return }
                guard case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint else {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.discoveryConnections.removeValue(forKey: name)?.cancel()
                        self.status = "Found \(name), but couldn’t resolve its address."
                    }
                    return
                }
                let resolvedHost: String
                switch host {
                case .name(let value, _):
                    // Network.framework can append its interface name to a
                    // resolved IPv4 literal (for example, 192.168.3.11%en0).
                    // That suffix is not part of an IPv4 URL host.
                    resolvedHost = Self.ipv4HostWithoutInterface(value)
                case .ipv4(let value):
                    // IPv4Address.debugDescription can include the same interface
                    // suffix, so normalize this case as well as `.name` above.
                    resolvedHost = Self.ipv4HostWithoutInterface(value.debugDescription)
                case .ipv6(let value): resolvedHost = value.debugDescription.replacingOccurrences(of: "%", with: "%25")
                @unknown default: return
                }
                // URLComponents.host rejects some Network.framework host strings
                // (notably scoped IPv6 values). Construct the authority explicitly,
                // adding brackets only for IPv6 literals.
                let normalizedHost = resolvedHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                let urlHost = normalizedHost.contains(":") ? "[\(normalizedHost)]" : normalizedHost
                guard let url = URL(string: "http://\(urlHost):\(port.rawValue)") else {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.discoveryConnections.removeValue(forKey: name)?.cancel()
                        self.status = "Found \(name), but couldn’t make a usable address (\(normalizedHost):\(port.rawValue))."
                    }
                    return
                }
                let source = MobileSource(name: name, kind: .desktop, url: url.absoluteString, streamTemplate: "")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer { self.discoveryConnections.removeValue(forKey: name)?.cancel() }
                    let desktopSources = self.sources.indices.filter { self.sources[$0].kind == .desktop }
                    let existingIndex = desktopSources.first(where: { self.sources[$0].name == name })
                        ?? (desktopSources.count == 1 ? desktopSources.first : nil)
                    if let index = existingIndex {
                        let existing = self.sources[index]
                        guard existing.url != source.url else { return }
                        if !Self.isLinkLocalIPv6(existing.url), await self.canReachDesktop(at: existing.url) {
                            return
                        }
                        var refreshed = existing
                        refreshed.url = source.url
                        self.sources[index] = refreshed
                        self.persist()
                        self.status = "Reconnected to the desktop on this network."
                        if self.selectedSourceID == refreshed.id { self.chooseSource(refreshed.id) }
                    } else if !self.sources.contains(where: { $0.kind == .desktop && $0.url == source.url }) {
                        self.discoveredDesktop = source
                    } else if self.sources.isEmpty {
                        self.status = "This desktop is already saved as a guide source."
                    }
                }
            }
            status = "Found \(name), connecting…"
            connection.start(queue: .main)
        }
    }
    nonisolated private static func ipv4HostWithoutInterface(_ value: String) -> String {
        String(value.split(separator: "%", maxSplits: 1).first ?? Substring(value))
    }
    private static func isLinkLocalIPv6(_ rawURL: String) -> Bool {
        guard let host = URLComponents(string: rawURL)?.host?.lowercased() else { return false }
        return host.hasPrefix("fe80:") || host.hasPrefix("[fe80:")
    }
    private func canReachDesktop(at rawURL: String) async -> Bool {
        guard let base = try? MobileSource.validatedURL(rawURL) else { return false }
        do {
            let data = try await fetch(endpoint("/api/mobile/state.json", base: base))
            return (try? JSONDecoder().decode(DesktopState.self, from: data).protocolVersion) == 1
        } catch {
            return false
        }
    }
    func addDiscoveredDesktop() {
        guard let source = discoveredDesktop else { return }
        discoveredDesktop = nil
        do {
            try saveSource(source)
            status = "Added \(source.name). Connecting to its guide…"
        } catch {
            status = "Could not add \(source.name): \(error.localizedDescription)"
        }
    }
    func dismissDiscoveredDesktop() { discoveredDesktop = nil }
    func refresh() { startMonitoring() }
    private func startMonitoring() {
        monitor?.cancel(); approvalMonitor?.cancel(); watchdog?.cancel(); generation = UUID(); isRequestingUnlock = false; isLoading = false
        guard !isFixture, isForeground else { return }
        let token = generation
        approvalMonitor = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.generation == token {
                await self.pollApproverActivity(generation: token)
                try? await Task.sleep(for: .seconds(2))
            }
        }
        guard let source = selectedSource else { return }
        if source.kind == .desktop, desktopState == nil { _ = restoreOfflineGuide(for: source) }
        monitor = Task { [weak self] in
            guard let self else { return }
            var lastStandaloneLoad = Date.distantPast
            while !Task.isCancelled && self.generation == token {
                do {
                    if source.kind == .desktop { try await self.syncDesktop(source, generation: token) }
                    else if Date().timeIntervalSince(lastStandaloneLoad) > 300 {
                        self.isLoading = true
                        let url = try MobileSource.validatedURL(source.url)
                        let data = try await self.fetch(url)
                        let guide = try await Task.detached { try MobileXMLTVParser.parse(data, sourceID: source.id, template: source.streamTemplate, baseURL: url) }.value
                        guard self.generation == token, !Task.isCancelled else { return }
                        do { try MobileLockPolicy.validateStandaloneGuide(guide) }
                        catch { self.invalidateDesktopSnapshot(); throw error }
                        self.channels = guide.channels; self.status = "\(guide.channels.count) channels · Direct from source"; lastStandaloneLoad = Date()
                    }
                } catch {
                    guard self.generation == token, !Task.isCancelled else { return }
                    if source.kind == .desktop {
                        let hasFreshDesktopState = self.validatedAt.map {
                            Date().timeIntervalSince($0) <= MobileLockPolicy.maximumStateAge
                        } ?? false
                        if hasFreshDesktopState {
                            // Keep the last complete guide visible through a
                            // transient request failure. The watchdog switches
                            // to the public offline cache once the state expires.
                            self.status = "Desktop connection interrupted · retrying"
                        } else if !self.restoreOfflineGuide(for: source) {
                            self.invalidateDesktopSnapshot()
                            self.status = error.localizedDescription
                        }
                    } else {
                        self.status = error.localizedDescription
                    }
                }
                self.isLoading = false
                try? await Task.sleep(for: .seconds(2))
            }
        }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.generation == token else { return }
                if self.selectedSource?.kind == .desktop, let channel = self.selectedChannel,
                   !MobileLockPolicy.canPlay(channel, state: self.desktopState, validatedAt: self.validatedAt) { self.clearProtected() }
                if !self.isUsingOfflineCache,
                   let timestamp = self.validatedAt,
                   Date().timeIntervalSince(timestamp) > MobileLockPolicy.maximumStateAge {
                    if let source = self.selectedSource, !self.restoreOfflineGuide(for: source) {
                        self.invalidateDesktopSnapshot()
                        self.status = "Desktop connection lost. Protected channels are locked."
                    }
                }
            }
        }
    }
    private func syncDesktop(_ source: MobileSource, generation token: UUID) async throws {
        let base = try MobileSource.validatedURL(source.url)
        let stateURL = endpoint("/api/mobile/state.json", base: base)
        let before = try JSONDecoder().decode(DesktopState.self, from: await fetch(stateURL))
        guard generation == token, !Task.isCancelled else { return }
        guard before.protocolVersion == 1 else { throw MobileError.message("Update lanTV on your desktop to connect this app.") }
        if !before.areProtectedChannelsUnlocked { clearProtected() }
        desktopState = before; validatedAt = Date()
        if MobileLockPolicy.mustInvalidateSnapshot(previousRevision: lastGuideRevision, newState: before) {
            // Keep the previous complete snapshot on screen while its replacement
            // loads. A lock change above has already removed protected channels.
            let previousSelectedID = selectedChannel?.id
            let wasPlaying = isPlaying
            let refreshToken = snapshotInvalidation
            isLoading = true
            guard before.guideURL.hasPrefix("/"), !before.guideURL.hasPrefix("//"), let relative = URLComponents(string: before.guideURL), relative.host == nil, relative.scheme == nil else { throw MobileError.message("Desktop returned an invalid guide address.") }
            let guideURL = endpoint(before.guideURL, base: base)
            let data = try await fetch(guideURL)
            let guide = try await Task.detached { try MobileXMLTVParser.parse(data, sourceID: source.id, template: "", baseURL: guideURL) }.value
            let after = try JSONDecoder().decode(DesktopState.self, from: await fetch(stateURL))
            guard generation == token, !Task.isCancelled else { return }
            try MobileLockPolicy.validate(before: before, guideRevision: guide.revision, after: after)
            desktopState = after; validatedAt = Date()
            cacheDesktopGuide(guide, for: source)
            isUsingOfflineCache = false
            channels = MobileLockPolicy.allowedChannels(guide.channels, state: after)
            lastGuideRevision = after.revision
            if refreshToken == snapshotInvalidation, let previousSelectedID, let refreshed = channels.first(where: { $0.id == previousSelectedID }) {
                if wasPlaying { select(refreshed) } else { selectedChannel = refreshed }
            }
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if selectedChannel == nil, let index = args.firstIndex(of: "--test-play-channel"), args.indices.contains(index + 1),
               let channel = channels.first(where: { $0.rawID == args[index + 1] || $0.number == args[index + 1] }) { select(channel) }
            #endif
            if let selectedChannel, let updated = channels.first(where: { $0.id == selectedChannel.id }) { self.selectedChannel = updated }
            else if selectedChannel != nil { stopPlayback(); selectedChannel = nil }
        }
        status = "\(channels.count) channels · Guide synced"
        if before.areProtectedChannelsUnlocked { unlockMessage = nil }
    }
    private func endpoint(_ path: String, base: URL) -> URL {
        // Desktop endpoints are rooted on the configured host, never a URL supplied by the feed.
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.path = path; components.query = nil; components.fragment = nil
        return components.url!
    }
    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw MobileError.message("The server did not return a usable response.") }
        guard data.count <= 64 * 1024 * 1024 else { throw MobileError.message("This guide is too large to load on this device.") }
        return data
    }
    private func invalidateDesktopSnapshot() {
        snapshotInvalidation = UUID()
        stopPlayback(); selectedChannel = nil; channels = []; desktopState = nil; validatedAt = nil; lastGuideRevision = nil
        isUsingOfflineCache = false
    }
    private func clearProtected() {
        channels.removeAll { $0.isProtected }
        if selectedChannel?.isProtected == true { stopPlayback(); selectedChannel = nil }
    }
    func select(_ channel: MobileChannel) {
        guard channel.sourceID == selectedSourceID else { return }
        if selectedSource?.kind == .desktop {
            if isUsingOfflineCache {
                guard !channel.isProtected,
                      let current = channels.first(where: { $0.id == channel.id }), current == channel else {
                    playerError = "Only saved, unprotected channels can play while the desktop is offline."; return
                }
            } else {
                guard let current = channels.first(where: { $0.id == channel.id }), current == channel,
                      let state = desktopState, state.protocolVersion == 1, state.revision == lastGuideRevision,
                      let validatedAt, Date().timeIntervalSince(validatedAt) <= MobileLockPolicy.maximumStateAge else {
                    invalidateDesktopSnapshot(); playerError = "Reconnect to your desktop before playing a channel."; return
                }
            }
        }
        if selectedSource?.kind == .desktop && !MobileLockPolicy.canPlay(channel, state: desktopState, validatedAt: validatedAt) {
            clearProtected(); playerError = "Protected channels need a current unlock from your desktop."; return
        }
        guard let url = channel.streamURL else { playerError = "This channel has no stream URL. Set a stream URL template for this XMLTV source."; return }
        do { _ = try MobileSource.validatedURL(url.absoluteString) }
        catch { playerError = "Update this channel’s stream address on the desktop or source. \(error.localizedDescription)"; return }
        activatePlaybackAudioSession()
        stopPlayback(); selectedChannel = channel; playerError = nil; isPlaying = true; isPaused = false; playbackGeneration = UUID()
        if usesNativePlayer {
            let item = AVPlayerItem(url: url)
            let token = playbackGeneration
            itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.playbackGeneration == token else { return }
                    self.playerError = "The source could not play this stream. Check that it is reachable from this device."
                    self.stopPlayback()
                }
            }
            player.isMuted = false
            player.replaceCurrentItem(with: item); player.play()
        }
    }
    private func activatePlaybackAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playback, mode: .moviePlayback)
            try audioSession.setActive(true)
        } catch {
            NSLog("Could not activate the mobile playback audio session: %@", error.localizedDescription)
        }
    }
    func stopPlayback() {
        itemObservation = nil; isPlaying = false; isPaused = false; player.pause(); player.replaceCurrentItem(with: nil); playbackGeneration = UUID()
    }
    func requestUnlock() {
        if isFixture { unlockMessage = "Request sent. Approve it in lanTV on your desktop."; return }
        guard !isRequestingUnlock, canRequestUnlock, let source = selectedSource else { return }
        isRequestingUnlock = true
        let token = generation
        Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.isRequestingUnlock = false } }
            do {
                let base = try MobileSource.validatedURL(source.url)
                var components = URLComponents(url: self.endpoint("/api/mobile/unlock-request", base: base), resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "deviceID", value: self.deviceID), URLQueryItem(name: "deviceName", value: UIDevice.current.name)]
                var request = URLRequest(url: components.url!); request.httpMethod = "POST"
                let (data, response) = try await self.session.data(for: request)
                guard self.generation == token else { return }
                guard let http = response as? HTTPURLResponse, [200, 202].contains(http.statusCode),
                      let result = try? JSONDecoder().decode(UnlockRequestResponse.self, from: data) else {
                    let serverMessage = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let detail = serverMessage.flatMap { $0.isEmpty ? nil : $0 }
                    throw MobileError.message(detail ?? "Could not send the unlock request. Try again shortly.")
                }
                if result.status == "alreadyUnlocked" {
                    self.unlockMessage = "Desktop is already unlocked. Refreshing guide…"
                    return
                }
                if let requestID = result.requestID.flatMap(UUID.init(uuidString:)),
                   let credential = ApproverCredentialStore.read(ApproverCredentialStore.account(source.id)) {
                    if await self.submitApproverDecision(requestID: requestID, source: source, credential: credential, approved: true) {
                        self.unlockMessage = "Unlocked by this approved device."
                    } else {
                        self.unlockMessage = "Request sent, but this device could not authorize it. Approve it on the desktop or check approver access."
                    }
                } else {
                    self.unlockMessage = "Request sent. Approve it in lanTV on your desktop."
                }
            } catch { if self.generation == token { self.unlockMessage = error.localizedDescription } }
        }
    }

    func requestLock() {
        guard !isRequestingLock, canRequestLock, let source = selectedSource,
              let credential = ApproverCredentialStore.read(ApproverCredentialStore.account(source.id)) else { return }
        isRequestingLock = true
        unlockMessage = nil
        let token = generation
        Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.isRequestingLock = false } }
            do {
                let base = try MobileSource.validatedURL(source.url)
                var components = URLComponents(url: self.endpoint("/api/mobile/approver-lock", base: base), resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "deviceID", value: self.deviceID), URLQueryItem(name: "credential", value: credential)]
                var request = URLRequest(url: components.url!); request.httpMethod = "POST"
                let (data, response) = try await self.session.data(for: request)
                guard self.generation == token else { return }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let result = try? JSONDecoder().decode(ApproverStatusResponse.self, from: data),
                      ["locked", "alreadyLocked"].contains(result.status) else {
                    throw MobileError.message("Could not lock channels from this device. Check approver access and the desktop connection.")
                }
                if var state = self.desktopState {
                    state = DesktopState(protocolVersion: state.protocolVersion, revision: state.revision, areProtectedChannelsUnlocked: false, protectedChannelCount: state.protectedChannelCount, guideURL: state.guideURL)
                    self.desktopState = state
                    self.validatedAt = Date()
                }
                self.clearProtected()
                self.unlockMessage = "Protected channels are locked."
            } catch { if self.generation == token { self.unlockMessage = error.localizedDescription } }
        }
    }

    func requestApproverRights() {
        guard canRequestApproverRights, let source = selectedSource else { return }
        isRequestingApproverAccess = true
        approverMessage = "Requesting desktop approval…"
        let token = generation
        Task { [weak self] in
            guard let self else { return }
            do {
                let base = try MobileSource.validatedURL(source.url)
                let account = ApproverCredentialStore.account(source.id)
                let credential = ApproverCredentialStore.read(account) ?? Self.newApproverCredential()
                ApproverCredentialStore.write(credential, account: account)
                var components = URLComponents(url: self.endpoint("/api/mobile/approver-request", base: base), resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "deviceID", value: self.deviceID), URLQueryItem(name: "deviceName", value: UIDevice.current.name), URLQueryItem(name: "credential", value: credential)]
                var request = URLRequest(url: components.url!); request.httpMethod = "POST"
                let (data, response) = try await self.session.data(for: request)
                guard self.generation == token else { return }
                guard let http = response as? HTTPURLResponse, [200, 202].contains(http.statusCode),
                      let result = try? JSONDecoder().decode(ApproverStatusResponse.self, from: data) else {
                    throw MobileError.message("Could not request approver access. Check the desktop connection.")
                }
                self.isApprover = result.status == "approved"
                self.isRequestingApproverAccess = result.status != "approved"
                self.approverMessage = result.status == "approved" ? "This device can approve unlock requests." : "Request sent. Approve this device in lanTV Settings on the desktop."
            } catch {
                if self.generation == token { self.isRequestingApproverAccess = false; self.approverMessage = error.localizedDescription }
            }
        }
    }

    func respondToUnlockApproval(approved: Bool) {
        guard let approval = pendingUnlockApproval, let sourceID = pendingUnlockApprovalSourceID,
              let source = sources.first(where: { $0.id == sourceID }), let credential = ApproverCredentialStore.read(ApproverCredentialStore.account(sourceID)) else { return }
        pendingUnlockApproval = nil; pendingUnlockApprovalSourceID = nil
        Task {
            let succeeded = await submitApproverDecision(requestID: approval.id, source: source, credential: credential, approved: approved)
            approverMessage = succeeded ? (approved ? "Unlock approved on this device." : "Unlock request denied.") : "The desktop no longer has this unlock request."
        }
    }

    private func submitApproverDecision(requestID: UUID, source: MobileSource, credential: String, approved: Bool) async -> Bool {
        do {
            let base = try MobileSource.validatedURL(source.url)
            var components = URLComponents(url: endpoint("/api/mobile/approver-decision", base: base), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "deviceID", value: deviceID), URLQueryItem(name: "credential", value: credential), URLQueryItem(name: "requestID", value: requestID.uuidString), URLQueryItem(name: "decision", value: approved ? "approve" : "deny")]
            var request = URLRequest(url: components.url!); request.httpMethod = "POST"
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let result = try? JSONDecoder().decode(ApproverStatusResponse.self, from: data) else { return false }
            return result.status == (approved ? "approved" : "denied")
        } catch { return false }
    }

    func dismissUnlockApprovalPrompt() { pendingUnlockApproval = nil; pendingUnlockApprovalSourceID = nil }

    private func pollApproverActivity(generation token: UUID) async {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        for source in sources where source.kind == .desktop {
            guard generation == token, !Task.isCancelled else { return }
            let account = ApproverCredentialStore.account(source.id)
            guard let credential = ApproverCredentialStore.read(account) else {
                if source.id == selectedSourceID {
                    isApprover = false
                    approverMessage = "This phone has no saved approval key for this desktop. Request approver access again in Settings."
                }
                continue
            }
            guard let base = try? MobileSource.validatedURL(source.url) else {
                if source.id == selectedSourceID { approverMessage = "The desktop address is invalid. Check it in Settings → Sources." }
                continue
            }
            do {
                let statusURL = endpoint("/api/mobile/approver-status", base: base).appending(queryItems: [URLQueryItem(name: "deviceID", value: deviceID), URLQueryItem(name: "credential", value: credential)])
                let statusData = try await fetch(statusURL)
                let status = try decoder.decode(ApproverStatusResponse.self, from: statusData).status
                guard generation == token else { return }
                if source.id == selectedSourceID {
                    isApprover = status == "approved"
                    isRequestingApproverAccess = status == "pending"
                    if status == "approved" { approverMessage = "Approver connected. Checking for unlock requests…" }
                    else if status == "pending" { approverMessage = "Waiting for desktop approval…" }
                    else if status == "denied" || status == "revoked" || status == "notAuthorized" {
                        approverMessage = status == "denied" ? "The desktop denied approver access." : (status == "revoked" ? "Approver access was revoked on the desktop." : nil)
                        if status != "pending" { ApproverCredentialStore.delete(account); isRequestingApproverAccess = false }
                    }
                }
                guard status == "approved" else { continue }
                let eventsURL = endpoint("/api/mobile/approver-events", base: base).appending(queryItems: [URLQueryItem(name: "deviceID", value: deviceID), URLQueryItem(name: "credential", value: credential)])
                let events = try decoder.decode(ApproverEventsResponse.self, from: await fetch(eventsURL))
                guard generation == token else { return }
                if source.id == selectedSourceID {
                    approverMessage = events.requests.isEmpty
                        ? "Approver connected. No pending unlock requests reached this phone."
                        : "Unlock request received from \(events.requests[0].deviceName)."
                }
                if pendingUnlockApprovalSourceID == source.id,
                   let current = pendingUnlockApproval,
                   !events.requests.contains(where: { $0.id == current.id }) {
                    pendingUnlockApproval = nil; pendingUnlockApprovalSourceID = nil
                }
                if pendingUnlockApproval == nil, let next = events.requests.first {
                    pendingUnlockApproval = next; pendingUnlockApprovalSourceID = source.id
                }
            } catch {
                if source.id == selectedSourceID {
                    approverMessage = "Could not check for unlock requests: \(error.localizedDescription)"
                }
            }
        }
    }

    private static func newApproverCredential() -> String {
        var bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        defer { _ = bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private func loadFixture() {
        let source = MobileSource(name: "Home Desktop", kind: .desktop, url: "http://desktop.lan:48921", streamTemplate: "")
        sources = [source]; selectedSourceID = source.id
        let now = Date(); let start = Calendar.current.dateInterval(of: .hour, for: now)?.start ?? now
        let names = ["World News", "Cinema", "Discovery", "Family", "Comedy", "Nature", "Classics", "Music"]
        channels = names.enumerated().map { index, name in
            let rawID = "fixture-\(index)"
            let programmes = (0..<5).map { offset in
                MobileProgramme(channelID: rawID, start: start.addingTimeInterval(Double(offset) * 3600), stop: start.addingTimeInterval(Double(offset + 1) * 3600), title: ["Morning Edition", "The Great Journey", "Behind the Scenes", "Afternoon Live", "Evening Stories"][(index + offset) % 5], detail: "Discover what’s on with lanTV. Your guide and live streams, together on every screen.")
            }
            return MobileChannel(sourceID: source.id, rawID: rawID, number: "\(100 + index)", name: name, streamURL: nil, logoURL: nil, isProtected: false, programmes: programmes)
        }
        desktopState = DesktopState(protocolVersion: 1, revision: "fixture", areProtectedChannelsUnlocked: false, protectedChannelCount: 3, guideURL: "/api/guide.xmltv")
        validatedAt = Date(); status = "8 channels · Desktop locked"
    }
}
