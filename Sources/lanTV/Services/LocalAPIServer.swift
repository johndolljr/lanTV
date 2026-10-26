import Foundation
import Network
import Darwin

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
    }

    private let queue = DispatchQueue(label: "lanTV.local-api")
    private var listener: NWListener?
    private var payloads: [String: HTTPPayload] = [:]
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
        let orderedHosts = Array(NSOrderedSet(array: [loopback] + addresses)) as? [String] ?? [loopback]
        return orderedHosts.compactMap { URL(string: "http://\($0):\(port)") }
    }

    func start() {
        guard listener == nil else { return }

        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
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
        let rendered = LocalAPIExportRenderer.render(context: context)
        queue.async { [weak self] in
            self?.payloads = rendered
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }

            let requestText = String(data: data ?? Data(), encoding: .utf8) ?? ""
            let payload = self.route(requestText: requestText)
            let response = self.httpResponse(for: payload)

            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func route(requestText: String) -> HTTPPayload {
        let requestLine = requestText.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            return HTTPPayload(
                contentType: "text/plain; charset=utf-8",
                data: Data("Method Not Allowed\n".utf8)
            )
        }

        let rawPath = String(parts[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        let path = rawPath.isEmpty ? "/" : rawPath

        return payloads[path]
            ?? payloads["/404"]
            ?? HTTPPayload(contentType: "text/plain; charset=utf-8", data: Data("Not Found\n".utf8))
    }

    private func httpResponse(for payload: HTTPPayload) -> Data {
        let isNotFound = payload.data == Data("Not Found\n".utf8)
        let statusLine = isNotFound ? "HTTP/1.1 404 Not Found" : "HTTP/1.1 200 OK"
        var header = "\(statusLine)\r\n"
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

            guard
                interface.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                (flags & IFF_UP) != 0,
                (flags & IFF_RUNNING) != 0,
                (flags & IFF_LOOPBACK) == 0
            else {
                continue
            }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                interface.ifa_addr,
                socklen_t(interface.ifa_addr.pointee.sa_len),
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

private enum LocalAPIExportRenderer {
    static func render(context: LocalAPIExportContext) -> [String: LocalAPIServer.HTTPPayload] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let settingsExport = SettingsExport(
            sources: context.settings.sources.map(SourceExport.init),
            hiddenChannelIDsBySource: context.settings.excludedChannelIDsBySource,
            lockedChannelIDsBySource: context.areProtectedChannelsUnlocked ? context.settings.adultChannelIDsBySource : [:],
            lockedChannelCountsBySource: context.settings.adultChannelIDsBySource.mapValues(\.count),
            areProtectedChannelsUnlocked: context.areProtectedChannelsUnlocked,
            autoRefreshIntervalSeconds: context.settings.autoRefreshIntervalSeconds,
            guideVisibleHours: context.settings.guideVisibleHours,
            volume: context.settings.volume,
            localAPIPort: context.settings.localAPIPort
        )

        let exportedChannels = context.visibleChannels.map(ChannelExport.init)
        let stateExport = StateExport(
            exportedAt: Date(),
            generatedAt: context.generatedAt,
            selectedChannelID: context.selectedChannelID,
            isPlayerDetached: context.isPlayerDetached,
            sourceStatus: context.sourceStatus,
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
        let xmltvData = Data(renderXMLTV(for: context.visibleChannels, generatedAt: context.generatedAt).utf8)
        let playlistData = Data(renderM3U(for: context.visibleChannels).utf8)

        return [
            "/": .init(contentType: "application/json; charset=utf-8", data: summaryData),
            "/api/settings.json": .init(contentType: "application/json; charset=utf-8", data: settingsData),
            "/api/channels.json": .init(contentType: "application/json; charset=utf-8", data: channelsData),
            "/api/state.json": .init(contentType: "application/json; charset=utf-8", data: stateData),
            "/api/guide.xmltv": .init(contentType: "application/xml; charset=utf-8", data: xmltvData),
            "/api/playlist.m3u": .init(contentType: "application/x-mpegURL; charset=utf-8", data: playlistData),
            "/404": .init(contentType: "text/plain; charset=utf-8", data: Data("Not Found\n".utf8))
        ]
    }

    private static func renderXMLTV(for channels: [GuideChannel], generatedAt: Date?) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime, .withTimeZone]

        var xml: [String] = []
        xml.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        xml.append("<tv generator-info-name=\"lanTV\" generated-ts=\"\(generatedAt.map(formatter.string(from:)) ?? formatter.string(from: Date()))\">")

        for channel in channels {
            xml.append("  <channel id=\"\(escape(channel.rawChannelID))\">")
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
                    "  <programme start=\"\(xmltvDate(programme.start))\" stop=\"\(xmltvDate(programme.stop))\" channel=\"\(escape(channel.rawChannelID))\">"
                )
                xml.append("    <title>\(escape(programme.title))</title>")
                if let detail = programme.detail, !detail.isEmpty {
                    xml.append("    <desc>\(escape(detail))</desc>")
                }
                if let iconURL = programme.iconURL {
                    xml.append("    <icon src=\"\(escape(iconURL.absoluteString))\" />")
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
            lines.append(#"#EXTINF:-1 tvg-id="\#(channel.rawChannelID)" tvg-name="\#(channel.name)" tvg-logo="\#(logo)" group-title="\#(channel.sourceID)",\#(title)"#)
            lines.append(channel.streamURL.absoluteString)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func xmltvDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        return formatter.string(from: date)
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
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

        init(_ source: GuideSource) {
            id = source.id
            switch source.kind {
            case .xmltv(let url, let template):
                kind = "xmltv"
                xmltvURL = url.absoluteString
                streamURLTemplate = template
                baseURL = nil
            case .hdhomerun(let url):
                kind = "hdhomerun"
                xmltvURL = nil
                streamURLTemplate = nil
                baseURL = url.absoluteString
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
        let xmltvURL: String
        let nowPlaying: ProgrammeExport?
        let programmeCount: Int

        init(_ channel: GuideChannel) {
            id = channel.id
            sourceID = channel.sourceID
            rawChannelID = channel.rawChannelID
            displayNumber = channel.displayNumber
            name = channel.name
            detail = channel.detail
            logoURL = channel.logoURL?.absoluteString
            streamURL = channel.streamURL.absoluteString
            xmltvURL = channel.xmltvURL.absoluteString
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
