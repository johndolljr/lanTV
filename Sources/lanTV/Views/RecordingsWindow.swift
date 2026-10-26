import AppKit
import SwiftUI

@MainActor
final class RecordingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var viewModel: GuideViewModel?

    func show(viewModel: GuideViewModel) {
        self.viewModel = viewModel

        if let window {
            updateRootView(recordingManager: viewModel.recordingManager, settingsStore: viewModel.settingsStore)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = RecordingsWindowRootView(
            recordingManager: viewModel.recordingManager,
            settingsStore: viewModel.settingsStore,
            onClose: { [weak self] in
                self?.close()
            },
            onPlay: { [weak viewModel] item in
                viewModel?.playRecording(item)
            }
        )

        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Recordings"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.isMovableByWindowBackground = true
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.delegate = self
        window.setContentSize(NSSize(width: 800, height: 560))
        window.minSize = NSSize(width: 650, height: 420)

        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        guard let window else { return }
        window.close()
        self.window = nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    private func updateRootView(recordingManager: RecordingManager, settingsStore: AppSettingsStore) {
        guard let hostingController = window?.contentViewController as? NSHostingController<RecordingsWindowRootView> else {
            return
        }
        hostingController.rootView = RecordingsWindowRootView(
            recordingManager: recordingManager,
            settingsStore: settingsStore,
            onClose: { [weak self] in
                self?.close()
            },
            onPlay: { [weak viewModel] item in
                viewModel?.playRecording(item)
            }
        )
    }
}

private struct RecordingsWindowRootView: View {
    let recordingManager: RecordingManager
    let settingsStore: AppSettingsStore
    let onClose: () -> Void
    let onPlay: (RecordingItem) -> Void

    var body: some View {
        RecordingsView(
            recordingManager: recordingManager,
            settingsStore: settingsStore,
            onClose: onClose,
            onPlay: onPlay
        )
    }
}

struct RecordingsView: View {
    let recordingManager: RecordingManager
    let settingsStore: AppSettingsStore
    let onClose: () -> Void
    let onPlay: (RecordingItem) -> Void

    @State private var selectedFilter: FilterTab = .all
    @State private var itemToDelete: RecordingItem?
    @State private var showDeleteConfirmation = false

    enum FilterTab: String, CaseIterable, Identifiable {
        case all = "All"
        case active = "Active"
        case scheduled = "Scheduled"
        case completed = "Completed"

        var id: String { rawValue }
    }

    private var filteredRecordings: [RecordingItem] {
        let items = recordingManager.recordings
        switch selectedFilter {
        case .all:
            return items
        case .active:
            return items.filter { $0.status == .recording }
        case .scheduled:
            return items.filter { $0.status == .scheduled }
        case .completed:
            return items.filter { $0.status == .completed || $0.status.isTerminal }
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.05, blue: 0.11),
                    Color(red: 0.05, green: 0.09, blue: 0.16),
                    Color(red: 0.04, green: 0.07, blue: 0.14)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("Recordings & DVR")
                                .font(.system(size: 20, weight: .bold))
                            
                            let activeCount = recordingManager.activeRecordingsCount
                            if activeCount > 0 {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 8, height: 8)
                                    Text("\(activeCount) Active")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.red)
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.red.opacity(0.14))
                                .clipShape(Capsule())
                            }
                        }

                        Text("Scheduled and completed broadcasts saved to disk.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        let folderURL = settingsStore.settings.recordingsDirectoryURL
                        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(folderURL)
                    } label: {
                        Label("Open Folder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

                Divider()

                // Warning if ffmpeg missing
                if !recordingManager.isFFmpegAvailable {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("FFmpeg binary was not found. Recording requires ffmpeg (e.g. `brew install ffmpeg`).")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button("Recheck") {
                            recordingManager.locateFFmpeg()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.12))
                }

                // Filter Bar
                HStack {
                    HStack(spacing: 2) {
                        ForEach(FilterTab.allCases) { tab in
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedFilter = tab
                                }
                            } label: {
                                Text(tab.rawValue)
                                    .font(.system(size: 12, weight: selectedFilter == tab ? .semibold : .medium))
                                    .foregroundStyle(selectedFilter == tab ? Color.white : Color.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(selectedFilter == tab ? Color.accentColor : Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(width: 320)

                    Spacer()

                    let maxRec = settingsStore.settings.maxSimultaneousRecordings
                    Text("Limit: \(maxRec) concurrent")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)

                Divider()

                // List
                if filteredRecordings.isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "record.circle")
                            .font(.system(size: 42))
                            .foregroundStyle(.tertiary)
                        Text(emptyStateText)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("Click the Record button while watching or select 'Record' on any guide listing.")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(filteredRecordings) { item in
                                RecordingRow(
                                    item: item,
                                    onStop: {
                                        recordingManager.stopRecording(id: item.id)
                                    },
                                    onCancel: {
                                        recordingManager.cancelRecording(id: item.id)
                                    },
                                    globalLeadMinutes: settingsStore.settings.recordingStartLeadMinutes,
                                    onSetStartLead: { minutes in
                                        recordingManager.setStartLead(id: item.id, minutes: minutes)
                                    },
                                    onDelete: {
                                        itemToDelete = item
                                        showDeleteConfirmation = true
                                    },
                                    onPlay: {
                                        onPlay(item)
                                    },
                                    onRevealInFinder: {
                                        let url = URL(fileURLWithPath: item.outputFilePath)
                                        NSWorkspace.shared.activateFileViewerSelecting([url])
                                    }
                                )
                            }
                        }
                        .padding(16)
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete Recording?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete and Keep File", role: .none) {
                if let item = itemToDelete {
                    recordingManager.deleteRecording(id: item.id, deleteFile: false)
                }
            }
            Button("Delete and Move File to Trash", role: .destructive) {
                if let item = itemToDelete {
                    recordingManager.deleteRecording(id: item.id, deleteFile: true)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            if let item = itemToDelete {
                Text("Do you want to delete '\(item.programmeTitle)' from the recordings list?")
            }
        }
    }

    private var emptyStateText: String {
        switch selectedFilter {
        case .all: return "No Recordings Found"
        case .active: return "No Active Recordings"
        case .scheduled: return "No Scheduled Recordings"
        case .completed: return "No Completed Recordings"
        }
    }
}

