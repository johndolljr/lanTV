import Foundation

struct MobileSource: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable { case desktop, xmltv }
    var id = UUID()
    var name: String
    var kind: Kind
    var url: String
    var streamTemplate: String

    static func validatedURL(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty, url.user == nil, url.password == nil else {
            throw MobileError.message("Enter a complete http:// or https:// address.")
        }
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard normalized != "localhost", !normalized.hasSuffix(".localhost"), !normalized.hasPrefix("127."), normalized != "::1", normalized != "0.0.0.0", normalized != "::" else {
            throw MobileError.message("Use the source’s LAN address, such as tvserver.lan. Localhost refers to this iPhone or iPad.")
        }
        return url
    }
    func validated() throws -> MobileSource {
        _ = try Self.validatedURL(url)
        if kind == .xmltv && !streamTemplate.isEmpty {
            _ = try Self.validatedURL(streamTemplate.replacingOccurrences(of: "{channel}", with: "1"))
        }
        return self
    }
}

enum MobileError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { text } else { nil } }
}

struct MobileProgramme: Identifiable, Hashable, Codable, Sendable {
    var id: String { "\(channelID)|\(start.timeIntervalSince1970)" }
    let channelID: String
    let start: Date
    let stop: Date
    let title: String
    let detail: String
}
struct MobileChannel: Identifiable, Hashable, Codable, Sendable {
    var id: String { "\(sourceID.uuidString)|\(rawID)" }
    let sourceID: UUID
    let rawID: String
    let number: String
    let name: String
    let streamURL: URL?
    let logoURL: URL?
    let isProtected: Bool
    var programmes: [MobileProgramme]
    var nowPlaying: MobileProgramme? { programmes.first { $0.start <= Date() && $0.stop > Date() } }
    var upcoming: [MobileProgramme] { programmes.filter { $0.stop > Date() } }
}
struct MobileGuide: Sendable {
    let revision: String?
    var channels: [MobileChannel]
}
struct DesktopState: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let revision: String
    let areProtectedChannelsUnlocked: Bool
    let protectedChannelCount: Int
    let guideURL: String
}
struct MobileUnlockApproval: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let deviceID: UUID
    let deviceName: String
    let createdAt: Date
}
enum MobileLockPolicy {
    static let maximumStateAge: TimeInterval = 5
    static func validateStandaloneGuide(_ guide: MobileGuide) throws {
        guard guide.revision == nil else {
            throw MobileError.message("This is a lanTV desktop guide. Choose Desktop Server and enter the Mac’s Local API address to keep channel locks in sync.")
        }
    }
    static func allowedChannels(_ channels: [MobileChannel], state: DesktopState) -> [MobileChannel] {
        channels.filter { !$0.isProtected || (state.protocolVersion == 1 && state.areProtectedChannelsUnlocked) }
    }
    static func mustInvalidateSnapshot(previousRevision: String?, newState: DesktopState?) -> Bool {
        guard let newState, newState.protocolVersion == 1 else { return true }
        return previousRevision != newState.revision
    }
    static func canPlay(_ channel: MobileChannel, state: DesktopState?, validatedAt: Date?, now: Date = Date()) -> Bool {
        guard channel.isProtected else { return true }
        guard let state, state.protocolVersion == 1, state.areProtectedChannelsUnlocked, let validatedAt else { return false }
        return now.timeIntervalSince(validatedAt) >= 0 && now.timeIntervalSince(validatedAt) <= maximumStateAge
    }
    static func validate(before: DesktopState, guideRevision: String?, after: DesktopState) throws {
        guard before.protocolVersion == 1, after.protocolVersion == 1,
              before.revision == guideRevision, before.revision == after.revision,
              before.areProtectedChannelsUnlocked == after.areProtectedChannelsUnlocked else {
            throw MobileError.message("Desktop guide changed while loading. Reconnecting…")
        }
    }
}

