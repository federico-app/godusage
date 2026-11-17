import Foundation

extension WidgetData {
    var exhaustedWeeklyResetText: String { exhaustedWeeklyResetText(now: Date()) }

    func exhaustedWeeklyResetText(now: Date) -> String {
        guard let resetsAt else {
            return String(localized: "Reset Time Unavailable", comment: "Used-up weekly limit whose reset time is unknown")
        }
        let countdown = Formatters.resetRelativeLabel(until: resetsAt, now: now)
            ?? String(localized: "Resets soon", comment: "A usage limit resets within minutes")
        let date = resetsAt.formatted(.dateTime.month(.abbreviated).day().locale(AppLocale.current))
        let time = TimeFormatSetting.current.shortTime(resetsAt)
        return String(
            localized: "\(countdown) · \(date) at \(time)",
            comment: "Used-up weekly limit: the countdown to its reset, then the reset's date and time, e.g. Resets in 2d 5h · Feb 15 at 3:45 PM"
        )
    }
}
