import NoiseKit
import ServiceManagement
import SwiftUI

struct PopoverView: View {
    @EnvironmentObject var noise: NoisePlayer
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    /// Положение ползунка тембра во время перетаскивания; шум перерисовывается только когда ползунок отпущен.
    @State private var toneIndex: Double?

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

            SegmentedButtons(items: NoiseType.allCases, selection: $noise.type) { $0.title(noise.language) }

            toneControl

            volumeControl

            adaptiveControl

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
                SegmentedButtons(items: Language.allCases, selection: $noise.language) { $0.label }
                    .frame(width: 90)
            }
        }
        .onAppear { noise.refreshChannel() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in noise.refreshChannel() }
        .padding(16)
        .frame(width: 340)
        .fixedSize(horizontal: true, vertical: true)
    }

    private var shownToneIndex: Double { toneIndex ?? Double(Tone.nearestIndex(noise.tone)) }

    @ViewBuilder private var toneControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(noise.t(.tone))
                Spacer()
                let db = Tone.steps[Int(shownToneIndex)]
                Text(db == 0 ? "0 dB" : String(format: "%+.0f dB", db)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { shownToneIndex }, set: { toneIndex = $0.rounded() }),
                   in: 0...Double(Tone.steps.count - 1), step: 1) { editing in
                if !editing, let i = toneIndex {
                    noise.tone = Tone.steps[Int(i)]
                    toneIndex = nil
                }
            }
            HStack {
                Text(noise.t(.darker))
                Spacer()
                Text(noise.t(.brighter))
            }
            .font(.caption).foregroundStyle(.secondary)
        }
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

    @ViewBuilder private var adaptiveControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(noise.t(.adaptive), isOn: $noise.adaptive)
            if noise.adaptive {
                HStack {
                    Text(noise.t(.headroom)).font(.caption)
                    Spacer()
                    if noise.isPlaying {
                        Text(noise.t(.boostNow) + String(format: " +%.1f dB", noise.boostDB))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                SegmentedButtons(items: NoisePlayer.headroomSteps, selection: $noise.headroomDB) { "+\(Int($0)) dB" }
                Text(noise.t(.adaptiveHint))
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

/// Свой сегментный переключатель из кнопок. Системный `Picker(.segmented)` на новой macOS при перерисовке
/// временно становится шире окна `MenuBarExtra` и сдвигает всё содержимое за край. Этот делит ширину поровну
/// и никогда её не превышает.
struct SegmentedButtons<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let on = item == selection
                Button { selection = item } label: {
                    Text(title(item))
                        .font(.system(size: 11, weight: on ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.accentColor : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
    }
}
