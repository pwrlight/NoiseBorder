import AVFoundation
import AppKit
import Combine
import NoiseKit

/// Воспроизведение шума. Вывод идёт через AVQueuePlayer, поэтому AirPlay-маршрут (кнопка AVRoutePickerView)
/// действует только на звук этого приложения, а системный вывод Mac не меняется.
@MainActor
final class NoisePlayer: ObservableObject {
    private enum Key { static let type = "noiseType", volume = "volume", language = "language" }
    /// Версия рендера в имени файла кэша: смена параметров генератора инвалидирует кэш.
    private nonisolated static let cacheVersion = "v1-18dbfs"

    @Published var type: NoiseType {
        didSet {
            UserDefaults.standard.set(type.rawValue, forKey: Key.type)
            if isPlaying { restartItems() }
        }
    }
    @Published var volume: Float {
        didSet {
            let v = VolumePolicy.clamp(volume)
            if v != volume { volume = v }  // повторно didSet не вызывается
            UserDefaults.standard.set(v, forKey: Key.volume)
            if isPlaying, fadeTask == nil, !channelAvailable { player.volume = v }
        }
    }
    @Published private(set) var isPlaying = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isOnAirPlay = false
    /// Имя выбранного AirPlay-приёмника, nil если маршрут не выбран.
    @Published private(set) var routeName: String?
    @Published private(set) var message: Notice?
    @Published var language: Language {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Key.language) }
    }
    func t(_ s: Str) -> String { tr(s, language) }
    /// Громкость выбранного AirPlay-приёмника (0...1) доступна для управления.
    @Published private(set) var channelAvailable = false
    @Published private(set) var channelVolume: Float = 0

    let player = AVQueuePlayer()
    private lazy var channel = ChannelVolume(player: player)
    private var fadeTask: Task<Void, Never>?
    private var lostRouteTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()

    init() {
        let d = UserDefaults.standard
        type = NoiseType(rawValue: d.string(forKey: Key.type) ?? "") ?? .speech
        language = Language(rawValue: d.string(forKey: Key.language) ?? "") ?? .systemDefault
        volume = d.object(forKey: Key.volume) == nil ? VolumePolicy.default : VolumePolicy.clamp(d.float(forKey: Key.volume))
        player.allowsExternalPlayback = true
        player.volume = 0

        player.publisher(for: \.isExternalPlaybackActive)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateRoute() }
            .store(in: &bag)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.stop(message: nil, fade: false) } }
            .store(in: &bag)
    }

    // MARK: Управление

    func start() {
        guard !isPlaying, startTask == nil else { return }
        message = nil
        isPreparing = true
        startTask = Task {
            defer { startTask = nil; isPreparing = false }
            do {
                let url = try await Self.ensureFile(for: type)
                guard !Task.isCancelled else { return }
                player.removeAllItems()
                enqueue(url); enqueue(url)
                player.volume = 0
                player.play()
                isPlaying = true
                startMonitor()
                fade(to: targetPlayerVolume)
            } catch {
                message = .prepareFailed(error.localizedDescription)
            }
        }
    }

    func stop(message: Notice?, fade shouldFade: Bool = true) {
        startTask?.cancel()
        lostRouteTask?.cancel()
        monitorTask?.cancel()
        self.message = message
        guard isPlaying else { return }
        isPlaying = false
        let finish = { [weak self] in
            self?.fadeTask = nil
            self?.player.pause()
            self?.player.removeAllItems()
            self?.player.volume = 0
        }
        if shouldFade {
            fade(to: 0, then: finish)
        } else {
            fadeTask?.cancel()
            finish()
        }
    }

    // MARK: Громкость канала

    /// Если приёмник отдаёт управление громкостью, она регулируется на нём, а плеер играет без ослабления.
    /// Иначе остаётся прежняя схема: слайдер двигает `player.volume`.
    private var targetPlayerVolume: Float { channelAvailable ? 1 : volume }

    /// Перечитывает состояние канала. Вызывается при открытии окна и по таймеру, пока оно открыто.
    func refreshChannel() {
        updateRoute()
        let available = channel.canSet
        if available != channelAvailable {
            channelAvailable = available
            if isPlaying, fadeTask == nil { player.volume = targetPlayerVolume }
        }
        if available, let v = channel.value, abs(v - channelVolume) > 0.001 { channelVolume = v }
    }

    func setChannelVolume(_ v: Float) {
        let c = min(max(v.isFinite ? v : 0, 0), 1)
        channelVolume = c
        channel.set(c)
    }

    // MARK: Внутреннее

    private func fade(to target: Float, then done: (() -> Void)? = nil) {
        fadeTask?.cancel()
        let from = player.volume
        let steps = 20
        fadeTask = Task { [weak self] in
            for i in 1...steps {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, !Task.isCancelled else { return }
                self.player.volume = from + (target - from) * Float(i) / Float(steps)
            }
            guard let self, !Task.isCancelled else { return }
            self.fadeTask = nil
            done?()
        }
    }

    private func restartItems() {
        let wanted = type
        Task {
            guard let url = try? await Self.ensureFile(for: wanted), isPlaying, type == wanted else { return }
            player.removeAllItems()
            enqueue(url); enqueue(url)
            player.play()
        }
    }

    /// Ручное зацикливание: AVPlayerLooper при AirPlay падает («Cannot play»).
    /// В очереди всегда два элемента, по окончанию текущего добавляем новый.
    private func enqueue(_ url: URL) {
        let item = AVPlayerItem(url: url)
        let wanted = type
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying, self.type == wanted else { return }
                self.enqueue(url)
            }
        }
        player.insert(item, after: nil)
    }

    /// Маршрут AirPlay определяем по выбранным устройствам в `AVOutputContext`: на роутере (аудио AirPlay)
    /// `isExternalPlaybackActive` остаётся false, хотя звук идёт. Флаг оставлен как запасной признак (ТВ).
    private func routeActive() -> Bool { !channel.deviceNames.isEmpty || player.isExternalPlaybackActive }

    func updateRoute() {
        let names = channel.deviceNames
        let name = names.isEmpty ? nil : names.joined(separator: ", ")
        if routeName != name { routeName = name }
        routeChanged(active: !names.isEmpty || player.isExternalPlaybackActive)
    }

    /// Пока играем, раз в секунду следим за маршрутом, даже если окно закрыто.
    private func startMonitor() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.refreshChannel()
            }
        }
    }

    private func routeChanged(active: Bool) {
        let was = isOnAirPlay
        isOnAirPlay = active
        if active { lostRouteTask?.cancel(); return }
        // Приёмник пропал во время игры: не переходим на динамики Mac, останавливаемся.
        // Задержка нужна, чтобы не срабатывать на кратковременный сброс при смене дорожки.
        guard was, isPlaying else { return }
        lostRouteTask?.cancel()
        lostRouteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled, self.isPlaying, !self.routeActive() else { return }
            self.stop(message: .routeLost, fade: false)
        }
    }

    // MARK: Кэш рендера

    nonisolated static func cacheDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("NoiseBorder", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Рендерит бесшовный шум в кэш при первом использовании. Дальше берёт готовый файл.
    nonisolated static func ensureFile(for type: NoiseType) async throws -> URL {
        let url = try cacheDirectory().appendingPathComponent("\(type.rawValue)-\(cacheVersion).wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        return try await Task.detached(priority: .userInitiated) {
            var o = RenderOptions()
            o.targetRMSdBFS = -18
            let tmp = url.appendingPathExtension("tmp")
            try WavWriter.write(NoiseRenderer.render(type, options: o), sampleRate: o.sampleRate, to: tmp)
            _ = try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tmp, to: url)
            return url
        }.value
    }
}
