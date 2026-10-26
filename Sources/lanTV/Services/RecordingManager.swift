import AppKit
import Foundation
import Observation

private final class CircularDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let maxCapacity: Int

    init(maxCapacity: Int = 16384) {
        self.maxCapacity = maxCapacity
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > maxCapacity {
            data = data.suffix(maxCapacity)
        }
    }

    func stringValue() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
@Observable
final class RecordingManager {
    var recordings: [RecordingItem] = []
    var isFFmpegAvailable: Bool = false
    var ffmpegBinaryPath: String?

    @ObservationIgnored
    private let settingsStore: AppSettingsStore
    @ObservationIgnored
    private let recordingsFileURL: URL
    @ObservationIgnored
    private var activeProcesses: [UUID: Process] = [:]
    @ObservationIgnored
    private var activeInputPipes: [UUID: Pipe] = [:]
    @ObservationIgnored
    private var lastGrowthTime: [UUID: Date] = [:]
    @ObservationIgnored
    private var lastRecordedBytes: [UUID: Int64] = [:]
    @ObservationIgnored
    private var activeOutputPaths: [UUID: String] = [:]
    @ObservationIgnored
    private var autoRestartCount: [UUID: Int] = [:]
    @ObservationIgnored
    private var launchingRecordings: Set<UUID> = []
    @ObservationIgnored
    private var schedulerTimer: Timer?
    private var finalizingRecordings: Set<UUID> = []
    @ObservationIgnored
    private var terminationObserver: NSObjectProtocol?

    /// Closure provided by ViewModel to check what channel is currently being watched
    @ObservationIgnored
    var currentlyWatchingChannelID: (() -> String?)?

    /// Closure provided by ViewModel to lookup current programme for a channel
    @ObservationIgnored
    var currentProgrammeLookup: ((String) -> (channel: GuideChannel, programme: GuideProgramme)?)?

    init(settingsStore: AppSettingsStore) {
        self.settingsStore = settingsStore
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("lanTV", isDirectory: true)
        self.recordingsFileURL = appSupport.appendingPathComponent("recordings.json")

        locateFFmpeg()
        loadRecordings()
        startScheduler()
        setupAppTerminationHandler()
    }

    isolated deinit {
        schedulerTimer?.invalidate()
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    // MARK: - FFmpeg Discovery

    func locateFFmpeg() {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
            "~/.local/bin/ffmpeg"
        ]

        for path in candidates {
            let expanded = (path as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) {
                self.ffmpegBinaryPath = expanded
                self.isFFmpegAvailable = true
                return
            }
        }

        // Try 'which ffmpeg'
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["ffmpeg"]
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty, FileManager.default.isExecutableFile(atPath: output) {
                self.ffmpegBinaryPath = output
                self.isFFmpegAvailable = true
                return
            }
        }

