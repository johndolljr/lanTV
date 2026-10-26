import Foundation

enum XMLTVParserError: Error {
    case invalidDocument
}

final class XMLTVParser: NSObject {
    private enum Element: String {
        case channel
        case programme
        case displayName = "display-name"
        case title
        case desc
        case icon
        case subTitle = "sub-title"
        case episodeNum = "episode-num"
    }

    private struct PartialChannel {
        var id: String
        var displayName: String?
        var iconURL: URL?
    }

    private struct PartialProgramme {
        var channelID: String
        var start: Date
        var stop: Date
        var title: String?
        var detail: String?
        var iconURL: URL?
        var subTitle: String?
        var seasonEpisode: String?
        var episodeSystemPriority: Int = 0
    }

    private enum TextTarget {
        case channelDisplayName
        case programmeTitle
        case programmeDescription
        case programmeSubTitle
        case programmeEpisodeNum
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        return formatter
    }()

    private var channels: [String: XMLTVChannel] = [:]
    private var programmes: [XMLTVProgramme] = []
    private var currentChannel: PartialChannel?
    private var currentProgramme: PartialProgramme?
    private var currentText = ""
    private var textTarget: TextTarget?
    private var currentEpisodeSystem: String?

    func parse(data: Data) throws -> XMLTVGuide {
        channels = [:]
        programmes = []
        currentChannel = nil
        currentProgramme = nil
        currentText = ""
        textTarget = nil
        currentEpisodeSystem = nil

        let parser = XMLParser(data: data)
        parser.delegate = self

        guard parser.parse() else {
            throw parser.parserError ?? XMLTVParserError.invalidDocument
        }

        return XMLTVGuide(channels: channels, programmes: programmes)
    }

    private func parseDate(_ value: String) -> Date? {
        Self.dateFormatter.date(from: value)
    }
}

extension XMLTVParser: XMLParserDelegate {
    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard let element = Element(rawValue: elementName) else {
            textTarget = nil
            return
        }

        currentText = ""

        switch element {
        case .channel:
            guard let id = attributeDict["id"] else { return }
            currentChannel = PartialChannel(id: id)
        case .programme:
            guard
                let channelID = attributeDict["channel"],
                let startText = attributeDict["start"],
                let stopText = attributeDict["stop"],
                let start = parseDate(startText),
                let stop = parseDate(stopText)
            else { return }

            currentProgramme = PartialProgramme(
                channelID: channelID,
                start: start,
                stop: stop
            )
        case .displayName:
            textTarget = .channelDisplayName
        case .title:
            textTarget = .programmeTitle
        case .desc:
            textTarget = .programmeDescription
        case .subTitle:
            textTarget = .programmeSubTitle
        case .episodeNum:
            textTarget = .programmeEpisodeNum
            currentEpisodeSystem = attributeDict["system"]
        case .icon:
            let url = attributeDict["src"].flatMap(URL.init(string:))
            if currentProgramme != nil {
                currentProgramme?.iconURL = url
            } else {
                currentChannel?.iconURL = url
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard let element = Element(rawValue: elementName) else { return }

        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch element {
        case .displayName:
            if case .channelDisplayName = textTarget, !trimmed.isEmpty {
                currentChannel?.displayName = trimmed
            }
            textTarget = nil
        case .title:
            if case .programmeTitle = textTarget, !trimmed.isEmpty {
                currentProgramme?.title = trimmed
            }
            textTarget = nil
        case .desc:
            if case .programmeDescription = textTarget, !trimmed.isEmpty {
                currentProgramme?.detail = trimmed
            }
            textTarget = nil
        case .subTitle:
            if case .programmeSubTitle = textTarget, !trimmed.isEmpty {
                currentProgramme?.subTitle = trimmed
            }
            textTarget = nil
        case .episodeNum:
            if case .programmeEpisodeNum = textTarget, !trimmed.isEmpty {
                let system = currentEpisodeSystem?.lowercased() ?? ""
                let priority: Int
                if system.contains("onscreen") {
                    priority = 3
                } else if system.contains("xmltv_ns") {
                    priority = 2
                } else {
                    priority = 1
                }
                if priority >= (currentProgramme?.episodeSystemPriority ?? 0) {
                    currentProgramme?.seasonEpisode = trimmed
                    currentProgramme?.episodeSystemPriority = priority
                }
            }
            textTarget = nil
            currentEpisodeSystem = nil
        case .channel:
            if let currentChannel {
                channels[currentChannel.id] = XMLTVChannel(
                    id: currentChannel.id,
                    displayName: currentChannel.displayName,
                    iconURL: currentChannel.iconURL
                )
            }
            self.currentChannel = nil
        case .programme:
            if let currentProgramme {
                programmes.append(
                    XMLTVProgramme(
                        channelID: currentProgramme.channelID,
                        start: currentProgramme.start,
                        stop: currentProgramme.stop,
                        title: currentProgramme.title,
                        detail: currentProgramme.detail,
                        iconURL: currentProgramme.iconURL,
                        seasonEpisode: currentProgramme.seasonEpisode,
                        subTitle: currentProgramme.subTitle
                    )
                )
            }
            self.currentProgramme = nil
        case .icon:
            break
        }

        currentText = ""
    }
}
