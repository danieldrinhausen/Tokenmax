import Foundation

/// One quota window the menubar icon can draw as a bar.
///
/// Deliberately a flat enum rather than a `(provider, kind)` pair: it is
/// persisted, dragged between slots, and used as a dictionary key, and every one
/// of those is simpler with a single stable identifier. The pair is recovered
/// through `provider` and `kind` where the rest of the app needs it.
enum MenuBarQuotaSource: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case claudeSession = "claude.session"
    case claudeWeekly = "claude.weekly"
    case codexWeekly = "codex.weekly"
    // Appended last on purpose. `allCases` order is the canonical order bars are
    // padded and grown from, so slotting this in beside `codexWeekly` would
    // silently change which quota the third bar of an existing layout draws.
    case codexSession = "codex.session"

    var id: String { rawValue }

    var provider: TokenmaxProvider {
        switch self {
        case .claudeSession, .claudeWeekly: .claudeCode
        case .codexWeekly, .codexSession: .codex
        }
    }

    var kind: UsageWindowKind {
        switch self {
        case .claudeSession, .codexSession: .session
        case .claudeWeekly, .codexWeekly: .weekly
        }
    }

    /// For the settings list, where the provider is not otherwise visible.
    var displayName: String {
        switch self {
        case .claudeSession: "Claude session"
        case .claudeWeekly: "Claude week"
        case .codexWeekly: "Codex week"
        case .codexSession: "Codex session"
        }
    }
}

/// Dedupe, drop disabled providers, pad from the canonical order, truncate.
///
/// Shared by `MenuBarBars` and `MenuBarRings` because the invariant is the same
/// one — no repeats, never empty, never longer than the geometry can draw — and
/// only the bounds differ. Normalizes rather than rejects: the callers sit on
/// the path from `settings.json`, which a user may have hand-edited, and from a
/// drag that a future editor could get wrong. Neither is worth a crash or an
/// empty menu bar item.
///
/// `allowed` is the set of sources whose provider is switched on.
///
/// `step` is what keeps a ring layout even. Half a ring — an outer arc with no
/// inner one — has no drawing. An odd list is filled up to the next whole ring
/// rather than cut down to one: padding invents a slot the user can re-assign,
/// truncating throws away one they had already chosen.
func normalizedQuotaSlots(
    _ sources: [MenuBarQuotaSource],
    allowed: [MenuBarQuotaSource],
    minimum: Int,
    maximum: Int,
    step: Int = 1
) -> [MenuBarQuotaSource] {
    // An empty universe has no normalization that produces a drawable icon.
    // Degrade to the full set; "every provider disabled" is prevented in
    // `AppSettings.init(from:)`, and this is the backstop.
    let universe = allowed.isEmpty ? MenuBarQuotaSource.allCases : allowed

    var seen: Set<MenuBarQuotaSource> = []
    // The `universe.contains` filter is what actually drops a disabled
    // provider's slot. Deduplication alone would keep it.
    var deduped = sources.filter { universe.contains($0) && seen.insert($0).inserted }

    // Never more slots than the enabled sources can fill: three bars cannot be
    // drawn when only one quota may be shown.
    let ceiling = min(maximum, universe.count)
    let floor = min(minimum, ceiling - ceiling % step)

    // Pad from the canonical order so a truncated list still renders, and so an
    // odd one reaches the next whole step. A lone enabled quota can only ever
    // be one slot, and one slot is drawable where an empty icon is not.
    for candidate in universe
    where deduped.count < floor || (deduped.count % step != 0 && deduped.count < ceiling) {
        if seen.insert(candidate).inserted { deduped.append(candidate) }
    }

    let capped = min(deduped.count, ceiling)
    return Array(deduped.prefix(capped - capped % step))
}

/// The ordered bars of the menubar icon, top to bottom.
///
/// Wrapped in a type rather than left as a bare array because the invariants are
/// what make the drag-and-drop editor safe: two or three bars, never a repeat.
/// A repeated source would draw the same number twice and silently waste a slot;
/// a count outside 2...3 has no geometry to render into.
struct MenuBarBars: Codable, Sendable, Equatable {
    static let minimumCount = 2
    static let maximumCount = 3

