import Foundation

final class GuideCacheStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        self.fileURL = Self.makeFileURL(fileManager: fileManager)
        self.encoder.outputFormatting = [.prettyPrinted]
    }

    func load() -> MergedGuide? {
        guard
            let data = try? Data(contentsOf: fileURL),
            let guide = try? decoder.decode(MergedGuide.self, from: data)
        else {
            return nil
        }
        return guide
    }

    func save(_ guide: MergedGuide) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(guide)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("Failed to save guide cache: %@", error.localizedDescription)
        }
    }

    private static func makeFileURL(fileManager: FileManager) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("lanTV", isDirectory: true)
            .appendingPathComponent("guide-cache.json")
    }
}
