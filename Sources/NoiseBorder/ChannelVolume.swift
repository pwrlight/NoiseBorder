import AVFoundation

/// Громкость AirPlay-канала (то, что двигает ползунок в меню кнопки AirPlay).
/// Публичного API нет: используется закрытый `AVOutputContext` плеера через KVC.
/// Каждое обращение защищено `responds(to:)`, поэтому при изменении системы просто станет «недоступно», без падения.
struct ChannelVolume {
    let player: AVPlayer

    /// Контекст появляется только после привязки AVRoutePickerView к плееру.
    private var context: NSObject? {
        let sel = NSSelectorFromString("outputContext")
        guard player.responds(to: sel) else { return nil }
        return player.value(forKey: "outputContext") as? NSObject
    }

    private func read(_ key: String, from c: NSObject) -> Any? {
        c.responds(to: NSSelectorFromString(key)) ? c.value(forKey: key) : nil
    }

    /// Можно ли сейчас менять громкость выбранного приёмника.
    var canSet: Bool {
        guard let c = context else { return false }
        return (read("canSetVolume", from: c) as? NSNumber)?.boolValue ?? false
    }

    /// Текущая громкость приёмника 0...1.
    var value: Float? {
        guard let c = context else { return nil }
        return (read("volume", from: c) as? NSNumber)?.floatValue
    }

    /// Имена выбранных удалённых AirPlay-приёмников. Пусто, если маршрут не выбран (звук идёт на Mac).
    var deviceNames: [String] {
        guard let c = context, let devices = read("outputDevices", from: c) as? [NSObject] else { return [] }
        return devices.compactMap { d in
            if d.responds(to: NSSelectorFromString("isLocalAirPlayDevice")),
               (d.value(forKey: "isLocalAirPlayDevice") as? NSNumber)?.boolValue == true { return nil }
            if d.responds(to: NSSelectorFromString("name")), let n = d.value(forKey: "name") as? String, !n.isEmpty { return n }
            return "AirPlay-приёмник"
        }
    }

    @discardableResult
    func set(_ v: Float) -> Bool {
        guard let c = context, canSet, c.responds(to: NSSelectorFromString("setVolume:")) else { return false }
        c.setValue(NSNumber(value: min(max(v, 0), 1)), forKey: "volume")
        return true
    }
}
