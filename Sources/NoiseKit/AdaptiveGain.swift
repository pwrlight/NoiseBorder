import Foundation

/// Адаптивная прибавка громкости шума по уровню с микрофона.
///
/// На вход раз в `dt` секунд приходит мощность звука в речевой полосе (см. `LevelMeter`).
/// Микрофон слышит и сам шум из динамика, поэтому:
/// - «фон» — минимум уровня (пауза между фразами), пересчитанный к прибавке 0 дБ;
/// - речь — то, что осталось после вычитания фона, умноженного на прибавку. Прибавку берём максимальную
///   за последние `latency` секунд, потому что AirPlay доносит изменение громкости с задержкой.
///   Вычитаем с запасом, значит речь скорее недооцениваем: шум не может раскачать сам себя.
/// Реагирует только на продолжительный звук, как у разговора: за последние `window` секунд не меньше доли
/// `minActivity` кадров должны быть громче шума на `triggerDB`. Щелчки, скрипы, стук длятся 0.1–0.2 с
/// (по журналу из офиса пользователя это 125 из 146 всплесков) и прибавку не дают.
/// Цель прибавки: медиана громких кадров окна, а не пик, поэтому одиночный громкий звук её не задирает.
/// Прибавка поднимается: сначала быстрее, потом добирает остаток; опускается медленно.
///
/// Признак голоса (периодичность тона, `LevelMeter`) в решении не участвует: в офисе пользователя фон
/// (вероятно, тональный гул техники) давал 0.25–0.35, как и большинство звуков. Он пишется в журнал калибровки.
public struct AdaptiveGain {
    public struct Config {
        /// Сглаживание вверх и вниз, секунды (постоянные времени).
        /// Рост экспоненциальный: с прыжком в начале. История: 1.5 с резко, 4 с с пределом 1 дБ/с скучно,
        /// 2 с с реакцией на пики снова резко. 3 с и цель по медиане вместо пика.
        public var attack: Double = 3
        public var release: Double = 12
        /// Предел скорости роста, дБ/с. По умолчанию без предела.
        public var maxRiseDBPerSecond: Double = .infinity
        /// Кадр «громкий», если звук над шумом больше `triggerDB`.
        public var triggerDB: Double = 4
        /// Идёт разговор, если за последние `window` секунд громких кадров не меньше доли `minActivity`.
        /// Подобрано по журналу из офиса: время с прибавкой больше 1 дБ упало с 87% до ~10%.
        public var window: Double = 2
        public var minActivity: Double = 0.4
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
    /// Для журнала калибровки: уровень речи над фоном в последнем кадре и идёт ли разговор.
    public private(set) var lastExcessDB: Double = -.infinity
    public private(set) var lastTalking = false
    private var settle: Double = 0
    private var history: [(t: Double, db: Double)] = []
    private var recent: [(t: Double, excess: Double)] = []
    private var time: Double = 0

    public init(config: Config = Config()) { self.config = config }

