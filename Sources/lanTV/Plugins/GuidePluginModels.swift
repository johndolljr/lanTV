import Foundation

struct GuidePluginTarget: Codable, Equatable, Hashable {
    var sourceID: String
    var rawChannelID: String

    var scopedID: String {
        "\(sourceID)::\(rawChannelID)"
    }
}

struct GuidePlugin: Identifiable, Codable, Equatable, Hashable {
    enum Kind: Hashable, Codable {
        case external(manifestPath: String)

        enum CodingKeys: String, CodingKey {
            case type
            case manifestPath
        }

        enum KindType: String, Codable {
            case external
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(KindType.self, forKey: .type)
            switch type {
            case .external:
                self = .external(
                    manifestPath: try container.decode(String.self, forKey: .manifestPath)
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .external(let manifestPath):
                try container.encode(KindType.external, forKey: .type)
                try container.encode(manifestPath, forKey: .manifestPath)
            }
        }
    }

    var id: String
    var name: String
    var isEnabled: Bool
    var refreshIntervalSeconds: Double
    var arguments: [String: String]
    var target: GuidePluginTarget
    var kind: Kind

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case isEnabled
        case refreshIntervalSeconds
        case arguments
        case target
        case kind
    }

    init(
        id: String,
        name: String,
        isEnabled: Bool,
        refreshIntervalSeconds: Double = 21_600,
        arguments: [String: String] = [:],
        target: GuidePluginTarget,
        kind: Kind
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.arguments = arguments
        self.target = target
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        refreshIntervalSeconds = try container.decodeIfPresent(Double.self, forKey: .refreshIntervalSeconds) ?? 21_600
        arguments = try container.decodeIfPresent([String: String].self, forKey: .arguments) ?? [:]
        target = try container.decode(GuidePluginTarget.self, forKey: .target)
        kind = try container.decode(Kind.self, forKey: .kind)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(refreshIntervalSeconds, forKey: .refreshIntervalSeconds)
        try container.encode(arguments, forKey: .arguments)
        try container.encode(target, forKey: .target)
        try container.encode(kind, forKey: .kind)
    }

    var providerLabel: String {
        switch kind {
        case .external:
            return "External Guide Plugin"
        }
    }
}
