import Foundation

enum GuidePluginRunnerError: LocalizedError {
    case missingPluginDirectory
    case invalidManifestPath(String)
    case failedToLaunch(String)
    case nonZeroExit(code: Int32, stderr: String)
    case invalidOutput
    case unsupportedPlugin

    var errorDescription: String? {
        switch self {
        case .missingPluginDirectory:
            return "The bundled Plugins directory could not be found."
        case .invalidManifestPath(let path):
            return "The plugin manifest could not be found: \(path)."
        case .failedToLaunch(let detail):
            return "Failed to launch guide plugin: \(detail)"
        case .nonZeroExit(let code, let stderr):
            if stderr.isEmpty {
                return "Guide plugin exited with status \(code)."
            }
            return "Guide plugin exited with status \(code): \(stderr)"
        case .invalidOutput:
            return "Guide plugin returned invalid output."
        case .unsupportedPlugin:
            return "Unsupported guide plugin."
        }
    }
}

struct GuidePluginRunner {
    func loadProgrammes(
        for plugin: GuidePlugin,
        channel: GuideChannel
    ) async throws -> [GuideProgramme] {
        switch plugin.kind {
        case .external(let manifestPath):
            return try await runExternalPlugin(
                manifestPath: manifestPath,
                arguments: plugin.arguments,
                channel: channel
            )
        }
    }

    private func runExternalPlugin(
        manifestPath: String,
        arguments: [String: String],
        channel: GuideChannel
    ) async throws -> [GuideProgramme] {
        let pluginsDirectory = try resolvePluginsDirectory()
        let manifestURL = pluginsDirectory.appendingPathComponent(manifestPath)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw GuidePluginRunnerError.invalidManifestPath(manifestPath)
        }

        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(ExternalGuidePluginManifest.self, from: manifestData)
        let pluginDirectory = manifestURL.deletingLastPathComponent()
        let command = try resolveCommand(manifest.command, pluginDirectory: pluginDirectory)

        let request = ExternalGuidePluginRequest(
            channelNumber: channel.displayNumber,
            channelName: channel.name,
            sourceID: channel.sourceID,
            rawChannelID: channel.rawChannelID,
            arguments: arguments,
            generatedAt: Date(),
            timeZoneIdentifier: TimeZone.current.identifier
        )
        let requestData = try JSONEncoder().encode(request)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        process.currentDirectoryURL = pluginDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        do {
            try process.run()
        } catch {
            throw GuidePluginRunnerError.failedToLaunch(error.localizedDescription)
        }

        stdinPipe.fileHandleForWriting.write(requestData)
        stdinPipe.fileHandleForWriting.closeFile()

        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            throw GuidePluginRunnerError.nonZeroExit(code: process.terminationStatus, stderr: stderr)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let response = try? decoder.decode(ExternalGuidePluginResponse.self, from: stdoutData) else {
            throw GuidePluginRunnerError.invalidOutput
        }

        return response.programmes.enumerated().map { index, item in
            GuideProgramme(
                id: "\(channel.id)|plugin|\(item.start.timeIntervalSinceReferenceDate)|\(index)",
                channelID: channel.id,
                start: item.start,
                stop: item.stop,
                title: item.title,
                detail: item.detail,
                iconURL: item.iconURL
            )
        }
        .sorted { $0.start < $1.start }
    }

    private func resolvePluginsDirectory() throws -> URL {
        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("Plugins"),
           FileManager.default.fileExists(atPath: resourceURL.path) {
            return resourceURL
        }

        let cwdCandidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Plugins")
        if FileManager.default.fileExists(atPath: cwdCandidate.path) {
            return cwdCandidate
        }

        throw GuidePluginRunnerError.missingPluginDirectory
    }

    private func resolveCommand(_ command: [String], pluginDirectory: URL) throws -> [String] {
        guard !command.isEmpty else {
            throw GuidePluginRunnerError.unsupportedPlugin
        }

        return command.enumerated().map { index, part in
            guard index != 0 else { return part }
            if part.hasPrefix("/") {
                return part
            }
            let candidate = pluginDirectory.appendingPathComponent(part)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
            return part
        }
    }
}

private struct ExternalGuidePluginManifest: Decodable {
    let schema: String
    let id: String
    let name: String
    let language: String
    let command: [String]
}

private struct ExternalGuidePluginRequest: Codable {
    let channelNumber: String
    let channelName: String
    let sourceID: String
    let rawChannelID: String
    let arguments: [String: String]
    let generatedAt: Date
    let timeZoneIdentifier: String
}

private struct ExternalGuidePluginResponse: Decodable {
    let programmes: [ExternalGuideProgramme]
}

private struct ExternalGuideProgramme: Decodable {
    let start: Date
    let stop: Date
    let title: String
    let detail: String?
    let iconURL: URL?
}
