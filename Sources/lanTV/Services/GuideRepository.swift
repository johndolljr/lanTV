import Foundation

enum GuideRepositoryError: LocalizedError {
    case invalidSourceURL(URL)
    case invalidXMLTVURL(channelID: String)
    case invalidStreamURL(channelID: String)
    case noSourcesLoaded(String)

    var errorDescription: String? {
        switch self {
        case .invalidSourceURL(let url):
            return "Failed to load guide source at \(url.absoluteString)."
        case .invalidXMLTVURL(let channelID):
            return "Channel \(channelID) is missing an XMLTV URL."
        case .invalidStreamURL(let channelID):
            return "Channel \(channelID) is missing an HLS stream URL."
        case .noSourcesLoaded(let detail):
            return detail
        }
    }
}

actor GuideRepository {
    private let session: URLSession
    private let xmltvParser = XMLTVParser()
    private let pluginRunner = GuidePluginRunner()
    private let pluginCacheStore: GuidePluginCacheStore

    init(
        session: URLSession = GuideRepository.makeSession(),
        pluginCacheStore: GuidePluginCacheStore = GuidePluginCacheStore()
    ) {
        self.session = session
        self.pluginCacheStore = pluginCacheStore
    }

    func load(settings: AppSettings) async throws -> MergedGuide {
        let sources = settings.sources
        let sourceResults = await withTaskGroup(of: SourceLoadResult.self) { group in
            for source in sources {
                group.addTask {
                    await self.loadSource(source)
                }
            }

            var collected: [SourceLoadResult] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        let successfulLoads = sourceResults.compactMap(\.loadedSource)
        let generatedAt = successfulLoads.compactMap(\.generatedAt).max()
        let sourceStatus = Dictionary(uniqueKeysWithValues: sourceResults.map { result in
            if let loaded = result.loadedSource {
                return (result.sourceID, "\(loaded.channels.count) channels")
            }
            return (result.sourceID, result.errorDescription ?? "Failed")
        })
        let excludedBySource = settings.excludedChannelIDsBySource
        let sourceFilteredChannels = successfulLoads
            .flatMap(\.channels)
            .filter { channel in
                let excluded = Set(excludedBySource[channel.sourceID] ?? [])
                return !excluded.contains(channel.rawChannelID)
            }
            .sorted(by: compareGuideChannelOrder)

        let channels = await applyGuidePlugins(
            settings.guidePlugins,
            to: sourceFilteredChannels
        )

        guard !channels.isEmpty else {
            let errors = sourceResults.compactMap(\.errorDescription)
            throw GuideRepositoryError.noSourcesLoaded(
                errors.first ?? "No guide sources could be loaded."
            )
        }

        return MergedGuide(channels: channels, generatedAt: generatedAt, sourceStatus: sourceStatus)
    }

    private func applyGuidePlugins(
        _ plugins: [GuidePlugin],
        to channels: [GuideChannel]
    ) async -> [GuideChannel] {
        let enabledPlugins = plugins.filter(\.isEnabled)
        guard !enabledPlugins.isEmpty, !channels.isEmpty else { return channels }

        let cache = pluginCacheStore.load()
        var updatedCache = cache

        let channelsByTarget = Dictionary(
            uniqueKeysWithValues: channels.map { channel in
                (GuidePluginTarget(sourceID: channel.sourceID, rawChannelID: channel.rawChannelID), channel)
            }
        )

        let pluginResults = await withTaskGroup(of: GuidePluginLoadResult.self) { group in
            for plugin in enabledPlugins {
                guard let channel = channelsByTarget[plugin.target] else { continue }

                if let cachedEntry = cache.entries[plugin.id],
                   !cachedEntry.programmes.isEmpty,
                   Date().timeIntervalSince(cachedEntry.fetchedAt) < plugin.refreshIntervalSeconds {
                    group.addTask {
                        .cached(target: plugin.target, programmes: cachedEntry.programmes)
                    }
                    continue
                }

                group.addTask {
                    do {
                        let programmes = try await self.pluginRunner.loadProgrammes(for: plugin, channel: channel)
                        if programmes.isEmpty, let cachedEntry = cache.entries[plugin.id], !cachedEntry.programmes.isEmpty {
                            return .cached(target: plugin.target, programmes: cachedEntry.programmes)
                        }
                        return .success(
                            target: plugin.target,
                            pluginID: plugin.id,
                            programmes: programmes,
                            fetchedAt: Date()
                        )
                    } catch {
                        if let cachedEntry = cache.entries[plugin.id], !cachedEntry.programmes.isEmpty {
                            return .cached(target: plugin.target, programmes: cachedEntry.programmes)
                        }
                        return .failure(
                            target: plugin.target,
                            pluginID: plugin.id,
                            errorDescription: error.localizedDescription
                        )
                    }
                }
            }

            var collected: [GuidePluginLoadResult] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        var programmesByTarget: [GuidePluginTarget: [GuideProgramme]] = [:]
        for result in pluginResults {
            guard let programmes = result.programmes, !programmes.isEmpty else { continue }
            programmesByTarget[result.target, default: []].append(contentsOf: programmes)
            if let pluginID = result.pluginID, let fetchedAt = result.fetchedAt {
                updatedCache.entries[pluginID] = GuidePluginCacheEntry(
                    fetchedAt: fetchedAt,
                    programmes: programmes
                )
            }
        }

        if updatedCache != cache {
            pluginCacheStore.save(updatedCache)
        }

        guard !programmesByTarget.isEmpty else { return channels }

        return channels.map { channel in
            let target = GuidePluginTarget(sourceID: channel.sourceID, rawChannelID: channel.rawChannelID)
            guard let programmes = programmesByTarget[target] else { return channel }

            return GuideChannel(
                id: channel.id,
                sourceID: channel.sourceID,
                rawChannelID: channel.rawChannelID,
                name: channel.name,
                number: channel.number,
                numberLabel: channel.numberLabel,
                detail: channel.detail,
                keyword: channel.keyword,
                logoURL: channel.logoURL,
                streamURL: channel.streamURL,
                xmltvURL: channel.xmltvURL,
                programmes: programmes.sorted { $0.start < $1.start }
            )
        }
    }

    func fetchChannels(for source: GuideSource) async throws -> [GuideChannel] {
        switch source.kind {
        case .xmltv:
            return try await loadStandaloneXMLTV(for: source).channels
        case .hdhomerun:
            return try await loadHDHomeRun(for: source).channels
        }
    }

    private func loadSource(_ source: GuideSource) async -> SourceLoadResult {
        do {
            switch source.kind {
            case .xmltv:
                return .success(sourceID: source.id, try await loadStandaloneXMLTV(for: source))
            case .hdhomerun:
                return .success(sourceID: source.id, try await loadHDHomeRun(for: source))
            }
        } catch {
            return .failure(sourceID: source.id, error.localizedDescription)
        }
    }

    private func loadStandaloneXMLTV(for source: GuideSource) async throws -> LoadedSource {
        guard case .xmltv(let xmltvURL, let streamURLTemplate) = source.kind else {
            fatalError("Invalid source kind for XMLTV load")
        }

        let (data, response) = try await session.data(from: xmltvURL)
        try validate(response: response, url: xmltvURL)

        let parsedGuide = try xmltvParser.parse(data: data)
        let channels = parsedGuide.channels.values.map { channel in
            let scopedChannelID = scopedChannelID(sourceID: source.id, rawChannelID: channel.id)
            let programmes = parsedGuide.programmes
                .filter { $0.channelID == channel.id }
                .map { programme in
                    GuideProgramme(
                        id: "\(scopedChannelID)|\(programme.start.timeIntervalSinceReferenceDate)",
                        channelID: scopedChannelID,
                        start: programme.start,
                        stop: programme.stop,
                        title: cleanDisplayTitle(programme.title ?? channel.displayName ?? channel.id),
                        detail: programme.detail,
                        iconURL: programme.iconURL ?? channel.iconURL
                    )
                }
                .sorted { $0.start < $1.start }

            let parsedNumber = Int(channel.id)
            let parsedNumberLabel: String?
            if parsedNumber != nil {
                parsedNumberLabel = nil
            } else {
                let trimmed = channel.id.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count <= 7,
                   trimmed.contains(where: \.isNumber),
                   trimmed.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }) {
                    parsedNumberLabel = trimmed
                } else {
                    parsedNumberLabel = nil
                }
            }

            return GuideChannel(
                id: scopedChannelID,
                sourceID: source.id,
                rawChannelID: channel.id,
                name: channel.displayName ?? channel.id,
                number: parsedNumber,
                numberLabel: parsedNumberLabel,
                detail: nil,
                keyword: nil,
                logoURL: channel.iconURL,
                streamURL: buildXMLTVStreamURL(
                    template: streamURLTemplate,
                    channelID: channel.id,
                    channelName: channel.displayName ?? channel.id
                ),
                xmltvURL: xmltvURL,
                programmes: programmes
            )
        }
        .sorted(by: compareGuideChannelOrder)

        return LoadedSource(generatedAt: nil, channels: channels)
    }

    private func loadHDHomeRun(for source: GuideSource) async throws -> LoadedSource {
        guard case .hdhomerun(let baseURL) = source.kind else {
            fatalError("Invalid source kind for HDHomeRun load")
        }

        let lineupURL = makeHDHomeRunLineupURL(baseURL: baseURL, showFoundOnly: true)
        let fallbackURL = makeHDHomeRunLineupURL(baseURL: baseURL, showFoundOnly: false)
        let lineup = try await fetchHDHomeRunLineup(primaryURL: lineupURL, fallbackURL: fallbackURL)
        let channels = lineup
            .map { item in
                let scopedChannelID = scopedChannelID(sourceID: source.id, rawChannelID: item.guideNumber)
                return GuideChannel(
                    id: scopedChannelID,
                    sourceID: source.id,
                    rawChannelID: item.guideNumber,
                    name: item.guideName,
                    number: nil,
                    numberLabel: item.guideNumber,
                    detail: hdhomerunDetail(for: item),
                    keyword: nil,
                    logoURL: nil,
                    streamURL: item.url,
                    xmltvURL: lineupURL,
                    programmes: []
                )
            }
            .sorted(by: compareGuideChannelOrder)

        return LoadedSource(generatedAt: nil, channels: channels)
    }

    private func fetchHDHomeRunLineup(primaryURL: URL, fallbackURL: URL) async throws -> [HDHomeRunLineupItem] {
        let primary = try await fetchHDHomeRunLineup(from: primaryURL)
        if !primary.isEmpty {
            return primary
        }
        if fallbackURL != primaryURL {
            return try await fetchHDHomeRunLineup(from: fallbackURL)
        }
        return primary
    }

    private func fetchHDHomeRunLineup(from url: URL) async throws -> [HDHomeRunLineupItem] {
        let (data, response) = try await session.data(from: url)
        try validate(response: response, url: url)
        return try JSONDecoder().decode([HDHomeRunLineupItem].self, from: data)
    }

    private func validate(response: URLResponse, url: URL) throws {
        guard
            let httpResponse = response as? HTTPURLResponse,
            200..<300 ~= httpResponse.statusCode
        else {
            throw GuideRepositoryError.invalidSourceURL(url)
        }
    }

    private func scopedChannelID(sourceID: String, rawChannelID: String) -> String {
        "\(sourceID)::\(rawChannelID)"
    }

    private func buildXMLTVStreamURL(template: String, channelID: String, channelName: String) -> URL {
        let encodedChannelID = channelID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? channelID
        let encodedChannelName = channelName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? channelName

        let resolved: String
        if template.contains("{channel}") || template.contains("{name}") {
            resolved = template
                .replacingOccurrences(of: "{channel}", with: encodedChannelID)
                .replacingOccurrences(of: "{name}", with: encodedChannelName)
        } else {
            resolved = template + encodedChannelID
        }

        guard let url = URL(string: resolved) else {
            fatalError("Invalid XMLTV stream URL template: \(template)")
        }
        return url
    }

    private func makeHDHomeRunLineupURL(baseURL: URL, showFoundOnly: Bool) -> URL {
        let lineupURL = baseURL.appendingPathComponent("lineup.json")
        guard showFoundOnly else { return lineupURL }
        var components = URLComponents(url: lineupURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "show", value: "found")]
        return components?.url ?? lineupURL
    }

    private func hdhomerunDetail(for item: HDHomeRunLineupItem) -> String? {
        var parts: [String] = []
        if let videoCodec = item.videoCodec {
            parts.append(videoCodec)
        }
        if let audioCodec = item.audioCodec {
            parts.append(audioCodec)
        }
        if item.isHD == 1 {
            parts.append("HD")
        }
        if item.isDRM == 1 {
            parts.append("DRM")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private func resolveProgrammeTitles(
        _ programmes: [GuideProgramme],
        channelNames: [String]
    ) -> [GuideProgramme] {
        guard !programmes.isEmpty else { return programmes }

        let normalizedChannelNames = Set(channelNames.map(normalizeComparisonText))

        let meaningfulTitles: [Int: String] = Dictionary(
            uniqueKeysWithValues: programmes.enumerated().compactMap { index, programme in
                let rawCandidate = preferredRawTitle(for: programme)
                let cleaned = cleanDisplayTitle(rawCandidate)
                guard !cleaned.isEmpty else { return nil }
                let normalized = normalizeComparisonText(cleaned)
                guard !normalizedChannelNames.contains(normalized) else { return nil }
                return (index, cleaned)
            }
        )

        return programmes.enumerated().map { index, programme in
            if let meaningful = meaningfulTitles[index] {
                return GuideProgramme(
                    id: programme.id,
                    channelID: programme.channelID,
                    start: programme.start,
                    stop: programme.stop,
                    title: meaningful,
                    detail: programme.detail,
                    iconURL: programme.iconURL
                )
            }

            let replacement = nearestMeaningfulTitle(
                around: index,
                meaningfulTitles: meaningfulTitles,
                fallback: cleanDisplayTitle(preferredRawTitle(for: programme))
            )

            return GuideProgramme(
                id: programme.id,
                channelID: programme.channelID,
                start: programme.start,
                stop: programme.stop,
                title: replacement,
                detail: programme.detail,
                iconURL: programme.iconURL
            )
        }
    }

    private func nearestMeaningfulTitle(
        around index: Int,
        meaningfulTitles: [Int: String],
        fallback: String
    ) -> String {
        if let previous = meaningfulTitles.keys.filter({ $0 < index }).max(),
           let title = meaningfulTitles[previous] {
            return title
        }

        if let next = meaningfulTitles.keys.filter({ $0 > index }).min(),
           let title = meaningfulTitles[next] {
            return title
        }

        return fallback
    }

    private func preferredRawTitle(for programme: GuideProgramme) -> String {
        if let detail = programme.detail, !detail.isEmpty {
            return detail
        }
        return programme.title
    }

    private func cleanDisplayTitle(_ raw: String) -> String {
        let withoutExtension = raw.replacingOccurrences(
            of: #"\.(m4v|mp4|mov|mkv|avi)$"#,
            with: "",
            options: .regularExpression
        )

        let unescaped = withoutExtension
            .replacingOccurrences(of: "_-_", with: " - ")
            .replacingOccurrences(of: "__", with: " ")
            .replacingOccurrences(of: "_", with: " ")

        return unescaped
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeComparisonText(_ value: String) -> String {
        cleanDisplayTitle(value)
            .lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: "", options: .regularExpression)
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }
}

private struct LoadedSource {
    let generatedAt: Date?
    let channels: [GuideChannel]
}

private struct SourceLoadResult {
    let sourceID: String
    let loadedSource: LoadedSource?
    let errorDescription: String?

    static func success(sourceID: String, _ source: LoadedSource) -> SourceLoadResult {
        SourceLoadResult(sourceID: sourceID, loadedSource: source, errorDescription: nil)
    }

    static func failure(sourceID: String, _ message: String) -> SourceLoadResult {
        SourceLoadResult(sourceID: sourceID, loadedSource: nil, errorDescription: message)
    }
}

private struct GuidePluginLoadResult {
    let target: GuidePluginTarget
    let pluginID: String?
    let programmes: [GuideProgramme]?
    let fetchedAt: Date?
    let errorDescription: String?

    static func success(
        target: GuidePluginTarget,
        pluginID: String,
        programmes: [GuideProgramme],
        fetchedAt: Date
    ) -> GuidePluginLoadResult {
        GuidePluginLoadResult(
            target: target,
            pluginID: pluginID,
            programmes: programmes,
            fetchedAt: fetchedAt,
            errorDescription: nil
        )
    }

    static func cached(target: GuidePluginTarget, programmes: [GuideProgramme]) -> GuidePluginLoadResult {
        GuidePluginLoadResult(
            target: target,
            pluginID: nil,
            programmes: programmes,
            fetchedAt: nil,
            errorDescription: nil
        )
    }

    static func failure(
        target: GuidePluginTarget,
        pluginID: String,
        errorDescription: String
    ) -> GuidePluginLoadResult {
        GuidePluginLoadResult(
            target: target,
            pluginID: pluginID,
            programmes: nil,
            fetchedAt: nil,
            errorDescription: errorDescription
        )
    }
}
