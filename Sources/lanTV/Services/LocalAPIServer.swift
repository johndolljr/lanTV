import Foundation
import Network
import Darwin
import CryptoKit

struct LocalAPIExportContext {
    let baseURLs: [URL]
    let visibleChannels: [GuideChannel]
    let generatedAt: Date?
    let sourceStatus: [String: String]
    let settings: AppSettings
    let areProtectedChannelsUnlocked: Bool
    let selectedChannelID: String?
    let isPlayerDetached: Bool
}

final class LocalAPIServer: @unchecked Sendable {
    static let defaultPort: UInt16 = 48921

    struct HTTPPayload {
        let contentType: String
        let data: Data
        var statusCode: Int = 200
    }

    private let queue = DispatchQueue(label: "lanTV.local-api")
    private var listener: NWListener?
    private let router = LocalAPIRequestRouter()
    var onUnlockRequest: (@MainActor @Sendable (MobileUnlockRequest) -> Void)? {
        didSet {
            let callback = onUnlockRequest
            queue.async { [weak self] in
                self?.router.onUnlockRequest = { request in
                    Task { @MainActor in callback?(request) }
                }
            }
        }
    }
    var onApproverRequest: (@MainActor @Sendable (MobileApproverRequest) -> Void)? {
        didSet {
            let callback = onApproverRequest
            queue.async { [weak self] in
                self?.router.onApproverRequest = { request in Task { @MainActor in callback?(request) } }
            }
        }
    }
    var onApproverUnlockDecision: (@MainActor @Sendable (MobileUnlockDecision) -> Void)? {
        didSet {
            let callback = onApproverUnlockDecision
            queue.async { [weak self] in
                self?.router.onApproverUnlockDecision = { decision in Task { @MainActor in callback?(decision) } }
            }
        }
    }
    var onApproverLock: (@MainActor @Sendable (String) -> Void)? {
        didSet {
            let callback = onApproverLock
            queue.async { [weak self] in
                self?.router.onApproverLock = { deviceName in Task { @MainActor in callback?(deviceName) } }
            }
        }
    }
    private(set) var port: UInt16

    init(port: UInt16 = defaultPort) {
        self.port = port
    }

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    var reachableBaseURLs: [URL] {
        let addresses = Self.localIPv4Addresses()
        let loopback = "127.0.0.1"
        let orderedHosts = Array(NSOrderedSet(array: addresses + [loopback])) as? [String] ?? [loopback]
        return orderedHosts.compactMap { URL(string: "http://\($0):\(port)") }
    }

    func start() {
        guard listener == nil else { return }

        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            listener.service = NWListener.Service(name: "lanTV", type: "_lantv._tcp", domain: "local.")
            listener.stateUpdateHandler = { state in
                if case let .failed(error) = state {
                    NSLog("Local API listener failed: %@", error.localizedDescription)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            NSLog("Failed to start local API listener: %@", error.localizedDescription)
        }
    }

    func updatePort(_ newPort: Int) {
        let normalized = UInt16(clamping: newPort)
        guard normalized != port else { return }
        queue.sync {
            listener?.cancel()
            listener = nil
            port = normalized
        }
        start()
    }

    func update(with context: LocalAPIExportContext) {
        queue.async { [weak self] in
            let rendered = LocalAPIExportRenderer.render(context: context)
            self?.router.update(payloads: rendered, approvers: context.settings.mobileApprovers)
        }
    }

    func denyApproverRequest(_ deviceID: UUID) {
        queue.async { [weak self] in self?.router.denyApproverRequest(deviceID) }
    }

    func completeUnlockRequest(_ requestID: UUID) {
        queue.async { [weak self] in self?.router.completeUnlockRequest(requestID) }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        // Header-only requests are capped and timed out, including fragmented TCP input.
        queue.asyncAfter(deadline: .now() + 5) { connection.cancel() }
        receiveHeaders(connection, accumulated: Data())
    }

    private func receiveHeaders(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = accumulated
            buffer.append(data ?? Data())
            if buffer.count > 16_384 {
                self.send(.init(contentType: "text/plain", data: Data("Request too large".utf8), statusCode: 413), on: connection)
            } else if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                let text = String(data: buffer, encoding: .utf8) ?? ""
                self.send(self.router.route(requestText: text), on: connection)
            } else if complete || error != nil {
                connection.cancel()
            } else {
                self.receiveHeaders(connection, accumulated: buffer)
            }
        }
    }

    private func send(_ payload: HTTPPayload, on connection: NWConnection) {
        let response = Self.httpResponse(for: payload)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    static func httpResponse(for payload: HTTPPayload) -> Data {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 413: "Payload Too Large", 429: "Too Many Requests", 503: "Service Unavailable"][payload.statusCode] ?? "Error"
        var header = "HTTP/1.1 \(payload.statusCode) \(reason)\r\n"
        header += "Content-Type: \(payload.contentType)\r\n"
        header += "Content-Length: \(payload.data.count)\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(payload.data)
        return response
    }

    private static func localIPv4Addresses() -> [String] {
        var results: [String] = []
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddrPointer) == 0, let first = ifaddrPointer else {
            return results
        }

        defer { freeifaddrs(ifaddrPointer) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            let flags = Int32(interface.ifa_flags)
            guard let address = interface.ifa_addr else { continue }

            guard
                address.pointee.sa_family == UInt8(AF_INET),
                (flags & IFF_UP) != 0,
                (flags & IFF_RUNNING) != 0,
                (flags & IFF_LOOPBACK) == 0
            else {
                continue
            }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            guard result == 0 else { continue }
            let host = String(cString: hostBuffer)
            if !host.isEmpty {
                results.append(host)
            }
        }

        return results.sorted()
    }
}

