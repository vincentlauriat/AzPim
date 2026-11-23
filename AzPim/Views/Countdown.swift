import AzPimCore
import SwiftUI

/// Time left on an activation, by the system formatters in the app's language (rounded down to the minute, to the
/// second in the last 5). Two styles: `compact` in the countdown capsules, `full` in sentences.
enum Countdown {
    /// Menu bar: « 5:16 » (hours:minutes), « 3:12 » (minutes:seconds) in the last 5 minutes.
    static func short(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 300 { return clock(total) }
        return Duration.seconds(total)
            .formatted(.time(pattern: .hourMinute(padHourToLength: 1, roundSeconds: .down)).locale(AppLanguage.locale))
    }

    /// Capsules (panel rows, palette): « 5h 16m » / « 5h 16min », « 42m », « 3:12 » in the last 5 minutes.
    static func compact(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total < 300 ? clock(total) : units(total, width: .narrow)
    }

    /// Sentences (hero line, tiles, tooltips): « 5 hr 16 min » / « 5 h 16 min », « 3:12 » in the last 5 minutes.
    static func full(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total < 300 ? clock(total) : units(total, width: .condensedAbbreviated)
    }

    /// « 5 hr 16 min left » / « Reste 5 h 16 min ».
    static func long(_ seconds: TimeInterval) -> String {
        String(localized: "\(full(seconds)) left")
    }

    /// VoiceOver: « 5 hours, 16 minutes », to the minute (`SpokenDuration`).
    static func spoken(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return String(localized: "unknown") }
        return SpokenDuration.text(seconds)
    }

    private static func clock(_ total: Int) -> String {
        Duration.seconds(total).formatted(.time(pattern: .minuteSecond).locale(AppLanguage.locale))
    }

    private static func units(_ total: Int, width: Duration.UnitsFormatStyle.UnitWidth) -> String {
        Duration.seconds(total / 60 * 60).formatted(.units(allowed: [.hours, .minutes], width: width).locale(AppLanguage.locale))
    }

    static func color(_ seconds: TimeInterval?) -> Color {
        guard let seconds else { return .primary }
        if seconds <= 300 { return Theme.danger }
        if seconds <= 900 { return Theme.warning }
        return .primary
    }
}
