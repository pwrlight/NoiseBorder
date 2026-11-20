import Foundation

/// Громкость приложения. При AirPlay `AVPlayer.volume` работает как громкость приёмника (проверено на ТВ и роутере),
/// поэтому у неё жёсткий потолок: чтобы случайный жест не оглушил офис.
public enum VolumePolicy {
    public static let maximum: Float = 0.5
    public static let `default`: Float = 0.1

    /// Приводит значение к 0...maximum. Мусор (NaN, бесконечность) превращается в значение по умолчанию.
    public static func clamp(_ v: Float) -> Float {
        guard v.isFinite else { return `default` }
        return min(max(v, 0), maximum)
    }
}