enum LocalAPIExportRenderer {
    static func render(context: LocalAPIExportContext) -> [String: LocalAPIServer.HTTPPayload] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let visibleChannels = context.visibleChannels.filter { channel in
            !(context.settings.excludedChannelIDsBySource[channel.sourceID] ?? []).contains(channel.rawChannelID) &&
            (context.areProtectedChannelsUnlocked || !(context.settings.adultChannelIDsBySource[channel.sourceID] ?? []).contains(channel.rawChannelID))
        }
        let settingsExport = SettingsExport(
            sources: context.settings.sources.map { SourceExport($0, includeURLs: context.areProtectedChannelsUnlocked) },
            hiddenChannelIDsBySource: context.settings.excludedChannelIDsBySource,
            lockedChannelIDsBySource: context.areProtectedChannelsUnlocked ? context.settings.adultChannelIDsBySource : [:],
            lockedChannelCountsBySource: context.settings.adultChannelIDsBySource.mapValues(\.count),
            areProtectedChannelsUnlocked: context.areProtectedChannelsUnlocked,
            autoRefreshIntervalSeconds: context.settings.autoRefreshIntervalSeconds,
            guideVisibleHours: context.settings.guideVisibleHours,
            volume: context.settings.volume,
            localAPIPort: context.settings.localAPIPort
        )

        let exportedChannels = visibleChannels.map { ChannelExport($0, includeGuideURL: context.areProtectedChannelsUnlocked) }
        let stateExport = StateExport(
            exportedAt: Date(),
            generatedAt: context.generatedAt,
            selectedChannelID: visibleChannels.contains(where: { $0.id == context.selectedChannelID }) ? context.selectedChannelID : nil,
            isPlayerDetached: context.isPlayerDetached,
            sourceStatus: context.areProtectedChannelsUnlocked
                ? context.sourceStatus
                : context.sourceStatus.mapValues { _ in "Status hidden while protected channels are locked." },
            settings: settingsExport,
            channels: exportedChannels,
            endpoints: EndpointsExport(baseURLs: context.baseURLs.map(\.absoluteString))
        )

