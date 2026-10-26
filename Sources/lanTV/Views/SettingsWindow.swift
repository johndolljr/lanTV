import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var viewModel: GuideViewModel?

    func show(viewModel: GuideViewModel) {
        self.viewModel = viewModel

        if let window {
            updateRootView(viewModel)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsWindowRootView(
            viewModel: viewModel,
            onClose: { [weak self] in
                self?.close()
            }
        )

        let hostingController = NSHostingController(rootView: settingsView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "lanTV Settings"
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
        window.setContentSize(NSSize(width: 960, height: 760))
        window.minSize = NSSize(width: 820, height: 600)

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

    private func updateRootView(_ viewModel: GuideViewModel) {
        guard let hostingController = window?.contentViewController as? NSHostingController<SettingsWindowRootView> else {
            return
        }
        hostingController.rootView = SettingsWindowRootView(
            viewModel: viewModel,
            onClose: { [weak self] in
                self?.close()
            }
        )
    }
}

private struct SettingsWindowRootView: View {
    let viewModel: GuideViewModel
    let onClose: () -> Void

    var body: some View {
        SettingsView(
            settings: viewModel.settingsStore.settings,
            channels: viewModel.unlockedChannels,
            areAdultChannelsUnlocked: viewModel.areAdultChannelsUnlocked,
            onAdultUnlockRequest: {
                Task {
                    await viewModel.unlockAdultChannels()
                }
            },
            onAdultLockRequest: {
                viewModel.lockAdultChannels()
            },
            onFetchChannels: { source in
                try await viewModel.fetchChannels(for: source)
            },
            onSave: { updatedSettings in
                viewModel.applySettings { current in
                    current = updatedSettings
                }
                onClose()
            },
            onCancel: {
                onClose()
            }
        )
    }
}
