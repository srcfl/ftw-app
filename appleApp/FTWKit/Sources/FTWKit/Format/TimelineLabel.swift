import Foundation
import FTWShared

/// What a node's timeline shows, named as a person says it: "Today",
/// "Yesterday" or "Tomorrow" for a whole day on the household's clock,
/// otherwise the day and the times, "Today 14:22–15:22" or "Fri 23 Oct
/// 22:00 – Today 02:00".
public enum TimelineLabel {
    public static func window(_ w: TimelineWindow, nowMs: Double, clock: ZoneClock) -> String {
        let today = TimelineWindow.today(nowMs: nowMs, clock: clock)
        if w.isToday || (w.fromMs == today.fromMs && w.toMs == today.toMs) { return NodeWords.text("Today") }
        let calendar = clock.calendar
        func midnight(_ days: Int) -> Double {
            let start = Date(timeIntervalSince1970: today.fromMs / 1000)
            return (calendar.date(byAdding: .day, value: days, to: start) ?? start).timeIntervalSince1970 * 1000
        }
        if w.fromMs == midnight(-1), w.toMs == midnight(0) { return NodeWords.text("Yesterday") }
        if w.fromMs == midnight(1), w.toMs == midnight(2) { return NodeWords.text("Tomorrow") }
        let from = day(w.fromMs, today: today.fromMs, clock: clock)
        // The end at midnight belongs to the day before it.
        let last = w.toMs - 1
        let to = day(last, today: today.fromMs, clock: clock)
        let a = clock.label(w.fromMs)
        // A day's end reads 24:00 on that day, not 00:00 on the next.
        let b = from == to && clock.minuteOfDay(w.toMs) == 0 ? "24:00" : clock.label(w.toMs)
        return from == to ? "\(from) \(a)–\(b)" : "\(from) \(a) – \(to) \(b)"
    }

    /// "Today", "Yesterday", "Tomorrow", or "Fri 23 Oct".
    static func day(_ ms: Double, today: Double, clock: ZoneClock) -> String {
        let calendar = clock.calendar
        let date = Date(timeIntervalSince1970: ms / 1000)
        let start = calendar.startOfDay(for: date).timeIntervalSince1970 * 1000
        let days = calendar.dateComponents([.day], from: Date(timeIntervalSince1970: today / 1000), to: Date(timeIntervalSince1970: start / 1000)).day ?? 0
        switch days {
        case 0: return NodeWords.text("Today")
        case -1: return NodeWords.text("Yesterday")
        case 1: return NodeWords.text("Tomorrow")
        default:
            var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: Locale(identifier: AppWords.language == .sv ? "sv_SE" : "en_US"), calendar: calendar, timeZone: clock.calendar.timeZone)
            style = style.weekday(.abbreviated).day().month(.abbreviated)
            return date.formatted(style)
        }
    }
}

extension DayWords {
    /// A stretch of a timeline in its node's words, "Charged 1.9 kWh · gave
    /// 0.3 kWh", from what the box recorded in it.
    public static func line(_ node: EnergyNode, inWh: Double, outWh: Double) -> String {
        line(node, EnergyToday(inWh: inWh, outWh: outWh, missingMs: 0))
    }
}
