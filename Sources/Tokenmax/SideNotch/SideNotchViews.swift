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
            SettingsLink {
                Text("Settings…")
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
        ZStack(alignment: .trailing) {
            Color.clear
            Capsule()
                .fill(Color.black.opacity(0.94))
                .frame(width: 8, height: 50)
                .overlay(alignment: .leading) {
                    LinearGradient(
                        colors: [.white.opacity(0.34), .white.opacity(0.10)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: 1)
                    .clipShape(Capsule())
                }
                .overlay {
                    Capsule()
                        .fill(Color.white.opacity(0.30))
                        .frame(width: 2, height: 11)
                }
        }
        .contentShape(Rectangle())
    }

    private var rail: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.20))
                .frame(width: 16, height: 2.5)
                .padding(.top, 9)
                .padding(.bottom, 6.5)

            ForEach(coordinator.presentations) { presentation in
                let isSelected = coordinator.state.selectedProvider == presentation.provider
                Button {
                    coordinator.providerClicked(presentation.provider)
                } label: {
                    SideNotchProviderRing(presentation: presentation)
                        .frame(width: 62, height: 60)
                        .background(
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .fill(isSelected ? Color.white.opacity(0.075) : .clear)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: 22,
                bottomLeadingRadius: 22,
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
                meter(presentation.outer, diameter: 46, lineWidth: 4, opacity: 0.78)
                meter(presentation.inner, diameter: 32, lineWidth: 3, opacity: 1)
                Image(systemName: presentation.provider.sideNotchSymbol)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }
            .frame(width: 47, height: 47)

            Text(percentText)
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
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
            SideNotchDetailBubble()
                .fill(Color.black.opacity(0.96))
        )
        .overlay {
            SideNotchDetailBubble()
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
                    Text(status.summary(now: coordinator.usage.tick))
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
            now: coordinator.usage.tick
        )
    }

    private func projectionLine(_ projection: UsageProjection) -> some View {
        let presentation = UsageWindowPresentation.projectionLine(
            for: projection,
            now: coordinator.usage.tick
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
    func path(in rect: CGRect) -> Path {
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
}

private extension TokenmaxProvider {
    var sideNotchSymbol: String {
        switch self {
        case .claudeCode: "sparkles"
        case .codex: "chevron.left.forwardslash.chevron.right"
        }
    }
}
