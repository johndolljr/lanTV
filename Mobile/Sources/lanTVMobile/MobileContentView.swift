import SwiftUI

private enum MobileTheme {
    static let background = LanTVDesignSystem.background
    static let panel = LanTVDesignSystem.panel
    static let accent = LanTVDesignSystem.accentGradient
}
struct MobileContentView: View {
    @Bindable var store: MobileStore
    @State private var showSettings = false
    @State private var showPlayer = false
    @FocusState private var searchFocused: Bool
    var body: some View {
        GeometryReader { geometry in
            let usesGuideGrid = geometry.size.width >= 760 || UIDevice.current.userInterfaceIdiom == .pad
            NavigationStack {
                VStack(spacing: 16) {
                    if usesGuideGrid {
                        wideNowPlaying(width: geometry.size.width)
                        timeline(availableWidth: geometry.size.width - 68)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        header(wide: false)
                        channelList(wide: false)
                    }
                }
                .padding(usesGuideGrid ? 16 : 14)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .background(LanTVDesignSystem.backgroundGradient.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { searchFocused = false }
                            .accessibilityIdentifier("dismiss-search-keyboard")
                    }
                }
                .onChange(of: store.selectedChannel?.id) { _, id in
                    if !usesGuideGrid, id != nil { showPlayer = true }
                }
                .sheet(isPresented: $showSettings) { MobileSettingsView(store: store) }
                .sheet(isPresented: $showPlayer) {
                    NavigationStack {
                        ScrollView { playerPanel(expanded: true).padding(16) }
                            .background(LanTVDesignSystem.backgroundGradient.ignoresSafeArea())
                            .navigationTitle("Now Watching")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Close") {
                                        store.stopPlayback()
                                        showPlayer = false
                                    }
                                }
                            }
                    }
                }
                .alert("Unable to Play", isPresented: Binding(get: { store.playerError != nil }, set: { if !$0 { store.playerError = nil } })) { Button("OK") { store.playerError = nil } } message: { Text(store.playerError ?? "") }
                .alert("lanTV Desktop Found", isPresented: Binding(get: { store.discoveredDesktop != nil }, set: { if !$0 { store.dismissDiscoveredDesktop() } })) {
                    Button("Not Now", role: .cancel) { store.dismissDiscoveredDesktop() }
                    Button("Add as Guide Source") { store.addDiscoveredDesktop() }
                } message: {
                    Text("Use \(store.discoveredDesktop?.name ?? "lanTV") for your guide and shared channel lock. Video will stream directly from each source.")
                }
            }
        }
        .overlay {
            if let approval = store.pendingUnlockApproval {
                unlockApprovalPrompt(approval)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .tint(.blue)
    }
    private func unlockApprovalPrompt(_ approval: MobileUnlockApproval) -> some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Label("Unlock requested", systemImage: "lock.open.fill")
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .foregroundStyle(.orange)
                Text(approval.deviceName)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                Text("is asking to unlock protected channels on your desktop.")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("Deny") { store.respondToUnlockApproval(approved: false) }
                        .buttonStyle(MobileChromeStyle())
                        .frame(maxWidth: .infinity)
                    Button("Approve") { store.respondToUnlockApproval(approved: true) }
                        .buttonStyle(MobileChromeStyle(primary: true))
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("approve-unlock-request")
                }
            }
            .padding(22)
            .frame(maxWidth: 440)
            .background(MobileTheme.panel, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.4), radius: 28, y: 12)
            .padding(24)
            .accessibilityIdentifier("unlock-approval-dialog")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func header(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11).fill(LanTVDesignSystem.accentGradient)
                        Image(systemName: "play.rectangle.on.rectangle.fill").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                    }
                    .frame(width: 38, height: 38)
                    .shadow(color: LanTVDesignSystem.accent.opacity(0.45), radius: 10)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("lanTV").font(.system(size: wide ? 34 : 27, weight: .bold, design: .rounded))
                        Text("Your guide. Every screen.").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if store.isLoading { ProgressView().controlSize(.small) }
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 20, height: 20) }
                    .buttonStyle(MobileChromeStyle()).accessibilityLabel("Refresh guide")
                Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 20, height: 20) }
                    .buttonStyle(MobileChromeStyle(primary: true)).accessibilityLabel("Settings").accessibilityIdentifier("mobile-settings")
            }
            HStack(spacing: 10) {
                if store.sources.count > 1 {
                    Menu {
                        ForEach(store.sources) { source in Button(source.name) { store.chooseSource(source.id) } }
                    } label: { Label(store.selectedSource?.name ?? "Source", systemImage: "server.rack").lineLimit(1) }
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                } else { Label(store.selectedSource?.name ?? "No source", systemImage: "server.rack").font(.system(size: 12, weight: .semibold, design: .rounded)) }
                Spacer()
            }
            Text(store.status).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary).lineLimit(3)
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 22).fill(LanTVDesignSystem.panelGradient)
                .overlay { LanTVSignalWave().clipShape(RoundedRectangle(cornerRadius: 22)) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(LanTVDesignSystem.panelBorder.opacity(0.65)))
    }
    private func channelList(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !wide {
                HStack {
                    Text("Channels").font(.system(size: 20, weight: .bold, design: .rounded))
                    Spacer()
                    Text("\(store.filteredChannels.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Channels & shows", text: $store.search)
                        .textFieldStyle(.plain).font(.subheadline)
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .onSubmit { searchFocused = false }
                        .padding(.horizontal, 7).padding(.vertical, 5)
                        .background(searchFocused ? LanTVDesignSystem.accent.opacity(0.3) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("mobile-search")
                }.padding(8)
                    .background(searchFocused ? Color.clear : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }
            if store.channels.isEmpty {
                ContentUnavailableView {
                    Label(store.selectedSource == nil ? "Connect Your Guide" : "No Channels", systemImage: "tv")
                } description: {
                    Text(store.selectedSource == nil ? "Connect to lanTV on your Mac, or add an XMLTV source." : "Refresh your guide or check the source address in Settings.")
                } actions: {
                    Button("Open Settings") { showSettings = true }.buttonStyle(MobileChromeStyle(primary: true))
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.filteredChannels) { channel in
                            Button {
                                searchFocused = false
                                store.select(channel)
                                if !wide && store.selectedChannel != nil && store.playerError == nil { showPlayer = true }
                            } label: { channelRow(channel) }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .refreshable { store.refresh() }
            }
        }
        .padding(14)
        .background(LanTVDesignSystem.panelGradient, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(LanTVDesignSystem.panelBorder.opacity(0.65)))
    }
    private func wideNowPlaying(width: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 20) {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(LanTVDesignSystem.accentGradient)
                    Image(systemName: "play.rectangle.on.rectangle.fill").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                }.frame(width: 36, height: 34)
                Text("lanTV").font(.system(size: 27, weight: .bold, design: .rounded)).tracking(-0.5)
                HStack(spacing: 6) {
                    Circle().fill(store.isUsingOfflineCache ? .orange : (store.selectedSource == nil ? .gray : LanTVDesignSystem.mint)).frame(width: 7, height: 7)
                    Text(store.selectedSource == nil ? "Searching" : (store.isUsingOfflineCache ? "Offline guide" : store.selectedSource?.name ?? "Connected"))
                        .lineLimit(1)
                }
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 9).padding(.vertical, 7)
                .background(Color(red: 0.10, green: 0.15, blue: 0.28), in: Capsule())
                if store.isLoading { ProgressView().controlSize(.small) }
                Spacer(minLength: 8)
                if store.sources.count > 1 {
                    Menu {
                        ForEach(store.sources) { source in Button(source.name) { store.chooseSource(source.id) } }
                    } label: { Label("Sources", systemImage: "server.rack") }
                        .buttonStyle(MobileChromeStyle())
                } else {
                    Button { showSettings = true } label: { Label("Sources", systemImage: "server.rack") }
                        .buttonStyle(MobileChromeStyle())
                }
                Button { store.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(MobileChromeStyle()).accessibilityLabel("Refresh guide")
                TextField("Search", text: $store.search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .focused($searchFocused).submitLabel(.search)
                    .onSubmit { searchFocused = false }
                    .padding(.horizontal, 8).padding(.vertical, 7)
                    .background(searchFocused ? LanTVDesignSystem.accent.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .frame(width: min(250, max(120, width * 0.15)))
                    .accessibilityIdentifier("mobile-search")
                Button { showSettings = true } label: { Label("Settings", systemImage: "slider.horizontal.3") }
                    .buttonStyle(MobileChromeStyle()).accessibilityIdentifier("mobile-settings")
            }

            HStack(spacing: 22) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 9) {
                        Circle().fill(LanTVDesignSystem.mint.opacity(0.45)).frame(width: 17, height: 17)
                        Text(store.selectedChannel?.name ?? "Choose a channel from the guide")
                            .font(.system(size: 23, weight: .bold, design: .rounded)).lineLimit(1)
                    }
                    Text(store.selectedChannel?.nowPlaying?.title ?? "Ready to watch")
                        .font(.system(size: 18, weight: .semibold, design: .rounded)).lineLimit(1)
                    HStack(spacing: 12) {
                        if let programme = store.selectedChannel?.nowPlaying {
                            Label("\(programme.start.formatted(date: .omitted, time: .shortened)) – \(programme.stop.formatted(date: .omitted, time: .shortened))", systemImage: "clock")
                        }
                        if let next = store.selectedChannel?.upcoming.first(where: { $0.start > Date() }) {
                            Text("Up next · \(next.title)").lineLimit(1)
                        }
                    }.font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                    Text(store.status).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if width < 1000 {
                    MobilePlayerView(store: store, miniPlayer: true)
                        .frame(width: min(300, width * 0.30))
                        .accessibilityIdentifier("ipad-mini-player")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if width >= 1000 {
            MobilePlayerView(store: store, miniPlayer: true)
                .frame(width: min(360, width * 0.25))
                .accessibilityIdentifier("ipad-mini-player")
        }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 22).fill(LanTVDesignSystem.panelGradient)
                .overlay { LanTVSignalWave().clipShape(RoundedRectangle(cornerRadius: 22)) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(LanTVDesignSystem.panelBorder.opacity(0.65)))
    }
    private func channelRow(_ channel: MobileChannel) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(MobileTheme.accent.opacity(0.22))
                if let url = channel.logoURL, !channel.isProtected {
                    AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { Text(channel.number).font(.system(size: 13, weight: .bold, design: .rounded)) }.padding(5)
                } else { Text(channel.number.isEmpty ? "TV" : channel.number).font(.system(size: 13, weight: .bold, design: .rounded)) }
            }.frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(channel.name).font(.system(size: 14, weight: .semibold, design: .rounded)).lineLimit(1)
                }
                Text(channel.nowPlaying?.title ?? "No programme information").font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.secondary).lineLimit(1)
                if let next = channel.programmes.first(where: { $0.start > Date() }) {
                    Text("\(next.start.formatted(date: .omitted, time: .shortened))  \(next.title)").font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "play.circle.fill").font(.system(size: 22)).foregroundStyle(.blue)
        }
        .padding(12)
        .background(store.selectedChannel?.id == channel.id ? LanTVDesignSystem.liveProgrammeGradient : LanTVDesignSystem.programmeGradient, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(store.selectedChannel?.id == channel.id ? LanTVDesignSystem.accent.opacity(0.8) : LanTVDesignSystem.panelBorder.opacity(0.4)))
        .contentShape(RoundedRectangle(cornerRadius: 15))
    }
    private func playerPanel(expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            MobilePlayerView(store: store, miniPlayer: true)
            if let channel = store.selectedChannel {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(channel.name).font(.system(size: 20, weight: .bold, design: .rounded))
                        Text(channel.nowPlaying?.title ?? "Live TV").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if expanded, let current = channel.nowPlaying {
                    Text(current.detail).font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(expanded ? Array(channel.upcoming.prefix(5)) : []) { programme in
                    HStack(alignment: .top, spacing: 14) {
                        Text(programme.start.formatted(date: .omitted, time: .shortened)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 65, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(programme.title).font(.subheadline.weight(.semibold))
                            if !programme.detail.isEmpty { Text(programme.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                        }
                    }.padding(.vertical, 6)
                }
            }
        }
    }
    private func timeline(availableWidth: CGFloat) -> some View {
        let origin = Calendar.current.dateInterval(of: .hour, for: Date())?.start ?? Date()
        let visibleHours = 3
        let end = origin.addingTimeInterval(Double(visibleHours) * 3600)
        let channelColumnWidth: CGFloat = 136
        let timelineWidth = max(1, availableWidth - channelColumnWidth - 24)
        let pointsPerSecond = timelineWidth / CGFloat(visibleHours * 3600)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("The Guide").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("\(store.filteredChannels.count) channels").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Label("Live Guide", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(LanTVDesignSystem.mint)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(LanTVDesignSystem.mint.opacity(0.1), in: Capsule())
            }
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("CHANNEL").frame(width: 136, alignment: .leading)
                        HStack(spacing: 0) {
                            ForEach(0..<visibleHours, id: \.self) { offset in
                                Text(origin.addingTimeInterval(Double(offset) * 3600).formatted(date: .omitted, time: .shortened)).frame(width: 3600 * pointsPerSecond, alignment: .leading)
                            }
                        }
                    }.font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.secondary).padding(.bottom, 4)
                    ForEach(store.filteredChannels) { channel in
                        HStack(spacing: 8) {
                            Button { store.select(channel) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(channel.number).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    Text(channel.name).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(2)
                                }.frame(width: 120, height: 64, alignment: .leading).padding(.horizontal, 8)
                            }
                            .buttonStyle(.plain)
                            .background(store.selectedChannel?.id == channel.id ? LanTVDesignSystem.liveProgrammeGradient : LanTVDesignSystem.programmeGradient, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(store.selectedChannel?.id == channel.id ? LanTVDesignSystem.accent : LanTVDesignSystem.panelBorder.opacity(0.45), lineWidth: 1))
                            .shadow(color: store.selectedChannel?.id == channel.id ? LanTVDesignSystem.accent.opacity(0.4) : .clear, radius: 6)
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.02))
                                ForEach(channel.programmes.filter { $0.stop > origin && $0.start < end }) { programme in
                                    let cellStart = max(programme.start, origin)
                                    let cellEnd = min(programme.stop, end)
                                    let width = max(1, CGFloat(cellEnd.timeIntervalSince(cellStart)) * pointsPerSecond - 4)
                                    Button { store.select(channel) } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(programme.title).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(2)
                                            Text("\(programme.start.formatted(date: .omitted, time: .shortened)) – \(programme.stop.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                        }.padding(.horizontal, min(12, width / 4)).frame(width: width, height: 64, alignment: .leading)
                                            .background(programme.id == channel.nowPlaying?.id ? LanTVDesignSystem.liveProgrammeGradient : LanTVDesignSystem.programmeGradient, in: RoundedRectangle(cornerRadius: 10))
                                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(programme.id == channel.nowPlaying?.id ? LanTVDesignSystem.accent.opacity(0.55) : LanTVDesignSystem.panelBorder.opacity(0.4), lineWidth: 1))
                                            .clipped()
                                    }.buttonStyle(.plain).offset(x: CGFloat(cellStart.timeIntervalSince(origin)) * pointsPerSecond)
                                }
                                Rectangle().fill(LanTVDesignSystem.mint).frame(width: 2).shadow(color: LanTVDesignSystem.mint, radius: 5).offset(x: CGFloat(Date().timeIntervalSince(origin)) * pointsPerSecond)
                            }.frame(width: timelineWidth, height: 64)
                        }
                    }
                }
                .frame(width: channelColumnWidth + timelineWidth + 8, alignment: .topLeading)
            }
            .defaultScrollAnchor(.topLeading)
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.visible)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 22).fill(LanTVDesignSystem.panelGradient)
                .overlay { LanTVSignalWave(guide: true).clipShape(RoundedRectangle(cornerRadius: 22)) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(LanTVDesignSystem.panelBorder.opacity(0.65)))
    }

}