        let summaryData = (try? encoder.encode(SummaryExport(
            name: "lanTV Local API",
            endpoints: EndpointsExport(baseURLs: context.baseURLs.map(\.absoluteString))
        ))) ?? Data("{}".utf8)
        let settingsData = (try? encoder.encode(settingsExport)) ?? Data("{}".utf8)
        let channelsData = (try? encoder.encode(exportedChannels)) ?? Data("[]".utf8)
        let stateData = (try? encoder.encode(stateExport)) ?? Data("{}".utf8)
        let rawXML = renderXMLTV(for: visibleChannels, generatedAt: context.generatedAt, settings: context.settings)
        // Content-derived revision changes on relock, URLs, programmes, or source rules.
        let encoderSettings = (try? encoder.encode([context.settings.adultChannelIDsBySource, context.settings.excludedChannelIDsBySource])) ?? Data()
        var revisionInput = Data(rawXML.utf8)
        revisionInput.append(encoderSettings)
        revisionInput.append(context.areProtectedChannelsUnlocked ? 1 : 0)
        let revision = SHA256.hash(data: revisionInput).map { String(format: "%02x", $0) }.joined()
        let xmltvData = Data(rawXML.replacingOccurrences(of: "<tv ", with: "<tv lanTV-revision=\"\(revision)\" ").utf8)
        let playlistData = Data(renderM3U(for: visibleChannels).utf8)
        let mobileState = MobileStateExport(protocolVersion: 1, revision: revision, areProtectedChannelsUnlocked: context.areProtectedChannelsUnlocked, protectedChannelCount: context.settings.adultChannelIDsBySource.values.reduce(0) { $0 + $1.count }, guideURL: "/api/guide.xmltv")
        let mobileStateData = (try? encoder.encode(mobileState)) ?? Data("{}".utf8)

