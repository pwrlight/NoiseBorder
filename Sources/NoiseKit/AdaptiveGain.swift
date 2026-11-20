import Foundation

/// Адаптивная прибавка громкости шума по уровню с микрофона.
///
/// На вход раз в `dt` секунд приходит мощность звука в речевой полосе (см. `LevelMeter`).
/// Микрофон слышит и сам шум из динамика, поэтому:
/// - «фон» — минимум уровня (пауза между фразами), пересчитанный к прибавке 0 дБ;
/// - речь — то, что осталось после вычитания фона, умноженного на прибавку. Прибавку берём максимальную
///   за последние `latency` секунд, потому что AirPlay доносит изменение громкости с задержкой.
///   Вычитаем с запасом, значит речь скорее недооцениваем: шум не может раскачать сам себя.
/// Прибавка поднимается до уровня речи над фоном плавно (не быстрее 1 дБ/с) и опускается ещё медленнее.
public struct AdaptiveGain {
    public struct Config {
        /// Сглаживание вверх и вниз, секунды (постоянные времени).
        public var attack: Double = 4
        public var release: Double = 12
        /// Предел скорости роста, дБ/с: громкость ползёт вверх плавно, а не прыгает на первом громком слове.
        public var maxRiseDBPerSecond: Double = 1
        /// Пик речи удерживается и спадает с этой скоростью, дБ/с: слоги не дёргают громкость.
        public var holdDecayDBPerSecond: Double = 3
        /// Медленный рост фона, дБ/с: подстройка под вентиляцию и т. п. В паузах речи фон и так обновляется.
        public var floorRiseDBPerSecond: Double = 0.1
        /// Задержка AirPlay между сменой громкости и её появлением в микрофоне, секунды.
        public var latency: Double = 3
        public init() {}
    }

    public var config: Config
    public private(set) var boostDB: Double = 0
    /// Фон в единицах мощности при нулевой прибавке.
    public private(set) var floor: Double?
    private var hold: Double = 0
    private var settle: Double = 0
    private var history: [(t: Double, db: Double)] = []
    private var time: Double = 0

    public init(config: Config = Config()) { self.config = config }

    /// Забыть фон и прибавку: громкость шума поменялась (старт, смена тембра, ползунок).
    /// Следующие `latency` секунд фон просто следует за уровнем.
    public mutating func relearn() {
        floor = nil
        boostDB = 0
        hold = 0
        settle = config.latency
        history.removeAll()
    }

    /// - Parameters:
    ///   - power: средняя мощность за кадр (линейная, единицы не важны, важны отношения).
    ///   - dt: длина кадра, секунды.
    ///   - maxBoostDB: допустимая прибавка сейчас. 0 значит «нельзя» (идёт нарастание): тогда фон переучивается.
    /// - Returns: прибавка в дБ, которую нужно применить.
    public mutating func update(power: Double, dt: Double, maxBoostDB: Double) -> Double {
        time += dt
        guard power.isFinite, power > 0 else { return boostDB }
        if maxBoostDB <= 0 {
            // Громкость шума сейчас не наша (нарастание, пауза): учиться заново после неё.
            relearn()
            floor = power
            return 0
        }
        history.append((time, boostDB))
        history.removeAll { time - $0.t > config.latency }
        let dbs = history.map(\.db)
        let gMax = pow(10, (dbs.max() ?? boostDB) / 10)
        let gMin = pow(10, (dbs.min() ?? boostDB) / 10)

        // Фон: сверху оценка (делим на минимальную прибавку), чтобы фон не занижался.
        let compensated = power / gMin
        if settle > 0 || floor == nil {
            settle -= dt
            floor = compensated
            return boostDB
        }
        var fl = floor!
        if compensated < fl {
            fl = compensated
        } else {
            fl *= pow(10, config.floorRiseDBPerSecond * dt / 10)
        }
        floor = fl

        // Речь над фоном, дБ. Шум вычитаем с запасом (максимальная прибавка за окно задержки).
        let speech = max(power - fl * gMax, fl * 1e-6)
        let excess = 10 * log10(speech / fl)
        hold = max(excess, hold - config.holdDecayDBPerSecond * dt)

        let target = min(max(hold, 0), maxBoostDB)
        let tau = target > boostDB ? config.attack : config.release
        var step = (target - boostDB) * (1 - exp(-dt / tau))
        step = min(step, config.maxRiseDBPerSecond * dt)
        boostDB += step
        boostDB = min(boostDB, maxBoostDB)
        return boostDB
    }
}

/// Уровень с микрофона в речевой полосе 300–3500 Гц, мощность по кадрам фиксированной длины.
public struct LevelMeter {
    public let frameSeconds: Double
    private var chain: [Biquad]
    private let frameLength: Int
    private var sum = 0.0
    private var count = 0

    public init(sampleRate: Double, frameSeconds: Double = 0.1) {
        let rate = Int(sampleRate.rounded())
        self.frameSeconds = frameSeconds
        frameLength = max(1, Int(sampleRate * frameSeconds))
        chain = Biquad.highpass(freq: 300, rate: rate, stages: 2) + Biquad.lowpass(freq: 3500, rate: rate, stages: 2)
    }

    /// Пропускает отсчёты, возвращает мощности законченных кадров.
    public mutating func process(_ samples: UnsafeBufferPointer<Float>) -> [Double] {
        var frames: [Double] = []
        for x in samples {
            var v = Double(x)
            for k in chain.indices { v = chain[k].process(v) }
            sum += v * v
            count += 1
            if count == frameLength {
                frames.append(sum / Double(count))
                sum = 0
                count = 0
            }
        }
        return frames
    }
}