final class MobileXMLTVParser: NSObject, XMLParserDelegate {
    private var sourceID = UUID()
    private var template = ""
    private var baseURL: URL?
    private var revision: String?
    private var channels: [MobileChannel] = []
    private var programmes: [MobileProgramme] = []
    private var channelID: String?
    private var channelName = ""
    private var channelNumber = ""
    private var channelStream: URL?
    private var channelLogo: URL?
    private var protectedChannel = false
    private var programmeID: String?
    private var start: Date?
    private var stop: Date?
    private var title = ""
    private var detail = ""
    private var text = ""
    private var rootSeen = false
    private var inProgramme = false
    private let dateFormatter: DateFormatter = {
        let value = DateFormatter(); value.locale = Locale(identifier: "en_US_POSIX"); value.timeZone = TimeZone(secondsFromGMT: 0); return value
    }()

    static func parse(_ data: Data, sourceID: UUID, template: String, baseURL: URL? = nil) throws -> MobileGuide {
        let delegate = MobileXMLTVParser()
        delegate.sourceID = sourceID; delegate.template = template; delegate.baseURL = baseURL
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.rootSeen else { throw MobileError.message("The address did not return a valid XMLTV guide.") }
        let grouped = Dictionary(grouping: delegate.programmes, by: \.channelID)
        let channels = delegate.channels.map { channel in
            var result = channel
            result.programmes = (grouped[channel.rawID] ?? []).sorted { $0.start < $1.start }
            return result
        }.sorted { a, b in
            if a.number != b.number { return a.number.localizedStandardCompare(b.number) == .orderedAscending }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return MobileGuide(revision: delegate.revision, channels: channels)
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        text = ""
        switch elementName {
        case "tv": rootSeen = true; revision = attributes["lanTV-revision"]
        case "channel":
            channelID = attributes["id"]; channelName = ""; channelNumber = ""; channelStream = nil; channelLogo = nil
            protectedChannel = attributes["protected"] == "true"
        case "programme":
            inProgramme = true; programmeID = attributes["channel"]; start = date(attributes["start"]); stop = date(attributes["stop"]); title = ""; detail = ""
        case "icon":
            if !inProgramme { channelLogo = attributes["src"].flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL } }
        default: break
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "display-name": if channelName.isEmpty { channelName = value }
        case "lcn", "display-number": channelNumber = value
        case "stream-url": channelStream = URL(string: value, relativeTo: baseURL)?.absoluteURL
        case "title": title = value
        case "desc": detail = value
        case "channel":
            if let rawID = channelID, !rawID.isEmpty {
                if channelNumber.isEmpty {
                    let first = channelName.split(separator: " ").first.map(String.init) ?? ""
                    if !first.isEmpty && first.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }) { channelNumber = first }
                }
                if channelStream == nil, !template.isEmpty {
                    var allowed = CharacterSet.urlQueryAllowed
                    allowed.remove(charactersIn: "&+=?#/%")
                    let encoded = rawID.addingPercentEncoding(withAllowedCharacters: allowed) ?? rawID
                    channelStream = URL(string: template.replacingOccurrences(of: "{channel}", with: encoded))
                }
                if channelNumber.isEmpty && rawID.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }) { channelNumber = rawID }
                channels.append(MobileChannel(sourceID: sourceID, rawID: rawID, number: channelNumber, name: channelName.isEmpty ? rawID : channelName, streamURL: channelStream, logoURL: channelLogo, isProtected: protectedChannel, programmes: []))
            }
            channelID = nil
        case "programme":
            if let programmeID, let start, let stop, stop > start {
                programmes.append(MobileProgramme(channelID: programmeID, start: start, stop: stop, title: title.isEmpty ? "Programme" : title, detail: detail))
            }
            inProgramme = false; programmeID = nil
        default: break
        }
        text = ""
    }
    private func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = dateFormatter
        for format in ["yyyyMMddHHmmss Z", "yyyyMMddHHmm Z", "yyyyMMddHHmmss", "yyyyMMddHHmm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
