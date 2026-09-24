import Foundation
import Testing

@testable import Tokenmax

@Suite("Side Notch presentation")
struct SideNotchPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    private func snapshot(
        _ provider: TokenmaxProvider,
        availableResetCount: Int? = nil,
        availableResetExpiresAt: Date? = nil,
        oneTimeCredit: OneTimeCredit? = nil,
        includeSession: Bool = true
    ) -> UsageSnapshot {
        var windows = [
            UsageWindow(
                id: "\(provider.rawValue).weekly", kind: .weekly, label: "Weekly",
                usedPercent: 60, resetAt: now.addingTimeInterval(86_400),
                observedAt: now, source: .manual, confidence: .authoritative
            ),
        ]
        if includeSession {
            windows.insert(
                UsageWindow(
                    id: "\(provider.rawValue).session", kind: .session, label: "Session",
                    usedPercent: 30, resetAt: now.addingTimeInterval(3_600),
                    observedAt: now, source: .manual, confidence: .authoritative
                ),
                at: 0
            )
        }

        return UsageSnapshot(
            providerID: provider.rawValue,
            planName: "Test",
            windows: windows,
            fetchedAt: now,
            fetchDuration: 0.1,
            errorMessage: nil,
            availableResetCount: availableResetCount,
            availableResetExpiresAt: availableResetExpiresAt,
            oneTimeCredit: oneTimeCredit
        )
    }

    private func make(
        layout: MenuBarRings,
        enabledProviders: [TokenmaxProvider],
        snapshot: @escaping (TokenmaxProvider) -> UsageSnapshot?,
        isStale: @escaping (TokenmaxProvider) -> Bool,
        alerting: Set<MenuBarQuotaSource> = [],
        ready: Set<MenuBarQuotaSource> = [],
        projection: @escaping (UsageWindow) -> UsageProjection? = { _ in nil },
        reminderStatus: @escaping (TokenmaxProvider, UsageWindowKind) -> ReminderStatus? = { _, _ in nil }
    ) -> [SideNotchProviderPresentation] {
        SideNotchPresentation.make(
            layout: layout,
            enabledProviders: enabledProviders,
            snapshot: { snapshot($0) },
            isStale: isStale,
            alerting: alerting,
            ready: ready,
            colors: .init(),
            now: now,
            projection: projection,
            reminderStatus: reminderStatus
        )
    }

    @Test("Cross-provider menu-bar pairs become one double ring per provider")
    func groupsByProvider() throws {
        let layout = MenuBarRings([
            .codexSession, .claudeWeekly, .codexWeekly, .claudeSession,
        ])
        let models = make(
            layout: layout,
            enabledProviders: [.claudeCode, .codex],
            snapshot: { snapshot($0) },
            isStale: { _ in false },
            alerting: [],
            ready: []
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
        let model = try #require(make(
            layout: MenuBarRings([.claudeWeekly, .claudeSession]),
            enabledProviders: [.claudeCode],
            snapshot: { snapshot($0) },
            isStale: { _ in true },
            alerting: [.claudeWeekly],
            ready: [.claudeSession]
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
            snapshot: { snapshot($0) },
            isStale: { _ in false },
            alerting: [],
            ready: [.claudeWeekly],
            colors: .init(scheme: .escalating),
            now: now,
            projection: { _ in nil },
            reminderStatus: { _, _ in nil }
        ).first)

        #expect(model.outer.remainingPercent == 40)
        #expect(model.outer.color == MenuBarEscalation.default.levels.last?.color)
        #expect(model.outer.color != HighlightColor.default)
    }

    @Test("Following the monochrome menu bar keeps its fixed reminder orange")
    func monochromeReminderKeepsOrange() throws {
        let model = try #require(make(
            layout: MenuBarRings([.claudeWeekly, .claudeSession]),
            enabledProviders: [.claudeCode],
            snapshot: { snapshot($0) },
            isStale: { _ in false },
            alerting: [.claudeWeekly],
            ready: []
        ).first)

        #expect(model.outer.color == HighlightColor(red: 1.00, green: 0.58, blue: 0.10))
    }

    @Test("The detail model carries the provider information shown in the popover")
    func carriesProviderDetails() throws {
        let reminder = ReminderStatus.scheduled(now.addingTimeInterval(1_800))
        let model = try #require(make(
            layout: MenuBarRings([.codexWeekly, .codexSession]),
            enabledProviders: [.codex],
            snapshot: {
                snapshot(
                    $0,
                    availableResetCount: 2,
                    availableResetExpiresAt: now.addingTimeInterval(86_400)
                )
            },
            isStale: { _ in false },
            projection: { UsageProjection.make(window: $0, now: now) },
            reminderStatus: { _, kind in kind == .weekly ? reminder : nil }
        ).first)

        #expect(model.planName == "Test")
        #expect(model.updatedText == "Updated 0s ago")
        #expect(model.detailMeters.count == 2)
        #expect(model.outer.projection != nil)
        #expect(model.outer.reminderStatus == reminder)
        #expect(model.availableResetLines.first?.contains("2 available resets") == true)
    }

    @Test("Expired Codex reset credits do not survive into the detail card")
    func expiredResetIsHidden() throws {
        let model = try #require(make(
            layout: MenuBarRings([.codexWeekly, .codexSession]),
            enabledProviders: [.codex],
            snapshot: {
                snapshot(
                    $0,
                    availableResetCount: 1,
                    availableResetExpiresAt: now.addingTimeInterval(-1)
                )
            },
            isStale: { _ in false }
        ).first)

        #expect(model.availableResetLines.isEmpty)
    }

    @Test("A weekly-only plan does not reserve space for an absent session")
    func weeklyOnlyDetailIsShorter() throws {
        let full = try #require(make(
            layout: MenuBarRings([.codexWeekly, .codexSession]),
            enabledProviders: [.codex],
            snapshot: { snapshot($0) },
            isStale: { _ in false }
        ).first)
        let weeklyOnly = try #require(make(
            layout: MenuBarRings([.codexWeekly, .codexSession]),
            enabledProviders: [.codex],
            snapshot: { snapshot($0, includeSession: false) },
            isStale: { _ in false }
        ).first)

        #expect(weeklyOnly.detailMeters.count == 1)
        #expect(
            SideNotchDetailLayout.dimensions(for: weeklyOnly).height
                < SideNotchDetailLayout.dimensions(for: full).height
        )
    }

    @Test("Claude's resets and cloud credit both reach the detail card")
    func claudeResetsAndCredit() throws {
        let plain = try #require(make(
            layout: MenuBarRings([.claudeWeekly, .claudeSession]),
            enabledProviders: [.claudeCode],
            snapshot: { snapshot($0) },
            isStale: { _ in false }
        ).first)
        let model = try #require(make(
            layout: MenuBarRings([.claudeWeekly, .claudeSession]),
            enabledProviders: [.claudeCode],
            snapshot: {
                snapshot(
                    $0,
                    availableResetCount: 1,
                    availableResetExpiresAt: now.addingTimeInterval(86_400),
                    oneTimeCredit: OneTimeCredit(
                        usedPercent: 12, remainingDollars: 220, limitDollars: 250,
                        expiresAt: now.addingTimeInterval(30 * 86_400)
                    )
                )
            },
            isStale: { _ in false }
        ).first)

        #expect(model.availableResetLines.first?.hasPrefix("1 available reset · expires") == true)
        #expect(model.oneTimeCreditText?.hasPrefix("Cloud credit · $220 of $250 left · expires") == true)
        #expect(
            SideNotchDetailLayout.dimensions(for: model).height
                == SideNotchDetailLayout.dimensions(for: plain).height + 44
        )
    }

    @Test("An expired or spent cloud credit is not advertised")
    func spentOrExpiredCreditIsHidden() {
        let expired = snapshot(.claudeCode, oneTimeCredit: OneTimeCredit(
            usedPercent: 0, remainingDollars: 250, limitDollars: 250, expiresAt: now.addingTimeInterval(-1)
        ))
        let spentDollars = snapshot(.claudeCode, oneTimeCredit: OneTimeCredit(
            usedPercent: 100, remainingDollars: 0, limitDollars: 250, expiresAt: nil
        ))
        let spentPercent = snapshot(.claudeCode, oneTimeCredit: OneTimeCredit(
            usedPercent: 100, remainingDollars: nil, limitDollars: nil, expiresAt: nil
        ))

        #expect(UsageWindowPresentation.oneTimeCreditText(for: expired, now: now) == nil)
        #expect(UsageWindowPresentation.oneTimeCreditText(for: spentDollars, now: now) == nil)
        #expect(UsageWindowPresentation.oneTimeCreditText(for: spentPercent, now: now) == nil)
    }

    @Test("A percentage-only credit shows the share left")
    func percentageCredit() {
        let credit = snapshot(.claudeCode, oneTimeCredit: OneTimeCredit(
            usedPercent: 12.5, remainingDollars: nil, limitDollars: nil, expiresAt: nil
        ))

        #expect(UsageWindowPresentation.oneTimeCreditText(for: credit, now: now) == "Cloud credit · 87% left")
    }

    @Test("Codex resets listed one by one get a line each, expired ones dropped")
    func eachResetGetsALine() throws {
        let resets = [
            BankedReset(title: "Full reset (Weekly + 5 hr)", expiresAt: now.addingTimeInterval(86_400)),
            BankedReset(title: "Full reset (Weekly + 5 hr)", expiresAt: now.addingTimeInterval(2 * 86_400)),
            BankedReset(title: nil, expiresAt: nil),
            BankedReset(title: "Gone", expiresAt: now.addingTimeInterval(-1)),
        ]
        let base = snapshot(.codex, availableResetCount: 3, availableResetExpiresAt: now.addingTimeInterval(86_400))
        let listed = UsageSnapshot(
            providerID: base.providerID, planName: base.planName, windows: base.windows,
            fetchedAt: base.fetchedAt, fetchDuration: 0.1, errorMessage: nil,
            availableResetCount: 3, availableResetExpiresAt: now.addingTimeInterval(86_400),
            availableResets: resets
        )

        let lines = UsageWindowPresentation.availableResetLines(for: listed, now: now)
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("Full reset (Weekly + 5 hr) · expires"))
        #expect(lines[2] == "Reset")

        let model = try #require(make(
            layout: MenuBarRings([.codexWeekly, .codexSession]),
            enabledProviders: [.codex],
            snapshot: { _ in listed },
            isStale: { _ in false }
        ).first)
        let summary = try #require(make(
            layout: MenuBarRings([.codexWeekly, .codexSession]),
            enabledProviders: [.codex],
            snapshot: { _ in base },
            isStale: { _ in false }
        ).first)
        #expect(
            SideNotchDetailLayout.dimensions(for: model).height
                == SideNotchDetailLayout.dimensions(for: summary).height + 44
        )
    }
}
