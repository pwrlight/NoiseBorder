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

print("\n== громкость")
check("потолок", VolumePolicy.clamp(1.0) == VolumePolicy.maximum, "1.0 -> \(VolumePolicy.clamp(1.0))")
check("не ниже нуля", VolumePolicy.clamp(-0.3) == 0, "-0.3 -> \(VolumePolicy.clamp(-0.3))")
check("внутри диапазона без изменений", VolumePolicy.clamp(0.2) == 0.2, "0.2 -> \(VolumePolicy.clamp(0.2))")
check("NaN -> по умолчанию", VolumePolicy.clamp(.nan) == VolumePolicy.default, "NaN -> \(VolumePolicy.clamp(.nan))")
check("inf -> по умолчанию", VolumePolicy.clamp(.infinity) == VolumePolicy.default, "inf -> \(VolumePolicy.clamp(.infinity))")
check("дефолт не выше потолка", VolumePolicy.default <= VolumePolicy.maximum, "\(VolumePolicy.default)")

print(failures == 0 ? "\nВсе проверки пройдены" : "\nПровалено: \(failures)")
exit(failures == 0 ? 0 : 1)
