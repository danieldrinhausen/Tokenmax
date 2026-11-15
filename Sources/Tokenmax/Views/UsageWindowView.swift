import SwiftUI

/// One quota window: label, meter, reading, reset countdown, and — when a
/// pace has been measured — what that pace means before the reset.
struct UsageWindowView: View {
    let window: UsageWindow
    let isStale: Bool
    let now: Date
    /// `nil` when there is nothing to project or the user switched it off.
    var projection: UsageProjection?
    /// Which way the reading and the meter run; see `QuotaReadout`.
    var readout: QuotaReadout = .remaining

    private var remaining: Double? { window.remainingPercent }

    /// The marker sits where an even burn would have left the meter right now.
    /// Reading what is left, past the fill means "behind by that much" and
    /// inside it means "the rest is spare"; reading what is used, the other way
    /// round.
    private var paceMarker: Double? {
        guard !isStale, let projection else { return nil }
        return UsageWindowPresentation.paceMarkerPosition(for: projection, readout: readout)
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

                // Nothing at 0% — `fillFraction` — as in the menu bar. The
                // colour stays keyed to what is left in either direction: red
                // means "nearly gone", not "long bar".
                if let remaining, let fill = UsageWindowPresentation.fillFraction(
                    for: window, isStale: isStale, readout: readout
                ) {
                    Capsule()
                        .fill(barColor(remaining))
                        .frame(width: max(6, geometry.size.width * fill))
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

    /// Chosen for contrast against whatever the marker lands on: white inside
    /// the saturated fill; on the pale track red for a deficit, which is the
    /// one worth noticing, and a neutral otherwise.
    private var markerColor: Color {
        guard let projection else { return .clear }
        if UsageWindowPresentation.paceMarkerIsOnFill(for: projection, readout: readout) {
            return Color.white.opacity(0.85)
        }
        if case .deficit = projection.outlook { return .red }
        return Color.primary.opacity(0.55)
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
        UsageWindowPresentation.remainingText(for: window, readout: readout)
    }

    private var resetText: String {
        UsageWindowPresentation.resetText(for: window, isStale: isStale, now: now)
    }

    // MARK: - Projection

    private func projectionLine(_ projection: UsageProjection) -> some View {
        let presentation = UsageWindowPresentation.projectionLine(for: projection, now: now)

        return HStack(alignment: .firstTextBaseline) {
            Text(presentation.outlookText)
                .font(.system(size: 12))
                .foregroundStyle(presentation.isDeficit ? Color.orange : Color.secondary)

            Spacer(minLength: 12)

            Text(presentation.paceText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .help(helpText(projection))
    }

    private func helpText(_ projection: UsageProjection) -> String {
        UsageWindowPresentation.paceHelpText(for: projection, readout: readout)
    }
}
