import Foundation
import Observation

@MainActor
@Observable
final class AppSettingsStore {
    var settings: AppSettings {
        didSet {
            save()
        }
    }

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        self.fileURL = Self.makeFileURL(fileManager: fileManager)
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let loadedSettings = Self.loadSettings(from: fileURL) ?? .default
        self.settings = loadedSettings
        if let persistedSettings = Self.loadRawSettings(from: fileURL), persistedSettings != loadedSettings {
            save()
        }
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        settings = copy
    }

    func reset() {
        settings = .default
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(settings)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("Failed to save settings: %@", error.localizedDescription)
        }
    }

    private static func makeFileURL(fileManager: FileManager) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("lanTV", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    private static func loadSettings(from url: URL) -> AppSettings? {
        loadRawSettings(from: url)
    }

    private static func loadRawSettings(from url: URL) -> AppSettings? {
        guard
            let data = try? Data(contentsOf: url),
            let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return nil
        }
        return settings
    }
}
