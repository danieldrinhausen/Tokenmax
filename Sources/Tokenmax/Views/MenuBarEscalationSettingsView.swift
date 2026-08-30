import SwiftUI

/// Builds the colour ladder: a base colour, then up to three rungs, each with a
/// colour and the thing that trips it.
///
/// The list is free rather than a fixed "caution and critical" pair because
/// what counts as low is a property of how someone works, not of the app. The
/// invariants that keep it drawable — three rungs, one reminder rung, sorted,
/// no duplicate thresholds — live in `MenuBarEscalation` and are applied on
/// every write, so this view never has to hold a valid ladder open while the
/// user is halfway through editing one.
struct MenuBarEscalationSettingsView: View {
    @Binding var escalation: MenuBarEscalation
    var surface: EscalationSettingsSurface = .menuBar

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            OptionalHighlightColorPicker(label: "Base", color: baseBinding)

            Text(surface.baseExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            ForEach(Array(escalation.levels.enumerated()), id: \.element.id) { index, level in
                row(index: index, level: level)
            }

            if let suggested = escalation.suggestedLevel {
                Button {
                    escalation = escalation.replacingLevels(escalation.levels + [suggested])
                } label: {
                    Label("Add level", systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.link)
            }

            let illegible = escalation.colors.filter { !$0.isLegibleOnAnyMenuBar }
            if surface == .menuBar, !illegible.isEmpty {
                Label(
                    "One of these colours is hard to make out against a light or a dark menu bar. Menu bar contrast follows your wallpaper, so the icon has to survive both.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var baseBinding: Binding<HighlightColor?> {
        Binding(
            get: { escalation.baseColor },
            set: { escalation = MenuBarEscalation(baseColor: $0, levels: escalation.levels) }
        )
    }

    private func row(index: Int, level: MenuBarEscalationLevel) -> some View {
        HStack(spacing: 8) {
            ColorPicker(
                "Level colour",
                selection: Binding(
                    get: { level.color.color },
                    set: { update(index, color: HighlightColor($0)) }
                ),
                supportsOpacity: false
            )
            .labelsHidden()

            Picker("Trigger", selection: triggerKindBinding(index: index, level: level)) {
                Text("at or below").tag(TriggerKind.percent)
                // A second reminder rung could never fire, so it is offered
                // only while none is placed — refusing here beats accepting a
                // rung normalization would silently drop.
                Text("reminder fired").tag(TriggerKind.reminder)
                    .disabled(reminderTaken(excluding: index))
            }
            .labelsHidden()
            .fixedSize()

            if case let .remainingAtOrBelow(percent) = level.trigger {
                Stepper(
                    value: Binding(
                        get: { percent },
                        set: { update(index, trigger: .remainingAtOrBelow($0)) }
                    ),
                    in: MenuBarEscalationTrigger.minimumPercent...MenuBarEscalationTrigger.maximumPercent,
                    step: 5
                ) {
                    Text("\(Int(percent))%")
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 34, alignment: .trailing)
                }
            }

            Spacer(minLength: 0)

            Button {
                escalation = escalation.replacingLevels(escalation.levels.filter { $0.id != level.id })
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove this level")
            .accessibilityLabel("Remove level")
        }
    }

    private enum TriggerKind: Hashable {
        case percent
        case reminder
    }

    private func reminderTaken(excluding index: Int) -> Bool {
        escalation.levels.enumerated().contains { $0.offset != index && $0.element.trigger == .reminderFired }
    }

    private func triggerKindBinding(index: Int, level: MenuBarEscalationLevel) -> Binding<TriggerKind> {
        Binding(
            get: { level.trigger == .reminderFired ? .reminder : .percent },
            set: { kind in
                switch kind {
                case .reminder:
                    update(index, trigger: .reminderFired)
                case .percent:
                    // Back to a threshold that is not already taken, so the
                    // switch does not silently collapse two rungs into one.
                    update(index, trigger: .remainingAtOrBelow(freeThreshold(excluding: index)))
                }
            }
        )
    }

    /// The first multiple of five nothing else occupies. Anything already used
    /// would be deduplicated away, taking the rung with it.
    private func freeThreshold(excluding index: Int) -> Double {
        let taken = Set(escalation.levels.enumerated().compactMap { offset, level -> Int? in
            guard offset != index, case let .remainingAtOrBelow(percent) = level.trigger else { return nil }
            return Int(percent)
        })
        return Double(stride(from: 50, through: 5, by: -5).first { !taken.contains($0) } ?? 50)
    }

    private func update(_ index: Int, color: HighlightColor? = nil, trigger: MenuBarEscalationTrigger? = nil) {
        var levels = escalation.levels
        guard levels.indices.contains(index) else { return }
        if let color { levels[index].color = color }
        if let trigger { levels[index].trigger = trigger }
        escalation = escalation.replacingLevels(levels)
    }
}

enum EscalationSettingsSurface {
    case menuBar
    case sideNotch

    var baseExplanation: String {
        switch self {
        case .menuBar:
            "What a meter is drawn in while it has reached no level. Neutral keeps the icon a template image, so macOS tints it to match the menu bar — pick a colour here only if you want the healthy state to say something too, because a colour that is always on stops matching your other menu bar icons on every wallpaper."
        case .sideNotch:
            "What a ring is drawn in before it reaches a level. Neutral uses white against the Side Notch's fixed dark surface; choose a colour if the healthy state should carry meaning too."
        }
    }
}
