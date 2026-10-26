import Foundation

func normalizeStreamURLTemplate(_ raw: String) -> String {
    raw.removingPercentEncoding ?? raw
}

func compareGuideChannelOrder(_ lhs: GuideChannel, _ rhs: GuideChannel) -> Bool {
    let lhsParts = lhs.displayNumber.split(separator: ".").compactMap { Int($0) }
    let rhsParts = rhs.displayNumber.split(separator: ".").compactMap { Int($0) }

    if !lhsParts.isEmpty, !rhsParts.isEmpty {
        for index in 0..<max(lhsParts.count, rhsParts.count) {
            let left = index < lhsParts.count ? lhsParts[index] : -1
            let right = index < rhsParts.count ? rhsParts[index] : -1
            if left != right {
                return left < right
            }
        }
    } else {
        switch (lhs.number, rhs.number) {
        case let (left?, right?) where left != right:
            return left < right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            break
        }
    }

    if lhs.hasDisplayNumber && rhs.hasDisplayNumber {
        let numberComparison = lhs.displayNumber.localizedStandardCompare(rhs.displayNumber)
        if numberComparison != .orderedSame {
            return numberComparison == .orderedAscending
        }
    } else if lhs.hasDisplayNumber != rhs.hasDisplayNumber {
        return lhs.hasDisplayNumber
    }

    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
}

struct GuideSource: Identifiable, Hashable, Codable {
    enum Kind: Hashable, Codable {
        case xmltv(url: URL, streamURLTemplate: String)
        case hdhomerun(URL)

        enum CodingKeys: String, CodingKey {
            case type
            case url
            case streamURLTemplate
            case streamBaseURL
        }

        enum SourceType: String, Codable {
            case xmltv
            case hdhomerun
            case manifest
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(SourceType.self, forKey: .type)
            switch type {
            case .xmltv:
                let template =
                    (try? container.decode(String.self, forKey: .streamURLTemplate)) ??
                    (try? container.decode(String.self, forKey: .streamBaseURL)) ??
                    (try? container.decode(URL.self, forKey: .streamBaseURL).absoluteString)

                self = .xmltv(
                    url: try container.decode(URL.self, forKey: .url),
                    streamURLTemplate: normalizeStreamURLTemplate(
                        template ?? "http://example.local/video?channel={channel}"
                    )
                )
            case .manifest:
                let manifestURL = try container.decode(URL.self, forKey: .url)
                let xmltvURL = manifestURL.deletingLastPathComponent().appendingPathComponent("xmltv.xml")
                let base = manifestURL.deletingLastPathComponent().absoluteString
                self = .xmltv(
                    url: xmltvURL,
                    streamURLTemplate: normalizeStreamURLTemplate("\(base){channel}/live.m3u8")
                )
            case .hdhomerun:
                self = .hdhomerun(try container.decode(URL.self, forKey: .url))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .xmltv(let url, let streamURLTemplate):
                try container.encode(SourceType.xmltv, forKey: .type)
                try container.encode(url, forKey: .url)
                try container.encode(streamURLTemplate, forKey: .streamURLTemplate)
            case .hdhomerun(let url):
                try container.encode(SourceType.hdhomerun, forKey: .type)
                try container.encode(url, forKey: .url)
            }
        }
    }

    let id: String
    let kind: Kind

    var displayName: String {
        switch kind {
        case .xmltv(let url, _):
            return url.host ?? id
        case .hdhomerun(let url):
            return url.host ?? id
        }
    }
}

struct MergedGuide: Equatable, Codable {
    var channels: [GuideChannel]
    var generatedAt: Date?
    var sourceStatus: [String: String] = [:]
}

struct GuideChannel: Identifiable, Hashable, Codable {
    let id: String
    let sourceID: String
    let rawChannelID: String
    let name: String
    let number: Int?
    let numberLabel: String?
    let detail: String?
    let keyword: String?
    let logoURL: URL?
    let streamURL: URL
    let xmltvURL: URL
    let programmes: [GuideProgramme]

    enum CodingKeys: String, CodingKey {
        case id
        case sourceID
        case rawChannelID
        case name
        case number
        case numberLabel
        case detail
        case keyword
        case logoURL
        case streamURL
        case xmltvURL
        case programmes
    }

