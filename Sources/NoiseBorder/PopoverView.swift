import NoiseKit
import ServiceManagement
import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var noise: NoisePlayer
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(noise.t(.title)).font(.headline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { noise.isPlaying || noise.isPreparing },
                    set: { $0 ? noise.start() : noise.stop(message: nil) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
            }

            Picker("", selection: $noise.type) {
                ForEach(NoiseType.allCases, id: \.self) { Text($0.title(noise.language)).tag($0) }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .frame(maxWidth: .infinity)

            volumeControl

            HStack {
                Text(noise.t(.airplayOutput))
                Spacer()
                RoutePicker(player: noise.player).frame(width: 28, height: 28)
            }

            statusLine

            Divider()

            Toggle(noise.t(.launchAtLogin), isOn: Binding(
                get: { launchAtLogin },
                set: { setLaunchAtLogin($0) }
            ))
            if let loginError {
                Text(noise.t(.loginUnavailable) + loginError).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(noise.t(.quit)) { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
                Spacer()
                Picker(noise.t(.language), selection: $noise.language) {
                    ForEach(Language.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .frame(width: 90)
            }
        }
        .onAppear { noise.refreshChannel() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in noise.refreshChannel() }
        .padding(16)
        .frame(width: 340)
        .fixedSize(horizontal: true, vertical: true)
    }

    @ViewBuilder private var volumeControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            if noise.channelAvailable {
                HStack {
                    Text(noise.t(.channelVolume))
                    Spacer()
                    Text("\(Int((noise.channelVolume * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { Double(noise.channelVolume) }, set: { noise.setChannelVolume(Float($0)) }),
                       in: 0...1)
            } else {
                HStack {
                    Text(noise.t(.volume))
                    Spacer()
                    Text("\(Int((noise.volume * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { Double(noise.volume) }, set: { noise.volume = Float($0) }),
                       in: 0...Double(VolumePolicy.maximum))
                Text(noise.t(.chooseReceiverHint))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        statusContent
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var statusContent: some View {
        if let m = noise.message {
            Label(tr(m, noise.language), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.caption)
        } else if noise.isPreparing {
            Label(noise.t(.preparing), systemImage: "hourglass").font(.caption)
        } else if noise.isPlaying && noise.isOnAirPlay {
            Label(noise.t(.playingAirPlay) + (noise.routeName.map { ": \($0)" } ?? ""), systemImage: "airplayaudio")
                .foregroundStyle(.green).font(.caption)
        } else if noise.isPlaying {
            Label(noise.t(.playingMac), systemImage: "speaker.wave.2.fill")
                .foregroundStyle(.orange).font(.caption)
        } else {
            Text(noise.t(.off) + (noise.routeName.map { " · AirPlay: \($0)" } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