        self.ffmpegBinaryPath = nil
        self.isFFmpegAvailable = false
    }

    // MARK: - State Persistence

    private func loadRecordings() {
        guard FileManager.default.fileExists(atPath: recordingsFileURL.path) else { return }
        do {
            let data = try Data(contentsOf: recordingsFileURL)
            let items = try JSONDecoder().decode([RecordingItem].self, from: data)
            // Reconcile items that were left in recording state from previous app crash
            self.recordings = items.map { item in
                var copy = item
                if copy.status == .recording {
                    copy.status = .failed(reason: "Interrupted by app termination")
                    copy.actualStop = copy.actualStop ?? Date()
                }
                return copy
            }
        } catch {
            print("[RecordingManager] Failed to load recordings: \(error)")
        }
    }

    private func saveRecordings() {
        do {
            let dir = recordingsFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(recordings)
            try data.write(to: recordingsFileURL, options: .atomic)
        } catch {
            print("[RecordingManager] Failed to save recordings: \(error)")
        }
    }

    // MARK: - Public Queries

    var activeRecordingsCount: Int {
        recordings.filter { $0.status == .recording }.count
    }

    func activeRecording(for channelID: String) -> RecordingItem? {
        recordings.first(where: { $0.channelID == channelID && $0.status == .recording })
    }

    func recordingItem(forProgrammeID programmeID: String) -> RecordingItem? {
        recordings.first(where: { $0.programmeID == programmeID && !$0.status.isTerminal })
    }

    // MARK: - Actions

    @discardableResult
    func startRecording(
        channel: GuideChannel,
        programme: GuideProgramme,
        isLiveRollOver: Bool = false
    ) -> RecordingItem? {
        guard isFFmpegAvailable, let ffmpegPath = ffmpegBinaryPath else {
            print("[RecordingManager] FFmpeg binary not found")
            return nil
        }

        let maxConcurrent = max(1, settingsStore.settings.maxSimultaneousRecordings)
        if activeRecordingsCount >= maxConcurrent {
            print("[RecordingManager] Max concurrent recordings reached (\(maxConcurrent))")
            return nil
        }

        // If this programme is already scheduled, update it; otherwise create new
        var item: RecordingItem
        if let existingIndex = recordings.firstIndex(where: { $0.programmeID == programme.id && $0.status == .scheduled }) {
            item = recordings[existingIndex]
            item.status = .recording
            item.actualStart = Date()
            item.isLiveRollOver = isLiveRollOver
            recordings[existingIndex] = item
        } else {
            let dirURL = settingsStore.settings.recordingsDirectoryURL
            try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            let destURL = RecordingFilenameGenerator.destinationFileURL(
                directory: dirURL,
                title: programme.title,
                subTitle: programme.subTitle,
                detail: programme.detail,
                seasonEpisode: programme.seasonEpisode,
                date: programme.start
            )

            item = RecordingItem(
                channelID: channel.id,
                channelName: channel.name,
                streamURL: channel.streamURL,
                programmeID: programme.id,
                programmeTitle: programme.title,
                programmeSubTitle: programme.subTitle,
                programmeDetail: programme.detail,
                seasonEpisode: programme.seasonEpisode,
                scheduledStart: programme.start,
                scheduledStop: programme.stop,
                actualStart: Date(),
                outputFilePath: destURL.path,
                status: .recording,
                isLiveRollOver: isLiveRollOver
            )
            recordings.insert(item, at: 0)
        }

        lastGrowthTime[item.id] = Date()
        lastRecordedBytes[item.id] = 0
        autoRestartCount[item.id] = 0
        activeOutputPaths[item.id] = item.outputFilePath
        launchFFmpeg(for: item, outputPath: item.outputFilePath, forceRefresh: true, ffmpegPath: ffmpegPath)
        saveRecordings()
        return item
    }

    @discardableResult
    func scheduleRecording(
        channel: GuideChannel,
        programme: GuideProgramme
    ) -> RecordingItem {
        if let existing = recordings.first(where: { $0.programmeID == programme.id && !$0.status.isTerminal }) {
            return existing
        }

        let dirURL = settingsStore.settings.recordingsDirectoryURL
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let destURL = RecordingFilenameGenerator.destinationFileURL(
            directory: dirURL,
            title: programme.title,
            subTitle: programme.subTitle,
            detail: programme.detail,
            seasonEpisode: programme.seasonEpisode,
            date: programme.start
        )

        let item = RecordingItem(
            channelID: channel.id,
            channelName: channel.name,
            streamURL: channel.streamURL,
            programmeID: programme.id,
            programmeTitle: programme.title,
            programmeSubTitle: programme.subTitle,
            programmeDetail: programme.detail,
            seasonEpisode: programme.seasonEpisode,
            scheduledStart: programme.start,
            scheduledStop: programme.stop,
            outputFilePath: destURL.path,
            status: .scheduled
        )
        recordings.insert(item, at: 0)
        saveRecordings()
        return item
    }

    /// Sets how many minutes early a scheduled recording starts. Pass nil to follow the global setting.
    func setStartLead(id: UUID, minutes: Int?) {
        guard let index = recordings.firstIndex(where: { $0.id == id }),
              recordings[index].status == .scheduled else { return }
        recordings[index].startLeadMinutes = minutes
        saveRecordings()
    }

    func stopRecording(id: UUID) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        var item = recordings[index]
        guard item.status == .recording else { return }

        item.actualStop = Date()
        recordings[index] = item

        launchingRecordings.remove(id)
        lastGrowthTime.removeValue(forKey: id)
        lastRecordedBytes.removeValue(forKey: id)
        activeOutputPaths.removeValue(forKey: id)
        autoRestartCount.removeValue(forKey: id)

        if let process = activeProcesses[id], let inputPipe = activeInputPipes[id] {
            let pid = process.processIdentifier

            // Send SIGINT directly to ffmpeg for immediate graceful exit and trailer flush
            kill(pid, SIGINT)

            // Signal clean quit to ffmpeg via stdin as well
            if let qData = "q\n".data(using: .utf8) {
                try? inputPipe.fileHandleForWriting.write(contentsOf: qData)
            }
            try? inputPipe.fileHandleForWriting.close()

            // Allow ffmpeg up to 4 seconds to finalize container, then terminate, then kill
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if process.isRunning {
                    process.terminate()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if process.isRunning {
                        kill(pid, SIGKILL)
                    }
                }
            }
        } else {
            finalizeRecording(id: id, success: true)
        }
    }

    func cancelRecording(id: UUID) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        let item = recordings[index]
        if item.status == .recording {
            stopRecording(id: id)
            recordings[index].status = .cancelled
        } else if item.status == .scheduled {
            recordings[index].status = .cancelled
        }
        saveRecordings()
    }

    func deleteRecording(id: UUID, deleteFile: Bool = false) {
        if let index = recordings.firstIndex(where: { $0.id == id }) {
            let item = recordings[index]
            if item.status == .recording {
                stopRecording(id: id)
            }
            if deleteFile {
                if !item.outputFilePath.isEmpty {
                    try? FileManager.default.removeItem(atPath: item.outputFilePath)
                }
                for part in item.partFilePaths ?? [] {
                    try? FileManager.default.removeItem(atPath: part)
                }
            }
            recordings.remove(at: index)
            saveRecordings()
        }
    }

    // MARK: - Guide Metadata Synchronization

    func syncScheduledRecordings(with channels: [GuideChannel]) {
        var didChange = false
        let dirURL = settingsStore.settings.recordingsDirectoryURL

        for index in recordings.indices {
            guard recordings[index].status == .scheduled else { continue }
            let item = recordings[index]

            // Match by programmeID or (channelID + start time window)
            guard let channel = channels.first(where: { $0.id == item.channelID }) else { continue }
            guard let programme = channel.programmes.first(where: { $0.id == item.programmeID }) ??
                                  channel.programmes.first(where: { abs($0.start.timeIntervalSince(item.scheduledStart)) < 120 }) else {
                continue
            }

            var itemChanged = false

            // Update programmeSubTitle if missing or changed
            if let sub = programme.subTitle, !sub.isEmpty, recordings[index].programmeSubTitle != sub {
                recordings[index].programmeSubTitle = sub
                itemChanged = true
            }

            // Update seasonEpisode if programme has a better/canonical format
            if let progSE = programme.seasonEpisode, !progSE.isEmpty {
                let existingSE = recordings[index].seasonEpisode ?? ""
                let existingHasSE = RecordingFilenameGenerator.extractSeasonEpisode(from: existingSE) != nil
                let newHasSE = RecordingFilenameGenerator.extractSeasonEpisode(from: progSE) != nil

                if newHasSE && (!existingHasSE || existingSE != progSE) {
                    recordings[index].seasonEpisode = progSE
                    itemChanged = true
                } else if recordings[index].seasonEpisode == nil || recordings[index].seasonEpisode?.isEmpty == true {
                    recordings[index].seasonEpisode = progSE
                    itemChanged = true
                }
            }

            // Update programmeDetail if missing
            if (recordings[index].programmeDetail == nil || recordings[index].programmeDetail?.isEmpty == true),
               let detail = programme.detail, !detail.isEmpty {
                recordings[index].programmeDetail = detail
                itemChanged = true
            }

            if itemChanged {
                let newDestURL = RecordingFilenameGenerator.destinationFileURL(
                    directory: dirURL,
                    title: recordings[index].programmeTitle,
                    subTitle: recordings[index].programmeSubTitle,
                    detail: recordings[index].programmeDetail,
                    seasonEpisode: recordings[index].seasonEpisode,
                    date: recordings[index].scheduledStart
                )
                recordings[index].outputFilePath = newDestURL.path
                didChange = true
            }
        }

        if didChange {
            print("[RecordingManager] Synchronized scheduled recordings with updated guide metadata")
            saveRecordings()
        }
    }

    // MARK: - Process Execution

    private func launchFFmpeg(
        for item: RecordingItem,
        outputPath: String? = nil,
        forceRefresh: Bool = false,
        ffmpegPath: String
    ) {
        if launchingRecordings.contains(item.id) {
            print("[RecordingManager] Launch already in progress for '\(item.programmeTitle)', ignoring duplicate.")
            return
        }
        launchingRecordings.insert(item.id)
        let outPath = outputPath ?? item.outputFilePath
        self.activeOutputPaths[item.id] = outPath
        self.executeFFmpeg(for: item, targetURL: item.streamURL, outputPath: outPath, ffmpegPath: ffmpegPath)
    }

    private func executeFFmpeg(
        for item: RecordingItem,
        targetURL: URL,
        outputPath: String,
        ffmpegPath: String
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        
        let urlString = targetURL.absoluteString.lowercased()
        let isHLS = urlString.contains(".m3u8") || targetURL.pathExtension.lowercased() == "m3u8"

        var args: [String] = [
            "-y",
            "-hide_banner",
            "-loglevel", "warning",
            "-fflags", "+genpts+discardcorrupt",
            "-i", targetURL.absoluteString
        ]

        if isHLS {
            // Live HLS streams can include #EXT-X-DISCONTINUITY tags,
            // shifting resolutions and resetting timestamps.
            // Using Apple Silicon hardware-accelerated VideoToolbox with standard 720p scaling
            // generates clean monotonic PTS and ensures uniform video dimensions across all parts.
            args.append(contentsOf: [
                "-vf", "scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,setsar=1",
                "-r", "30",
                "-c:v", "h264_videotoolbox",
                "-b:v", "3500k",
                "-c:a", "aac",
                "-b:a", "128k"
            ])
        } else {
            // MPEG-TS / HDHomeRun streams can be stream-copied losslessly
            args.append(contentsOf: [
                "-c", "copy"
            ])
        }

        args.append(contentsOf: [
            "-movflags", "+frag_keyframe+empty_moov+default_base_moof",
            outputPath
        ])

        process.arguments = args

        let inputPipe = Pipe()
        process.standardInput = inputPipe

        let errorPipe = Pipe()
        process.standardError = errorPipe

        // Continuous drain of standardError to prevent buffer saturation (64KB PIPE_BUF limit)
        // which causes ffmpeg to deadlock in write(2) and hang indefinitely.
        let errorBuffer = CircularDataBuffer(maxCapacity: 16384)

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            errorBuffer.append(chunk)
        }

        process.terminationHandler = { [weak self] proc in
            errorPipe.fileHandleForReading.readabilityHandler = nil
            let residual = errorPipe.fileHandleForReading.readDataToEndOfFile()
            errorBuffer.append(residual)
            let errorMsg = errorBuffer.stringValue()

            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.activeProcesses[item.id] === proc else {
                    // This process was already superseded or terminated intentionally
                    return
                }
                self.activeProcesses.removeValue(forKey: item.id)
                self.activeInputPipes.removeValue(forKey: item.id)

                let exitCode = proc.terminationStatus
                let success = (exitCode == 0 || exitCode == 255) // ffmpeg exits 255 on SIGINT / q

                let now = Date()
                if let currentItem = self.recordings.first(where: { $0.id == item.id }),
                   currentItem.status == .recording,
                   currentItem.actualStop == nil,
                   now < currentItem.scheduledStop.addingTimeInterval(-30) {
                    print("[RecordingManager] Process for '\(item.programmeTitle)' exited prematurely (code \(exitCode)). Recovering...")
                    self.recoverStalledRecording(id: item.id)
                } else {
                    self.finalizeRecording(id: item.id, success: success, error: success ? nil : errorMsg)
                }
            }
        }

        do {
            if let oldProc = activeProcesses.removeValue(forKey: item.id) {
                oldProc.terminationHandler = nil
                kill(oldProc.processIdentifier, SIGINT)
                oldProc.terminate()
            }
            try process.run()
            activeProcesses[item.id] = process
            activeInputPipes[item.id] = inputPipe
            launchingRecordings.remove(item.id)
        } catch {
            launchingRecordings.remove(item.id)
            print("[RecordingManager] Failed to launch ffmpeg: \(error)")
            finalizeRecording(id: item.id, success: false, error: error.localizedDescription)
        }
    }

    private func recoverStalledRecording(id: UUID) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        var item = recordings[index]
        guard item.status == .recording else { return }

        let now = Date()
        if now >= item.scheduledStop.addingTimeInterval(-30) {
            stopRecording(id: id)
            return
        }

        let retries = autoRestartCount[id] ?? 0
        guard retries < 15 else {
            print("[RecordingManager] Max auto-restarts reached for '\(item.programmeTitle)'. Stopping.")
            stopRecording(id: id)
            return
        }
        autoRestartCount[id] = retries + 1

        if let proc = activeProcesses.removeValue(forKey: id) {
            proc.terminationHandler = nil
            let oldPid = proc.processIdentifier
            kill(oldPid, SIGINT)
            proc.terminate()
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if proc.isRunning {
                    kill(oldPid, SIGKILL)
                }
            }
        }
        activeInputPipes.removeValue(forKey: id)

        let currentActivePath = activeOutputPaths[id] ?? item.outputFilePath
        var parts = item.partFilePaths ?? []

        if parts.isEmpty && currentActivePath == item.outputFilePath {
            let p1 = partFilePath(for: item.outputFilePath, partNumber: 1)
            if FileManager.default.fileExists(atPath: item.outputFilePath) {
                try? FileManager.default.moveItem(atPath: item.outputFilePath, toPath: p1)
                parts.append(p1)
            }
        } else if !parts.contains(currentActivePath) && FileManager.default.fileExists(atPath: currentActivePath) {
            parts.append(currentActivePath)
        }

        let nextPartNumber = parts.count + 1
        let nextPartPath = partFilePath(for: item.outputFilePath, partNumber: nextPartNumber)
        parts.append(nextPartPath)
        item.partFilePaths = parts
        recordings[index] = item
        saveRecordings()

        activeOutputPaths[id] = nextPartPath
        lastRecordedBytes[id] = 0
        lastGrowthTime[id] = now

        print("[RecordingManager] Launching recovery part \(nextPartNumber) for '\(item.programmeTitle)' at: \(nextPartPath)")
        if let ffmpegPath = ffmpegBinaryPath {
            launchFFmpeg(for: item, outputPath: nextPartPath, forceRefresh: true, ffmpegPath: ffmpegPath)
        }
    }

    private func partFilePath(for basePath: String, partNumber: Int) -> String {
        let ns = basePath as NSString
        let ext = ns.pathExtension
        let baseWithoutExt = ns.deletingPathExtension
        return "\(baseWithoutExt) - Part \(partNumber).\(ext)"
    }

    /// Concatenates recovery parts into the final file. Blocks on ffmpeg for a long time, so it must run off the main actor.
    nonisolated private static func mergeRecordingParts(parts: [String], path: String, ffmpegPath: String) {
        let validParts = parts.filter { FileManager.default.fileExists(atPath: $0) && ((try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? Int64) ?? 0) > 1024 }
        if validParts.count > 1 {
            let totalPartsBytes: Int64 = validParts.reduce(0) { total, part in
                let size = (try? FileManager.default.attributesOfItem(atPath: part)[.size] as? Int64) ?? 0
                return total + size
            }
            print("[RecordingManager] Merging \(validParts.count) parts (\(totalPartsBytes / 1_000_000) MB) into final file: \(path)...")
            let concatListPath = (path as NSString).deletingPathExtension + ".concat.txt"
            let concatLines = validParts.map { "file '\($0)'" }.joined(separator: "\n")
            if (try? concatLines.write(toFile: concatListPath, atomically: true, encoding: .utf8)) != nil {
                let tempMerged = (path as NSString).deletingPathExtension + ".merged.mp4"
                let concatProc = Process()
                concatProc.executableURL = URL(fileURLWithPath: ffmpegPath)
                concatProc.arguments = [
                    "-y", "-hide_banner", "-loglevel", "error",
                    "-f", "concat", "-safe", "0",
                    "-i", concatListPath,
                    "-c", "copy",
                    "-movflags", "+frag_keyframe+empty_moov+default_base_moof",
                    tempMerged
                ]
                try? concatProc.run()
                concatProc.waitUntilExit()

                var mergedSize = (try? FileManager.default.attributesOfItem(atPath: tempMerged)[.size] as? Int64) ?? 0
                let copySucceeded = concatProc.terminationStatus == 0 && mergedSize >= (totalPartsBytes * 75) / 100

                if !copySucceeded {
                    print("[RecordingManager] Direct copy concat truncated (\(mergedSize / 1_000_000) MB vs \(totalPartsBytes / 1_000_000) MB expected). Running robust MPEG-TS concat fallback...")
                    try? FileManager.default.removeItem(atPath: tempMerged)
                    
                    var tsFiles: [String] = []
                    for (i, part) in validParts.enumerated() {
                        let tsPath = (part as NSString).deletingPathExtension + "_\(i).ts"
                        let tsProc = Process()
                        tsProc.executableURL = URL(fileURLWithPath: ffmpegPath)
                        tsProc.arguments = [
                            "-y", "-hide_banner", "-loglevel", "error",
                            "-i", part,
                            "-c", "copy", "-bsf:v", "h264_mp4toannexb",
                            "-f", "mpegts", tsPath
                        ]
                        try? tsProc.run()
                        tsProc.waitUntilExit()
                        if FileManager.default.fileExists(atPath: tsPath) {
                            tsFiles.append(tsPath)
                        }
                    }

                    if !tsFiles.isEmpty {
                        let concatArg = "concat:" + tsFiles.joined(separator: "|")
                        let tsConcatProc = Process()
                        tsConcatProc.executableURL = URL(fileURLWithPath: ffmpegPath)
                        tsConcatProc.arguments = [
                            "-y", "-hide_banner", "-loglevel", "error",
                            "-i", concatArg,
                            "-c:v", "h264_videotoolbox", "-b:v", "3500k",
                            "-c:a", "aac", "-b:a", "128k",
                            "-movflags", "+faststart",
                            tempMerged
                        ]
                        try? tsConcatProc.run()
                        tsConcatProc.waitUntilExit()

                        for ts in tsFiles {
                            try? FileManager.default.removeItem(atPath: ts)
                        }
                    }
                    mergedSize = (try? FileManager.default.attributesOfItem(atPath: tempMerged)[.size] as? Int64) ?? 0
                }

                if FileManager.default.fileExists(atPath: tempMerged), mergedSize >= (totalPartsBytes * 50) / 100 {
                    try? FileManager.default.removeItem(atPath: path)
                    try? FileManager.default.moveItem(atPath: tempMerged, toPath: path)
                    try? FileManager.default.removeItem(atPath: concatListPath)
                    for part in validParts {
                        try? FileManager.default.removeItem(atPath: part)
                    }
                    print("[RecordingManager] Successfully concatenated all parts into \(path) (\(mergedSize / 1_000_000) MB)")
                } else {
                    print("[RecordingManager] Concat produced undersized file (\(mergedSize / 1_000_000) MB vs \(totalPartsBytes / 1_000_000) MB). Preserving individual parts.")
                    try? FileManager.default.removeItem(atPath: concatListPath)
                    try? FileManager.default.removeItem(atPath: tempMerged)
                }
            }
        }
    }

    private func finalizeRecording(id: UUID, success: Bool, error: String? = nil) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        // The scheduler re-checks every 2s and the merge is now asynchronous, so ignore repeat triggers
        // while a merge for this recording is already running.
        guard !finalizingRecordings.contains(id) else { return }
        let item = recordings[index]

        // If there were multiple parts recorded due to recovery, concatenate them into the final file
        // off the main actor; the merge re-encodes and can take minutes.
        if let parts = item.partFilePaths, parts.count > 1, let ffmpegPath = ffmpegBinaryPath {
            let path = item.outputFilePath
            finalizingRecordings.insert(id)
            Task { @MainActor [weak self] in
                await Task.detached(priority: .utility) {
                    Self.mergeRecordingParts(parts: parts, path: path, ffmpegPath: ffmpegPath)
                }.value
                self?.completeFinalization(id: id, success: success, error: error)
            }
            return
        }
        completeFinalization(id: id, success: success, error: error)
    }

    private func completeFinalization(id: UUID, success: Bool, error: String? = nil) {
        finalizingRecordings.remove(id)
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        var item = recordings[index]

        let path = item.outputFilePath

        let fileExists = FileManager.default.fileExists(atPath: path)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0

        item.actualStop = item.actualStop ?? Date()
        item.bytesRecorded = fileSize

        if item.status != .cancelled {
            // ffmpeg can exit with an odd status after repeated stop signals at the scheduled end even though the
            // file is complete, so a non-empty file at the scheduled stop time counts as success.
            let reachedScheduledStop = Date() >= item.scheduledStop.addingTimeInterval(-60)
            if (success || reachedScheduledStop) && fileExists && fileSize > 1024 {
                item.status = .completed
            } else {
                let reason = error ?? (fileSize <= 1024 ? "File empty or invalid" : "Process failed")
                item.status = .failed(reason: reason)
                item.errorMessage = reason
            }
        }

        recordings[index] = item
        saveRecordings()

        // Check for live roll-over:
        // If this recording was live or roll-over, and user is still watching the channel, start the next show!
        checkLiveRollOver(completedItem: item)
    }

    private func checkLiveRollOver(completedItem: RecordingItem) {
        guard settingsStore.settings.autoRecordNextShowOnSameChannel else { return }
        guard completedItem.isLiveRollOver || completedItem.actualStart != nil else { return }

        // Is user currently watching this channel?
        guard let watchingChannelID = currentlyWatchingChannelID?(), watchingChannelID == completedItem.channelID else {
            return
        }

        // Look up the current programme now airing on this channel
        guard let lookup = currentProgrammeLookup?(completedItem.channelID) else { return }
        let (channel, nextProgramme) = lookup

        // If next programme is different from the completed one, start recording it!
        if nextProgramme.id != completedItem.programmeID {
            print("[RecordingManager] Rolling over recording to next show: \(nextProgramme.title)")
            startRecording(channel: channel, programme: nextProgramme, isLiveRollOver: true)
        }
    }

    // MARK: - Scheduler Loop

    private func startScheduler() {
        schedulerTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    private func tick() {
        let now = Date()
        let maxConcurrent = max(1, settingsStore.settings.maxSimultaneousRecordings)

        // 0. Clean up any recordings marked .recording without a running process
        for item in recordings where item.status == .recording {
            if launchingRecordings.contains(item.id) {
                continue
            }
            if let proc = activeProcesses[item.id] {
                if !proc.isRunning {
                    if now < item.scheduledStop.addingTimeInterval(-30) {
                        recoverStalledRecording(id: item.id)
                    } else {
                        finalizeRecording(id: item.id, success: false, error: "Recording process exited unexpectedly")
                    }
                }
            } else {
                finalizeRecording(id: item.id, success: false, error: "No active process for recording")
            }
        }

        // 1. Check active recordings to update size, check stop time, and run watchdog
        for item in recordings where item.status == .recording {
            let currentPath = activeOutputPaths[item.id] ?? item.outputFilePath
            var currentSize: Int64 = 0
            if !currentPath.isEmpty {
                currentSize = (try? FileManager.default.attributesOfItem(atPath: currentPath)[.size] as? Int64) ?? 0
            }

            let previousPartsSize: Int64 = (item.partFilePaths ?? []).reduce(0) { total, partPath in
                guard partPath != currentPath else { return total }
                let partSize = (try? FileManager.default.attributesOfItem(atPath: partPath)[.size] as? Int64) ?? 0
                return total + partSize
            }

            if let idx = recordings.firstIndex(where: { $0.id == item.id }) {
                recordings[idx].bytesRecorded = previousPartsSize + currentSize
            }

            let lastSize = lastRecordedBytes[item.id] ?? 0
            if currentSize > lastSize {
                lastRecordedBytes[item.id] = currentSize
                lastGrowthTime[item.id] = now
            }

            // If past stop time + 5s buffer, stop normally
            if now >= item.scheduledStop.addingTimeInterval(5) {
                stopRecording(id: item.id)
                continue
            }

            // Watchdog: detect stream stalls (e.g. stream drops or network stall)
            if !launchingRecordings.contains(item.id) {
                let elapsedSinceStart = now.timeIntervalSince(item.actualStart ?? now)
                let stallTime = now.timeIntervalSince(lastGrowthTime[item.id] ?? item.actualStart ?? now)
                if elapsedSinceStart > 25.0 && stallTime >= 75.0 {
                    print("[RecordingManager] Recording '\(item.programmeTitle)' stalled (no data for \(Int(stallTime))s). Triggering auto-recovery...")
                    recoverStalledRecording(id: item.id)
                }
            }
        }

        // 2. Check scheduled recordings ready to start
        let globalLeadMinutes = max(0, settingsStore.settings.recordingStartLeadMinutes)
        let scheduledToStart = recordings.filter { item in
            item.status == .scheduled && now >= item.scheduledStart.addingTimeInterval(-5 - TimeInterval(max(0, item.startLeadMinutes ?? globalLeadMinutes) * 60)) && now < item.scheduledStop
        }

        for item in scheduledToStart {
            if activeRecordingsCount < maxConcurrent {
                if let ffmpegPath = ffmpegBinaryPath {
                    if let index = recordings.firstIndex(where: { $0.id == item.id }) {
                        recordings[index].status = .recording
                        recordings[index].actualStart = Date()
                        lastGrowthTime[item.id] = now
                        lastRecordedBytes[item.id] = 0
                        autoRestartCount[item.id] = 0
                        activeOutputPaths[item.id] = recordings[index].outputFilePath
                        launchFFmpeg(for: recordings[index], outputPath: recordings[index].outputFilePath, forceRefresh: true, ffmpegPath: ffmpegPath)
                        saveRecordings()
                    }
                }
            } else {
                print("[RecordingManager] Concurrent recording limit reached (\(activeRecordingsCount)/\(maxConcurrent)), holding '\(item.programmeTitle)'")
            }
        }

        // 3. Mark missed scheduled recordings as failed
        for item in recordings where item.status == .scheduled && now >= item.scheduledStop {
            if let index = recordings.firstIndex(where: { $0.id == item.id }) {
                recordings[index].status = .failed(reason: "Missed scheduled broadcast window")
                saveRecordings()
            }
        }
    }

    private func setupAppTerminationHandler() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for (id, process) in self.activeProcesses {
                    if let pipe = self.activeInputPipes[id], let data = "q\n".data(using: .utf8) {
                        try? pipe.fileHandleForWriting.write(contentsOf: data)
                    }
                    process.terminate()
                }
            }
        }
    }
}