    /// Also the fallback order used to pad a short or corrupted list, so the
    /// icon that appears is the one Tokenmax has always shipped.
    static let `default` = MenuBarBars([.claudeSession, .claudeWeekly])

    private(set) var sources: [MenuBarQuotaSource]

    /// Normalizes rather than rejects. This initializer is on the path from
    /// `settings.json`, which a user may have hand-edited, and from a drag that
    /// a future editor could get wrong — neither is worth a crash or an empty
    /// menu bar item.
    ///
    /// `allowed` is the set of sources whose provider is switched on. It is a
    /// parameter rather than a stored property because this type is `Codable`
    /// and `Equatable` and its encoded form is a bare array — a settings-derived
    /// value has no business inside that identity.
    init(_ sources: [MenuBarQuotaSource], allowed: [MenuBarQuotaSource] = MenuBarQuotaSource.allCases) {
        self.sources = normalizedQuotaSlots(
            sources,
            allowed: allowed,
            minimum: Self.minimumCount,
            maximum: Self.maximumCount
        )
    }

    /// Decodes against the *full* universe, never the enabled set — the decoder
    /// has no settings access and must not gain any. Restricting to the enabled
    /// sources is strictly a read-time concern (`AppSettings.effectiveMenuBarBars`),
    /// which is what lets a disabled provider's slot survive on disk until its
    /// provider is switched back on.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // `try?` for the same reason as `AppSettings.init(from:)`: a source that
        // no longer decodes must cost this one setting, not the whole file.
        let decoded = (try? container.decode([MenuBarQuotaSource].self)) ?? Self.default.sources
        self.init(decoded)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(sources)
    }

    var count: Int { sources.count }

    /// The sources not currently on a bar, in canonical order, for the editor's
    /// "available" tray.
    func unused(allowed: [MenuBarQuotaSource] = MenuBarQuotaSource.allCases) -> [MenuBarQuotaSource] {
        allowed.filter { !sources.contains($0) }
    }

    /// Replaces the source at `index`. If the incoming source already occupies
    /// another slot the two swap, which is the only reading of a drag onto an
    /// occupied slot that cannot lose a bar.
    func replacing(
        at index: Int,
        with source: MenuBarQuotaSource,
        allowed: [MenuBarQuotaSource] = MenuBarQuotaSource.allCases
    ) -> MenuBarBars {
        // A disabled provider's source is never in the tray, but a stale drag
        // payload could still carry one. Refusing beats accepting a bar that
        // normalization would immediately drop.
        guard sources.indices.contains(index), allowed.contains(source) else { return self }
        var updated = sources
        if let existing = updated.firstIndex(of: source) {
            updated.swapAt(existing, index)
        } else {
            updated[index] = source
        }
        return MenuBarBars(updated, allowed: allowed)
    }

    /// Grows or shrinks to `count` bars. Shrinking drops from the bottom;
    /// growing appends the first unused source, so the user never lands on an
    /// empty slot they have to fill before the icon renders again.
    func resized(to count: Int, allowed: [MenuBarQuotaSource] = MenuBarQuotaSource.allCases) -> MenuBarBars {
        let universe = allowed.isEmpty ? MenuBarQuotaSource.allCases : allowed
        // The enabled set is also a ceiling: three bars cannot be asked for when
        // only one quota may be drawn.
        let target = max(
            min(Self.minimumCount, universe.count),
            min(Self.maximumCount, universe.count, count)
        )
        if sources.count == target { return self }
        if sources.count > target { return MenuBarBars(Array(sources.prefix(target)), allowed: universe) }
        return MenuBarBars(
            sources + unused(allowed: universe).prefix(target - sources.count),
            allowed: universe
        )
    }
}

