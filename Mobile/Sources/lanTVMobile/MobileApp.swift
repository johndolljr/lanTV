import SwiftUI

@main
struct LanTVMobileApp: App {
    @State private var store = MobileStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            MobileContentView(store: store)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in store.foregroundChanged(phase == .active) }
        }
    }
}
