import Foundation
import NoiseKit

// Проверки генератора шума. Запуск: swift run noise-check. Ненулевой код выхода при провале.

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String) {
    print("\(ok ? "ok  " : "FAIL") \(name): \(detail)")
    if !ok { failures += 1 }
}
func f(_ x: Double) -> String { String(format: "%.2f", x) }

// MARK: FFT и анализ

func fft(_ re: inout [Double], _ im: inout [Double]) {
    let n = re.count
    var j = 0
    for i in 1..<n {
        var bit = n >> 1
        while j & bit != 0 { j ^= bit; bit >>= 1 }
        j ^= bit
        if i < j { re.swapAt(i, j); im.swapAt(i, j) }
    }
    var len = 2
    while len <= n {
        let ang = -2 * Double.pi / Double(len)
        for i in stride(from: 0, to: n, by: len) {
            for k in 0..<len / 2 {
                let wr = cos(ang * Double(k)), wi = sin(ang * Double(k))
                let a = i + k, b = i + k + len / 2
                let tr = re[b] * wr - im[b] * wi, ti = re[b] * wi + im[b] * wr
                re[b] = re[a] - tr; im[b] = im[a] - ti
                re[a] += tr; im[a] += ti
            }
        }
        len <<= 1
    }
}

/// Мощность в октавных полосах (Welch, окно Ханна), дБ.
func octaveBandsDB(_ x: [Float], rate: Int, centers: [Double]) -> [Double] {
    let n = 8192
    var psd = [Double](repeating: 0, count: n / 2)
    let win = (0..<n).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n)) }
    var segs = 0
    var start = 0
    while start + n <= x.count {
        var re = (0..<n).map { Double(x[start + $0]) * win[$0] }
        var im = [Double](repeating: 0, count: n)
        fft(&re, &im)
        for k in 0..<n / 2 { psd[k] += re[k] * re[k] + im[k] * im[k] }
        segs += 1
        start += n / 2
    }
    let binHz = Double(rate) / Double(n)
    return centers.map { c in
        let lo = c / 2.0.squareRoot(), hi = c * 2.0.squareRoot()
        var p = 0.0
        for k in 1..<n / 2 {
            let hz = Double(k) * binHz
            if hz >= lo && hz < hi { p += psd[k] }
        }
        return 10 * log10(p / Double(segs))
    }
}

func rms(_ a: ArraySlice<Float>) -> Double {
    (a.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(a.count)).squareRoot()
}
func db(_ v: Double) -> Double { 20 * log10(v) }

// MARK: Проверки

var o = RenderOptions()
o.seconds = 20
o.crossfadeSeconds = 2
let rate = o.sampleRate
let mid: [Double] = [125, 250, 500, 1000, 2000, 4000]

