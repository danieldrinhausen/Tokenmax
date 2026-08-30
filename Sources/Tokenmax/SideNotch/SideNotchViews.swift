import SwiftUI

struct SideNotchRailView: View {
    @ObservedObject var coordinator: SideNotchCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if coordinator.state == .peek {
                peek
            } else {
                rail
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: coordinator.state)
        .onHover { inside in
            if inside {
                coordinator.state == .peek
                    ? coordinator.pointerEnteredHandle()
                    : coordinator.pointerEnteredRail()
            } else {
                coordinator.pointerExitedRail()
            }
        }
    }

    private var peek: some View {
        ZStack(alignment: .trailing) {
            Color.clear
            Capsule()
                .fill(Color.black.opacity(0.92))
                .frame(width: 7, height: 52)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.14))
                        .frame(width: 1)
                }
        }
        .contentShape(Rectangle())
    }

    private var rail: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.22))
                .frame(width: 18, height: 3)
                .padding(.top, 10)
                .padding(.bottom, 7)

            ForEach(coordinator.presentations) { presentation in
                Button {
                    coordinator.providerClicked(presentation.provider)
                } label: {
                    SideNotchProviderRing(presentation: presentation)
                        .frame(width: 68, height: 68)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { coordinator.pointerEnteredProvider(presentation.provider) }
                }
                .accessibilityLabel("Show \(presentation.provider.displayName) usage")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 24,
                bottomLeadingRadius: 24,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0
            )
            .fill(Color.black.opacity(0.96))
        )
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1).padding(.vertical, 18)
        }
    }
}

private struct SideNotchProviderRing: View {
    let presentation: SideNotchProviderPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 1) {
            ZStack {
                meter(presentation.outer, diameter: 48, lineWidth: 5, opacity: 0.86)
                meter(presentation.inner, diameter: 35, lineWidth: 4, opacity: 1)
                Image(systemName: presentation.provider.sideNotchSymbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .frame(width: 50, height: 50)

            Text(percentText)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.82))
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: presentation)
    }

    private func meter(
        _ meter: SideNotchMeterPresentation,
        diameter: CGFloat,
        lineWidth: CGFloat,
        opacity: Double
    ) -> some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.14), lineWidth: lineWidth)
            if let fraction = meter.fraction {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(
                        meter.color?.color ?? Color.white,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .opacity(opacity)
                    .shadow(
                        color: meter.glow ? (meter.color?.color ?? .white).opacity(0.65) : .clear,
                        radius: meter.glow ? 5 : 0
                    )
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private var percentText: String {
        guard let remaining = presentation.outer.remainingPercent else { return "—" }
        return "\(Int(remaining.rounded()))%"
    }
}

struct SideNotchDetailView: View {
    @ObservedObject var coordinator: SideNotchCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let presentation = coordinator.selectedPresentation {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 7) {
                        Image(systemName: presentation.provider.sideNotchSymbol)
                        Text(presentation.provider.displayName)
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        if coordinator.state.isLocked {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }

                    detailRow(presentation.outer)
                    detailRow(presentation.inner)
                }
                .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 18,
                bottomLeadingRadius: 18,
                bottomTrailingRadius: 4,
                topTrailingRadius: 4
            )
            .fill(Color.black.opacity(0.96))
        )
        .overlay {
            UnevenRoundedRectangle(
                topLeadingRadius: 18,
                bottomLeadingRadius: 18,
                bottomTrailingRadius: 4,
                topTrailingRadius: 4
            )
            .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
        }
        .onHover { inside in
            if inside { coordinator.pointerEnteredDetail() }
            else { coordinator.pointerExitedDetail() }
        }
    }

    private func detailRow(_ meter: SideNotchMeterPresentation) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(meter.shortLabel)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text(remainingText(meter))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.13))
                    if let fraction = meter.fraction {
                        Capsule()
                            .fill(meter.color?.color ?? .white)
                            .frame(width: geometry.size.width * fraction)
                            .shadow(
                                color: meter.glow ? (meter.color?.color ?? .white).opacity(0.55) : .clear,
                                radius: meter.glow ? 4 : 0
                            )
                    }
                }
            }
            .frame(height: 4)

            Text(resetText(meter))
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: meter)
    }

    private func remainingText(_ meter: SideNotchMeterPresentation) -> String {
        if meter.isStale { return "Stale" }
        guard let window = meter.window else { return "Unavailable" }
        return UsageWindowPresentation.remainingText(for: window)
    }

    private func resetText(_ meter: SideNotchMeterPresentation) -> String {
        guard let window = meter.window else { return "No quota reading available" }
        return UsageWindowPresentation.resetText(
            for: window,
            isStale: meter.isStale,
            now: coordinator.usage.tick
        )
    }
}

private extension TokenmaxProvider {
    var sideNotchSymbol: String {
        switch self {
        case .claudeCode: "sparkles"
        case .codex: "chevron.left.forwardslash.chevron.right"
        }
    }
}
