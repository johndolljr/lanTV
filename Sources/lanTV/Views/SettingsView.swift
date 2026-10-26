import SwiftUI

struct SettingsView: View {
    private enum SettingsTab: String, CaseIterable, Identifiable {
        case sources = "Sources"
        case plugins = "Plugins"
        case behavior = "Behavior"

        var id: String { rawValue }

        var iconName: String {
            switch self {
            case .sources:
                return "square.stack.3d.up"
            case .plugins:
                return "puzzlepiece.extension"
            case .behavior:
                return "slider.horizontal.3"
            }
        }

        var title: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss

    private struct SourceDraftItem: Identifiable {
        let id: UUID
        var source: GuideSource
        let originalID: String
    }

    @State private var draft: AppSettings
    @State private var sourceDraftItems: [SourceDraftItem]
    @State private var selectedTab: SettingsTab = .sources
    @State private var localAPIPortText: String
    @State private var fetchedChannelsBySourceID: [String: [GuideChannel]] = [:]
    @State private var isFetchingBySourceID: [String: Bool] = [:]
    @State private var fetchErrorBySourceID: [String: String] = [:]
    @State private var focusedSourceItemID: UUID?
    let channels: [GuideChannel]
    let areAdultChannelsUnlocked: Bool
    let onAdultUnlockRequest: () -> Void
    let onAdultLockRequest: () -> Void
    let onFetchChannels: (GuideSource) async throws -> [GuideChannel]
    let onSave: (AppSettings) -> Void
    let onCancel: (() -> Void)?

    init(
        settings: AppSettings,
        channels: [GuideChannel],
        areAdultChannelsUnlocked: Bool,
        onAdultUnlockRequest: @escaping () -> Void,
        onAdultLockRequest: @escaping () -> Void,
        onFetchChannels: @escaping (GuideSource) async throws -> [GuideChannel] = { _ in [] },
        onSave: @escaping (AppSettings) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        _draft = State(initialValue: settings)
        _sourceDraftItems = State(initialValue: settings.sources.map {
            SourceDraftItem(id: UUID(), source: $0, originalID: $0.id)
        })
        _localAPIPortText = State(initialValue: String(settings.localAPIPort))
        self.channels = channels
        self.areAdultChannelsUnlocked = areAdultChannelsUnlocked
        self.onAdultUnlockRequest = onAdultUnlockRequest
        self.onAdultLockRequest = onAdultLockRequest
        self.onFetchChannels = onFetchChannels
        self.onSave = onSave
        self.onCancel = onCancel
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

            VStack(alignment: .leading, spacing: 22) {
                header

                HStack(alignment: .top, spacing: 22) {
                    tabRail

                    ScrollView {
                        currentTabContent
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)

                HStack {
                    Spacer()
                    actionBar
                }
            }
            .padding(28)
        }
        .frame(width: 940, height: 760)
        .toolbar(.hidden, for: .windowToolbar)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("lanTV Settings")
                    .font(.system(size: 30, weight: .bold, design: .rounded))

                Text("Shape the guide, trim the channel list, and tune refresh behavior without touching code.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520, alignment: .leading)
            }

            Spacer()

            HStack(spacing: 10) {
                StatBadge(label: "Sources", value: "\(sourceDraftItems.count)")
                StatBadge(label: "Plugins", value: "\(draft.guidePlugins.count)")
                StatBadge(label: "Channels", value: "\(channels.count)")
                StatBadge(label: "Refresh", value: refreshLabel)
                Button(areAdultChannelsUnlocked ? "Lock" : "Unlock") {
                    if areAdultChannelsUnlocked {
                        onAdultLockRequest()
                    } else {
                        onAdultUnlockRequest()
                    }
                }
                .buttonStyle(SettingsActionButtonStyle(kind: .secondary))
            }
        }
    }