private struct RecordingRow: View {
    let item: RecordingItem
    let onStop: () -> Void
    let onCancel: () -> Void
    let globalLeadMinutes: Int
    let onSetStartLead: (Int?) -> Void
    let onDelete: () -> Void
    let onPlay: () -> Void
    let onRevealInFinder: () -> Void

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // Status Icon / Badge
            statusIcon

            // Details
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.programmeTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let se = item.formattedSeasonEpisode, !se.isEmpty {
                        Text(se)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(se.starts(with: "S") ? Color.blue.opacity(0.15) : Color.indigo.opacity(0.15))
                            .foregroundStyle(se.starts(with: "S") ? .blue : .indigo)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    if item.isLiveRollOver {
                        Text("Auto Roll-over")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.12))
                            .foregroundStyle(.purple)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }

                if let subTitle = item.programmeSubTitle, !subTitle.isEmpty {
                    Text(subTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.85))
                        .lineLimit(1)
                }

                HStack(spacing: 12) {
                    Text(item.channelName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text("•")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

                    Text(timeSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if item.status == .recording {
                        Text("•")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)

                        Text("Duration: \(item.formattedDuration)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.red)

                        if !item.formattedFileSize.isEmpty {
                            Text("(\(item.formattedFileSize))")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    } else if item.status == .completed && !item.formattedFileSize.isEmpty {
                        Text("•")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)

                        Text(item.formattedFileSize)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                if let err = item.errorMessage, !err.isEmpty {
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer()

            // Action Buttons
            HStack(spacing: 8) {
                switch item.status {
                case .recording:
                    Button {
                        onStop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)

                case .scheduled:
                    Menu {
                        Button(globalLeadMinutes == 0 ? "Default (off)" : "Default (\(globalLeadMinutes) min)") { onSetStartLead(nil) }
                        Divider()
                        Button("Off") { onSetStartLead(0) }
                        ForEach([1, 2, 5, 10, 15, 30], id: \.self) { minutes in
                            Button("\(minutes) min early") { onSetStartLead(minutes) }
                        }
                    } label: {
                        Label(startLeadLabel, systemImage: "clock.arrow.circlepath")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Start this recording early")

                    Button {
                        onCancel()
                    } label: {
                        Text("Cancel")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                case .completed:
                    if item.outputFileExists {
                        Button {
                            onPlay()
                        } label: {
                            Label("Play", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button {
                            onRevealInFinder()
                        } label: {
                            Label("Finder", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(4)

                case .failed, .cancelled:
                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(4)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(item.status == .recording ? Color.red.opacity(0.3) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .help(item.outputFilePath.isEmpty ? item.programmeTitle : URL(fileURLWithPath: item.outputFilePath).lastPathComponent)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .recording:
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.2))
                    .frame(width: 32, height: 32)
                Circle()
                    .fill(Color.red)
                    .frame(width: 12, height: 12)
            }
        case .scheduled:
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: "clock")
                    .font(.system(size: 14))
                    .foregroundStyle(.blue)
            }
        case .completed:
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.green)
            }
        case .failed:
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: "exclamationmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.orange)
            }
        case .cancelled:
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 32, height: 32)
                Image(systemName: "xmark")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var startLeadLabel: String {
        let minutes = item.startLeadMinutes ?? globalLeadMinutes
        return minutes == 0 ? "On time" : "\(minutes) min early"
    }

    private var timeSubtitle: String {
        switch item.status {
        case .scheduled:
            return "\(Self.dateFormatter.string(from: item.scheduledStart)) – \(Self.timeFormatter.string(from: item.scheduledStop))"
        case .recording:
            return "Started \(Self.timeFormatter.string(from: item.actualStart ?? item.scheduledStart))"
        case .completed, .failed, .cancelled:
            if let start = item.actualStart {
                return Self.dateFormatter.string(from: start)
            }
            return Self.dateFormatter.string(from: item.scheduledStart)
        }
    }
}

