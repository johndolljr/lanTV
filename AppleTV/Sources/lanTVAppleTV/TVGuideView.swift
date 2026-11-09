import AVKit
import SwiftUI
import TVVLCKit
import UIKit

private enum TVTheme {
    static let background = LanTVDesignSystem.background
    static let panel = LanTVDesignSystem.panel
    static let accent = LanTVDesignSystem.accent
    static let mint = LanTVDesignSystem.mint
    static let violet = LanTVDesignSystem.violet
}

struct TVGuideView: View {
    private enum HeaderControl: Hashable { case sources, refresh, search, settings }

    @Bindable var store: MobileStore
    @State private var fullscreen = false
    @State private var showDetails = false
    @State private var showSources = false
    @State private var showSettings = false
    @State private var searchExpanded = false
    @State private var newSourceName = ""
    @State private var newSourceURL = ""
    @State private var newStreamTemplate = ""
    @State private var newSourceKind: MobileSource.Kind = .xmltv
    @FocusState private var guideSearchFocused: Bool
    @FocusState private var focusedHeaderControl: HeaderControl?
    @FocusState private var focusedChannelID: String?
    @FocusState private var focusedProgrammeID: String?
    @State private var focusedProgramme: MobileProgramme?
    @State private var focusedProgrammeChannel: MobileChannel?
    @StateObject private var vlc = TVVLCController()

    private var currentChannel: MobileChannel? { store.selectedChannel }