    private var tabRail: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: tab.iconName)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 18)

                        Text(tab.title)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(tabBackground(for: tab))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(
                                selectedTab == tab ? Color.blue.opacity(0.35) : Color.white.opacity(0.06),
                                lineWidth: 1
                            )
                    }
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .frame(width: 180)
    }

    @ViewBuilder
    private var currentTabContent: some View {
        switch selectedTab {
        case .sources:
            sourcesTab
        case .plugins:
            pluginsTab
        case .behavior:
            behaviorTab
        }
    }

    private var sourcesTab: some View {
        ScrollViewReader { scrollProxy in
            SectionCard(title: "Guide Sources", subtitle: "Manage each XMLTV or HDHomeRun feed and decide which channels appear in the guide.") {
                VStack(spacing: 16) {
                    sourceToolbar(scrollProxy: scrollProxy)

                    ForEach($sourceDraftItems) { $item in
                        SourceEditorCard(
                            source: $item.source,
                            channels: channelsForSource(item.source.id, originalID: item.originalID),
                            hiddenChannelIDs: hiddenChannelIDsBinding(for: item.source.id, originalID: item.originalID),
                            adultChannelIDs: adultChannelIDsBinding(for: item.source.id, originalID: item.originalID),
                            areAdultChannelsUnlocked: areAdultChannelsUnlocked,
                            isURLFocused: focusedSourceItemID == item.id,
                            isFetching: isFetchingBySourceID[item.source.id] == true,
                            fetchError: fetchErrorBySourceID[item.source.id],
                            onAdultUnlockRequest: onAdultUnlockRequest,
                            onFetchChannels: {
                                fetchChannels(for: item.source)
                            },
                            onRemove: {
                                let removedSourceID = item.source.id
                                let origID = item.originalID
                                sourceDraftItems.removeAll(where: { $0.id == item.id })
                                draft.excludedChannelIDsBySource.removeValue(forKey: removedSourceID)
                                draft.adultChannelIDsBySource.removeValue(forKey: removedSourceID)
                                draft.excludedChannelIDsBySource.removeValue(forKey: origID)
                                draft.adultChannelIDsBySource.removeValue(forKey: origID)
                                fetchedChannelsBySourceID.removeValue(forKey: removedSourceID)
                                isFetchingBySourceID.removeValue(forKey: removedSourceID)
                                fetchErrorBySourceID.removeValue(forKey: removedSourceID)
                            }
                        )
                        .id(item.id)
                    }
                }
            }
        }
    }

    private var pluginsTab: some View {
        SectionCard(title: "Guide Plugins", subtitle: "Attach scraped schedule providers to specific playback channels. Start small, then add more mappings as you prove the sources are stable.") {
            VStack(spacing: 16) {
                pluginToolbar

                ForEach(Array(draft.guidePlugins.enumerated()), id: \.element.id) { index, _ in
                    GuidePluginEditorCard(
                        plugin: pluginBinding(at: index),
                        channels: channels.sorted(by: compareGuideChannelOrder),
                        onRemove: {
                            draft.guidePlugins.remove(at: index)
                        }
                    )
                }
            }
        }
    }

    private var behaviorTab: some View {
        SectionCard(title: "Guide Behavior", subtitle: "Tune refresh timing, visible guide span, playback defaults, and the LAN API service.") {
            VStack(spacing: 16) {
                LabeledControlRow(
                    title: "Auto refresh",
                    subtitle: "The guide refreshes in the background while the cached guide stays visible."
                ) {
                    VStack(alignment: .trailing, spacing: 6) {
                        Slider(value: $draft.autoRefreshIntervalSeconds, in: 300...86_400, step: 300)
                        Text(refreshLabel)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 280)
                }

                Divider().overlay(Color.white.opacity(0.08))

                LabeledControlRow(
                    title: "Visible guide span",
                    subtitle: "Controls how many future hours are visible across the horizontal guide."
                ) {
                    Stepper(value: $draft.guideVisibleHours, in: 2...12) {
                        Text("\(draft.guideVisibleHours) hours")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    .frame(width: 160, alignment: .trailing)
                }

                Divider().overlay(Color.white.opacity(0.08))

                LabeledControlRow(
                    title: "Default volume",
                    subtitle: "Applied to both AVPlayer and embedded VLCKit playback."
                ) {
                    VStack(alignment: .trailing, spacing: 6) {
                        Slider(value: $draft.volume, in: 0...1)
                        Text("\(Int(draft.volume * 100))%")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .frame(width: 220)
                }

                Divider().overlay(Color.white.opacity(0.08))

                LabeledControlRow(
                    title: "Local API port",
                    subtitle: "Other devices on your LAN can fetch the merged guide, playlist, and app state from this port."
                ) {
                    TextField("48921", text: $localAPIPortText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 140)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .onChange(of: localAPIPortText) { _, newValue in
                            let digits = newValue.filter(\.isNumber)
                            if digits != newValue {
                                localAPIPortText = digits
                                return
                            }

                            guard let value = Int(digits) else { return }
                            draft.localAPIPort = min(max(value, 1024), 65535)
                        }
                }
            }
        }
    }

    private func tabBackground(for tab: SettingsTab) -> some ShapeStyle {
        if selectedTab == tab {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        Color.blue.opacity(0.30),
                        Color.cyan.opacity(0.16)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }

        return AnyShapeStyle(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.05),
                    Color.white.opacity(0.02)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private func sourceToolbar(scrollProxy: ScrollViewProxy) -> some View {
        HStack(spacing: 10) {
            Button {
                let newID = UUID()
                let nextIndex = sourceDraftItems.count + 1
                let newSource = GuideSource(
                    id: "XMLTV \(nextIndex)",
                    kind: .xmltv(
                        url: URL(string: "http://localhost:8000/xmltv.xml")!,
                        streamURLTemplate: "http://localhost:8000/video?channel={channel}"
                    )
                )
                let newItem = SourceDraftItem(id: newID, source: newSource, originalID: newSource.id)
                sourceDraftItems.append(newItem)
                focusedSourceItemID = newID
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        scrollProxy.scrollTo(newID, anchor: .bottom)
                    }
                }
            } label: {
                Label("Add XMLTV", systemImage: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(SettingsActionButtonStyle(kind: .secondary))

            Button {
                let newID = UUID()
                let nextIndex = sourceDraftItems.count + 1
                let newSource = GuideSource(
                    id: "HDHomeRun \(nextIndex)",
                    kind: .hdhomerun(URL(string: "http://hdhomerun.local/")!)
                )
                let newItem = SourceDraftItem(id: newID, source: newSource, originalID: newSource.id)
                sourceDraftItems.append(newItem)
                focusedSourceItemID = newID
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        scrollProxy.scrollTo(newID, anchor: .bottom)
                    }
                }
            } label: {
                Label("Add HDHomeRun", systemImage: "tv")
            }
            .buttonStyle(SettingsActionButtonStyle(kind: .secondary))

            Spacer()
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button("Cancel") {
                if let onCancel {
                    onCancel()
                } else {
                    dismiss()
                }
            }
            .buttonStyle(SettingsActionButtonStyle(kind: .ghost))

            Button("Save Changes") {
                if let typedPort = Int(localAPIPortText.filter(\.isNumber)) {
                    draft.localAPIPort = min(max(typedPort, 1024), 65535)
                } else {
                    draft.localAPIPort = Int(LocalAPIServer.defaultPort)
                }
                for item in sourceDraftItems {
                    if item.source.id != item.originalID {
                        if let excluded = draft.excludedChannelIDsBySource.removeValue(forKey: item.originalID) {
                            draft.excludedChannelIDsBySource[item.source.id] = excluded
                        }
                        if let adult = draft.adultChannelIDsBySource.removeValue(forKey: item.originalID) {
                            draft.adultChannelIDsBySource[item.source.id] = adult
                        }
                    }
                }
                draft.sources = sourceDraftItems.map(\.source)
                onSave(draft)
                if onCancel == nil {
                    dismiss()
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(SettingsActionButtonStyle(kind: .primary))
        }
    }

    private var refreshLabel: String {
        let seconds = Int(draft.autoRefreshIntervalSeconds)
        if seconds >= 86_400, seconds % 86_400 == 0 {
            let days = seconds / 86_400
            return days == 1 ? "1 day" : "\(days) days"
        }
        if seconds >= 3_600, seconds % 3_600 == 0 {
            let hours = seconds / 3_600
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        let minutes = seconds / 60
        return "\(minutes)m"
    }

    private func pluginBinding(at index: Int) -> Binding<GuidePlugin> {
        Binding(
            get: { draft.guidePlugins[index] },
            set: { draft.guidePlugins[index] = $0 }
        )
    }

    private func channelsForSource(_ sourceID: String, originalID: String) -> [GuideChannel] {
        if let fetched = fetchedChannelsBySourceID[sourceID], !fetched.isEmpty {
            return fetched.sorted(by: compareGuideChannelOrder)
        }
        return channels
            .filter { $0.sourceID == sourceID || $0.sourceID == originalID }
            .sorted(by: compareGuideChannelOrder)
    }

    private func fetchChannels(for source: GuideSource) {
        let sourceID = source.id
        isFetchingBySourceID[sourceID] = true
        fetchErrorBySourceID.removeValue(forKey: sourceID)

        Task {
            do {
                let loaded = try await onFetchChannels(source)
                await MainActor.run {
                    fetchedChannelsBySourceID[sourceID] = loaded
                    isFetchingBySourceID[sourceID] = false
                }
            } catch {
                await MainActor.run {
                    fetchErrorBySourceID[sourceID] = error.localizedDescription
                    isFetchingBySourceID[sourceID] = false
                }
            }
        }
    }

    private func hiddenChannelIDsBinding(for sourceID: String, originalID: String) -> Binding<[String]> {
        Binding(
            get: {
                draft.excludedChannelIDsBySource[sourceID] ??
                draft.excludedChannelIDsBySource[originalID] ?? []
            },
            set: { draft.excludedChannelIDsBySource[sourceID] = $0 }
        )
    }

    private func adultChannelIDsBinding(for sourceID: String, originalID: String) -> Binding<[String]> {
        Binding(
            get: {
                draft.adultChannelIDsBySource[sourceID] ??
                draft.adultChannelIDsBySource[originalID] ?? []
            },
            set: { draft.adultChannelIDsBySource[sourceID] = $0 }
        )
    }

    private var pluginToolbar: some View {
        HStack(spacing: 10) {
            Button {
                draft.guidePlugins.append(
                    GuidePlugin(
                        id: UUID().uuidString,
                        name: "New Listings Plugin",
                        isEnabled: true,
                        refreshIntervalSeconds: 21_600,
                        arguments: [:],
                        target: GuidePluginTarget(
                            sourceID: channels.first?.sourceID ?? "",
                            rawChannelID: channels.first?.rawChannelID ?? "1"
                        ),
                        kind: .external(
                            manifestPath: "tvpassport-station/plugin.json"
                        )
                    )
                )
            } label: {
                Label("Add Guide Plugin", systemImage: "puzzlepiece.extension")
            }
            .buttonStyle(SettingsActionButtonStyle(kind: .secondary))

            Spacer()
        }
    }
}

private struct SourceEditorCard: View {
    @Binding var source: GuideSource
    let channels: [GuideChannel]
    @Binding var hiddenChannelIDs: [String]
    @Binding var adultChannelIDs: [String]
    let areAdultChannelsUnlocked: Bool
    let isURLFocused: Bool
    let isFetching: Bool
    let fetchError: String?
    let onAdultUnlockRequest: () -> Void
    let onFetchChannels: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Source Name", text: Binding(
                        get: { source.id },
                        set: { source = GuideSource(id: $0, kind: source.kind) }
                    ))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(fieldBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    Text(source.displayName)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .trailing, spacing: 10) {
                    Picker("Type", selection: kindSelection) {
                        Text("XMLTV").tag(0)
                        Text("HDHomeRun").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)

                    Button("Remove Source", role: .destructive, action: onRemove)
                        .buttonStyle(SettingsActionButtonStyle(kind: .danger))
                }
            }

            VStack(spacing: 10) {
                switch source.kind {
                case .xmltv(let url, let streamURLTemplate):
                    LabeledTextField(
                        label: "XMLTV URL",
                        text: Binding(
                            get: { url.absoluteString },
                            set: { source = GuideSource(id: source.id, kind: .xmltv(url: URL(string: $0) ?? url, streamURLTemplate: streamURLTemplate)) }
                        ),
                        isFocused: isURLFocused,
                        onSubmit: onFetchChannels
                    )

                    LabeledTextField(
                        label: "Stream URL Template",
                        text: Binding(
                            get: { streamURLTemplate },
                            set: { source = GuideSource(id: source.id, kind: .xmltv(url: url, streamURLTemplate: $0)) }
                        ),
                        onSubmit: onFetchChannels
                    )
                case .hdhomerun(let url):
                    LabeledTextField(
                        label: "Device Base URL",
                        text: Binding(
                            get: { url.absoluteString },
                            set: { source = GuideSource(id: source.id, kind: .hdhomerun(URL(string: $0) ?? url)) }
                        ),
                        isFocused: isURLFocused,
                        onSubmit: onFetchChannels
                    )
                }

                HStack(spacing: 12) {
                    Button(action: onFetchChannels) {
                        HStack(spacing: 6) {
                            if isFetching {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(isFetching ? "Fetching Channels..." : (channels.isEmpty ? "Fetch Channels" : "Re-fetch Channels"))
                        }
                    }
                    .buttonStyle(SettingsActionButtonStyle(kind: .secondary))
                    .disabled(isFetching)

                    if let fetchError {
                        Label(fetchError, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }

                    Spacer()
                }
                .padding(.top, 2)
            }

            Divider().overlay(Color.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Channel Rules")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                        Text(ruleSummary)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if !channels.isEmpty {
                        Button(hiddenChannelIDs.isEmpty ? "Hide All" : "Show All") {
                            if hiddenChannelIDs.isEmpty {
                                hiddenChannelIDs = channels.map(\.rawChannelID)
                            } else {
                                hiddenChannelIDs = []
                            }
                        }
                        .buttonStyle(SettingsActionButtonStyle(kind: .ghost))
                    }

                    if areAdultChannelsUnlocked, !channels.isEmpty {
                        Button(adultChannelIDs.isEmpty ? "Mark None" : "Clear Locked") {
                            adultChannelIDs = []
                        }
                        .buttonStyle(SettingsActionButtonStyle(kind: .ghost))
                    } else {
                        Button("Unlock") {
                            onAdultUnlockRequest()
                        }
                        .buttonStyle(SettingsActionButtonStyle(kind: .ghost))
                    }
                }

                if channels.isEmpty {
                    Text("Load the guide to manage this source’s channel rules.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    VStack(spacing: 8) {
                        HStack(spacing: 12) {
                            Text("Channel")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("Hidden")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .frame(width: 60)
                            if areAdultChannelsUnlocked {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 60)
                            }
                        }
                        .padding(.horizontal, 12)

                        ForEach(channels, id: \.id) { channel in
                            HStack(spacing: 12) {
                                HStack(spacing: 8) {
                                    if channel.hasDisplayNumber {
                                        Text(channel.displayNumber)
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 42, alignment: .leading)
                                    }
                                    Text(channel.name)
                                        .font(.system(size: 13, weight: .medium, design: .rounded))
                                        .lineLimit(1)
                                }
                                Spacer()
                                Toggle("", isOn: hiddenBinding(for: channel.rawChannelID))
                                    .toggleStyle(.checkbox)
                                    .labelsHidden()
                                    .frame(width: 60)
                                if areAdultChannelsUnlocked {
                                    Toggle("", isOn: adultBinding(for: channel.rawChannelID))
                                        .toggleStyle(.checkbox)
                                        .labelsHidden()
                                        .frame(width: 60)
                                        .disabled(hiddenChannelIDs.contains(channel.rawChannelID))
                                        .opacity(hiddenChannelIDs.contains(channel.rawChannelID) ? 0.35 : 1)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(fieldBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private var fieldBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                Color.white.opacity(0.06),
                Color.white.opacity(0.025)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var cardBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                Color(red: 0.08, green: 0.11, blue: 0.18).opacity(0.94),
                Color(red: 0.05, green: 0.08, blue: 0.14).opacity(0.97)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var channelSummary: String {
        let hiddenCount = min(hiddenChannelIDs.count, channels.count)
        let visibleCount = max(0, channels.count - hiddenCount)
        return "\(visibleCount) visible • \(hiddenCount) hidden"
    }

    private var adultSummary: String {
        let protectedCount = min(adultChannelIDs.count, channels.count)
        if protectedCount == 0 {
            return "No locked channels"
        }
        return "\(protectedCount) locked"
    }

    private var ruleSummary: String {
        if areAdultChannelsUnlocked {
            return "\(channelSummary) • \(adultSummary)"
        }
        return "\(channelSummary) • Locked channels hidden"
    }

    private var kindSelection: Binding<Int> {
        Binding(
            get: {
                switch source.kind {
                case .xmltv: return 0
                case .hdhomerun: return 1
                }
            },
            set: { newValue in
                switch newValue {
                case 0:
                    source = GuideSource(
                        id: source.id,
                        kind: .xmltv(
                            url: URL(string: "http://localhost:8000/xmltv.xml")!,
                            streamURLTemplate: "http://localhost:8000/video?channel={channel}"
                        )
                    )
                default:
                    source = GuideSource(
                        id: source.id,
                        kind: .hdhomerun(URL(string: "http://hdhomerun.local/")!)
                    )
                }
            }
        )
    }

    private func hiddenBinding(for rawChannelID: String) -> Binding<Bool> {
        Binding(
            get: { hiddenChannelIDs.contains(rawChannelID) },
            set: { isHidden in
                if isHidden {
                    if !hiddenChannelIDs.contains(rawChannelID) {
                        hiddenChannelIDs.append(rawChannelID)
                    }
                    adultChannelIDs.removeAll { $0 == rawChannelID }
                } else {
                    hiddenChannelIDs.removeAll { $0 == rawChannelID }
                }
            }
        )
    }

    private func adultBinding(for rawChannelID: String) -> Binding<Bool> {
        Binding(
            get: { adultChannelIDs.contains(rawChannelID) },
            set: { isAdult in
                guard !hiddenChannelIDs.contains(rawChannelID) else { return }
                if isAdult {
                    if !adultChannelIDs.contains(rawChannelID) {
                        adultChannelIDs.append(rawChannelID)
                    }
                } else {
                    adultChannelIDs.removeAll { $0 == rawChannelID }
                }
            }
        )
    }
}

private struct GuidePluginEditorCard: View {
    @Binding var plugin: GuidePlugin
    let channels: [GuideChannel]
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Plugin Name", text: $plugin.name)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(fieldBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    Text(plugin.providerLabel)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("Enabled", isOn: $plugin.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()

                Button("Remove Plugin", role: .destructive, action: onRemove)
                    .buttonStyle(SettingsActionButtonStyle(kind: .danger))
            }

            VStack(spacing: 10) {
                switch plugin.kind {
                case .external(let manifestPath):
                    LabeledTextField(label: "Plugin Manifest", text: Binding(
                        get: { manifestPath },
                        set: { plugin.kind = .external(manifestPath: $0) }
                    ))

                    LabeledTextField(label: "Arguments JSON", text: pluginArgumentsBinding)
                }
            }

            LabeledControlRow(
                title: "Plugin refresh interval",
                subtitle: "Scraper plugins refresh on their own cadence and use cached data between fetches."
            ) {
                Stepper(value: $plugin.refreshIntervalSeconds, in: 1800...86400, step: 1800) {
                    Text(pluginRefreshLabel)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                .frame(width: 220, alignment: .trailing)
            }

            Divider().overlay(Color.white.opacity(0.08))

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Target Channel")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text("Map this scraper onto an existing playback channel.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if channels.isEmpty {
                    Text("Load the guide first to choose a channel.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Target Channel", selection: selectedChannelBinding) {
                        ForEach(channels, id: \.id) { channel in
                            Text(channelOptionLabel(channel))
                                .tag(channel.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 340, alignment: .trailing)
                }
            }
        }
        .padding(18)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
    }

    private var selectedChannelBinding: Binding<String> {
        Binding(
            get: {
                channels.first(where: {
                    $0.sourceID == plugin.target.sourceID && $0.rawChannelID == plugin.target.rawChannelID
                })?.id ?? channels.first?.id ?? ""
            },
            set: { selectedID in
                guard let channel = channels.first(where: { $0.id == selectedID }) else { return }
                plugin.target = GuidePluginTarget(
                    sourceID: channel.sourceID,
                    rawChannelID: channel.rawChannelID
                )
            }
        )
    }

    private func channelOptionLabel(_ channel: GuideChannel) -> String {
        if channel.hasDisplayNumber {
            return "\(channel.displayNumber)  \(channel.name)  •  \(channel.sourceID)"
        } else {
            return "\(channel.name)  •  \(channel.sourceID)"
        }
    }

    private var pluginArgumentsBinding: Binding<String> {
        Binding(
            get: { pluginArgumentsJSON },
            set: { newValue in
                guard
                    let data = newValue.data(using: .utf8),
                    let parsed = try? JSONDecoder().decode([String: String].self, from: data)
                else {
                    return
                }
                plugin.arguments = parsed
            }
        )
    }

    private var pluginArgumentsJSON: String {
        guard
            let data = try? JSONEncoder().encode(plugin.arguments),
            let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }

    private var pluginRefreshLabel: String {
        let hours = plugin.refreshIntervalSeconds / 3600
        if hours >= 1 {
            return String(format: "%.1f hours", hours)
        }
        return "\(Int(plugin.refreshIntervalSeconds / 60)) minutes"
    }

    private var fieldBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                Color.white.opacity(0.06),
                Color.white.opacity(0.025)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var cardBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                Color(red: 0.08, green: 0.11, blue: 0.18).opacity(0.94),
                Color(red: 0.05, green: 0.08, blue: 0.14).opacity(0.97)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct SectionCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            content
        }
        .padding(22)
        .background(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.08),
                    Color.white.opacity(0.03)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .overlay {
            RoundedRectangle(cornerRadius: 26)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct LabeledControlRow<Control: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420, alignment: .leading)
            }

            Spacer()

            control
        }
    }
}

