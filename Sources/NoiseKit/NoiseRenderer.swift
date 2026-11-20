import Foundation

public enum NoiseType: String, CaseIterable, Sendable {
    /// Розовый шум со срезом <150 Гц и >5 кГц: форма спектра близка к речи, лучше всего маскирует разговоры.
    case speech
    case white
    case pink
    case brown
}

public struct RenderOptions {
    public var sampleRate: Int = 48_000
    public var seconds: Double = 60
    public var crossfadeSeconds: Double = 3
    /// Целевой уровень RMS в dBFS. Не LUFS и без A-взвешивания: простая и повторяемая нормализация.
    public var targetRMSdBFS: Double = -32
    public var seed: UInt64 = 1
    /// Тембр: подъём (или спад) в полосе разборчивости речи с пиком около 3 кГц, в дБ.
    /// Для речевого шума при подъёме ещё и раздвигается верхний срез с 5 до 8 кГц:
    /// громкая и особенно женская речь «прорезается» именно в 2–6 кГц.
    public var presenceDB: Double = 0
    public init() {}

    /// Верхний срез речевого шума: 5 кГц по умолчанию, до 8 кГц на максимальной яркости.
    public var speechLowpassHz: Double { 5000 + max(0, min(presenceDB, Tone.maximum)) / Tone.maximum * 3000 }
}

/// Шаги регулятора тембра (дБ в полосе разборчивости).
public enum Tone {
    public static let steps: [Double] = [-6, -3, 0, 3, 6, 9]
    public static let `default`: Double = 0
    public static var maximum: Double { steps.last! }
    public static func nearestIndex(_ db: Double) -> Int {
        steps.indices.min { abs(steps[$0] - db) < abs(steps[$1] - db) } ?? 2
    }
}

/// Рендер бесшовных стереофонических шумовых петель. Каналы независимы (шире и приятнее на слух).
public enum NoiseRenderer {
    public static func render(_ type: NoiseType, options o: RenderOptions = RenderOptions()) -> [[Float]] {
        (0..<2).map { ch in
            var rng = SplitMix64(seed: o.seed &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(ch) &+ 1)
            let loop = renderChannel(type, options: o, rng: &rng)
            return normalize(loop, targetRMSdBFS: o.targetRMSdBFS)
        }
    }

    static func renderChannel(_ type: NoiseType, options o: RenderOptions, rng: inout SplitMix64) -> [Float] {
        let n = Int(o.seconds * Double(o.sampleRate))
        let x = Int(o.crossfadeSeconds * Double(o.sampleRate))
        let warmup = o.sampleRate
        let total = warmup + n + x

        var s = [Double](repeating: 0, count: total)
        var pink = PinkFilter()
        var brown = 0.0
        for i in 0..<total {
            let w = rng.nextUniform()
            switch type {
            case .white: s[i] = w
            case .pink, .speech: s[i] = pink.process(w)
            case .brown:
                brown = 0.999 * brown + w
                s[i] = brown
            }
        }

        // Срезы: убираем DC и инфранизкие для всех, речевой шум режем по бокам.
        var chain: [Biquad] = Biquad.highpass(freq: 20, rate: o.sampleRate, stages: 1)
        if type == .speech {
            chain += Biquad.highpass(freq: 150, rate: o.sampleRate, stages: 2)
            chain += Biquad.lowpass(freq: o.speechLowpassHz, rate: o.sampleRate, stages: 2)
        }
        if o.presenceDB != 0 {
            chain.append(Biquad.peaking(freq: 3000, q: 0.7, gainDB: o.presenceDB, rate: o.sampleRate))
        }
        for i in 0..<total {
            var v = s[i]
            for k in chain.indices { v = chain[k].process(v) }
            s[i] = v
        }

        // Бесшовная петля: хвост длиной x равномерно по мощности подмешивается в начало.
        let body = Array(s[warmup..<(warmup + n + x)])
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            if i < x {
                let t = Double.pi / 2 * Double(i) / Double(x)
                out[i] = Float(body[n + i] * cos(t) + body[i] * sin(t))
            } else {
                out[i] = Float(body[i])
            }
        }
        return out
    }

    static func normalize(_ a: [Float], targetRMSdBFS: Double) -> [Float] {
        let rms = (a.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(a.count)).squareRoot()
        let gain = Float(pow(10, targetRMSdBFS / 20) / rms)
        return a.map { $0 * gain }
    }
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Равномерно в [-1, 1).
    mutating func nextUniform() -> Double {
        Double(next() >> 11) / Double(1 << 52) - 1
    }
}

/// Розовый шум, фильтр Пола Келлета (refined): наклон -3 дБ/окт.
struct PinkFilter {
    var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0
    mutating func process(_ w: Double) -> Double {
        b0 = 0.99886 * b0 + w * 0.0555179
        b1 = 0.99332 * b1 + w * 0.0750759
        b2 = 0.96900 * b2 + w * 0.1538520
        b3 = 0.86650 * b3 + w * 0.3104856
        b4 = 0.55000 * b4 + w * 0.5329522
        b5 = -0.7616 * b5 - w * 0.0168980
        let y = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362
        b6 = w * 0.115926
        return y
    }
}

/// Бикуад Баттерворта 2-го порядка (RBJ), каскад даёт 4-й порядок и т. д.
struct Biquad {
    var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var z1 = 0.0, z2 = 0.0

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    private static func make(freq: Double, rate: Int, high: Bool) -> Biquad {
        let w0 = 2 * Double.pi * freq / Double(rate)
        let alpha = sin(w0) / (2 * (1 / 2.0.squareRoot()))
        let c = cos(w0)
        let a0 = 1 + alpha
        var f = Biquad()
        if high {
            f.b0 = (1 + c) / 2 / a0; f.b1 = -(1 + c) / a0; f.b2 = (1 + c) / 2 / a0
        } else {
            f.b0 = (1 - c) / 2 / a0; f.b1 = (1 - c) / a0; f.b2 = (1 - c) / 2 / a0
        }
        f.a1 = -2 * c / a0
        f.a2 = (1 - alpha) / a0
        return f
    }
    /// Колокол (RBJ peaking EQ).
    static func peaking(freq: Double, q: Double, gainDB: Double, rate: Int) -> Biquad {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * freq / Double(rate)
        let alpha = sin(w0) / (2 * q)
        let c = cos(w0)
        let a0 = 1 + alpha / a
        var f = Biquad()
        f.b0 = (1 + alpha * a) / a0
        f.b1 = -2 * c / a0
        f.b2 = (1 - alpha * a) / a0
        f.a1 = -2 * c / a0
        f.a2 = (1 - alpha / a) / a0
        return f
    }
    static func highpass(freq: Double, rate: Int, stages: Int) -> [Biquad] {
        (0..<stages).map { _ in make(freq: freq, rate: rate, high: true) }
    }
    static func lowpass(freq: Double, rate: Int, stages: Int) -> [Biquad] {
        (0..<stages).map { _ in make(freq: freq, rate: rate, high: false) }
    }
}
