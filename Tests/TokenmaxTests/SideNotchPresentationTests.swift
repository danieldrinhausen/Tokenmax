import Foundation
import Testing

@testable import Tokenmax

@Suite("Side Notch presentation")
struct SideNotchPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    private func snapshot(_ provider: TokenmaxProvider) -> UsageSnapshot {
        UsageSnapshot(
            providerID: provider.rawValue,
            planName: "Test",
            windows: [
                UsageWindow(
                    id: "\(provider.rawValue).session", kind: .session, label: "Session",
                    usedPercent: 30, resetAt: now.addingTimeInterval(3_600),
                    observedAt: now, source: .manual, confidence: .authoritative
                ),
                UsageWindow(
                    id: "\(provider.rawValue).weekly", kind: .weekly, label: "Weekly",
                    usedPercent: 60, resetAt: now.addingTimeInterval(86_400),
                    observedAt: now, source: .manual, confidence: .authoritative
                ),
            ],
            fetchedAt: now,
            fetchDuration: 0.1,
            errorMessage: nil
        )
    }

    @Test("Cross-provider menu-bar pairs become one double ring per provider")
    func groupsByProvider() throws {
        let layout = MenuBarRings([
            .codexSession, .claudeWeekly, .codexWeekly, .claudeSession,
        ])
        let models = SideNotchPresentation.make(
            layout: layout,
            enabledProviders: [.claudeCode, .codex],
            snapshot: snapshot,
            isStale: { _ in false },
            alerting: [],
            ready: [],
            colors: .init()
        )

        #expect(models.map(\.provider) == [.codex, .claudeCode])
        let codex = try #require(models.first)
        #expect(codex.outer.source == .codexSession)
        #expect(codex.inner.source == .codexWeekly)
        #expect(codex.outer.remainingPercent == 70)
        #expect(codex.inner.remainingPercent == 40)
    }

    @Test("A stale reading draws empty tracks rather than pretending to be zero")
    func staleHasNoFraction() throws {
        let model = try #require(SideNotchPresentation.make(
            layout: MenuBarRings([.claudeWeekly, .claudeSession]),
            enabledProviders: [.claudeCode],
            snapshot: snapshot,
            isStale: { _ in true },
            alerting: [.claudeWeekly],
            ready: [.claudeSession],
            colors: .init(scheme: .escalating)
        ).first)

        #expect(model.outer.fraction == nil)
        #expect(model.inner.fraction == nil)
        #expect(model.outer.color == nil)
        #expect(model.inner.color == nil)
    }

    @Test("A severe threshold outranks the opportunity colour in the notch")
    func escalationOutranksOpportunity() throws {
        let model = try #require(SideNotchPresentation.make(
            layout: MenuBarRings([.claudeWeekly, .claudeSession]),
            enabledProviders: [.claudeCode],
            snapshot: snapshot,
            isStale: { _ in false },
            alerting: [],
            ready: [.claudeWeekly],
            colors: .init(scheme: .escalating)
        ).first)

        #expect(model.outer.remainingPercent == 40)
        #expect(model.outer.color == MenuBarEscalation.default.levels.last?.color)
        #expect(model.outer.color != HighlightColor.default)
    }

    @Test("Following the monochrome menu bar keeps its fixed reminder orange")
    func monochromeReminderKeepsOrange() throws {
        let model = try #require(SideNotchPresentation.make(
            layout: MenuBarRings([.claudeWeekly, .claudeSession]),
            enabledProviders: [.claudeCode],
            snapshot: snapshot,
            isStale: { _ in false },
            alerting: [.claudeWeekly],
            ready: [],
            colors: .init(scheme: .monochrome)
        ).first)

        #expect(model.outer.color == HighlightColor(red: 1.00, green: 0.58, blue: 0.10))
    }
}
