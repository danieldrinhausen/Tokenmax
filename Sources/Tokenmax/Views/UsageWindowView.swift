import SwiftUI

/// One quota window: label, meter, remaining %, reset countdown, and — when a
/// pace has been measured — what that pace means before the reset.
struct UsageWindowView: View {
    let window: UsageWindow
    let isStale: Bool
    let now: Date
    /// `nil` when there is nothing to project or the user switched it off.
    var projection: UsageProjection?

    private var remaining: Double? { window.remainingPercent }

    /// The marker sits where an even burn would have left the meter right now,
    /// so past the fill means "behind by that much" and inside it means "the
    /// rest is spare".
    private var paceMarker: Double? {
        guard !isStale, let projection else { return nil }
        return max(0, min(1, projection.evenPaceRemainingPercent / 100))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(window.label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)

            meter

            HStack(alignment: .firstTextBaseline) {
                Text(remainingText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isStale ? .secondary : .primary)

                Spacer(minLength: 12)

                Text(resetText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if let projection, !isStale {
                projectionLine(projection)
            }
        }
    }

    // MARK: - Meter

    private var meter: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.22))

                if let remaining, !isStale {
                    Capsule()
                        .fill(barColor(remaining))
                        .frame(width: max(6, geometry.size.width * (remaining / 100)))
                }

                if let paceMarker {
                    Capsule()
                        .fill(markerColor)
                        // Inset by its own width so the marker stays inside the
                        // track at either extreme instead of half-hanging off it.
                        .frame(width: markerWidth)
                        .offset(x: (geometry.size.width - markerWidth) * paceMarker)
                }
            }
        }
        .frame(height: 7)
    }

    private var markerWidth: CGFloat { 2.5 }

    /// Chosen for contrast against whatever the marker lands on: a deficit
    /// marker sits past the fill on the pale track, a reserve marker sits inside
    /// the saturated fill.
    private var markerColor: Color {
        if case .deficit = projection?.outlook { return .red }
        return Color.white.opacity(0.85)
    }

    private func barColor(_ remaining: Double) -> Color {
        switch remaining {
        case ..<10: .red
        case ..<25: .orange
        default: .green
        }
    }

    // Shared with the queue header's compact bars, so the two cannot end up
    // describing the same snapshot differently — see `UsageWindowPresentation`.
    private var remainingText: String {
        UsageWindowPresentation.remainingText(for: window)
    }

    private var resetText: String {
        UsageWindowPresentation.resetText(for: window, isStale: isStale, now: now)
    }

    // MARK: - Projection

    private func projectionLine(_ projection: UsageProjection) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(outlookText(projection.outlook))
                .font(.system(size: 12))
                .foregroundStyle(outlookColor(projection.outlook))

            Spacer(minLength: 12)

            Text(paceText(projection.outlook))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .help(helpText(projection))
    }

    /// Rounding to zero means spending is sitting on the even-burn line.
    /// "0% in reserve" reads as an error; "On pace" is the same fact stated the
    /// way it is meant.
    private func outlookText(_ outlook: UsageOutlook) -> String {
        switch outlook {
        case let .reserve(percent):
            percent.rounded() < 1 ? "On pace" : "\(Int(percent.rounded()))% in reserve"
        case let .deficit(percent, _):
            percent.rounded() < 1 ? "On pace" : "\(Int(percent.rounded()))% in deficit"
        }
    }

    private func paceText(_ outlook: UsageOutlook) -> String {
        switch outlook {
        case .reserve:
            "Lasts until reset"
        case let .deficit(_, emptyAt):
            "Projected empty in \(RelativeTime.countdown(emptyAt.timeIntervalSince(now)))"
        }
    }

    private func outlookColor(_ outlook: UsageOutlook) -> Color {
        if case .deficit = outlook { return .orange }
        return .secondary
    }

    /// The number is an extrapolation, not a measurement of the future. Saying
    /// what it is based on is what keeps it from being read as a promise.
    private func helpText(_ projection: UsageProjection) -> String {
        let pace = String(format: "%.0f", projection.evenPaceRemainingPercent)
        let perHour = String(format: "%.1f", projection.percentPerHour)

        return """
        An even burn would leave \(pace)% at this point in the window — that is the marker on the bar. \
        You have averaged \(perHour)% of the window per hour since it opened.
        """
    }
}