for type in NoiseType.allCases {
    print("\n== \(type.rawValue)")
    let ch = NoiseRenderer.render(type, options: o)
    let l = ch[0], r = ch[1]

    // Уровень и пики
    let level = db(rms(l[...]))
    check("уровень RMS", abs(level - o.targetRMSdBFS) < 0.1, "\(f(level)) dBFS, цель \(f(o.targetRMSdBFS))")
    let peak = l.map { abs($0) }.max()!
    check("пики без клиппинга", peak < 0.5, "peak \(f(Double(peak)))")

    // Спектр: в октавных полосах мощность растёт/падает на slope дБ за октаву
    let bands = octaveBandsDB(l, rate: rate, centers: mid)
    let expectedSlope: Double? = {
        switch type {
        case .white: return 3
        case .pink: return 0
        case .brown: return -3
        case .speech: return nil
        }
    }()
    if let s = expectedSlope {
        let slope = (bands.last! - bands.first!) / Double(mid.count - 1)
        check("наклон по октавам", abs(slope - s) < 0.7,
              "\(f(slope)) дБ/окт, ожидали \(f(s)) (полосы \(bands.map(f).joined(separator: " ")))")
    } else {
        let all = octaveBandsDB(l, rate: rate, centers: [62.5, 250, 500, 1000, 2000, 4000, 8000, 16000])
        let ref = all[3]
        let flat = [all[1], all[2], all[4], all[5]].map { abs($0 - ref) }.max()!
        check("плато 250..4000 Гц", flat < 4, "отклонение до \(f(flat)) дБ от 1 кГц (250: \(f(all[1] - ref)), 500: \(f(all[2] - ref)), 2к: \(f(all[4] - ref)), 4к: \(f(all[5] - ref)))")
        check("срез басов", all[0] - ref < -10, "62 Гц: \(f(all[0] - ref)) дБ относительно 1 кГц")
        check("срез верхов", all[6] - ref < -10, "8 кГц: \(f(all[6] - ref)) дБ, 16 кГц: \(f(all[7] - ref)) дБ")
    }

    // Шов петли: скачок на стыке не больше обычного скачка между соседними отсчётами
    for (i, c) in [l, r].enumerated() {
        let diffs = zip(c.dropFirst(), c).map { Double($0 - $1) }
        let sd = (diffs.reduce(0) { $0 + $1 * $1 } / Double(diffs.count)).squareRoot()
        let seam = abs(Double(c[0] - c[c.count - 1]))
        check("шов петли, канал \(i)", seam < 4.5 * sd, "скачок \(f(seam / sd))σ")
    }

    // Постоянство громкости в зоне кроссфейда
    let xf = Int(o.crossfadeSeconds * Double(rate))
    let dipDB = db(rms(l[0..<xf])) - db(rms(l[xf..<l.count]))
    check("громкость в кроссфейде", abs(dipDB) < 1.0, "\(f(dipDB)) дБ относительно остального")

    // Каналы независимы
    var sxy = 0.0, sxx = 0.0, syy = 0.0
    for i in 0..<l.count { sxy += Double(l[i] * r[i]); sxx += Double(l[i] * l[i]); syy += Double(r[i] * r[i]) }
    let corr = sxy / (sxx * syy).squareRoot()
    check("каналы не коррелируют", abs(corr) < 0.1, "corr \(f(corr))")

    // Детерминизм
    let again = NoiseRenderer.render(type, options: o)
    check("детерминизм по seed", again[0] == l, "одинаковый результат")
}

print("\n== тембр (речевой шум)")
// Полоса разборчивости 2–4 кГц относительно 500 Гц: «ярче» поднимает её, «темнее» опускает.
func clarity(_ db: Double) -> Double {
    var t = o
    t.presenceDB = db
    let b = octaveBandsDB(NoiseRenderer.render(.speech, options: t)[0], rate: rate, centers: [500, 2000, 4000])
    return (b[1] + b[2]) / 2 - b[0]
}
let c0 = clarity(0), cUp = clarity(6), cDown = clarity(-6)
check("ярче +6 дБ поднимает 2–4 кГц", cUp - c0 > 4, "\(f(cUp - c0)) дБ")
check("темнее −6 дБ опускает 2–4 кГц", c0 - cDown > 3, "\(f(c0 - cDown)) дБ")
for gain in [Tone.steps.first!, Tone.maximum] {
    var t = o
    t.presenceDB = gain
    let ch = NoiseRenderer.render(.speech, options: t)
    let lvl = db(rms(ch[0][...]))
    let pk = ch[0].map { abs($0) }.max()!
    check("тембр \(f(gain)): уровень и пики", abs(lvl - o.targetRMSdBFS) < 0.1 && pk < 0.5, "RMS \(f(lvl)), peak \(f(Double(pk)))")
    let diffs = zip(ch[0].dropFirst(), ch[0]).map { Double($0 - $1) }
    let sd = (diffs.reduce(0) { $0 + $1 * $1 } / Double(diffs.count)).squareRoot()
    let seam = abs(Double(ch[0][0] - ch[0][ch[0].count - 1]))
    check("тембр \(f(gain)): шов петли", seam < 4.5 * sd, "скачок \(f(seam / sd))σ")
}
check("ближайший шаг тембра", Tone.steps[Tone.nearestIndex(4)] == 3 && Tone.steps[Tone.nearestIndex(100)] == Tone.maximum, "4 -> 3, 100 -> max")