    var body: some View {
        GeometryReader { geometry in
            let compactHeader = min(260, max(240, geometry.size.height * 0.25))
            let miniWidth = min(460, min(geometry.size.width * 0.30, (compactHeader - 28) * 16 / 9))
            let miniHeight = miniWidth * 9 / 16
            let horizontalInset: CGFloat = 24
            let verticalInset: CGFloat = 16
            let headerHorizontalInset: CGFloat = 16
            let headerVerticalInset: CGFloat = 14
            ZStack(alignment: .topTrailing) {
                ZStack {
                    LanTVDesignSystem.backgroundGradient
                    RadialGradient(colors: [TVTheme.accent.opacity(0.15), .clear], center: .topTrailing, startRadius: 20, endRadius: 760)
                    RadialGradient(colors: [TVTheme.violet.opacity(0.20), .clear], center: .bottomLeading, startRadius: 0, endRadius: 680)
                }
                .ignoresSafeArea()
                guideLayout(
                    width: geometry.size.width,
                    height: geometry.size.height,
                    headerHeight: compactHeader,
                    miniPlayerSize: CGSize(width: miniWidth, height: miniHeight)
                )
                .allowsHitTesting(!fullscreen)
                .accessibilityHidden(fullscreen)
                // Keep one video surface mounted while it grows from the mini
                // player to full screen. Replacing VLC's drawable here leaves
                // audio running while its video output stays black.
                playerSurface
                    .allowsHitTesting(false)
                    .frame(width: fullscreen ? geometry.size.width : miniWidth,
                           height: fullscreen ? geometry.size.height : miniHeight)
                    .clipShape(RoundedRectangle(cornerRadius: fullscreen ? 0 : 20))
                    .position(x: fullscreen ? geometry.size.width / 2 : geometry.size.width - horizontalInset - headerHorizontalInset - miniWidth / 2,
                              y: fullscreen ? geometry.size.height / 2 : verticalInset + headerVerticalInset + miniHeight / 2)
                    .overlay(alignment: .topLeading) {
                        if fullscreen && showDetails {
                            programmeDetails.padding(36).transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                if !fullscreen {
                    Button {
                        guard currentChannel != nil else { return }
                        if !store.isPlaying { togglePlayback() }
                        withAnimation(.easeInOut(duration: 0.22)) { fullscreen = true }
                    } label: { Color.clear }
                        .buttonStyle(TVVideoSurfaceButtonStyle())
                        .frame(width: miniWidth, height: miniHeight)
                        .position(x: geometry.size.width - horizontalInset - headerHorizontalInset - miniWidth / 2,
                                  y: verticalInset + headerVerticalInset + miniHeight / 2)
                        .accessibilityIdentifier("tv-mini-player-fullscreen")
                        .accessibilityLabel(store.isPlaying ? "Show playing video full screen" : "Play selected channel full screen")
                        .disabled(currentChannel == nil)
                }
            }
        }
        .ignoresSafeArea()
        .onAppear { selectFirstChannelIfNeeded() }
        .onChange(of: store.channels.count) { _, _ in selectFirstChannelIfNeeded() }
        .onChange(of: focusedProgrammeID) { _, id in updateFocusedProgramme(id) }
        .onChange(of: guideSearchFocused) { _, focused in
            if focused { focusedProgramme = nil; focusedProgrammeChannel = nil }
        }
        .onChange(of: store.playbackGeneration) { _, _ in
            if store.isPlaying, !store.usesNativePlayer, let url = store.selectedChannel?.streamURL { vlc.play(url) }
            else { vlc.stop() }
        }
        .onChange(of: fullscreen) { _, isFullscreen in
            if isFullscreen {
                guideSearchFocused = false
            } else {
                showDetails = false
            }
        }
        .onPlayPauseCommand(perform: togglePlayback)
        .onExitCommand {
            if guideSearchFocused {
                guideSearchFocused = false
                searchExpanded = false
                focusedHeaderControl = .search
            }
            else if fullscreen { fullscreen = false }
            else if showSettings { showSettings = false }
            else if showSources { showSources = false }
            else if focusedProgrammeID != nil, let channelID = focusedProgrammeChannel?.id {
                focusedProgrammeID = nil
                focusedChannelID = channelID
            } else if focusedChannelID != nil {
                focusedChannelID = nil
                focusedHeaderControl = .sources
            }
        }
        .sheet(isPresented: $showSources) { sourceSheet }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .alert("lanTV Desktop Found", isPresented: Binding(get: { store.discoveredDesktop != nil }, set: { if !$0 { store.dismissDiscoveredDesktop() } })) {
            Button("Not Now", role: .cancel) { store.dismissDiscoveredDesktop() }
            Button("Add as Guide Source") { store.addDiscoveredDesktop() }
        } message: {
            Text("Use \(store.discoveredDesktop?.name ?? "lanTV") for your guide and shared channel locks. Video streams directly from each source.")
        }
        .alert("Unable to Play", isPresented: Binding(get: { store.playerError != nil }, set: { if !$0 { store.playerError = nil } })) {
            Button("OK") { store.playerError = nil }
        } message: { Text(store.playerError ?? "") }
    }

    private func guideLayout(width: CGFloat, height: CGFloat, headerHeight: CGFloat, miniPlayerSize: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            tvNowPlaying(width: width, miniPlayerSize: miniPlayerSize)
                .frame(height: headerHeight)
            if let approval = store.pendingUnlockApproval {
                HStack(spacing: 18) {
                    Label("Unlock requested by \(approval.deviceName)", systemImage: "lock.open.fill")
                        .font(.headline).foregroundStyle(.orange)
                    Spacer()
                    Button("Deny") { store.respondToUnlockApproval(approved: false) }
                    Button("Approve Unlock") { store.respondToUnlockApproval(approved: true) }
                        .buttonStyle(.borderedProminent)
                }
                .padding(16)
                .background(TVTheme.panel, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.orange.opacity(0.35)))
                .focusSection()
                .accessibilityIdentifier("tv-unlock-approval-controls")
            }
            tvGuideGrid(availableWidth: width - 80)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .frame(width: width, height: height, alignment: .topLeading)
    }

    private var playerSurface: some View {
        ZStack {
            Color.black
            if (store.isPlaying || store.isPaused), store.selectedChannel?.streamURL != nil {
                if store.usesNativePlayer { TVNativeVideoSurface(player: store.player) }
                else { TVVLCVideoSurface(controller: vlc) }
            } else {
                ZStack {
                    LinearGradient(colors: [Color(red: 0.045, green: 0.09, blue: 0.17), Color(red: 0.07, green: 0.045, blue: 0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Circle().fill(TVTheme.accent.opacity(0.17)).frame(width: 180).blur(radius: 62).offset(x: -100, y: 40)
                    Circle().fill(TVTheme.violet.opacity(0.18)).frame(width: 190).blur(radius: 64).offset(x: 110, y: -35)
                    VStack(spacing: 12) {
                        Image(systemName: store.isLoading && store.channels.isEmpty ? "dot.radiowaves.left.and.right" : "play.rectangle.on.rectangle.fill")
                            .font(.system(size: 34, weight: .medium)).foregroundStyle(TVTheme.accent)
                        Text(currentChannel?.name ?? (store.channels.isEmpty ? "Connecting to lanTV" : "Ready when you are"))
                            .font(.system(size: 19, weight: .bold, design: .rounded)).lineLimit(1)
                        Text(store.channels.isEmpty ? "Finding your guide" : "Choose a channel below")
                            .font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
                    }
                    .padding(18).multilineTextAlignment(.center)
                }
                .clipped()
            }
        }
    }

    private func tvNowPlaying(width: CGFloat, miniPlayerSize: CGSize) -> some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 13).fill(LinearGradient(colors: [TVTheme.accent, TVTheme.violet], startPoint: .topLeading, endPoint: .bottomTrailing))
                        Image(systemName: "play.rectangle.on.rectangle.fill").font(.system(size: 19, weight: .bold)).foregroundStyle(.white)
                    }.frame(width: 40, height: 38).shadow(color: TVTheme.accent.opacity(0.22), radius: 10, y: 4)
                    Text("lanTV").font(.system(size: 30, weight: .bold, design: .rounded)).tracking(-1)
                    HStack(spacing: 8) {
                        Circle().fill(store.isUsingOfflineCache ? .orange : (store.selectedSource == nil ? .gray : TVTheme.mint)).frame(width: 8, height: 8)
                        Text(store.selectedSource == nil ? "Searching" : (store.isUsingOfflineCache ? "Offline guide" : store.selectedSource?.name ?? "Connected"))
                            .lineLimit(1)
                    }
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(.white.opacity(0.055), in: Capsule())
                    Button { showSources = true } label: { Label("Sources", systemImage: "server.rack") }
                        .focused($focusedHeaderControl, equals: .sources)
                        .accessibilityIdentifier("tv-sources")
                    Button { store.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .focused($focusedHeaderControl, equals: .refresh)
                        .accessibilityIdentifier("tv-refresh")
                    if searchExpanded {
                        HStack(spacing: 8) {
                            TextField("Search channels & shows", text: $store.search)
                                .font(.system(size: 16, weight: .medium, design: .rounded))
                                .textFieldStyle(.plain)
                                .focused($guideSearchFocused)
                                .submitLabel(.search)
                                .onSubmit {
                                    guideSearchFocused = false
                                    searchExpanded = false
                                    focusedHeaderControl = .search
                                }
                                .padding(.horizontal, 8).padding(.vertical, 6)
                                .background(guideSearchFocused ? TVTheme.accent.opacity(0.34) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                .animation(.easeInOut(duration: 0.12), value: guideSearchFocused)
                                .accessibilityIdentifier("tv-guide-search")
                            if !store.search.isEmpty {
                                Button { store.search = "" } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.72))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Clear guide search")
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .frame(width: min(260, max(210, width * 0.14)))
                        .onAppear { guideSearchFocused = true }
                    } else {
                        Button { searchExpanded = true } label: {
                            Label("Search", systemImage: "magnifyingglass")
                        }
                        .focused($focusedHeaderControl, equals: .search)
                        .accessibilityIdentifier("tv-guide-search")
                    }
                    Button { showSettings = true } label: { Label("Settings", systemImage: "slider.horizontal.3") }
                        .focused($focusedHeaderControl, equals: .settings)
                        .accessibilityIdentifier("tv-settings")
                }
                .font(.system(size: 16, weight: .semibold)).buttonStyle(TVControlButtonStyle())
                .controlSize(.regular)
                .padding(.bottom, 14)

                HStack(alignment: .center, spacing: 12) {
                    Circle()
                        .fill(LinearGradient(colors: [TVTheme.mint.opacity(0.60), TVTheme.accent.opacity(0.26)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 24, height: 24)
                    Text(currentChannel?.name ?? "Your guide, at a glance")
                        .font(.system(size: 33, weight: .bold, design: .rounded)).lineLimit(1)
                }
                .padding(.bottom, 6)
                Text(currentChannel?.nowPlaying?.title ?? (store.channels.isEmpty ? "Find your channels" : "Choose a channel to start watching"))
                    .font(.system(size: 26, weight: .semibold, design: .rounded)).lineLimit(1)
                HStack(spacing: 16) {
                    if let programme = currentChannel?.nowPlaying {
                        Label("\(programme.start.formatted(date: .omitted, time: .shortened)) – \(programme.stop.formatted(date: .omitted, time: .shortened))", systemImage: "clock")
                    } else {
                        Text(store.status).lineLimit(1)
                    }
                    if store.isLoading && store.channels.isEmpty { ProgressView().controlSize(.small) }
                }
                .font(.callout).foregroundStyle(.secondary).padding(.top, 5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.black.opacity(0.22))
                .frame(width: miniPlayerSize.width, height: miniPlayerSize.height)
                .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 26)
                .fill(LanTVDesignSystem.panelGradient)
                .overlay { LanTVSignalWave().clipShape(RoundedRectangle(cornerRadius: 26)) }
                .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(LanTVDesignSystem.panelBorder.opacity(0.65), lineWidth: 1))
                .shadow(color: .black.opacity(0.22), radius: 14, y: 5)
        }
    }

    private func tvGuideGrid(availableWidth: CGFloat) -> some View {
        let origin = Calendar.current.dateInterval(of: .hour, for: Date())?.start ?? Date()
        // Fit the three-hour timeline inside the guide panel instead of letting
        // its content widen the panel beyond the screen.
        let visibleHours = 3
        let end = origin.addingTimeInterval(Double(visibleHours) * 3600)
        let channelColumnWidth: CGFloat = 190
        let timelineWidth = max(1, availableWidth - channelColumnWidth - 24)
        let pointsPerSecond = timelineWidth / CGFloat(visibleHours * 3600)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("The Guide").font(.system(size: 32, weight: .bold, design: .rounded)).tracking(-0.5)
                    Text(store.search.isEmpty
                         ? "\(store.channels.count) channels"
                         : "\(store.filteredChannels.count) results from \(store.channels.count) channels")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Label(store.isUsingOfflineCache ? "Saved Guide" : "Live Guide", systemImage: store.isUsingOfflineCache ? "arrow.down.doc" : "dot.radiowaves.left.and.right")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(store.isUsingOfflineCache ? .orange : TVTheme.mint)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background((store.isUsingOfflineCache ? Color.orange : TVTheme.mint).opacity(0.10), in: Capsule())
            }
            if let programme = focusedProgramme, let channel = focusedProgrammeChannel {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(channel.number)  ·  \(channel.name.uppercased())")
                            .font(.caption.weight(.bold)).tracking(1.1).foregroundStyle(TVTheme.mint).lineLimit(1)
                        Text(programme.title)
                            .font(.system(size: 26, weight: .bold, design: .rounded)).lineLimit(1)
                    }
                    Spacer(minLength: 20)
                    Label("\(programme.start.formatted(date: .omitted, time: .shortened)) – \(programme.stop.formatted(date: .omitted, time: .shortened))", systemImage: "clock")
                        .font(.callout.weight(.semibold)).foregroundStyle(.white.opacity(0.72)).lineLimit(1)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(LinearGradient(colors: [TVTheme.accent.opacity(0.15), TVTheme.violet.opacity(0.10)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.white.opacity(0.08), lineWidth: 1))
                .accessibilityIdentifier("tv-focused-programme")
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if store.channels.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 34, weight: .light)).foregroundStyle(TVTheme.accent)
                    Text("Your channels are on the way").font(.title2.bold())
                    Text(store.status).font(.callout).foregroundStyle(.secondary)
                    Button { showSources = true } label: { Label("Choose a Guide Source", systemImage: "server.rack") }
                        .buttonStyle(.borderedProminent).tint(TVTheme.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if store.filteredChannels.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "magnifyingglass").font(.system(size: 36, weight: .light)).foregroundStyle(TVTheme.accent.opacity(0.9))
                    Text("No channels match “\(store.search)”").font(.title2.bold())
                    Text(store.isUsingOfflineCache ? "The saved guide is available while your desktop is offline." : "Try a different channel number or show title.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button { store.search = "" } label: { Label("Clear Search", systemImage: "xmark") }
                        .buttonStyle(.borderedProminent).tint(TVTheme.accent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            Text("CHANNEL").frame(width: channelColumnWidth, alignment: .leading)
                            HStack(spacing: 0) {
                                ForEach(0..<visibleHours, id: \.self) { offset in
                                    Text(origin.addingTimeInterval(Double(offset) * 3600).formatted(date: .omitted, time: .shortened))
                                        .frame(width: 3600 * pointsPerSecond, alignment: .leading)
                                }
                            }
                        }
                        .font(.caption.weight(.bold)).tracking(1.1).foregroundStyle(.white.opacity(0.50)).padding(.bottom, 5)
                        ForEach(store.filteredChannels) { channel in
                            HStack(spacing: 8) {
                                Button { store.select(channel) } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(channel.number.isEmpty ? "TV" : channel.number).font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(.secondary)
                                        Text(channel.name).font(.system(size: 24, weight: .semibold, design: .rounded)).lineLimit(1)
                                    }.frame(width: channelColumnWidth - 16, height: 88, alignment: .leading).padding(.horizontal, 8)
                                }
                                .focused($focusedChannelID, equals: channel.id)
                                .buttonStyle(TVChannelButtonStyle(selected: currentChannel?.id == channel.id))
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.18))
                                    ForEach(channel.programmes.filter { $0.stop > origin && $0.start < end }) { programme in
                                        let start = max(programme.start, origin)
                                        let stop = min(programme.stop, end)
                                        let cellWidth = max(1, CGFloat(stop.timeIntervalSince(start)) * pointsPerSecond - 4)
                                        let focusWidth = max(cellWidth, 48)
                        let isNowPlaying = programme.id == channel.nowPlaying?.id
                        let isActiveProgramme = store.isPlaying && store.selectedChannel?.id == channel.id && isNowPlaying
                        Button {
                            if isActiveProgramme { fullscreen = true }
                            else { store.select(channel) }
                        } label: {
                            Group {
                                if cellWidth >= 165 {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(programme.title).font(.system(size: 22, weight: .semibold, design: .rounded)).lineLimit(1)
                                        Text("\(programme.start.formatted(date: .omitted, time: .shortened)) – \(programme.stop.formatted(date: .omitted, time: .shortened))")
                                            .font(.system(size: 17, weight: .medium)).foregroundStyle(.white.opacity(0.80)).lineLimit(1)
                                    }
                                } else if cellWidth >= 62 {
                                    Text(programme.title).font(.system(size: 20, weight: .semibold, design: .rounded)).lineLimit(1)
                                } else {
                                    HStack(spacing: 0) {
                                        Capsule().fill(isNowPlaying ? TVTheme.mint : TVTheme.accent.opacity(0.60)).frame(width: isNowPlaying ? 5 : 3)
                                        Spacer(minLength: 0)
                                    }
                                }
                            }
                            .padding(.horizontal, cellWidth >= 62 ? 12 : 5)
                            .frame(width: focusWidth, height: 88, alignment: .leading)
                            .background {
                                RoundedRectangle(cornerRadius: 11)
                                    .fill(isNowPlaying
                                          ? LanTVDesignSystem.liveProgrammeGradient
                                          : LanTVDesignSystem.programmeGradient)
                            }
                            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(isNowPlaying ? TVTheme.accent.opacity(0.58) : LanTVDesignSystem.panelBorder.opacity(0.42), lineWidth: 1))
                            .contentShape(Rectangle())
                            .clipped()
                        }
                        .accessibilityLabel("\(channel.number) \(channel.name), \(programme.title), \(programme.start.formatted(date: .omitted, time: .shortened)) to \(programme.stop.formatted(date: .omitted, time: .shortened))")
                                        .focused($focusedProgrammeID, equals: programme.id)
                                        .buttonStyle(TVProgrammeButtonStyle())
                        .contentShape(Rectangle())
                                        .zIndex(focusedProgrammeID == programme.id ? 3 : 0)
                                        .offset(x: CGFloat(start.timeIntervalSince(origin)) * pointsPerSecond)
                                    }
                                    Rectangle().fill(TVTheme.mint).frame(width: 2).shadow(color: TVTheme.mint.opacity(0.7), radius: 5).offset(x: CGFloat(Date().timeIntervalSince(origin)) * pointsPerSecond)
                                }.frame(width: timelineWidth, height: 88)
                            }
                        }
                    }.padding(6)
                        .frame(width: channelColumnWidth + timelineWidth + 8, alignment: .topLeading)
                }.focusSection()
                    .defaultScrollAnchor(.topLeading)
                    .scrollIndicators(.visible)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 26)
                .fill(LanTVDesignSystem.panelGradient)
                .overlay { LanTVSignalWave(guide: true).clipShape(RoundedRectangle(cornerRadius: 26)) }
                .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(LanTVDesignSystem.panelBorder.opacity(0.65), lineWidth: 1))
                .shadow(color: .black.opacity(0.20), radius: 14, y: 5)
        }
    }

    private var programmeDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(currentChannel?.name ?? "Live TV").font(.system(size: 30, weight: .bold, design: .rounded))
                Spacer()
                if let programme = currentChannel?.nowPlaying {
                    Text("\(programme.start.formatted(date: .omitted, time: .shortened)) – \(programme.stop.formatted(date: .omitted, time: .shortened))")
                        .font(.headline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Text(currentChannel?.nowPlaying?.title ?? "Select a channel to see programme information")
                .font(.title2.weight(.semibold)).lineLimit(1)
            if let detail = currentChannel?.nowPlaying?.detail, !detail.isEmpty {
                Text(detail).font(.body).foregroundStyle(.secondary).lineLimit(3)
            }
            if let next = currentChannel?.upcoming.first(where: { $0.start > Date() }) {
                Label("Up next · \(next.start.formatted(date: .omitted, time: .shortened)) · \(next.title)", systemImage: "forward.end")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(TVTheme.panel.opacity(0.8), in: RoundedRectangle(cornerRadius: 20))
    }

    private var sourceSheet: some View {
        NavigationStack {
            List {
                Section("Saved Sources") {
                    ForEach(store.sources) { source in
                        Button {
                            store.chooseSource(source.id)
                            showSources = false
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) { Text(source.name); Text(source.kind == .desktop ? "lanTV Desktop" : "XMLTV").font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                if source.id == store.selectedSourceID { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) }
                            }
                        }
                    }
                }
                Section {
                    Text("A lanTV desktop on this network will appear here as a discovery prompt. Add an independent XMLTV source in Settings.")
                        .foregroundStyle(.secondary)
                    Button("Refresh Guide") { store.refresh(); showSources = false }
                }
            }
            .navigationTitle("Guide Sources")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSources = false } } }
        }
    }

    private var settingsSheet: some View {
        NavigationStack {
            List {
                Section("Playback") {
                    LabeledContent("Player", value: currentChannel.map { _ in store.usesNativePlayer ? "System Player" : "VLC Network Player" } ?? "Not playing")
                    Button { togglePlayback() } label: { Label(store.isPlaying ? "Pause Playback" : "Resume Playback", systemImage: store.isPlaying ? "pause.fill" : "play.fill") }
                    Button { store.stopPlayback(); vlc.stop() } label: { Label("Stop Playback", systemImage: "stop.fill") }
                    Button { fullscreen = true; showSettings = false } label: { Label("Open Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") }.disabled(!store.isPlaying)
                }
                Section("Guide") {
                    LabeledContent("Source", value: store.selectedSource?.name ?? "None")
                    LabeledContent("Channels", value: "\(store.channels.count)")
                    LabeledContent("Connection", value: store.isUsingOfflineCache ? "Using saved guide" : store.status)
                    Button { store.refresh() } label: { Label("Refresh Guide", systemImage: "arrow.clockwise") }
                    if let state = store.desktopState, store.selectedSource?.kind == .desktop {
                        LabeledContent("Protected Channels", value: state.areProtectedChannelsUnlocked ? "Unlocked" : "Locked")
                        if store.canRequestUnlock {
                            Button(store.isRequestingUnlock ? "Unlocking…" : (store.isApprover ? "Unlock Protected Channels" : "Request Channel Unlock")) {
                                store.requestUnlock()
                            }
                            .disabled(store.isRequestingUnlock)
                        } else if store.canRequestLock {
                            Button(store.isRequestingLock ? "Locking…" : "Lock Protected Channels", role: .destructive) {
                                store.requestLock()
                            }
                            .disabled(store.isRequestingLock)
                        }
                    }
                    if store.isApprover {
                        Label("This TV can approve unlock requests", systemImage: "person.badge.key.fill")
                    } else if store.canRequestApproverRights {
                        Button(store.isRequestingApproverAccess ? "Waiting for Desktop Approval…" : "Request Approver Access") { store.requestApproverRights() }
                            .disabled(store.isRequestingApproverAccess)
                    }
                    if let message = store.approverMessage { Text(message).foregroundStyle(.secondary) }
                }
                Section("Add Source") {
                    Picker("Type", selection: $newSourceKind) {
                        Text("XMLTV Feed").tag(MobileSource.Kind.xmltv)
                        Text("lanTV Desktop").tag(MobileSource.Kind.desktop)
                    }
                    TextField("Source Name", text: $newSourceName)
                    TextField(newSourceKind == .desktop ? "Desktop URL, e.g. http://tvserver.lan:48921" : "XMLTV URL", text: $newSourceURL)
                    if newSourceKind == .xmltv { TextField("Stream URL template (use {channel})", text: $newStreamTemplate) }
                    Button("Add and Connect") { addSource() }
                        .disabled(newSourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newSourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("lanTV Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
        }
    }

    private func selectFirstChannelIfNeeded() {
        guard store.selectedChannel == nil, let first = store.channels.first else { return }
        store.select(first)
    }

    private func updateFocusedProgramme(_ id: String?) {
        guard let id else { return }
        let channelID = id.split(separator: "|", omittingEmptySubsequences: false).dropLast().joined(separator: "|")
        guard let channel = store.channels.first(where: { $0.rawID == channelID }),
              let programme = channel.programmes.first(where: { $0.id == id }) else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            focusedProgramme = programme
            focusedProgrammeChannel = channel
        }
    }

    private func togglePlayback() {
        guard let channel = store.selectedChannel else { return }
        if store.isPlaying {
            store.player.pause(); vlc.pause(); store.isPlaying = false; store.isPaused = true
        } else if store.isPaused {
            store.isPaused = false; store.isPlaying = true
            if store.usesNativePlayer { store.player.play() } else { vlc.resume() }
        } else {
            // Stop clears the underlying AVPlayer item, so starting again must
            // reload the selected channel instead of calling play() on nothing.
            store.select(channel)
        }
    }

    private func addSource() {
        let source = MobileSource(
            name: newSourceName.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: newSourceKind,
            url: newSourceURL.trimmingCharacters(in: .whitespacesAndNewlines),
            streamTemplate: newSourceKind == .xmltv ? newStreamTemplate.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        )
        do {
            try store.saveSource(source)
            newSourceName = ""; newSourceURL = ""; newStreamTemplate = ""
            showSettings = false
        } catch { store.playerError = error.localizedDescription }
    }
}

private struct TVChannelButtonStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(selected
                          ? LanTVDesignSystem.liveProgrammeGradient
                          : LanTVDesignSystem.programmeGradient)
            }
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(isFocused ? TVTheme.accent : (selected ? TVTheme.accent.opacity(0.86) : LanTVDesignSystem.panelBorder.opacity(0.42)), lineWidth: isFocused ? 3 : (selected ? 2 : 1)))
            .shadow(color: (isFocused || selected) ? TVTheme.accent.opacity(0.55) : .clear, radius: 12, y: 0)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.16), value: isFocused)
    }
}