    init(
        id: String,
        sourceID: String,
        rawChannelID: String,
        name: String,
        number: Int?,
        numberLabel: String? = nil,
        detail: String?,
        keyword: String?,
        logoURL: URL?,
        streamURL: URL,
        xmltvURL: URL,
        programmes: [GuideProgramme]
    ) {
        self.id = id
        self.sourceID = sourceID
        self.rawChannelID = rawChannelID
        self.name = name
        self.number = number
        self.numberLabel = numberLabel
        self.detail = detail
        self.keyword = keyword
        self.logoURL = logoURL
        self.streamURL = streamURL
        self.xmltvURL = xmltvURL
        self.programmes = programmes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sourceID = try container.decode(String.self, forKey: .sourceID)
        rawChannelID = try container.decode(String.self, forKey: .rawChannelID)
        name = try container.decode(String.self, forKey: .name)
        number = try container.decodeIfPresent(Int.self, forKey: .number)
        numberLabel = try container.decodeIfPresent(String.self, forKey: .numberLabel)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        keyword = try container.decodeIfPresent(String.self, forKey: .keyword)
        logoURL = try container.decodeIfPresent(URL.self, forKey: .logoURL)
        streamURL = try container.decode(URL.self, forKey: .streamURL)
        xmltvURL = try container.decode(URL.self, forKey: .xmltvURL)
        programmes = try container.decode([GuideProgramme].self, forKey: .programmes)
    }

    var hasDisplayNumber: Bool {
        if number != nil { return true }
        guard let numberLabel, !numberLabel.isEmpty else { return false }
        return numberLabel.count <= 7 &&
            numberLabel.contains(where: \.isNumber) &&
            numberLabel.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" })
    }

    var displayNumber: String {
        guard hasDisplayNumber else { return "" }
        if let numberLabel, !numberLabel.isEmpty {
            return numberLabel
        }
        guard let number else { return "" }
        return String(number)
    }

    var nowPlaying: GuideProgramme? {
        let now = Date()
        return programmes.first { $0.start <= now && now < $0.stop }
    }
}

struct GuideProgramme: Identifiable, Hashable, Codable {
    let id: String
    let channelID: String
    let start: Date
    let stop: Date
    let title: String
    let detail: String?
    let iconURL: URL?
    var seasonEpisode: String?
    var subTitle: String?

    var formattedSeasonEpisode: String? {
        RecordingFilenameGenerator.formatSeasonEpisodeForDisplay(
            seasonEpisode: seasonEpisode,
            title: title,
            detail: detail
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, channelID, start, stop, title, detail, iconURL, seasonEpisode, subTitle
    }

    init(
        id: String,
        channelID: String,
        start: Date,
        stop: Date,
        title: String,
        detail: String?,
        iconURL: URL?,
        seasonEpisode: String? = nil,
        subTitle: String? = nil
    ) {
        self.id = id
        self.channelID = channelID
        self.start = start
        self.stop = stop
        self.title = title
        self.detail = detail
        self.iconURL = iconURL
        self.seasonEpisode = seasonEpisode
        self.subTitle = subTitle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        channelID = try container.decode(String.self, forKey: .channelID)
        start = try container.decode(Date.self, forKey: .start)
        stop = try container.decode(Date.self, forKey: .stop)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        iconURL = try container.decodeIfPresent(URL.self, forKey: .iconURL)
        seasonEpisode = try container.decodeIfPresent(String.self, forKey: .seasonEpisode)
        subTitle = try container.decodeIfPresent(String.self, forKey: .subTitle)
    }
}

struct HDHomeRunLineupItem: Decodable {
    let guideNumber: String
    let guideName: String
    let videoCodec: String?
    let audioCodec: String?
    let isHD: Int?
    let isFavorite: Int?
    let isDRM: Int?
    let url: URL

    enum CodingKeys: String, CodingKey {
        case guideNumber = "GuideNumber"
        case guideName = "GuideName"
        case videoCodec = "VideoCodec"
        case audioCodec = "AudioCodec"
        case isHD = "HD"
        case isFavorite = "Favorite"
        case isDRM = "DRM"
        case url = "URL"
    }
}

struct XMLTVGuide {
    var channels: [String: XMLTVChannel]
    var programmes: [XMLTVProgramme]
}

struct XMLTVChannel {
    let id: String
    var displayName: String?
    var iconURL: URL?
}

struct XMLTVProgramme {
    let channelID: String
    let start: Date
    let stop: Date
    var title: String?
    var detail: String?
    var iconURL: URL?
    var seasonEpisode: String?
    var subTitle: String?

    var formattedSeasonEpisode: String? {
        RecordingFilenameGenerator.formatSeasonEpisodeForDisplay(
            seasonEpisode: seasonEpisode,
            title: title,
            detail: detail
        )
    }
}

struct AppSettings: Codable, Equatable {
    var sources: [GuideSource]
    var guidePlugins: [GuidePlugin]
    var excludedChannelIDsBySource: [String: [String]]
    var adultChannelIDsBySource: [String: [String]]
    var autoRefreshIntervalSeconds: Double
    var guideVisibleHours: Int
    var volume: Double
    var localAPIPort: Int
    var hasInitializedGuidePlugins: Bool
    var lastSelectedChannelID: String?
    var recordingsDirectoryPath: String
    var maxSimultaneousRecordings: Int
    var autoRecordNextShowOnSameChannel: Bool
    var recordingStartLeadMinutes: Int