// MARK: Тестовые сигналы для детектора голоса (48 кГц)
struct Sig {
    static let rate = 48000.0
    static func rng(_ seed: UInt64) -> () -> Double {
        var st = seed
        return { st = st &* 6364136223846793005 &+ 1442695040888963407; return Double(st >> 11) / Double(1 << 53) * 2 - 1 }
    }
    static func rmsOf(_ x: [Double]) -> Double { (x.reduce(0) { $0 + $1 * $1 } / Double(x.count)).squareRoot() }
    static func scaled(_ x: [Double], rms: Double) -> [Double] { let k = rms / max(rmsOf(x), 1e-12); return x.map { $0 * k } }
    /// Гласная: гармоники основного тона с формантами, вибрато ±3% на 5 Гц.
    static func vowel(f0: Double, seconds: Double, formants: [Double] = [800, 1300, 2600]) -> [Double] {
        let n = Int(seconds * rate)
        var out = [Double](repeating: 0, count: n)
        var phase = 0.0
        let kMax = Int(4000 / f0)
        let amps = (1...kMax).map { k -> Double in
            let fk = Double(k) * f0
            return formants.reduce(0.05) { $0 + 1 / (1 + pow((fk - $1) / 120, 2)) }
        }
        for i in 0..<n {
            let t = Double(i) / rate
            phase += 2 * Double.pi * f0 * (1 + 0.03 * sin(2 * Double.pi * 5 * t)) / rate
            var v = 0.0
            for k in 1...kMax { v += amps[k - 1] * sin(Double(k) * phase) }
            out[i] = v
        }
        return out
    }
    static func masking(_ type: NoiseType, seconds: Double) -> [Double] {
        var o = RenderOptions(); o.seconds = seconds; o.crossfadeSeconds = 1
        return NoiseRenderer.render(type, options: o)[0].map(Double.init)
    }
    /// Щелчки клавиатуры: 3 мс затухающего шума каждые 150 мс.
    static func clicks(seconds: Double, every: Double = 0.15, length: Double = 0.003) -> [Double] {
        let n = Int(seconds * rate), r = rng(5)
        var out = [Double](repeating: 0, count: n)
        var start = 0
        while start < n {
            let len = Int(length * rate)
            for j in 0..<len where start + j < n { out[start + j] = r() * exp(-Double(j) / Double(len) * 4) }
            start += Int(every * rate)
        }
        return out
    }
    static func mix(_ a: [Double], _ b: [Double]) -> [Double] { zip(a, b).map { $0 + $1 } }
    static func frames(_ x: [Double]) -> [LevelMeter.Frame] {
        var m = LevelMeter(sampleRate: rate)
        let f = x.map(Float.init)
        return f.withUnsafeBufferPointer { m.process($0) }
    }
    static func voicedShare(_ x: [Double]) -> Double {
        let fr = frames(x)
        return Double(fr.filter(\.isVoiced).count) / Double(fr.count)
    }
}

