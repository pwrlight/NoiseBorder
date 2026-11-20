import AVFoundation
import AppKit
import Combine
import NoiseKit

/// Воспроизведение шума. Вывод идёт через AVQueuePlayer, поэтому AirPlay-маршрут (кнопка AVRoutePickerView)
/// действует только на звук этого приложения, а системный вывод Mac не меняется.
@MainActor
final class NoisePlayer: ObservableObject {
    private enum Key {
        static let type = "noiseType", volume = "volume", language = "language", tone = "tone"
        static let adaptive = "adaptive", headroom = "adaptiveHeadroom"
    }
    /// Версия рендера в имени файла кэша: смена параметров генератора инвалидирует кэш.
    private nonisolated static let cacheVersion = "v2-18dbfs"

    @Published var type: NoiseType {
        didSet {
            UserDefaults.standard.set(type.rawValue, forKey: Key.type)
            if isPlaying { restartItems() }
        }
    }
    /// Тембр в дБ (шаги `Tone.steps`). Смена перерисовывает шум и подменяет его на лету.
    @Published var tone: Double {
        didSet {
            UserDefaults.standard.set(tone, forKey: Key.tone)
            if isPlaying { restartItems() }
        }
    }
    @Published var volume: Float {
        didSet {
            let v = VolumePolicy.clamp(volume)
            if v != volume { volume = v }  // повторно didSet не вызывается
            UserDefaults.standard.set(v, forKey: Key.volume)
            gain.relearn()
            if isPlaying, !channelAvailable {
                cancelRamp()
                if fadeTask == nil { player.volume = v }
            }
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

    /// Подстройка под голоса по микрофону. По умолчанию выключена; микрофон работает только пока играет шум.
    @Published var adaptive: Bool {
        didSet {
            UserDefaults.standard.set(adaptive, forKey: Key.adaptive)
            if adaptive, isPlaying { startMic() } else if !adaptive { stopMic() }
        }
    }
    /// Наибольшая прибавка к громкости шума, дБ (шаги `headroomSteps`).
    @Published var headroomDB: Double {
        didSet { UserDefaults.standard.set(headroomDB, forKey: Key.headroom) }
    }
    static let headroomSteps: [Double] = [3, 6, 9, 12]
    /// Текущая прибавка для показа, с шагом 0.5 дБ.
    @Published private(set) var boostDB: Double = 0

    let player = AVQueuePlayer()
    private lazy var channel = ChannelVolume(player: player)
    private var fadeTask: Task<Void, Never>?
    /// Плавное нарастание после старта и после смены тембра или типа.
    private var rampTask: Task<Void, Never>?
    private var rampUsesChannel = false
    private var rampTarget: Float = 0
    /// Длительность нарастания, секунды.
    private let rampSeconds: Double = 9
    private var lostRouteTask: Task<Void, Never>?
    private var startTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()
    private let mic = MicMonitor()
    private var gain = AdaptiveGain()
    private var micLog: MicLog?
    /// Сколько прибавки сейчас добавлено к громкости приёмника (в единицах его шкалы 0...1).
    private var appliedChannelDelta: Float = 0
    private var lastBoostSet = Date.distantPast
    /// Допущение: шкала громкости AirPlay-приёмника 0...1 линейна в децибелах на 30 дБ (так в RAOP).
    /// Для конкретного роутера может отличаться: потолок прибавки подбирается на слух.
    private static let channelDBRange: Double = 30

    init() {
        let d = UserDefaults.standard
        type = NoiseType(rawValue: d.string(forKey: Key.type) ?? "") ?? .speech
        language = Language(rawValue: d.string(forKey: Key.language) ?? "") ?? .systemDefault
        tone = d.object(forKey: Key.tone) == nil ? Tone.default : Tone.steps[Tone.nearestIndex(d.double(forKey: Key.tone))]
        Self.removeStaleCache()
        volume = d.object(forKey: Key.volume) == nil ? VolumePolicy.default : VolumePolicy.clamp(d.float(forKey: Key.volume))
        adaptive = d.bool(forKey: Key.adaptive)
        let h = d.double(forKey: Key.headroom)
        headroomDB = Self.headroomSteps.contains(h) ? h : 6
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
                let url = try await Self.ensureFile(for: type, tone: tone)
                guard !Task.isCancelled else { return }
                player.removeAllItems()
                enqueue(url); enqueue(url)
                refreshChannel()
                rampIn()
                player.play()
                isPlaying = true
                startMonitor()
                if adaptive { startMic() }
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
        // Остановка посреди нарастания или с прибавкой: вернуть приёмнику громкость пользователя уже после паузы.
        let restoreChannel: Float? = (rampTask != nil && rampUsesChannel) ? rampTarget
            : (appliedChannelDelta != 0 ? channelVolume : nil)
        mic.stop()
        micLog = nil
        resetBoost()
        cancelRamp()
        let finish = { [weak self] in
            self?.fadeTask = nil
            self?.player.pause()
            self?.player.removeAllItems()
            self?.player.volume = 0
            if let v = restoreChannel { self?.channel.set(v) }
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
            if isPlaying, fadeTask == nil, rampTask == nil { player.volume = targetPlayerVolume }
        }
        // Во время нарастания ползунок показывает целевую громкость, а не промежуточную.
        // С прибавкой ползунок показывает громкость пользователя без неё. Громкость поменяли в другом месте
        // (меню AirPlay): это новая громкость пользователя.
        // Пока прибавка меняется, приёмник может отдавать громкость с опозданием: сверяем только спустя 2 с
        // после нашей последней установки, иначе своя же прибавка ушла бы в громкость пользователя.
        let settled = appliedChannelDelta == 0 || Date().timeIntervalSince(lastBoostSet) > 2
        if available, rampTask == nil, settled, let v = channel.value {
            let tolerance: Float = appliedChannelDelta == 0 ? 0.001 : 0.02
            if abs(v - (channelVolume + appliedChannelDelta)) > tolerance {
                channelVolume = v
                appliedChannelDelta = 0
                gain.relearn()
            }
        }
    }

    func setChannelVolume(_ v: Float) {
        let c = min(max(v.isFinite ? v : 0, 0), 1)
        cancelRamp()
        channelVolume = c
        resetBoost()
        channel.set(c)
    }

    // MARK: Подстройка под голоса

    private func startMic() {
        guard !mic.isRunning else { return }
        Task {
            guard await MicMonitor.requestAccess() else {
                adaptive = false
                message = .micDenied
                return
            }
            guard adaptive, isPlaying, !mic.isRunning else { return }
            gain.relearn()
            micLog = MicLog()
            do {
                try mic.start { [weak self] frame, dt in self?.micFrame(frame, dt: dt) }
            } catch {
                adaptive = false
                message = .micFailed("\(error)")
            }
        }
    }

    private func stopMic() {
        mic.stop()
        micLog = nil
        let hadBoost = appliedChannelDelta != 0 || boostDB != 0
        resetBoost()
        guard isPlaying, hadBoost, rampTask == nil, fadeTask == nil else { return }
        if channelAvailable { channel.set(channelVolume) } else { player.volume = volume }
    }

    private func resetBoost() {
        gain.relearn()
        appliedChannelDelta = 0
        if boostDB != 0 { boostDB = 0 }
    }

    /// Кадр уровня с микрофона: пересчитать прибавку и применить её к громкости приёмника или плеера.
    private func micFrame(_ frame: LevelMeter.Frame, dt: Double) {
        guard isPlaying, adaptive else { return }
        // Во время нарастания громкость шума меняем не мы: прибавку не даём, фон переучивается.
        let busy = rampTask != nil || fadeTask != nil
        let room: Double
        if busy {
            room = 0
        } else if channelAvailable {
            room = Double(1 - channelVolume) * Self.channelDBRange
        } else {
            room = volume > 0 ? 20 * log10(Double(VolumePolicy.maximum / volume)) : 0
        }
        let b = gain.update(power: frame.power, dt: dt, maxBoostDB: max(0, min(headroomDB, room)))
        micLog?.write(frame, gain: gain)
        let shown = (b * 2).rounded() / 2
        if shown != boostDB { boostDB = shown }
        guard !busy else { return }
        if channelAvailable {
            let delta = Float(b / Self.channelDBRange)
            // Шаг 0.01 шкалы ≈ 0.3 дБ: на слух не заметно, а приёмник не дёргаем 10 раз в секунду.
            if abs(delta - appliedChannelDelta) >= 0.01 || (delta == 0 && appliedChannelDelta != 0) {
                appliedChannelDelta = delta
                lastBoostSet = Date()
                channel.set(min(channelVolume + delta, 1))
            }
        } else {
            player.volume = min(volume * Float(pow(10, b / 20)), VolumePolicy.maximum)
        }
    }

    // MARK: Нарастание

    /// Уводит громкость в ноль и, как только воспроизведение реально началось, поднимает её до уровня пользователя.
    /// На AirPlay-приёмнике с управляемой громкостью двигаем громкость приёмника: `player.volume` там не действует.
    /// Иначе двигаем `player.volume`. Ждём старта, потому что AirPlay буферизует звук на 1–2 секунды.
    private func rampIn() {
        cancelRamp()
        fadeTask?.cancel(); fadeTask = nil
        let useChannel = channelAvailable
        let target: Float = useChannel ? channelVolume : volume
        rampUsesChannel = useChannel
        rampTarget = target
        resetBoost()
        if useChannel {
            player.volume = 1
            channel.set(0)
        } else {
            player.volume = 0
        }
        let seconds = rampSeconds
        rampTask = Task { [weak self] in
            for _ in 0..<100 {  // до 5 секунд ждём реального старта
                guard let self, !Task.isCancelled else { return }
                if self.player.timeControlStatus == .playing, self.player.currentTime().seconds > 0.05 { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            let steps = 30
            for i in 1...steps {
                try? await Task.sleep(nanoseconds: UInt64(seconds / Double(steps) * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                let x = Float(i) / Float(steps)
                if useChannel {
                    self.channel.set(target * x)          // шкала приёмника уже близка к восприятию
                } else {
                    self.player.volume = target * x * x   // player.volume линейный по амплитуде
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.rampTask = nil
        }
    }

    private func cancelRamp() {
        rampTask?.cancel()
        rampTask = nil
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
        let wanted = type, wantedTone = tone
        Task {
            guard let url = try? await Self.ensureFile(for: wanted, tone: wantedTone),
                  isPlaying, type == wanted, tone == wantedTone else { return }
            // Если идёт нарастание на приёмнике, сначала вернуть цель, чтобы rampIn взял верный уровень.
            if rampTask != nil, rampUsesChannel { channelVolume = rampTarget }
            refreshChannel()
            rampIn()                   // старый шум сразу в тишину, новый нарастает
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
                guard let self, self.isPlaying, self.type == wanted, self.url(matches: url) else { return }
                self.enqueue(url)
            }
        }
        player.insert(item, after: nil)
    }

    /// Текущий элемент очереди играет тот же файл (тип и тембр не менялись).
    private func url(matches url: URL) -> Bool {
        (player.currentItem?.asset as? AVURLAsset)?.url == url
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

    /// Удаляет файлы кэша от прошлых версий генератора, чтобы они не копились.
    nonisolated static func removeStaleCache() {
        guard let dir = try? cacheDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where !f.lastPathComponent.hasSuffix("-\(cacheVersion).wav") {
            try? FileManager.default.removeItem(at: f)
        }
    }

    /// Рендерит бесшовный шум в кэш при первом использовании. Дальше берёт готовый файл.
    nonisolated static func ensureFile(for type: NoiseType, tone: Double) async throws -> URL {
        let url = try cacheDirectory().appendingPathComponent("\(type.rawValue)-t\(Int(tone))-\(cacheVersion).wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        return try await Task.detached(priority: .userInitiated) {
            var o = RenderOptions()
            o.targetRMSdBFS = -18
            o.presenceDB = tone
            let tmp = url.appendingPathExtension("tmp")
            try WavWriter.write(NoiseRenderer.render(type, options: o), sampleRate: o.sampleRate, to: tmp)
            _ = try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tmp, to: url)
            return url
        }.value
    }
}
