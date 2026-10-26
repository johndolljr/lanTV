import Foundation

enum RecordingStatus: Codable, Equatable, Hashable {
    case scheduled
    case recording
    case completed
    case failed(reason: String)
    case cancelled

    enum CodingKeys: String, CodingKey {
        case type
        case reason
    }

    private enum StatusType: String, Codable {
        case scheduled
        case recording
        case completed
        case failed
        case cancelled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(StatusType.self, forKey: .type)
        switch type {
        case .scheduled:
            self = .scheduled
        case .recording:
            self = .recording
        case .completed:
            self = .completed
        case .failed:
            let reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? "Unknown error"
            self = .failed(reason: reason)
        case .cancelled:
            self = .cancelled
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .scheduled:
            try container.encode(StatusType.scheduled, forKey: .type)
        case .recording:
            try container.encode(StatusType.recording, forKey: .type)
        case .completed:
            try container.encode(StatusType.completed, forKey: .type)
        case .failed(let reason):
            try container.encode(StatusType.failed, forKey: .type)
            try container.encode(reason, forKey: .reason)
        case .cancelled:
            try container.encode(StatusType.cancelled, forKey: .type)
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .scheduled, .recording:
            return false
        }
    }

    var label: String {
        switch self {
        case .scheduled: return "Scheduled"
        case .recording: return "Recording"
        case .completed: return "Completed"
        case .failed(let reason): return "Failed: \(reason)"
        case .cancelled: return "Cancelled"
        }
    }
}

struct RecordingItem: Identifiable, Codable, Equatable {
    let id: UUID
    let channelID: String
    var channelName: String
    var streamURL: URL
    let programmeID: String
    var programmeTitle: String
    var programmeSubTitle: String?
    var programmeDetail: String?
    var seasonEpisode: String?
    let scheduledStart: Date
    let scheduledStop: Date
    var actualStart: Date?
    var actualStop: Date?
    var outputFilePath: String
    var status: RecordingStatus
    var isLiveRollOver: Bool
    var bytesRecorded: Int64
    var errorMessage: String?
    var partFilePaths: [String]? = []
    /// Minutes before the scheduled start to begin recording; nil uses the global setting.
    var startLeadMinutes: Int? = nil

    init(
        id: UUID = UUID(),
        channelID: String,
        channelName: String,
        streamURL: URL,
        programmeID: String,
        programmeTitle: String,
        programmeSubTitle: String? = nil,
        programmeDetail: String? = nil,
        seasonEpisode: String? = nil,
        scheduledStart: Date,
        scheduledStop: Date,
        actualStart: Date? = nil,
        actualStop: Date? = nil,
        outputFilePath: String = "",
        status: RecordingStatus = .scheduled,
        isLiveRollOver: Bool = false,
        bytesRecorded: Int64 = 0,
        errorMessage: String? = nil,
        partFilePaths: [String]? = [],
        startLeadMinutes: Int? = nil
    ) {
        self.id = id
        self.channelID = channelID
        self.channelName = channelName
        self.streamURL = streamURL
        self.programmeID = programmeID
        self.programmeTitle = programmeTitle
        self.programmeSubTitle = programmeSubTitle
        self.programmeDetail = programmeDetail
        self.seasonEpisode = seasonEpisode
        self.scheduledStart = scheduledStart
        self.scheduledStop = scheduledStop
        self.actualStart = actualStart
        self.actualStop = actualStop
        self.outputFilePath = outputFilePath
        self.status = status
        self.isLiveRollOver = isLiveRollOver
        self.bytesRecorded = bytesRecorded
        self.errorMessage = errorMessage
        self.partFilePaths = partFilePaths ?? []
        self.startLeadMinutes = startLeadMinutes
    }