print("\n== признак голоса (только для журнала калибровки)")
// Голос (гласные с вибрато, основной тон 110/220/300 Гц) под речевым шумом должен узнаваться,
// а шумы, щелчки клавиатуры и хлопки нет.
do {
    let sec = 5.0
    let noise = Sig.scaled(Sig.masking(.speech, seconds: sec), rms: 0.1)
    let others: [(String, [Double])] = [
        ("речевой шум", noise),
        ("розовый шум", Sig.scaled(Sig.masking(.pink, seconds: sec), rms: 0.1)),
        ("белый шум", Sig.scaled(Sig.masking(.white, seconds: sec), rms: 0.1)),
        ("коричневый шум (гул вентиляции)", Sig.scaled(Sig.masking(.brown, seconds: sec), rms: 0.1)),
        ("клавиатура в тишине", Sig.clicks(seconds: sec)),
        ("клавиатура под шумом", Sig.mix(noise, Sig.scaled(Sig.clicks(seconds: sec), rms: 0.3))),
        ("хлопки дверью", Sig.clicks(seconds: sec, every: 1, length: 0.05)),
    ]
    for (name, x) in others {
        let fr = Sig.frames(x)
        let share = Double(fr.filter(\.isVoiced).count) / Double(fr.count)
        check("не голос: \(name)", share < 0.05, "кадров с голосом \(f(share * 100))%, признак до \(f(fr.map(\.voicing).max()!))")
    }
    for f0 in [110.0, 220, 300] {
        let v = Sig.vowel(f0: f0, seconds: sec)
        for snr in [0.0, 3] {
            let share = Sig.voicedShare(Sig.mix(noise, Sig.scaled(v, rms: 0.1 * pow(10, snr / 20))))
            check("голос \(Int(f0)) Гц на \(Int(snr)) дБ громче шума", share >= 0.95, "кадров с голосом \(f(share * 100))%")
        }
    }
}

