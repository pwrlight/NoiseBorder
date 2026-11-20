import AVKit
import SwiftUI

/// Стандартная кнопка выбора AirPlay, привязанная к плееру приложения.
struct RoutePicker: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.player = player
        v.isRoutePickerButtonBordered = false
        return v
    }

    func updateNSView(_ v: AVRoutePickerView, context: Context) { v.player = player }
}