    enum CodingKeys: String, CodingKey {
        case id
        case channelID
        case channelName
        case streamURL
        case programmeID
        case programmeTitle
        case programmeSubTitle
        case programmeDetail
        case seasonEpisode
        case scheduledStart
        case scheduledStop
        case actualStart
        case actualStop
        case outputFilePath
        case status
        case isLiveRollOver
        case bytesRecorded
        case errorMessage
        case partFilePaths
        case startLeadMinutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        channelID = try container.decode(String.self, forKey: .channelID)
        channelName = try container.decode(String.self, forKey: .channelName)
        streamURL = try container.decode(URL.self, forKey: .streamURL)
        programmeID = try container.decode(String.self, forKey: .programmeID)
        programmeTitle = try container.decode(String.self, forKey: .programmeTitle)
        programmeSubTitle = try container.decodeIfPresent(String.self, forKey: .programmeSubTitle)
        programmeDetail = try container.decodeIfPresent(String.self, forKey: .programmeDetail)
        seasonEpisode = try container.decodeIfPresent(String.self, forKey: .seasonEpisode)
        scheduledStart = try container.decode(Date.self, forKey: .scheduledStart)
        scheduledStop = try container.decode(Date.self, forKey: .scheduledStop)
        actualStart = try container.decodeIfPresent(Date.self, forKey: .actualStart)
        actualStop = try container.decodeIfPresent(Date.self, forKey: .actualStop)
        outputFilePath = try container.decode(String.self, forKey: .outputFilePath)
        status = try container.decode(RecordingStatus.self, forKey: .status)
        isLiveRollOver = try container.decodeIfPresent(Bool.self, forKey: .isLiveRollOver) ?? false
        bytesRecorded = try container.decodeIfPresent(Int64.self, forKey: .bytesRecorded) ?? 0
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        partFilePaths = try container.decodeIfPresent([String].self, forKey: .partFilePaths) ?? []
        startLeadMinutes = try container.decodeIfPresent(Int.self, forKey: .startLeadMinutes)
    }

    var isActive: Bool {
        status == .recording
    }

    var isScheduled: Bool {
        status == .scheduled
    }