print("\n== подстройка под голоса (микрофон)")
// Модель комнаты: микрофон слышит фон помещения, наш шум (с задержкой AirPlay 2 с) и речь соседей.
// Речь: слоги по 200 мс с заполнением ~70% и паузы 0.5 с каждые ~3 с.
struct Room {
    var ambient = 0.3, noise = 1.0
    var latency = 2.0
}
/// `speech`: мощность голоса во времени; `bursts`: мощность прочих звуков без голоса (щелчки, хлопки).
func simulate(_ room: Room, seconds: Double, maxBoost: Double = 12,
              speech: (Double) -> Double, bursts: (Double) -> Double = { _ in 0 },
              gain: inout AdaptiveGain, seed: UInt64 = 7) -> [Double] {
    let dt = 0.1
    var state = seed
    func uniform() -> Double {  // детерминированный ГПСЧ (LCG), чтобы проверка повторялась
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
    var applied: [Double] = []
    var out: [Double] = []
    let lag = Int(room.latency / dt)
    var t = 0.0
    var syllableOn = true
    while t < seconds {
        if Int(t * 10) % 2 == 0 { syllableOn = uniform() < 0.7 }
        let inPause = t.truncatingRemainder(dividingBy: 3) > 2.5
        let sp = speech(t)
        let g = applied.count > lag ? applied[applied.count - 1 - lag] : 0
        var p = room.ambient + room.noise * pow(10, g / 10)
        if sp > 0, syllableOn, !inPause { p += sp }
        p += bursts(t)
        p *= pow(10, (uniform() - 0.5) * 0.6 / 10)  // ±0.3 дБ разброс кадра
        let b = gain.update(power: p, dt: dt, maxBoostDB: maxBoost)
        applied.append(b)
        out.append(b)
        t += dt
    }
    return out
}
func at(_ a: [Double], _ s: Double) -> Double { a[min(a.count - 1, Int(s * 10))] }
func peak(_ a: [Double], from: Double, to: Double) -> Double { a[Int(from * 10)..<min(a.count, Int(to * 10))].max()! }
let n0 = 1.3  // фон при нулевой прибавке в модели по умолчанию

do {
    var g = AdaptiveGain(); g.relearn()
    // Клавиатура и хлопки на 15 дБ громче фона 5 минут: без голоса прибавки нет.
    let r = simulate(Room(), seconds: 300, speech: { _ in 0 },
                     bursts: { t in t > 30 && t.truncatingRemainder(dividingBy: 0.7) < 0.1 ? 30 * n0 : 0 }, gain: &g)
    check("щелчки и хлопки: прибавки нет", peak(r, from: 0, to: 300) < 0.5, "максимум \(f(peak(r, from: 0, to: 300))) дБ")
}
do {
    var g = AdaptiveGain(); g.relearn()
    // Короткий возглас 0.3 с на 15 дБ громче: не разговор.
    let r = simulate(Room(), seconds: 120, speech: { $0 >= 60 && $0 < 60.3 ? 30 * n0 : 0 }, gain: &g)
    check("одиночный короткий возглас: почти без прибавки", peak(r, from: 0, to: 120) < 1, "максимум \(f(peak(r, from: 0, to: 120))) дБ")
}
do {
    var g = AdaptiveGain(); g.relearn()
    // Скрипы стула по 0.1 с каждые 0.4 с (25% кадров) и скрип 0.6 с подряд, на 15 дБ громче: не разговор.
    let r = simulate(Room(), seconds: 200, speech: { _ in 0 }, bursts: { t in
        (t > 30 && t < 90 && t.truncatingRemainder(dividingBy: 0.4) < 0.1) || (t > 120 && t < 120.6) ? 30 * n0 : 0
    }, gain: &g)
    check("частые скрипы и скрип 0.6 с: прибавки нет", peak(r, from: 0, to: 200) < 0.5, "максимум \(f(peak(r, from: 0, to: 200))) дБ")
}

do {
    var g = AdaptiveGain(); g.relearn()
    let r = simulate(Room(), seconds: 600, speech: { _ in 0 }, gain: &g)
    check("тишина: шум не раскачивается", peak(r, from: 30, to: 600) < 0.5, "максимум прибавки \(f(peak(r, from: 30, to: 600))) дБ за 10 мин")
}
do {
    var g = AdaptiveGain(); g.relearn()
    let r = simulate(Room(), seconds: 240, speech: { $0 >= 60 && $0 < 90 ? 10 * n0 : 0 }, gain: &g)
    let t6 = Double(r.firstIndex { $0 >= 6 } ?? r.count) / 10 - 60
    check("громкая речь (+10 дБ): прыжок, но мягкий", t6 >= 2.5 && t6 <= 6, "+6 дБ через \(f(t6)) с речи (первый вариант ≈1.7 с)")
    check("громкая речь: добирает остаток", at(r, 70) > 8, "через 10 с речи \(f(at(r, 70))) дБ")
    check("громкая речь: не выше уровня речи", peak(r, from: 0, to: 240) < 11.5, "максимум \(f(peak(r, from: 0, to: 240))) дБ")
    check("после речи: плавно возвращается", at(r, 150) < 1 && at(r, 92) > 3, "через 2 с \(f(at(r, 92))) дБ, через 60 с \(f(at(r, 150))) дБ")
    let jumps = zip(r.dropFirst(), r).map { abs($0 - $1) }.max()!
    check("без скачков", jumps < 0.6, "максимальный шаг \(f(jumps)) дБ за 0.1 с")
}
do {
    var g = AdaptiveGain(); g.relearn()
    let r = simulate(Room(ambient: 0, noise: 1), seconds: 300, speech: { $0 >= 30 && $0 < 45 ? 30 : 0 }, gain: &g)
    check("микрофон слышит только шум: нет самовозбуждения", at(r, 120) < 1 && peak(r, from: 120, to: 300) < 1,
          "после речи через 75 с \(f(at(r, 120))) дБ, максимум потом \(f(peak(r, from: 120, to: 300))) дБ")
}
do {
    var g = AdaptiveGain(); g.relearn()
    let r = simulate(Room(), seconds: 260, speech: { $0 >= 60 && $0 < 240 ? 6.3 * n0 : 0 }, gain: &g)
    let tail = r[Int(200 * 10)..<Int(238 * 10)].reduce(0, +) / Double(38 * 10)
    check("долгий разговор 3 мин (+8 дБ): прибавка держится", tail > 4, "в среднем за последние 40 с \(f(tail)) дБ")
}
do {
    var g = AdaptiveGain(); g.relearn()
    let r = simulate(Room(ambient: 4, noise: 1), seconds: 240, speech: { $0 >= 30 && $0 < 50 ? 50 : 0 }, gain: &g)
    check("громкий фон помещения: после речи возвращается", at(r, 150) < 1, "через 100 с \(f(at(r, 150))) дБ (пик \(f(peak(r, from: 0, to: 240))))")
}
do {
    var g = AdaptiveGain(); g.relearn()
    let r = simulate(Room(), seconds: 120, maxBoost: 3, speech: { $0 >= 30 && $0 < 90 ? 30 * n0 : 0 }, gain: &g)
    check("потолок прибавки", peak(r, from: 0, to: 120) <= 3.0001, "максимум \(f(peak(r, from: 0, to: 120))) дБ при потолке 3")
}
do {
    var g = AdaptiveGain(); g.relearn()
    var room = Room()
    var r = simulate(room, seconds: 60, speech: { _ in 0 }, gain: &g)
    room.ambient = 0.3 + 3 * n0  // включили вентиляцию: фон +6 дБ навсегда
    r = simulate(room, seconds: 300, speech: { _ in 0 }, gain: &g, seed: 9)
    check("фон вырос навсегда: прибавка уходит", at(r, 180) < 1, "через 3 мин \(f(at(r, 180))) дБ (пик \(f(peak(r, from: 0, to: 300))))")
}
do {
    var g = AdaptiveGain(); g.relearn()
    _ = simulate(Room(), seconds: 30, speech: { $0 > 10 ? 30 : 0 }, gain: &g)
    let b = g.update(power: 5, dt: 0.1, maxBoostDB: 0)
    check("нарастание: прибавка сбрасывается", b == 0 && g.boostDB == 0, "\(b)")
}
do {
    var m = LevelMeter(sampleRate: 48000)
    func tone(_ hz: Double) -> [Double] {
        let x = (0..<48000).map { Float(sin(2 * Double.pi * hz * Double($0) / 48000)) }
        return x.withUnsafeBufferPointer { m.process($0) }.map(\.power)
    }
    let k = tone(1000), lowHum = tone(50)
    check("измеритель: кадры по 0.1 с", k.count == 10, "\(k.count) кадров за 1 с")
    check("измеритель: речь проходит, гул 50 Гц нет", abs(db(k.last!.squareRoot() * 2.0.squareRoot())) < 1 && 10 * log10(lowHum.last! / k.last!) < -30,
          "1 кГц \(f(10 * log10(k.last! * 2))) дБ, 50 Гц \(f(10 * log10(lowHum.last! / k.last!))) дБ относительно 1 кГц")
}

print("\n== громкость")
check("потолок", VolumePolicy.clamp(1.0) == VolumePolicy.maximum, "1.0 -> \(VolumePolicy.clamp(1.0))")
check("не ниже нуля", VolumePolicy.clamp(-0.3) == 0, "-0.3 -> \(VolumePolicy.clamp(-0.3))")
check("внутри диапазона без изменений", VolumePolicy.clamp(0.2) == 0.2, "0.2 -> \(VolumePolicy.clamp(0.2))")
check("NaN -> по умолчанию", VolumePolicy.clamp(.nan) == VolumePolicy.default, "NaN -> \(VolumePolicy.clamp(.nan))")
check("inf -> по умолчанию", VolumePolicy.clamp(.infinity) == VolumePolicy.default, "inf -> \(VolumePolicy.clamp(.infinity))")
check("дефолт не выше потолка", VolumePolicy.default <= VolumePolicy.maximum, "\(VolumePolicy.default)")

print(failures == 0 ? "\nВсе проверки пройдены" : "\nПровалено: \(failures)")
exit(failures == 0 ? 0 : 1)