/// The rings of the menubar icon: outer arc then inner arc, ring by ring,
/// left to right.
///
/// Stored flat rather than as a list of pairs so it shares
/// `normalizedQuotaSlots` with `MenuBarBars` and encodes as the same bare array
/// — the dedupe rules, the drag editor and the tolerant decoder then exist
/// once instead of twice. The pairs are recovered through `rings`.
///
/// One or two rings, because two rings already spend 35pt of menu bar and a
/// third would put the icon past anything that still reads as one item.
struct MenuBarRings: Codable, Sendable, Equatable, Hashable {
    /// Slots, not rings: one ring is two arcs.
    static let minimumCount = 2
    static let maximumCount = 4

    /// Outer week, inner session, per provider — the nesting the layout exists
    /// to show, since a session runs inside a week. Also the fallback order a
    /// short or corrupted list is padded from; normalization reduces it to a
    /// single ring when only one provider is switched on.
    static let `default` = MenuBarRings([.claudeWeekly, .claudeSession, .codexWeekly, .codexSession])

    private(set) var sources: [MenuBarQuotaSource]

    /// See `normalizedQuotaSlots`. `allowed` is a parameter rather than a stored
    /// property for the same reason as in `MenuBarBars`: this type is `Codable`
    /// and `Equatable` and its encoded form is a bare array, so a
    /// settings-derived value has no business inside that identity.
    init(_ sources: [MenuBarQuotaSource], allowed: [MenuBarQuotaSource] = MenuBarQuotaSource.allCases) {
        self.sources = normalizedQuotaSlots(
            sources,
            allowed: allowed,
            minimum: Self.minimumCount,
            maximum: Self.maximumCount,
            step: 2
        )
    }

    /// Decodes against the *full* universe, never the enabled set — same
    /// reasoning as `MenuBarBars.init(from:)`, which is what lets a disabled
    /// provider's ring survive on disk until its provider is switched back on.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decoded = (try? container.decode([MenuBarQuotaSource].self)) ?? Self.default.sources
        self.init(decoded)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(sources)
    }

    var count: Int { sources.count }
    var ringCount: Int { sources.count / 2 }

    /// The slots paired up as they are drawn. Total by construction — the
    /// initializer guarantees an even count, so there is no half ring to
    /// represent.
    var rings: [(outer: MenuBarQuotaSource, inner: MenuBarQuotaSource)] {
        stride(from: 0, to: sources.count - 1, by: 2).map {
            (outer: sources[$0], inner: sources[$0 + 1])
        }
    }

    /// The sources not currently on a ring, in canonical order, for the
    /// editor's "available" tray.
    func unused(allowed: [MenuBarQuotaSource] = MenuBarQuotaSource.allCases) -> [MenuBarQuotaSource] {
        allowed.filter { !sources.contains($0) }
    }

    /// Replaces the source at `index`. If the incoming source already occupies
    /// another slot the two swap, which is the only reading of a drag onto an
    /// occupied slot that cannot lose an arc.
    func replacing(
        at index: Int,
        with source: MenuBarQuotaSource,
        allowed: [MenuBarQuotaSource] = MenuBarQuotaSource.allCases
    ) -> MenuBarRings {
        guard sources.indices.contains(index), allowed.contains(source) else { return self }
        var updated = sources
        if let existing = updated.firstIndex(of: source) {
            updated.swapAt(existing, index)
        } else {
            updated[index] = source
        }
        return MenuBarRings(updated, allowed: allowed)
    }

    /// Grows or shrinks to `rings` rings. Shrinking drops from the right;
    /// growing appends the first unused sources, so the user never lands on an
    /// empty slot they have to fill before the icon renders again.
    func resized(toRings rings: Int, allowed: [MenuBarQuotaSource] = MenuBarQuotaSource.allCases) -> MenuBarRings {
        let universe = allowed.isEmpty ? MenuBarQuotaSource.allCases : allowed
        // The enabled set is also a ceiling: two rings cannot be asked for when
        // only one provider's two quotas may be drawn.
        let target = max(
            min(Self.minimumCount, universe.count),
            min(Self.maximumCount, universe.count, rings * 2)
        )
        if sources.count == target { return self }
        if sources.count > target { return MenuBarRings(Array(sources.prefix(target)), allowed: universe) }
        return MenuBarRings(
            sources + unused(allowed: universe).prefix(target - sources.count),
            allowed: universe
        )
    }
}
