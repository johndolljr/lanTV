import SwiftUI

@main
struct lanTVAppleTVApp: App {
    @State private var store = MobileStore()

    var body: some Scene {
        WindowGroup {
            TVGuideView(store: store)
                .preferredColorScheme(.dark)
        }
    }
}