    var outputFileExists: Bool {
        guard !outputFilePath.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: outputFilePath)
    }

    var formattedDuration: String {
        guard let start = actualStart else { return "" }
        let end = actualStop ?? Date()
        let elapsed = max(0, Int(end.timeIntervalSince(start)))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var formattedFileSize: String {
        let size: Int64
        if bytesRecorded > 0 {
            size = bytesRecorded
        } else if outputFileExists,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: outputFilePath),
                  let fileSize = attrs[.size] as? Int64, fileSize > 0 {
            size = fileSize
        } else {
            return ""
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    var formattedSeasonEpisode: String? {
        RecordingFilenameGenerator.formatSeasonEpisodeForDisplay(
            seasonEpisode: seasonEpisode,
            title: programmeTitle,
            detail: programmeDetail
        )
    }
}

enum RecordingFilenameGenerator {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        return formatter
    }()

    static func sanitizeFilename(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
        var sanitized = name.components(separatedBy: invalidCharacters).joined(separator: " ")
        sanitized = sanitized.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "Recording" : sanitized
    }

    static func extractSeasonEpisode(from text: String) -> (season: Int, episode: Int)? {
        // Pattern 1: S02E15 or S2E5
        let patternSE = #"\bS(\d{1,3})[\s._-]?E(\d{1,3})\b"#
        if let regex = try? NSRegularExpression(pattern: patternSE, options: .caseInsensitive),
           let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)) {
            if let seasonRange = Range(match.range(at: 1), in: text),
               let episodeRange = Range(match.range(at: 2), in: text),
               let s = Int(text[seasonRange]),
               let e = Int(text[episodeRange]) {
                return (s, e)
            }
        }

        // Pattern 2: Season 2 Episode 15
        let patternFull = #"\bSeason\s+(\d{1,3})[\s,]+Episode\s+(\d{1,3})\b"#
        if let regex = try? NSRegularExpression(pattern: patternFull, options: .caseInsensitive),
           let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)) {
            if let seasonRange = Range(match.range(at: 1), in: text),
               let episodeRange = Range(match.range(at: 2), in: text),
               let s = Int(text[seasonRange]),
               let e = Int(text[episodeRange]) {
                return (s, e)
            }
        }

        // Pattern 3: 2x15
        let patternX = #"\b(\d{1,3})x(\d{1,3})\b"#
        if let regex = try? NSRegularExpression(pattern: patternX, options: .caseInsensitive),
           let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)) {
            if let seasonRange = Range(match.range(at: 1), in: text),
               let episodeRange = Range(match.range(at: 2), in: text),
               let s = Int(text[seasonRange]),
               let e = Int(text[episodeRange]) {
                return (s, e)
            }
        }

        // Pattern 4: xmltv_ns "season . episode . part" (0-indexed)
        let patternXMLTV = #"^\s*(\d+)\s*\.\s*(\d+)\s*(\.|\/|$)"#
        if let regex = try? NSRegularExpression(pattern: patternXMLTV),
           let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)) {
            if let seasonRange = Range(match.range(at: 1), in: text),
               let episodeRange = Range(match.range(at: 2), in: text),
               let s = Int(text[seasonRange]),
               let e = Int(text[episodeRange]) {
                return (s + 1, e + 1)
            }
        }

        return nil
    }

    static func formatSeasonEpisodeForDisplay(
        seasonEpisode: String?,
        title: String? = nil,
        detail: String? = nil
    ) -> String? {
        // 1. Try to extract S/E from seasonEpisode
        if let se = seasonEpisode, let extracted = extractSeasonEpisode(from: se) {
            return String(format: "S%02dE%02d", extracted.season, extracted.episode)
        }

        // 2. Try to extract S/E from title
        if let title, let extracted = extractSeasonEpisode(from: title) {
            return String(format: "S%02dE%02d", extracted.season, extracted.episode)
        }

        // 3. Try to extract S/E from detail
        if let detail, let extracted = extractSeasonEpisode(from: detail) {
            return String(format: "S%02dE%02d", extracted.season, extracted.episode)
        }

        // 4. If no S/E found anywhere, check if seasonEpisode is an air date e.g. "19670309000000 +0000" or "19670309"
        guard let raw = seasonEpisode?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        let datePattern = #"^(\d{4})(\d{2})(\d{2})"#
        if let regex = try? NSRegularExpression(pattern: datePattern),
           let match = regex.firstMatch(in: raw, options: [], range: NSRange(location: 0, length: raw.utf16.count)),
           let yRange = Range(match.range(at: 1), in: raw),
           let mRange = Range(match.range(at: 2), in: raw),
           let dRange = Range(match.range(at: 3), in: raw),
           let y = Int(raw[yRange]), let m = Int(raw[mRange]), let d = Int(raw[dRange]) {
            var components = DateComponents()
            components.year = y
            components.month = m
            components.day = d
            if let date = Calendar.current.date(from: components) {
                let df = DateFormatter()
                df.dateStyle = .medium
                df.timeStyle = .none
                return "Aired \(df.string(from: date))"
            }
        }

        return raw
    }

    static func generateFilename(
        title: String,
        subTitle: String? = nil,
        detail: String? = nil,
        seasonEpisode: String? = nil,
        date: Date
    ) -> String {
        let cleanTitle = sanitizeFilename(title)
        let cleanSubTitle = subTitle.flatMap { sanitizeFilename($0) }?.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 1. Check if seasonEpisode string itself contains season/episode
        var seInfo: (season: Int, episode: Int)? = nil
        if let seasonEpisode, !seasonEpisode.isEmpty {
            seInfo = extractSeasonEpisode(from: seasonEpisode)
        }
        
        // 2. Check title
        if seInfo == nil {
            seInfo = extractSeasonEpisode(from: title)
        }
        
        // 3. Check detail
        if seInfo == nil, let detail, !detail.isEmpty {
            seInfo = extractSeasonEpisode(from: detail)
        }

        if let se = seInfo {
            let seString = String(format: "S%02dE%02d", se.season, se.episode)
            if let cleanSubTitle, !cleanSubTitle.isEmpty {
                return "\(cleanTitle) - \(seString) - \(cleanSubTitle).mp4"
            } else {
                return "\(cleanTitle) - \(seString).mp4"
            }
        } else {
            let dateStr = dateFormatter.string(from: date)
            if let cleanSubTitle, !cleanSubTitle.isEmpty {
                return "\(cleanTitle) - \(cleanSubTitle) - \(dateStr).mp4"
            } else {
                return "\(cleanTitle) - \(dateStr).mp4"
            }
        }
    }

    static func destinationFileURL(
        directory: URL,
        title: String,
        subTitle: String? = nil,
        detail: String? = nil,
        seasonEpisode: String? = nil,
        date: Date
    ) -> URL {
        let filename = generateFilename(
            title: title,
            subTitle: subTitle,
            detail: detail,
            seasonEpisode: seasonEpisode,
            date: date
        )
        let baseName = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        
        var targetURL = directory.appendingPathComponent(filename)
        var counter = 1
        while FileManager.default.fileExists(atPath: targetURL.path) {
            let candidate = "\(baseName) (\(counter)).\(ext)"
            targetURL = directory.appendingPathComponent(candidate)
            counter += 1
        }
        return targetURL
    }
}