struct MobileChromeStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 12).padding(.vertical, 10)
            .foregroundStyle(.white)
            .background(primary ? AnyShapeStyle(MobileTheme.accent) : AnyShapeStyle(LanTVDesignSystem.programmeGradient), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(LanTVDesignSystem.panelBorder.opacity(0.65)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct MobileSettingsView: View {
    @Bindable var store: MobileStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = MobileSource(name: "Home Desktop", kind: .desktop, url: "", streamTemplate: "")
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Your Sources") {
                    ForEach(store.sources) { source in
                        Button { draft = source } label: {
                            HStack { VStack(alignment: .leading) { Text(source.name).foregroundStyle(.primary); Text(source.url).font(.caption).foregroundStyle(.secondary) }; Spacer(); if source.id == store.selectedSourceID { Image(systemName: "checkmark.circle.fill") } }
                        }
                    }.onDelete { indexes in let ids = indexes.map { store.sources[$0].id }; for id in ids { store.removeSource(id) } }
                    Button("Add Another Source", systemImage: "plus") { draft = MobileSource(name: "New Source", kind: .desktop, url: "", streamTemplate: "") }
                }
                Section("Source Details") {
                    TextField("Name", text: $draft.name)
                    Picker("Source Type", selection: $draft.kind) { Text("Desktop Server").tag(MobileSource.Kind.desktop); Text("XMLTV").tag(MobileSource.Kind.xmltv) }
                    TextField(draft.kind == .desktop ? "http://desktop.lan:48921" : "http://source.lan/guide.xml", text: $draft.url)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    if draft.kind == .xmltv {
                        TextField("http://source.lan/video?channel={channel}", text: $draft.streamTemplate, axis: .vertical).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        Text("Use {channel} for the XMLTV channel ID. A template is optional when the guide includes stream-url elements.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Enter the Local API address shown on your Mac. Guide data comes from the desktop; video streams directly from the original source.").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Save & Connect") {
                        do { try store.saveSource(draft); dismiss() } catch { self.error = error.localizedDescription }
                    }.buttonStyle(MobileChromeStyle(primary: true))
                }
                Section("Protected Channels") {
                    if let state = store.desktopState, store.selectedSource?.kind == .desktop {
                        LabeledContent("Status", value: state.areProtectedChannelsUnlocked ? "Unlocked" : "Locked")
                        if state.protectedChannelCount > 0 {
                            LabeledContent("Protected channels", value: "\(state.protectedChannelCount)")
                        }
                        if store.canRequestUnlock {
                            Button(store.isRequestingUnlock ? "Unlocking…" : (store.isApprover ? "Unlock Channels" : "Request Unlock")) {
                                store.requestUnlock()
                            }
                            .disabled(store.isRequestingUnlock)
                        } else if store.canRequestLock {
                            Button(store.isRequestingLock ? "Locking…" : "Lock Channels", role: .destructive) {
                                store.requestLock()
                            }
                            .disabled(store.isRequestingLock)
                        }
                        Text(store.isApprover
                             ? "This approved device can unlock or lock channels directly."
                             : "Unlock requests require approval on the desktop. If the desktop disconnects, protected playback stops.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Desktop sources share the Mac’s channel lock. If the desktop disconnects, protected playback stops.")
                    }
                    if store.isApprover {
                        Label("This device is approved to authorize channel locks", systemImage: "person.badge.key.fill").foregroundStyle(.green)
                    } else if store.canRequestApproverRights {
                        Button(store.isRequestingApproverAccess ? "Waiting for Desktop Approval…" : "Request Approver Access") { store.requestApproverRights() }
                            .disabled(store.isRequestingApproverAccess)
                    }
                    if let message = store.approverMessage { Text(message).foregroundStyle(.secondary) }
                    if let message = store.unlockMessage { Text(message).foregroundStyle(.secondary) }
                    Text("Standalone XMLTV sources are independent of desktop channel rules.").foregroundStyle(.secondary)
                }.font(.footnote)
            }
            .scrollContentBackground(.hidden).background(MobileTheme.background)
            .navigationTitle("lanTV Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Check Source", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }
        .onAppear { if let source = store.selectedSource { draft = source } }
    }
}