private struct TVProgrammeButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(isFocused ? .white : .clear, lineWidth: 3))
            .shadow(color: isFocused ? TVTheme.accent.opacity(0.42) : .clear, radius: 12, y: 3)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.14), value: isFocused)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct TVControlButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 19, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background { RoundedRectangle(cornerRadius: 12).fill(isFocused ? LanTVDesignSystem.accentGradient : LanTVDesignSystem.programmeGradient) }
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isFocused ? Color.white : LanTVDesignSystem.panelBorder.opacity(0.72), lineWidth: isFocused ? 2 : 1))
            .shadow(color: isFocused ? TVTheme.accent.opacity(0.65) : .clear, radius: 15, y: 0)
            .animation(.easeOut(duration: 0.12), value: isFocused)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

private struct TVVideoSurfaceButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(isFocused ? .white : .clear, lineWidth: 4))
            .overlay(alignment: .bottomTrailing) {
                if !configuration.isPressed {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 16, weight: .bold)).padding(10)
                        .background(.black.opacity(0.72), in: Circle())
                        .padding(12)
                }
            }
    }
}

private struct TVVLCVideoSurface: UIViewRepresentable {
    let controller: TVVLCController
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.backgroundColor = .black
        controller.attach(view)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) { controller.attach(uiView) }
}

private struct TVNativeVideoSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> TVPlayerLayerView {
        let view = TVPlayerLayerView()
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: TVPlayerLayerView, context: Context) {
        view.playerLayer.player = player
    }
}

private final class TVPlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class TVVLCController: ObservableObject {
    private let player = VLCMediaPlayer()
    private var playingURL: URL?

    private weak var drawableView: UIView?

    func attach(_ view: UIView) {
        guard drawableView !== view else { return }
        drawableView = view
        player.drawable = view
    }
    func play(_ url: URL) {
        guard playingURL != url else { resume(); return }
        playingURL = url
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=1000")
        player.media = media
        player.play()
    }
    func pause() { if player.isPlaying { player.pause() } }
    func resume() { if !player.isPlaying { player.play() } }
    func stop() { player.stop(); playingURL = nil }
}