    /// Забыть фон и прибавку: громкость шума поменялась (старт, смена тембра, ползунок).
    /// Следующие `latency` секунд фон просто следует за уровнем.
    public mutating func relearn() {
        floor = nil
        boostDB = 0
        settle = config.latency
        history.removeAll()
        recent.removeAll()
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

        // Звук над шумом, дБ. Шум вычитаем с запасом (максимальная прибавка за окно задержки).
        let speech = max(power - fl * gMax, fl * 1e-6)
        lastExcessDB = 10 * log10(speech / fl)
        recent.append((time, lastExcessDB))
        recent.removeAll { time - $0.t >= config.window - 1e-9 }
        let frames = max(1, Int((config.window / dt).rounded()))
        let loud = recent.map(\.excess).filter { $0 > config.triggerDB }.sorted()
        let talking = Double(loud.count) >= config.minActivity * Double(frames)
        lastTalking = talking

        let target = talking ? min(loud[loud.count / 2], maxBoostDB) : 0
        let tau = target > boostDB ? config.attack : config.release
        var step = (target - boostDB) * (1 - exp(-dt / tau))
        step = min(step, config.maxRiseDBPerSecond * dt)
        boostDB += step
        boostDB = min(boostDB, maxBoostDB)
        return boostDB
    }
}

/// Уровень с микрофона в речевой полосе 300–3500 Гц и признак голоса, по кадрам фиксированной длины.
///
/// Голос отличаем от прочих звуков по периодичности: гласные звучат с основным тоном 70–400 Гц,
/// и сигнал повторяет себя через период тона. У щелчков клавиатуры, хлопков, шагов, вентиляции и у самого
/// маскирующего шума такой периодичности нет. Перед анализом подъём верхов (pre-emphasis), чтобы розовый шум
/// не давал ложной «периодичности» на низких частотах, и прореживание до ~16 кГц, чтобы было дёшево.
public struct LevelMeter {
    public struct Frame: Sendable {
        public let power: Double
        /// Наибольшая нормированная автокорреляция на лагах периода тона, 0...1.
        public let voicing: Double
        public var isVoiced: Bool { voicing >= LevelMeter.voicedThreshold }
    }
    /// Порог признака голоса. На синтетике шумы дают до 0.32 (чаще 0.2–0.28), гласные под шумом 0.4–0.9.
    /// 0.4 в офисе оказалось слишком строго: реальная речь через стекло, с эхом и под шумом периодична слабее.
    public static let voicedThreshold = 0.3

    public let frameSeconds: Double
    private var chain: [Biquad]
    private let frameLength: Int
    private let decimation: Int
    private let lagRange: ClosedRange<Int>
    private let subLength: Int
    private var sum = 0.0
    private var count = 0
    private var prev = 0.0
    private var decimated: [Double] = []

    public init(sampleRate: Double, frameSeconds: Double = 0.1) {
        let rate = Int(sampleRate.rounded())
        self.frameSeconds = frameSeconds
        frameLength = max(1, Int(sampleRate * frameSeconds))
        chain = Biquad.highpass(freq: 300, rate: rate, stages: 2) + Biquad.lowpass(freq: 3500, rate: rate, stages: 2)
        decimation = max(1, Int(sampleRate / 16000))
        let r = sampleRate / Double(decimation)
        lagRange = Int(r / 400)...Int(r / 70)
        subLength = Int(r * 0.025)
        decimated.reserveCapacity(frameLength / decimation + 1)
    }

    /// Пропускает отсчёты, возвращает законченные кадры.
    public mutating func process(_ samples: UnsafeBufferPointer<Float>) -> [Frame] {
        var frames: [Frame] = []
        for x in samples {
            var v = Double(x)
            for k in chain.indices { v = chain[k].process(v) }
            sum += v * v
            let e = v - 0.95 * prev
            prev = v
            if count % decimation == 0 { decimated.append(e) }
            count += 1
            if count == frameLength {
                frames.append(Frame(power: sum / Double(count), voicing: Self.voicing(decimated, lags: lagRange, sub: subLength)))
                sum = 0
                count = 0
                decimated.removeAll(keepingCapacity: true)
            }
        }
        return frames
    }

    /// Наибольшая нормированная автокорреляция по подкадрам 25 мс на лагах периода тона.
    static func voicing(_ d: [Double], lags: ClosedRange<Int>, sub: Int) -> Double {
        var best = 0.0
        var s = 0
        while s + sub + lags.upperBound <= d.count {
            var e0 = 0.0
            for n in s..<(s + sub) { e0 += d[n] * d[n] }
            if e0 > 0 {
                for lag in lags {
                    var c = 0.0, e1 = 0.0
                    for n in s..<(s + sub) {
                        let y = d[n + lag]
                        c += d[n] * y
                        e1 += y * y
                    }
                    // Делим на среднюю энергию, а не на среднее геометрическое: у затухающего щелчка
                    // (звон фильтра) энергии сдвинутых отрезков разные, и он не сойдёт за голос.
                    best = max(best, 2 * c / (e0 + e1))
                }
            }
            s += sub
        }
        return best
    }
}
