import SwiftUI
import AppKit

@main
struct LanTVApp: App {
    @State private var viewModel = GuideViewModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("lanTV", id: "guide") {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 900, idealWidth: 980, minHeight: 700)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    viewModel.openSettingsWindow()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }

        MenuBarExtra {
            MenuBarControls(viewModel: viewModel)
        } label: {
            Label("lanTV", systemImage: "tv.badge.wifi")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

private struct MenuBarControls: View {
    @Bindable var viewModel: GuideViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("lanTV")
                    .font(.headline)
                Text("API on \(viewModel.localAPIBaseURLString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("Open Guide") {
                openWindow(id: "guide")
                NSApp.activate(ignoringOtherApps: true)
            }

            Button("Refresh Guide") {
                viewModel.refresh()
            }

            Button("Settings...") {
                viewModel.openSettingsWindow()
            }

            Button(viewModel.adultLockButtonTitle) {
                viewModel.toggleAdultLock()
            }

            if viewModel.isPlayerDetached {
                Button("Show Player Window") {
                    viewModel.focusDetachedPlayerWindow()
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Local API")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(viewModel.localAPIReachableURLs, id: \.self) { url in
                    Text(url)
                        .font(.caption.monospaced())
                }
                Divider()
                Text("/api/guide.xmltv")
                    .font(.caption.monospaced())
                Text("/api/channels.json")
                    .font(.caption.monospaced())
                Text("/api/settings.json")
                    .font(.caption.monospaced())
                Text("/api/state.json")
                    .font(.caption.monospaced())
                Text("/api/playlist.m3u")
                    .font(.caption.monospaced())
            }
            .foregroundStyle(.secondary)

            Divider()

            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(12)
        .frame(minWidth: 240)
    }
}
