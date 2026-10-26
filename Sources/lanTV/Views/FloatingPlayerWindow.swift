import AppKit
import SwiftUI

@MainActor
final class FloatingPlayerWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var suppressCloseCallback = false
    private weak var viewModel: GuideViewModel?

    func show(viewModel: GuideViewModel) {
        self.viewModel = viewModel

        if let window {
            updateRootView(viewModel)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: FloatingPlayerWindowView(viewModel: viewModel))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "lanTV Player"
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
        window.setContentSize(NSSize(width: 900, height: 620))
        window.minSize = NSSize(width: 520, height: 380)

        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        guard let window else { return }
        suppressCloseCallback = true
        window.close()
        suppressCloseCallback = false
        self.window = nil
    }

    func windowWillClose(_ notification: Notification) {
        let shouldNotify = !suppressCloseCallback
        window = nil
        if shouldNotify {
            viewModel?.floatingPlayerWindowDidClose()
        }
    }

    private func updateRootView(_ viewModel: GuideViewModel) {
        guard let hostingController = window?.contentViewController as? NSHostingController<FloatingPlayerWindowView> else {
            return
        }
        hostingController.rootView = FloatingPlayerWindowView(viewModel: viewModel)
    }
}

private struct FloatingPlayerWindowView: View {
    @Bindable var viewModel: GuideViewModel
    @Environment(\.openWindow) private var openWindow
    @State private var currentTime = Date()
    private let clock = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.02, green: 0.04, blue: 0.08),
                    Color(red: 0.04, green: 0.07, blue: 0.12),
                    Color(red: 0.03, green: 0.06, blue: 0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if let channel = viewModel.selectedChannel {
                SelectedChannelPlayerPanel(
                    viewModel: viewModel,
                    channel: channel,
                    currentTime: currentTime,
                    dockMode: .floating,
                    onDockToggle: {
                        openWindow(id: "guide")
                        viewModel.dockPlayer()
                    }
                )
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("No Channel Selected", systemImage: "tv")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 520, minHeight: 380)
        .onReceive(clock) { now in
            currentTime = now
        }
    }
}