private struct LabeledTextField: View {
    let label: String
    @Binding var text: String
    var isFocused: Bool = false
    var onSubmit: (() -> Void)? = nil

    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(0.8)

            TextField(label, text: $text)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit {
                    onSubmit?()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.06),
                            Color.white.opacity(0.025)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(fieldFocused ? Color.blue.opacity(0.6) : Color.white.opacity(0.06), lineWidth: 1)
                }
        }
        .onAppear {
            if isFocused {
                DispatchQueue.main.async {
                    fieldFocused = true
                }
            }
        }
        .onChange(of: isFocused) { _, newValue in
            if newValue {
                DispatchQueue.main.async {
                    fieldFocused = true
                }
            }
        }
    }
}

private struct StatBadge: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.06))
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct SettingsActionButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case ghost
        case danger
    }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(background(configuration.isPressed))
            .foregroundStyle(foreground)
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(stroke, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary:
            return .white
        case .secondary, .ghost:
            return .primary
        case .danger:
            return Color(red: 1.0, green: 0.82, blue: 0.82)
        }
    }

    private var stroke: Color {
        switch kind {
        case .primary:
            return Color.white.opacity(0.10)
        case .secondary, .ghost:
            return Color.white.opacity(0.08)
        case .danger:
            return Color.red.opacity(0.22)
        }
    }

    private func background(_ isPressed: Bool) -> AnyShapeStyle {
        switch kind {
        case .primary:
            return AnyShapeStyle(LinearGradient(
                colors: [
                    Color(red: 0.16, green: 0.52, blue: 1.0).opacity(isPressed ? 0.82 : 1),
                    Color(red: 0.32, green: 0.22, blue: 1.0).opacity(isPressed ? 0.72 : 0.92)
                ],
                startPoint: .leading,
                endPoint: .trailing
            ))
        case .secondary:
            return AnyShapeStyle(LinearGradient(
                colors: [
                    Color.white.opacity(isPressed ? 0.08 : 0.12),
                    Color.white.opacity(isPressed ? 0.04 : 0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        case .ghost:
            return AnyShapeStyle(Color.white.opacity(isPressed ? 0.08 : 0.04))
        case .danger:
            return AnyShapeStyle(LinearGradient(
                colors: [
                    Color.red.opacity(isPressed ? 0.18 : 0.24),
                    Color.red.opacity(isPressed ? 0.10 : 0.14)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        }
    }
}
