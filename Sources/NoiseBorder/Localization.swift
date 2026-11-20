import Foundation
import NoiseKit

enum Language: String, CaseIterable, Identifiable {
    case ru, en
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }

    /// Язык системы: русский, если он первый в списке предпочтений, иначе английский.
    static var systemDefault: Language {
        Locale.preferredLanguages.first?.hasPrefix("ru") == true ? .ru : .en
    }
}

/// Сообщения плеера. Хранятся как значения, а не как строки, чтобы переключать язык на лету.
enum Notice: Equatable {
    case routeLost
    case prepareFailed(String)
}

enum Str {
    case title, volume, channelVolume, chooseReceiverHint, airplayOutput
    case preparing, playingAirPlay, playingMac, off, launchAtLogin, quit, language
    case routeLost, prepareFailed, loginUnavailable
}

func tr(_ s: Str, _ l: Language) -> String {
    func p(_ ru: String, _ en: String) -> String { l == .ru ? ru : en }
    switch s {
    case .title: return p("Шумовая завеса", "Noise Barrier")
    case .volume: return p("Громкость", "Volume")
    case .channelVolume: return p("Громкость AirPlay-приёмника", "AirPlay receiver volume")
    case .chooseReceiverHint:
        return p("Выберите AirPlay-приёмник: после этого здесь появится его громкость",
                 "Choose an AirPlay receiver: its volume control will appear here")
    case .airplayOutput: return p("Выход AirPlay", "AirPlay output")
    case .preparing: return p("Готовлю шум, первый запуск займёт несколько секунд",
                              "Preparing noise, the first start takes a few seconds")
    case .playingAirPlay: return p("Играет на AirPlay", "Playing on AirPlay")
    case .playingMac: return p("Играет на динамиках Mac: выберите AirPlay-приёмник",
                               "Playing on this Mac's speakers: choose an AirPlay receiver")
    case .off: return p("Выключено", "Off")
    case .launchAtLogin: return p("Запускать при входе", "Launch at login")
    case .quit: return p("Выйти", "Quit")
    case .language: return p("Язык", "Language")
    case .routeLost: return p("Приёмник AirPlay отключился, шум остановлен",
                              "AirPlay receiver disconnected, noise stopped")
    case .prepareFailed: return p("Не удалось подготовить шум: ", "Could not prepare noise: ")
    case .loginUnavailable: return p("Автозапуск недоступен: ", "Launch at login is unavailable: ")
    }
}

func tr(_ n: Notice, _ l: Language) -> String {
    switch n {
    case .routeLost: return tr(Str.routeLost, l)
    case .prepareFailed(let detail): return tr(Str.prepareFailed, l) + detail
    }
}

extension NoiseType {
    func title(_ l: Language) -> String {
        switch self {
        case .speech: return l == .ru ? "Речевой" : "Speech"
        case .white: return l == .ru ? "Белый" : "White"
        case .pink: return l == .ru ? "Розовый" : "Pink"
        case .brown: return l == .ru ? "Коричневый" : "Brown"
        }
    }
}
