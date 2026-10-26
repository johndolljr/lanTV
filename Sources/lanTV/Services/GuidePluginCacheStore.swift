import Foundation

final class GuidePluginCacheStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        self.fileURL = Self.makeFileURL(fileManager: fileManager)
    }

    func load() -> GuidePluginCache {
        guard
            let data = try? Data(contentsOf: fileURL),
            let cache = try? decoder.decode(GuidePluginCache.self, from: data)
        else {
            return GuidePluginCache()
        }
        return GuidePluginCache(
            entries: cache.entries.filter { !$0.value.programmes.isEmpty }
        )
    }

    func save(_ cache: GuidePluginCache) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(cache)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("Failed to save guide plugin cache: %@", error.localizedDescription)
        }
    }

    private static func makeFileURL(fileManager: FileManager) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("lanTV", isDirectory: true)
            .appendingPathComponent("guide-plugin-cache.json")
    }
}

struct GuidePluginCache: Codable, Equatable {
    var entries: [String: GuidePluginCacheEntry] = [:]
}

struct GuidePluginCacheEntry: Codable, Equatable {
    var fetchedAt: Date
    var programmes: [GuideProgramme]
}
