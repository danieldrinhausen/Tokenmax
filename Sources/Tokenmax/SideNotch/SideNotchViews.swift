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
        .contextMenu {
            Button("Settings…") {
                NotificationCenter.default.post(name: .tokenmaxOpenSettings, object: nil)
            }
            Divider()
            Button(coordinator.settingsStore.settings.showMenuBarItem
                ? "Hide Menu Bar Item"
                : "Show Menu Bar Item"
            ) {
                coordinator.toggleMenuBarItem()
            }
            Button("Refresh") { coordinator.refreshFromContextMenu() }
                .disabled(coordinator.usage.isRefreshingAny)
            Divider()
            Button("Quit Tokenmax") { coordinator.quit() }
        }
    }

    private var peek: some View {
        let dockNotch = coordinator.settingsStore.settings.sideNotch.placement == .dock
        return ZStack(alignment: dockNotch ? .bottom : .trailing) {
            Color.clear
            Capsule()
                .fill(Color.black.opacity(0.94))
                .frame(width: dockNotch ? 50 : 8, height: dockNotch ? 8 : 50)
                .overlay(alignment: dockNotch ? .top : .leading) {
                    LinearGradient(
                        colors: [.white.opacity(0.34), .white.opacity(0.10)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: dockNotch ? 50 : 1, height: dockNotch ? 1 : 50)
                    .clipShape(Capsule())
                }
                .overlay {
                    Capsule()
                        .fill(Color.white.opacity(0.30))
                        .frame(width: dockNotch ? 11 : 2, height: dockNotch ? 2 : 11)
                }
        }
        .contentShape(Rectangle())
    }

    private var rail: some View {
        Group {
            if coordinator.settingsStore.settings.sideNotch.placement == .dock {
                dockRail
            } else {
                sideRail
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(railBackground)
        .overlay(alignment: coordinator.settingsStore.settings.sideNotch.placement == .dock ? .top : .leading) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(
                    width: coordinator.settingsStore.settings.sideNotch.placement == .dock ? nil : 1,
                    height: coordinator.settingsStore.settings.sideNotch.placement == .dock ? 1 : nil
                )
                .padding(coordinator.settingsStore.settings.sideNotch.placement == .dock ? .horizontal : .vertical, 18)
        }
    }

    private var sideRail: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.20))
                .frame(width: 16, height: 2.5)
                .padding(.top, 9)
                .padding(.bottom, 6.5)

            ForEach(coordinator.presentations) { presentation in
                providerButton(presentation, compact: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var dockRail: some View {
        HStack(spacing: 0) {
            ForEach(coordinator.presentations) { presentation in
                providerButton(presentation, compact: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func providerButton(_ presentation: SideNotchProviderPresentation, compact: Bool) -> some View {
        let isSelected = coordinator.state.selectedProvider == presentation.provider
        return Button {
            coordinator.providerClicked(presentation.provider)
        } label: {
            SideNotchProviderRing(presentation: presentation, compact: compact)
                .frame(width: compact ? 58 : 66, height: compact ? 50 : 66)
                .background(
                    RoundedRectangle(cornerRadius: compact ? 15 : 19, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.075) : .clear)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: compact ? 15 : 19, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.white.opacity(0.10) : .clear,
                            lineWidth: 0.75
                        )
                }
                .scaleEffect(isSelected ? 1 : 0.97)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { coordinator.pointerEnteredProvider(presentation.provider) }
        }
        .accessibilityLabel("Show \(presentation.provider.displayName) usage")
        .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: isSelected)
    }

    @ViewBuilder
    private var railBackground: some View {
        if coordinator.settingsStore.settings.sideNotch.placement == .dock {
            UnevenRoundedRectangle(
                topLeadingRadius: 22,
                bottomLeadingRadius: 18,
                bottomTrailingRadius: 18,
                topTrailingRadius: 22
            )
            .fill(Color.black.opacity(0.78))
        } else {
            UnevenRoundedRectangle(
                topLeadingRadius: 22,
                bottomLeadingRadius: 22,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0
            )
            .fill(Color.black.opacity(0.78))
        }
    }
}

private struct SideNotchProviderRing: View {
    let presentation: SideNotchProviderPresentation
    let compact: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 1) {
            ZStack {
                meter(
                    presentation.outer,
                    diameter: compact ? 34 : 42,
                    lineWidth: compact ? 3 : 3.5,
                    opacity: 0.78
                )
                meter(
                    presentation.inner,
                    diameter: compact ? 24 : 30,
                    lineWidth: compact ? 2.5 : 3,
                    opacity: 1
                )
                Image(systemName: presentation.provider.sideNotchSymbol)
                    .font(.system(size: compact ? 9 : 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .frame(width: compact ? 40 : 50, height: compact ? 40 : 50)

            Text(percentText)
                .font(.system(size: compact ? 8 : 8.5, weight: .semibold, design: .rounded))
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
                VStack(alignment: .leading, spacing: 9) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: presentation.provider.sideNotchSymbol)
                                .font(.system(size: 10.5, weight: .semibold))
                            Text(presentation.provider.displayName)
                                .font(.system(size: 12, weight: .semibold))
                            if presentation.isStale, presentation.updatedText != "Never updated" {
                                Text("· Stale")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.orange)
                            }
                            Spacer(minLength: 4)
                            if let plan = presentation.planName {
                                Text(plan)
                                    .font(.system(size: 9, weight: .medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.white.opacity(0.12), in: Capsule())
                            }
                            if coordinator.state.isLocked {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(presentation.updatedText)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.45))
                    }

                    if presentation.detailMeters.isEmpty {
                        Text("No quota reading available")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.55))
                    } else {
                        ForEach(presentation.detailMeters) { meter in
                            detailRow(meter)
                        }
                    }

                    if let availableResetText = presentation.availableResetText {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise.circle")
                                .font(.system(size: 9))
                            Text(availableResetText)
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(.white.opacity(0.62))
                        .help("A banked reset refreshes Codex's eligible usage windows. Redeem it from Codex after reviewing its offer details.")
                    }
                }
                .padding(.leading, 14)
                .padding(.vertical, 13)
                .padding(.trailing, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
        .background(
            SideNotchDetailBubble(
                tail: coordinator.settingsStore.settings.sideNotch.placement == .dock ? .bottom : .right
            )
                .fill(Color.black.opacity(0.86))
        )
        .overlay {
            SideNotchDetailBubble(
                tail: coordinator.settingsStore.settings.sideNotch.placement == .dock ? .bottom : .right
            )
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
        .onHover { inside in
            if inside { coordinator.pointerEnteredDetail() }
            else { coordinator.pointerExitedDetail() }
        }
    }

    private func detailRow(_ meter: SideNotchMeterPresentation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meter.shortLabel.uppercased())
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.58))
                .tracking(0.5)

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
                    if let marker = paceMarker(for: meter) {
                        Capsule()
                            .fill(markerColor(for: meter))
                            .frame(width: 2)
                            .offset(x: (geometry.size.width - 2) * marker)
                    }
                }
            }
            .frame(height: 3.5)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(remainingText(meter))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(meter.isStale ? Color.white.opacity(0.50) : .white)
                Spacer(minLength: 4)
                Text(resetText(meter))
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }

            if let projection = meter.projection {
                projectionLine(projection)
            }

            if let status = meter.reminderStatus {
                HStack(spacing: 4) {
                    Image(systemName: status.isSuppressed ? "bell.slash" : "bell")
                        .font(.system(size: 8))
                    Text(status.summary(now: coordinator.usage.clock.now))
                        .font(.system(size: 9))
                        .lineLimit(1)
                }
                .foregroundStyle(status.isNoteworthy ? Color.orange : Color.white.opacity(0.55))
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: meter.fraction)
    }

    private func remainingText(_ meter: SideNotchMeterPresentation) -> String {
        guard let window = meter.window else { return "Unavailable" }
        return UsageWindowPresentation.remainingText(for: window)
    }

    private func resetText(_ meter: SideNotchMeterPresentation) -> String {
        guard let window = meter.window else { return "No quota reading available" }
        return UsageWindowPresentation.resetText(
            for: window,
            isStale: meter.isStale,
            now: coordinator.usage.clock.now
        )
    }

    private func projectionLine(_ projection: UsageProjection) -> some View {
        let presentation = UsageWindowPresentation.projectionLine(
            for: projection,
            now: coordinator.usage.clock.now
        )

        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(presentation.outlookText)
                .foregroundStyle(presentation.isDeficit ? Color.orange : Color.white.opacity(0.58))
            Spacer(minLength: 4)
            Text(presentation.paceText)
                .foregroundStyle(Color.white.opacity(0.55))
        }
        .font(.system(size: 9))
        .lineLimit(1)
    }

    private func paceMarker(for meter: SideNotchMeterPresentation) -> Double? {
        guard !meter.isStale, let projection = meter.projection else { return nil }
        return max(0, min(1, projection.evenPaceRemainingPercent / 100))
    }

    private func markerColor(for meter: SideNotchMeterPresentation) -> Color {
        guard let projection = meter.projection else { return .clear }
        if case .deficit = projection.outlook { return .red }
        return Color.white.opacity(0.85)
    }
}

