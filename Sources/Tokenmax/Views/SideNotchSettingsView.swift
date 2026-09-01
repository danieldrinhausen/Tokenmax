import SwiftUI

struct SideNotchSettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var sideNotch: SideNotchCoordinator

    var body: some View {
        Section("Side Notch · Alpha") {
            Toggle("Show the Side Notch", isOn: sideNotchEnabledBinding)

            Text("A small handle stays at the centre of the right screen edge. Hover it for provider rings; hover a ring for quota, pace, reminders and reset details, or click one to pin the card. It follows the pointer between displays and never takes keyboard focus.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if settingsStore.settings.sideNotch.enabled {
                if let suppression = sideNotch.suppression {
                    Label(suppression.explanation, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("Surface", selection: placementBinding) {
                    ForEach(SideNotchPlacement.allCases) { placement in
                        Text(placement.displayName).tag(placement)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()

                if settingsStore.settings.sideNotch.placement == .dock {
                    Picker("Dock placement", selection: dockPlacementBinding) {
                        ForEach(DockNotchPlacement.allCases) { placement in
                            Text(placement.displayName).tag(placement)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()

                    Text("Dock Notch rests just above the Dock's reserved edge, on the side you choose. It keeps the same hover and pin behaviour without occupying the screen edge.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker("Colours", selection: colorSourceBinding) {
                    ForEach(SideNotchColorSource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("Provider order and each ring's outer/inner quotas follow the ring arrangement above. The Side Notch keeps one double ring per provider even when the menu bar pairs quotas across providers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if settingsStore.settings.sideNotch.colorSource == .custom {
                    Picker("Ring colour", selection: schemeBinding) {
                        ForEach(MenuBarColorScheme.allCases) { scheme in
                            Text(scheme.displayName).tag(scheme)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()

                    if customColors.scheme == .escalating {
                        MenuBarEscalationSettingsView(
                            escalation: escalationBinding,
                            surface: .sideNotch
                        )
                    }

                    HighlightColorPicker(label: "Opportunity", color: opportunityBinding)
                    Toggle("Add a glow", isOn: glowBinding)

                    Text("Custom colours start as a copy of the current menu bar palette, then remain independent when you switch between Follow menu bar and Custom.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var colorSourceBinding: Binding<SideNotchColorSource> {
        Binding(
            get: { settingsStore.settings.sideNotch.colorSource },
            set: { source in
                if source == .custom, settingsStore.settings.sideNotch.customColors == nil {
                    settingsStore.settings.sideNotch.customColors = settingsStore.settings.menuBarColorsForSideNotch
                }
                settingsStore.settings.sideNotch.colorSource = source
            }
        )
    }

    private var placementBinding: Binding<SideNotchPlacement> {
        Binding(
            get: { settingsStore.settings.sideNotch.placement },
            set: { settingsStore.settings.sideNotch.placement = $0 }
        )
    }

    private var dockPlacementBinding: Binding<DockNotchPlacement> {
        Binding(
            get: { settingsStore.settings.sideNotch.dockPlacement },
            set: { settingsStore.settings.sideNotch.dockPlacement = $0 }
        )
    }

    private var sideNotchEnabledBinding: Binding<Bool> {
        Binding(
            get: { settingsStore.settings.sideNotch.enabled },
            set: { enabled in
                if !enabled {
                    settingsStore.settings.showMenuBarItem = true
                }
                settingsStore.settings.sideNotch.enabled = enabled
            }
        )
    }

    private var customColors: SideNotchColorSettings {
        settingsStore.settings.sideNotch.customColors ?? settingsStore.settings.menuBarColorsForSideNotch
    }

    private var schemeBinding: Binding<MenuBarColorScheme> {
        Binding(
            get: { customColors.scheme },
            set: { value in updateCustom { $0.scheme = value } }
        )
    }

    private var escalationBinding: Binding<MenuBarEscalation> {
        Binding(
            get: { customColors.escalation },
            set: { value in updateCustom { $0.escalation = value } }
        )
    }

    private var opportunityBinding: Binding<HighlightColor> {
        Binding(
            get: { customColors.opportunityColor },
            set: { value in updateCustom { $0.opportunityColor = value } }
        )
    }

    private var glowBinding: Binding<Bool> {
        Binding(
            get: { customColors.glow },
            set: { value in updateCustom { $0.glow = value } }
        )
    }

    private func updateCustom(_ update: (inout SideNotchColorSettings) -> Void) {
        var colors = customColors
        update(&colors)
        settingsStore.settings.sideNotch.customColors = colors
    }
}
