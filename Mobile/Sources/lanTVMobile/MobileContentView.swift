import SwiftUI

private enum MobileTheme {
    static let background = Color(red: 0.025, green: 0.045, blue: 0.09)
    static let panel = Color(red: 0.065, green: 0.095, blue: 0.15)
    static let accent = LinearGradient(colors: [Color(red: 0.13, green: 0.53, blue: 1), Color(red: 0.42, green: 0.22, blue: 1)], startPoint: .leading, endPoint: .trailing)
}
struct MobileContentView: View {
    @Bindable var store: MobileStore
    @State private var showSettings = false
    @State private var showPlayer = false
    @FocusState private var searchFocused: Bool
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 760
            NavigationStack {
                VStack(spacing: 16) {
                    if wide {
                        wideNowPlaying(width: geometry.size.width)
                        timeline.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        header(wide: false)
                        channelList(wide: false)
                    }
                }
                .padding(wide ? 16 : 14)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .background(MobileTheme.background.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { searchFocused = false }
                            .accessibilityIdentifier("dismiss-search-keyboard")
                    }
                }
                .onChange(of: store.selectedChannel?.id) { _, id in
                    if !wide, id != nil { showPlayer = true }
                }
                .sheet(isPresented: $showSettings) { MobileSettingsView(store: store) }
                .sheet(isPresented: $showPlayer) {
                    NavigationStack {
                        ScrollView { playerPanel(expanded: true).padding(16) }
                            .background(MobileTheme.background.ignoresSafeArea())
                            .navigationTitle("Now Watching")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showPlayer = false } } }
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
                VStack(alignment: .leading, spacing: 3) {
                    Text("lanTV").font(.system(size: wide ? 34 : 30, weight: .bold, design: .rounded))
                    Text("Your guide. Every screen.").font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
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
        .padding(16).background(MobileTheme.panel, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.08)))
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
                        .accessibilityIdentifier("mobile-search")
                }.padding(12).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
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
        .padding(14).background(MobileTheme.panel.opacity(0.7), in: RoundedRectangle(cornerRadius: 20))
    }
    private func wideNowPlaying(width: CGFloat) -> some View {
        HStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .center, spacing: 14) {
                    Text("lanTV").font(.system(size: 28, weight: .bold, design: .rounded))
                    if store.sources.count > 1 {
                        Menu {
                            ForEach(store.sources) { source in Button(source.name) { store.chooseSource(source.id) } }
                        } label: {
                            Label(store.selectedSource?.name ?? "Source", systemImage: "server.rack").lineLimit(1)
                        }.font(.system(size: 12, weight: .semibold, design: .rounded))
                    } else {
                        Label(store.selectedSource?.name ?? "No guide source", systemImage: "server.rack")
                            .font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                    }
                    if store.isLoading { ProgressView().controlSize(.small) }
                    Spacer(minLength: 0)
                    Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(MobileChromeStyle()).accessibilityLabel("Refresh guide")
                    Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .buttonStyle(MobileChromeStyle(primary: true)).accessibilityLabel("Settings").accessibilityIdentifier("mobile-settings")
                }
                HStack(spacing: 9) {
                    Text(store.selectedChannel?.number ?? "LIVE")
                        .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(.blue)
                    Text(store.selectedChannel?.name ?? "Choose a channel from the guide")
                        .font(.system(size: 22, weight: .bold, design: .rounded)).lineLimit(1)
                }
                Text(store.selectedChannel?.nowPlaying?.title ?? "Ready to watch")
                    .font(.system(size: 18, weight: .semibold, design: .rounded)).lineLimit(1)
                if let detail = store.selectedChannel?.nowPlaying?.detail, !detail.isEmpty {
                    Text(detail).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 12) {
                    if let programme = store.selectedChannel?.nowPlaying {
                        Label("\(programme.start.formatted(date: .omitted, time: .shortened)) – \(programme.stop.formatted(date: .omitted, time: .shortened))", systemImage: "clock")
                    }
                    if let next = store.selectedChannel?.upcoming.first(where: { $0.start > Date() }) {
                        Text("Up next · \(next.title)").lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(store.status).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MobilePlayerView(store: store)
                .frame(width: min(360, width * 0.32))
                .accessibilityIdentifier("ipad-mini-player")
        }
        .padding(14)
        .background(MobileTheme.panel, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.08)))
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
        .padding(12).background(.white.opacity(store.selectedChannel?.id == channel.id ? 0.1 : 0.04), in: RoundedRectangle(cornerRadius: 15))
        .contentShape(RoundedRectangle(cornerRadius: 15))
    }
    private func playerPanel(expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            MobilePlayerView(store: store)
            if let channel = store.selectedChannel {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(channel.name).font(.system(size: 20, weight: .bold, design: .rounded))
                        Text(channel.nowPlaying?.title ?? "Live TV").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { store.stopPlayback() } label: { Image(systemName: "stop.fill") }.buttonStyle(MobileChromeStyle()).accessibilityLabel("Stop playback")
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
    private var timeline: some View {
        let origin = Calendar.current.dateInterval(of: .hour, for: Date())?.start ?? Date()
        let visibleHours = 8
        let end = origin.addingTimeInterval(Double(visibleHours) * 3600)
        let pointsPerSecond: CGFloat = 0.06
        let channelColumnWidth: CGFloat = 136
        let timelineWidth = CGFloat(visibleHours * 3600) * pointsPerSecond
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("TV Guide").font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("\(store.filteredChannels.count) channels").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search channels & shows", text: $store.search)
                        .textFieldStyle(.plain).font(.subheadline)
                        .focused($searchFocused).submitLabel(.search)
                        .onSubmit { searchFocused = false }
                        .accessibilityIdentifier("mobile-search")
                    if !store.search.isEmpty {
                        Button { store.search = ""; searchFocused = false } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("Clear guide search")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: 320)
                Spacer(minLength: 0)
                Label("Live", systemImage: "dot.radiowaves.left.and.right").font(.caption).foregroundStyle(.blue)
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
                            }.buttonStyle(.plain)
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
                                            .background(MobileTheme.accent.opacity(programme.id == channel.nowPlaying?.id ? 0.25 : 0.09), in: RoundedRectangle(cornerRadius: 12))
                                            .clipped()
                                    }.buttonStyle(.plain).offset(x: CGFloat(cellStart.timeIntervalSince(origin)) * pointsPerSecond)
                                }
                                Rectangle().fill(Color.blue).frame(width: 1).offset(x: CGFloat(Date().timeIntervalSince(origin)) * pointsPerSecond)
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
        }.padding(18).background(MobileTheme.panel, in: RoundedRectangle(cornerRadius: 22))
    }

}

struct MobileChromeStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 12).padding(.vertical, 10)
            .foregroundStyle(.white)
            .background(primary ? AnyShapeStyle(MobileTheme.accent) : AnyShapeStyle(Color.white.opacity(0.09)), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
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