        return [
            "/": .init(contentType: "application/json; charset=utf-8", data: summaryData),
            "/api/mobile/state.json": .init(contentType: "application/json; charset=utf-8", data: mobileStateData),
            "/api/settings.json": .init(contentType: "application/json; charset=utf-8", data: settingsData),
            "/api/channels.json": .init(contentType: "application/json; charset=utf-8", data: channelsData),
            "/api/state.json": .init(contentType: "application/json; charset=utf-8", data: stateData),
            "/api/guide.xmltv": .init(contentType: "application/xml; charset=utf-8", data: xmltvData),
            "/api/playlist.m3u": .init(contentType: "application/x-mpegURL; charset=utf-8", data: playlistData),
            "/404": .init(contentType: "text/plain; charset=utf-8", data: Data("Not Found\n".utf8), statusCode: 404)
        ]
    }

    private static func renderXMLTV(for channels: [GuideChannel], generatedAt: Date?, settings: AppSettings) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime, .withTimeZone]

        var xml: [String] = []
        xml.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        xml.append("<tv generator-info-name=\"lanTV\" generated-ts=\"\(generatedAt.map(formatter.string(from:)) ?? formatter.string(from: Date(timeIntervalSince1970: 0)))\">")

        for channel in channels {
            let isProtected = (settings.adultChannelIDsBySource[channel.sourceID] ?? []).contains(channel.rawChannelID)
            xml.append("  <channel id=\"\(escape(channel.id))\" protected=\"\(isProtected)\">")
            xml.append("    <stream-url>\(escape(channel.streamURL.absoluteString))</stream-url>")
            let displayName = channel.hasDisplayNumber
                ? "\(escape(channel.displayNumber)) \(escape(channel.name))"
                : escape(channel.name)
            xml.append("    <display-name>\(displayName)</display-name>")
            if let logoURL = channel.logoURL {
                xml.append("    <icon src=\"\(escape(logoURL.absoluteString))\" />")
            }
            xml.append("  </channel>")
        }

        for channel in channels {
            for programme in channel.programmes.sorted(by: { $0.start < $1.start }) {
                xml.append(
                    "  <programme start=\"\(xmltvDate(programme.start))\" stop=\"\(xmltvDate(programme.stop))\" channel=\"\(escape(channel.id))\">"
                )
                xml.append("    <title>\(escape(programme.title))</title>")
                if let detail = programme.detail, !detail.isEmpty {
                    xml.append("    <desc>\(escape(detail))</desc>")
                }
                if let iconURL = programme.iconURL {
                    xml.append("    <icon src=\"\(escape(iconURL.absoluteString))\" />")
                }
                if let se = programme.formattedSeasonEpisode, !se.isEmpty {
                    xml.append("    <episode-num system=\"onscreen\">\(escape(se))</episode-num>")
                }
                xml.append("  </programme>")
            }
        }

        xml.append("</tv>")
        return xml.joined(separator: "\n")
    }

    private static func renderM3U(for channels: [GuideChannel]) -> String {
        var lines = ["#EXTM3U"]
        for channel in channels {
            let logo = channel.logoURL?.absoluteString ?? ""
            let title = channel.hasDisplayNumber ? "\(channel.displayNumber) \(channel.name)" : channel.name
            lines.append(#"#EXTINF:-1 tvg-id="\#(channel.id)" tvg-name="\#(channel.name)" tvg-logo="\#(logo)" group-title="\#(channel.sourceID)",\#(title)"#)
            lines.append(channel.streamURL.absoluteString)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static let xmltvFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        return formatter
    }()

    private static func xmltvDate(_ date: Date) -> String {
        return xmltvFormatter.string(from: date)
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private struct MobileStateExport: Encodable {
        let protocolVersion: Int
        let revision: String
        let areProtectedChannelsUnlocked: Bool
        let protectedChannelCount: Int
        let guideURL: String
    }

    private struct SummaryExport: Encodable {
        let name: String
        let endpoints: EndpointsExport
    }

    private struct EndpointsExport: Encodable {
        let baseURLs: [String]
        let guideXMLTV: [String]
        let channelsJSON: [String]
        let settingsJSON: [String]
        let stateJSON: [String]
        let playlistM3U: [String]

        init(baseURLs: [String]) {
            self.baseURLs = baseURLs
            guideXMLTV = baseURLs.map { "\($0)/api/guide.xmltv" }
            channelsJSON = baseURLs.map { "\($0)/api/channels.json" }
            settingsJSON = baseURLs.map { "\($0)/api/settings.json" }
            stateJSON = baseURLs.map { "\($0)/api/state.json" }
            playlistM3U = baseURLs.map { "\($0)/api/playlist.m3u" }
        }
    }

    private struct StateExport: Encodable {
        let exportedAt: Date
        let generatedAt: Date?
        let selectedChannelID: String?
        let isPlayerDetached: Bool
        let sourceStatus: [String: String]
        let settings: SettingsExport
        let channels: [ChannelExport]
        let endpoints: EndpointsExport
    }

    private struct SettingsExport: Encodable {
        let sources: [SourceExport]
        let hiddenChannelIDsBySource: [String: [String]]
        let lockedChannelIDsBySource: [String: [String]]
        let lockedChannelCountsBySource: [String: Int]
        let areProtectedChannelsUnlocked: Bool
        let autoRefreshIntervalSeconds: Double
        let guideVisibleHours: Int
        let volume: Double
        let localAPIPort: Int
    }

    private struct SourceExport: Encodable {
        let id: String
        let kind: String
        let xmltvURL: String?
        let streamURLTemplate: String?
        let baseURL: String?

        init(_ source: GuideSource, includeURLs: Bool) {
            id = source.id
            switch source.kind {
            case .xmltv(let url, let template):
                kind = "xmltv"
                xmltvURL = includeURLs ? url.absoluteString : nil
                streamURLTemplate = includeURLs ? template : nil
                baseURL = nil
            case .hdhomerun(let url):
                kind = "hdhomerun"
                xmltvURL = nil
                streamURLTemplate = nil
                baseURL = includeURLs ? url.absoluteString : nil
            }
        }
    }

    private struct ChannelExport: Encodable {
        let id: String
        let sourceID: String
        let rawChannelID: String
        let displayNumber: String
        let name: String
        let detail: String?
        let logoURL: String?
        let streamURL: String
        let xmltvURL: String?
        let nowPlaying: ProgrammeExport?
        let programmeCount: Int

        init(_ channel: GuideChannel, includeGuideURL: Bool) {
            id = channel.id
            sourceID = channel.sourceID
            rawChannelID = channel.rawChannelID
            displayNumber = channel.displayNumber
            name = channel.name
            detail = channel.detail
            logoURL = channel.logoURL?.absoluteString
            streamURL = channel.streamURL.absoluteString
            xmltvURL = includeGuideURL ? channel.xmltvURL.absoluteString : nil
            nowPlaying = channel.nowPlaying.map(ProgrammeExport.init)
            programmeCount = channel.programmes.count
        }
    }

    private struct ProgrammeExport: Encodable {
        let start: Date
        let stop: Date
        let title: String
        let detail: String?

        init(_ programme: GuideProgramme) {
            start = programme.start
            stop = programme.stop
            title = programme.title
            detail = programme.detail
        }
    }
}

struct MobileUnlockRequest: Codable, Identifiable, Sendable {
    let id: UUID
    let deviceID: UUID
    let deviceName: String
    let createdAt: Date
}

private struct MobileApproverEvents: Encodable {
    let requests: [MobileUnlockRequest]
}

struct MobileApproverRequest: Identifiable, Sendable {
    let id: UUID
    let deviceName: String
    let credentialHash: String
    let createdAt: Date
}

struct MobileUnlockDecision: Sendable {
    let requestID: UUID
    let approverName: String
    let approved: Bool
}

private extension JSONEncoder {
    static var apiDateEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

/// Confined to the local API queue. Requesting only notifies the desktop; no route can approve.
final class LocalAPIRequestRouter {
    var payloads: [String: LocalAPIServer.HTTPPayload] = [:]
    var onUnlockRequest: ((MobileUnlockRequest) -> Void)?
    var onApproverRequest: ((MobileApproverRequest) -> Void)?
    var onApproverUnlockDecision: ((MobileUnlockDecision) -> Void)?
    var onApproverLock: ((String) -> Void)?
    private var recentRequests: [UUID: Date] = [:]
    private var recentGlobalRequests: [Date] = []
    private var recentApproverRequests: [UUID: Date] = [:]
    private var recentGlobalApproverRequests: [Date] = []
    private var approvers: [UUID: MobileApprover] = [:]
    private var pendingApproverRequests: [UUID: MobileApproverRequest] = [:]
    private var approverStatuses: [UUID: ApproverStatus] = [:]
    private var pendingUnlockRequests: [UUID: MobileUnlockRequest] = [:]
    private var activeUnlockRequestByDevice: [UUID: UUID] = [:]

    private func releaseUnlockRequestCooldown(for deviceID: UUID) {
        guard let timestamp = recentRequests.removeValue(forKey: deviceID) else { return }
        if let index = recentGlobalRequests.firstIndex(of: timestamp) {
            recentGlobalRequests.remove(at: index)
        }
    }

    private struct ApproverStatus {
        let credentialHash: String
        let status: String
        let expiresAt: Date
    }

    func update(payloads: [String: LocalAPIServer.HTTPPayload], approvers nextApprovers: [MobileApprover]) {
        self.payloads = payloads
        if let statePayload = payloads["/api/mobile/state.json"],
           let state = (try? JSONSerialization.jsonObject(with: statePayload.data)) as? [String: Any],
           state["areProtectedChannelsUnlocked"] as? Bool == true {
            for request in pendingUnlockRequests.values { releaseUnlockRequestCooldown(for: request.deviceID) }
            pendingUnlockRequests.removeAll()
            activeUnlockRequestByDevice.removeAll()
        }
        let next = Dictionary(uniqueKeysWithValues: nextApprovers.map { ($0.deviceID, $0) })
        for (deviceID, previous) in approvers where next[deviceID]?.credentialHash != previous.credentialHash {
            approverStatuses[deviceID] = ApproverStatus(credentialHash: previous.credentialHash, status: "revoked", expiresAt: .distantFuture)
        }
        for (deviceID, approver) in next {
            if let request = pendingApproverRequests[deviceID], request.credentialHash == approver.credentialHash {
                approverStatuses[deviceID] = ApproverStatus(credentialHash: approver.credentialHash, status: "approved", expiresAt: .distantFuture)
                pendingApproverRequests.removeValue(forKey: deviceID)
            }
        }
        approvers = next
    }

    func denyApproverRequest(_ deviceID: UUID) {
        guard let request = pendingApproverRequests.removeValue(forKey: deviceID) else { return }
        approverStatuses[deviceID] = ApproverStatus(credentialHash: request.credentialHash, status: "denied", expiresAt: Date().addingTimeInterval(300))
    }

    func completeUnlockRequest(_ requestID: UUID) {
        guard let request = pendingUnlockRequests.removeValue(forKey: requestID) else { return }
        if activeUnlockRequestByDevice[request.deviceID] == requestID {
            activeUnlockRequestByDevice.removeValue(forKey: request.deviceID)
        }
        releaseUnlockRequestCooldown(for: request.deviceID)
    }

    func completeAllUnlockRequests() {
        for request in pendingUnlockRequests.values { releaseUnlockRequestCooldown(for: request.deviceID) }
        pendingUnlockRequests.removeAll()
        activeUnlockRequestByDevice.removeAll()
    }

    func route(requestText: String, now: Date = Date()) -> LocalAPIServer.HTTPPayload {
        func error(_ code: Int, _ text: String) -> LocalAPIServer.HTTPPayload {
            .init(contentType: "text/plain; charset=utf-8", data: Data(text.utf8), statusCode: code)
        }
        func json(_ value: [String: Any], statusCode: Int = 200) -> LocalAPIServer.HTTPPayload {
            let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
            return .init(contentType: "application/json; charset=utf-8", data: data, statusCode: statusCode)
        }
        guard requestText.utf8.count <= 16_384 else { return error(413, "Request too large") }
        let line = requestText.components(separatedBy: "\r\n").first ?? ""
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0",
              parts[1].hasPrefix("/"), let url = URLComponents(string: String(parts[1])), url.fragment == nil else {
            return error(400, "Bad request")
        }
        let headers = requestText.components(separatedBy: "\r\n").dropFirst().prefix(while: { !$0.isEmpty })
        for header in headers {
            let pieces = header.split(separator: ":", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { return error(400, "Invalid header") }
            let name = pieces[0].lowercased()
            let value = pieces[1].trimmingCharacters(in: .whitespaces)
            if name == "transfer-encoding" || (name == "content-length" && value != "0") {
                return error(400, "Request bodies are not supported")
            }
        }
        let path = url.path
        let method = String(parts[0])
        let fields = url.queryItems ?? []
        func value(_ key: String) -> String? {
            guard fields.filter({ $0.name == key }).count == 1 else { return nil }
            return fields.first(where: { $0.name == key })?.value
        }
        func device() -> (UUID, String)? {
            guard let rawID = value("deviceID"), let id = UUID(uuidString: rawID),
                  let rawName = value("deviceName"), rawName.utf8.count <= 128 else { return nil }
            let cleanName = rawName.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanName.isEmpty else { return nil }
            return (id, cleanName)
        }
        func credentialHash() -> String? {
            guard let token = value("credential"), token.count == 43,
                  token.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0) }) else { return nil }
            let base64 = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
            guard let bytes = Data(base64Encoded: base64), bytes.count == 32 else { return nil }
            return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
        func isAuthorized(_ id: UUID, hash: String) -> Bool {
            guard let expected = approvers[id]?.credentialHash else { return false }
            let lhs = Array(expected.utf8), rhs = Array(hash.utf8)
            guard lhs.count == rhs.count else { return false }
            return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
        }
        func isUnlocked() -> Bool? {
            guard let payload = payloads["/api/mobile/state.json"],
                  let state = (try? JSONSerialization.jsonObject(with: payload.data)) as? [String: Any] else { return nil }
            return state["areProtectedChannelsUnlocked"] as? Bool
        }

        if path == "/api/mobile/unlock-request" {
            guard method == "POST" else { return error(405, "POST required") }
            guard let (deviceID, name) = device() else { return error(400, "Invalid device") }
            guard let unlocked = isUnlocked() else { return error(503, "Desktop starting") }
            if unlocked { return json(["status": "alreadyUnlocked"]) }
            pendingUnlockRequests = pendingUnlockRequests.filter { now.timeIntervalSince($0.value.createdAt) < 300 }
            recentRequests = recentRequests.filter { now.timeIntervalSince($0.value) < 60 }
            recentGlobalRequests.removeAll { now.timeIntervalSince($0) >= 60 }
            if let existingID = activeUnlockRequestByDevice[deviceID], pendingUnlockRequests[existingID] != nil {
                return json(["status": "pending", "requestID": existingID.uuidString], statusCode: 202)
            }
            guard recentRequests[deviceID] == nil else { return error(429, "A recent request was already handled; try again in a minute") }
            guard recentGlobalRequests.count < 10 else { return error(429, "Too many requests; try again in a minute") }
            recentRequests[deviceID] = now
            recentGlobalRequests.append(now)
            let request = MobileUnlockRequest(id: UUID(), deviceID: deviceID, deviceName: name, createdAt: now)
            pendingUnlockRequests[request.id] = request
            activeUnlockRequestByDevice[deviceID] = request.id
            onUnlockRequest?(request)
            return json(["status": "pending", "requestID": request.id.uuidString], statusCode: 202)
        }

        if path == "/api/mobile/approver-request" {
            guard method == "POST" else { return error(405, "POST required") }
            guard let (deviceID, name) = device(), let hash = credentialHash() else { return error(400, "Invalid device credential") }
            if isAuthorized(deviceID, hash: hash) { return json(["status": "approved"]) }
            recentApproverRequests = recentApproverRequests.filter { now.timeIntervalSince($0.value) < 60 }
            recentGlobalApproverRequests.removeAll { now.timeIntervalSince($0) >= 60 }
            if let pending = pendingApproverRequests[deviceID], pending.credentialHash == hash {
                return json(["status": "pending"], statusCode: 202)
            }
            guard recentApproverRequests[deviceID] == nil, recentGlobalApproverRequests.count < 10 else {
                return error(429, "Too many approver requests; try again in a minute")
            }
            recentApproverRequests[deviceID] = now
            recentGlobalApproverRequests.append(now)
            let request = MobileApproverRequest(id: deviceID, deviceName: name, credentialHash: hash, createdAt: now)
            pendingApproverRequests[deviceID] = request
            approverStatuses[deviceID] = ApproverStatus(credentialHash: hash, status: "pending", expiresAt: now.addingTimeInterval(300))
            onApproverRequest?(request)
            return json(["status": "pending"], statusCode: 202)
        }

        if path == "/api/mobile/approver-status" {
            guard method == "GET" else { return error(405, "GET required") }
            guard let rawID = value("deviceID"), let deviceID = UUID(uuidString: rawID), let hash = credentialHash() else { return error(400, "Invalid device credential") }
            if isAuthorized(deviceID, hash: hash) { return json(["status": "approved"]) }
            if let status = approverStatuses[deviceID], status.expiresAt > now, status.credentialHash == hash {
                return json(["status": status.status])
            }
            if approvers[deviceID] != nil { return json(["status": "revoked"]) }
            return json(["status": "notAuthorized"])
        }

        if path == "/api/mobile/approver-events" {
            guard method == "GET" else { return error(405, "GET required") }
            guard let rawID = value("deviceID"), let deviceID = UUID(uuidString: rawID), let hash = credentialHash() else { return error(400, "Invalid device credential") }
            guard isAuthorized(deviceID, hash: hash) else { return error(401, "Approver access required") }
            let unlocked = isUnlocked()
            if unlocked == nil { return error(503, "Desktop starting") }
            if unlocked == true { return json(["requests": []]) }
            let events = pendingUnlockRequests.values.filter { now.timeIntervalSince($0.createdAt) < 300 }.sorted { $0.createdAt < $1.createdAt }
            let data = (try? JSONEncoder.apiDateEncoder.encode(MobileApproverEvents(requests: events))) ?? Data("{\"requests\":[]}".utf8)
            return .init(contentType: "application/json; charset=utf-8", data: data)
        }

        if path == "/api/mobile/approver-decision" {
            guard method == "POST" else { return error(405, "POST required") }
            guard let rawID = value("deviceID"), let deviceID = UUID(uuidString: rawID),
                  let hash = credentialHash(), isAuthorized(deviceID, hash: hash), let approver = approvers[deviceID],
                  let rawRequestID = value("requestID"), let requestID = UUID(uuidString: rawRequestID),
                  let rawDecision = value("decision"), ["approve", "deny"].contains(rawDecision) else { return error(401, "Invalid approver decision") }
            guard let request = pendingUnlockRequests.removeValue(forKey: requestID), now.timeIntervalSince(request.createdAt) < 300 else {
                return error(404, "Unlock request expired or already handled")
            }
            if activeUnlockRequestByDevice[request.deviceID] == requestID { activeUnlockRequestByDevice.removeValue(forKey: request.deviceID) }
            releaseUnlockRequestCooldown(for: request.deviceID)
            let approved = rawDecision == "approve"
            onApproverUnlockDecision?(.init(requestID: requestID, approverName: approver.deviceName, approved: approved))
            return json(["status": approved ? "approved" : "denied"])
        }

        if path == "/api/mobile/approver-lock" {
            guard method == "POST" else { return error(405, "POST required") }
            guard let rawID = value("deviceID"), let deviceID = UUID(uuidString: rawID),
                  let hash = credentialHash(), isAuthorized(deviceID, hash: hash),
                  let approver = approvers[deviceID] else { return error(401, "Approver access required") }
            guard let unlocked = isUnlocked() else { return error(503, "Desktop starting") }
            guard unlocked else { return json(["status": "alreadyLocked"]) }
            onApproverLock?(approver.deviceName)
            return json(["status": "locked"])
        }

        guard method == "GET" else { return error(405, "GET required") }
        return payloads[path] ?? error(404, "Not Found\n")
    }
}
