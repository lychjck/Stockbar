import Foundation

/// A-share market session helper.
/// CN trading window: 09:30–11:30, 13:00–15:00, Mon–Fri (no holidays support).
enum MarketHours {

    enum Phase: String {
        case weekend          // sat/sun
        case preMarket        // before 09:30
        case morningSession   // 09:30–11:30
        case lunchBreak       // 11:30–13:00
        case afternoonSession // 13:00–15:00
        case postMarket       // after 15:00

        var isLive: Bool {
            self == .morningSession || self == .afternoonSession
        }
    }

    /// Compute the current phase based on the local Asia/Shanghai time.
    /// We use the user's local clock — this app is meant for CN users on a CN clock.
    static func currentPhase(date: Date = Date(), calendar: Calendar = .current) -> Phase {
        let weekday = calendar.component(.weekday, from: date) // 1=Sunday
        if weekday == 1 || weekday == 7 { return .weekend }

        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let total = hour * 60 + minute

        let open = 9 * 60 + 30
        let lunchStart = 11 * 60 + 30
        let lunchEnd = 13 * 60
        let close = 15 * 60

        if total < open { return .preMarket }
        if total < lunchStart { return .morningSession }
        if total < lunchEnd { return .lunchBreak }
        if total < close { return .afternoonSession }
        return .postMarket
    }

    /// Recommended refresh interval based on phase:
    ///   live trading → use config value (default 5s)
    ///   pre-/post-market or lunch → 60s (still useful for late prints)
    ///   weekend → 600s (basically idle, but we still poll for sanity)
    static func recommendedInterval(base: TimeInterval, date: Date = Date()) -> TimeInterval {
        switch currentPhase(date: date) {
        case .morningSession, .afternoonSession:
            return max(1, base)
        case .preMarket, .lunchBreak, .postMarket:
            return max(60, base * 5)
        case .weekend:
            return 600
        }
    }
}
