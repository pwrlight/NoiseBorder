import SwiftUI

@main
struct NoiseBorderApp: App {
    @StateObject private var noise = NoisePlayer()

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environmentObject(noise)
        } label: {
            Image(systemName: noise.isPlaying ? "waveform.circle.fill" : "waveform.circle")
        }
        .menuBarExtraStyle(.window)
    }
}