/// A rounded card whose short pointer lands underneath the selected rail cell.
/// It gives the two separately hit-tested panels one visual silhouette without
/// adding a transparent window between them that would swallow desktop clicks.
private struct SideNotchDetailBubble: Shape {
    enum Tail: Sendable {
        case right
        case bottom
    }

    let tail: Tail

    func path(in rect: CGRect) -> Path {
        switch tail {
        case .right: rightTailPath(in: rect)
        case .bottom: bottomTailPath(in: rect)
        }
    }

    private func rightTailPath(in rect: CGRect) -> Path {
        let radius: CGFloat = 16
        let tailWidth: CGFloat = 10
        let tailHalfHeight: CGFloat = 9
        let bodyMaxX = rect.maxX - tailWidth
        let middleY = rect.midY

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: bodyMaxX - radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: bodyMaxX, y: rect.minY + radius),
            control: CGPoint(x: bodyMaxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: bodyMaxX, y: middleY - tailHalfHeight))
        path.addLine(to: CGPoint(x: rect.maxX, y: middleY))
        path.addLine(to: CGPoint(x: bodyMaxX, y: middleY + tailHalfHeight))
        path.addLine(to: CGPoint(x: bodyMaxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: bodyMaxX - radius, y: rect.maxY),
            control: CGPoint(x: bodyMaxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }

    private func bottomTailPath(in rect: CGRect) -> Path {
        let radius: CGFloat = 16
        let tailHeight: CGFloat = 10
        let tailHalfWidth: CGFloat = 9
        let bodyMaxY = rect.maxY - tailHeight
        let middleX = rect.midX

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + radius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: bodyMaxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: bodyMaxY),
            control: CGPoint(x: rect.maxX, y: bodyMaxY)
        )
        path.addLine(to: CGPoint(x: middleX + tailHalfWidth, y: bodyMaxY))
        path.addLine(to: CGPoint(x: middleX, y: rect.maxY))
        path.addLine(to: CGPoint(x: middleX - tailHalfWidth, y: bodyMaxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: bodyMaxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: bodyMaxY - radius),
            control: CGPoint(x: rect.minX, y: bodyMaxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
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