    var recordingsDirectoryURL: URL {
        let expanded = (recordingsDirectoryPath as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    static var defaultRecordingsPath: String {
        if let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first {
            return movies.appendingPathComponent("lanTV").path
        }
        return "~/Movies/lanTV"
    }

    enum CodingKeys: String, CodingKey {
        case sources
        case guidePlugins
        case excludedChannelIDsBySource
        case adultChannelIDsBySource
        case autoRefreshIntervalSeconds
        case guideVisibleHours
        case volume
        case localAPIPort
        case hasInitializedGuidePlugins
        case lastSelectedChannelID
        case recordingsDirectoryPath
        case maxSimultaneousRecordings
        case autoRecordNextShowOnSameChannel
        case recordingStartLeadMinutes
    }

    init(
        sources: [GuideSource],
        guidePlugins: [GuidePlugin] = [],
        excludedChannelIDsBySource: [String: [String]] = [:],
        adultChannelIDsBySource: [String: [String]] = [:],
        autoRefreshIntervalSeconds: Double,
        guideVisibleHours: Int,
        volume: Double,
        localAPIPort: Int = Int(LocalAPIServer.defaultPort),
        hasInitializedGuidePlugins: Bool = false,
        lastSelectedChannelID: String? = nil,
        recordingsDirectoryPath: String = AppSettings.defaultRecordingsPath,
        maxSimultaneousRecordings: Int = 1,
        autoRecordNextShowOnSameChannel: Bool = true,
        recordingStartLeadMinutes: Int = 0
    ) {
        self.sources = sources
        self.guidePlugins = guidePlugins
        self.excludedChannelIDsBySource = excludedChannelIDsBySource
        self.adultChannelIDsBySource = adultChannelIDsBySource
        self.autoRefreshIntervalSeconds = autoRefreshIntervalSeconds
        self.guideVisibleHours = guideVisibleHours
        self.volume = volume
        self.localAPIPort = localAPIPort
        self.hasInitializedGuidePlugins = hasInitializedGuidePlugins
        self.lastSelectedChannelID = lastSelectedChannelID
        self.recordingsDirectoryPath = recordingsDirectoryPath
        self.maxSimultaneousRecordings = maxSimultaneousRecordings
        self.autoRecordNextShowOnSameChannel = autoRecordNextShowOnSameChannel
        self.recordingStartLeadMinutes = recordingStartLeadMinutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sources = try container.decode([GuideSource].self, forKey: .sources)
        guidePlugins = try container.decodeIfPresent([GuidePlugin].self, forKey: .guidePlugins) ?? []
        excludedChannelIDsBySource = try container.decodeIfPresent([String: [String]].self, forKey: .excludedChannelIDsBySource) ?? [:]
        adultChannelIDsBySource = try container.decodeIfPresent([String: [String]].self, forKey: .adultChannelIDsBySource) ?? [:]
        autoRefreshIntervalSeconds = try container.decodeIfPresent(Double.self, forKey: .autoRefreshIntervalSeconds) ?? 300
        guideVisibleHours = try container.decodeIfPresent(Int.self, forKey: .guideVisibleHours) ?? 6
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 0.8
        localAPIPort = try container.decodeIfPresent(Int.self, forKey: .localAPIPort) ?? Int(LocalAPIServer.defaultPort)
        hasInitializedGuidePlugins = try container.decodeIfPresent(Bool.self, forKey: .hasInitializedGuidePlugins) ?? false
        lastSelectedChannelID = try container.decodeIfPresent(String.self, forKey: .lastSelectedChannelID)
        recordingsDirectoryPath = try container.decodeIfPresent(String.self, forKey: .recordingsDirectoryPath) ?? AppSettings.defaultRecordingsPath
        maxSimultaneousRecordings = try container.decodeIfPresent(Int.self, forKey: .maxSimultaneousRecordings) ?? 1
        autoRecordNextShowOnSameChannel = try container.decodeIfPresent(Bool.self, forKey: .autoRecordNextShowOnSameChannel) ?? true
        recordingStartLeadMinutes = try container.decodeIfPresent(Int.self, forKey: .recordingStartLeadMinutes) ?? 0
    }

    static let `default` = AppSettings(
        sources: [],
        guidePlugins: [],
        autoRefreshIntervalSeconds: 300,
        guideVisibleHours: 6,
        volume: 0.8,
        localAPIPort: Int(LocalAPIServer.defaultPort),
        hasInitializedGuidePlugins: true,
        lastSelectedChannelID: nil,
        recordingsDirectoryPath: AppSettings.defaultRecordingsPath,
        maxSimultaneousRecordings: 1,
        autoRecordNextShowOnSameChannel: true
    )
}
