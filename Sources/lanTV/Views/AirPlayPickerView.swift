import AVKit
import SwiftUI

struct AirPlayPickerView: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        AVRoutePickerView()
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
    }
}
