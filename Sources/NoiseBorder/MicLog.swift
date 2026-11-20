import Foundation
import NoiseKit

/// Журнал калибровки подстройки: по строке на кадр 0.1 с, только числа (уровни и признаки), без звука.
/// Включается вручную: `defaults write app.noiseborder.NoiseBorder micLog -bool true`.
/// Файл: ~/Library/Logs/NoiseBorder/mic.csv, при размере больше 20 МБ начинается заново.
@MainActor
final class MicLog {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "micLog") }
    private var handle: FileHandle?
    private let start = Date()

    init?() {
        guard Self.enabled else { return nil }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/NoiseBorder", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mic.csv")
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > 20_000_000 { try? FileManager.default.removeItem(at: url) }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data("time,clock,power_db,floor_db,excess_db,voicing,voiced,talking,boost_db\n".utf8))
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        h.seekToEndOfFile()
        handle = h
    }

    func write(_ frame: LevelMeter.Frame, gain: AdaptiveGain) {
        func db(_ p: Double?) -> String { p.map { String(format: "%.1f", 10 * log10(max($0, 1e-20))) } ?? "" }
        let clock = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = String(format: "%.1f,", Date().timeIntervalSince(start)) + clock + "," + db(frame.power) + "," + db(gain.floor) + ","
            + (gain.lastExcessDB.isFinite ? String(format: "%.1f", gain.lastExcessDB) : "") + ","
            + String(format: "%.2f,%d,%d,%.2f\n", frame.voicing, frame.isVoiced ? 1 : 0, gain.lastTalking ? 1 : 0, gain.boostDB)
        handle?.write(Data(line.utf8))
    }

    deinit { try? handle?.close() }
}
