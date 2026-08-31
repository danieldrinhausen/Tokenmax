import Foundation

/// What the user is told about a window's reminder.
///
/// This exists because the scheduler making a correct decision silently is
/// indistinguishable, from the outside, from the app being broken.
enum ReminderStatus: Equatable, Sendable {
    case scheduled(Date)
    case justDelivered
    /// `firedAt` is set only for `.alreadyFiredForWindow`, and only when the
    /// delivery time is actually known.
    case suppressed(SchedulingDecision.SkipReason, firedAt: Date?)

    init(decision: SchedulingDecision, firedAt: Date? = nil) {
        switch decision {
        case let .schedule(_, fireDate, _, _): self = .scheduled(fireDate)
        case .deliverNow: self = .justDelivered
        case let .skip(reason): self = .suppressed(reason, firedAt: firedAt)
        }
    }

    private static let firedAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    /// One short line for the popover.
    func summary(now: Date = Date()) -> String {
        switch self {
        case let .scheduled(fireDate):
            let interval = fireDate.timeIntervalSince(now)
            return interval > 0
                ? "Reminder in \(RelativeTime.countdown(interval))"
                : "Reminder due"
        case .justDelivered:
            return "Reminder sent"
        case let .suppressed(reason, firedAt):
            // "Already notified for this window" next to a 45-minute lead time
            // reads as a contradiction. The delivery time is what makes it make
            // sense, so show it whenever it is known.
            guard reason == .alreadyFiredForWindow, let firedAt else { return reason.summary }
            return "Already notified at \(Self.firedAtFormatter.string(from: firedAt))"
        }
    }

    var isSuppressed: Bool {
        if case .suppressed = self { return true }
        return false
    }

    /// The reminder for this window has gone off, and the window has not reset
    /// since. That stretch — not the instant of delivery — is what the menubar
    /// bar colours, so a notification missed while away is still visible on the
    /// icon when the user comes back.
    var hasFiredForCurrentWindow: Bool {
        switch self {
        case .justDelivered: true
        case let .suppressed(reason, _): reason == .alreadyFiredForWindow
        case .scheduled: false
        }
    }

    /// Suppressions the user chose are normal; the rest are worth highlighting.
    var isNoteworthy: Bool {
        guard case let .suppressed(reason, _) = self else { return false }
        switch reason {
        // Chosen by the user, or simply nothing to report yet — none of these
        // are a problem, so none of them get the orange treatment.
        case .remindersDisabled, .ruleDisabled, .windowUnavailable, .windowNotStarted: return false
        default: return true
        }
    }
}

extension SchedulingDecision.SkipReason {
    /// Plain-language explanation. Every one of these answers "why didn't I get
    /// a notification?" without needing the log.
    var summary: String {
        switch self {
        case .remindersDisabled: "Reminders are off"
        case .ruleDisabled: "Reminder off for this window"
        case .dataStale: "No reminder — usage data is stale"
        case .noSnapshot: "No reminder — no usage snapshot available"
        case .windowUnavailable: "No reminder — this plan reports no such window"
        case .noResetTime: "No reminder — reset time unknown"
        case .windowNotStarted: "No session running — starts with your next prompt"
        case .notEnoughQuotaLeft: "No reminder — below your minimum quota"
        case .queueEmpty: "No reminder — queue is empty"
        case .alreadyFiredForWindow: "Already notified for this window"
        case .quietHours: "No reminder — quiet hours"
        case .resetTooSoon: "No reminder — reset is too close to be useful"
        }
    }
}
