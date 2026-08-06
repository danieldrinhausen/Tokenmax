import Foundation

/// Where the running build describes itself. One place, so the popover header,
/// the About pane and the launch log cannot disagree about what is running.
enum AppInfo {
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    static let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
}

/// A dotted version — `0.1.2` — as something that can be ordered.
///
/// Comparing these as strings is wrong the moment a component reaches two
/// digits: `"0.1.10" < "0.1.9"` alphabetically, so the update check would go
/// quiet exactly when there had been enough releases for it to matter.
/// Components are compared numerically instead, and a missing one reads as
/// zero, so `0.2` and `0.2.0` are one version rather than two.
struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    /// As written, not normalised — `description` has to render the version the
    /// user's build actually claims, and trimming `0.1.0` to `0.1` would make
    /// the About pane disagree with the release they downloaded.
    let components: [Int]

    /// Tolerant of the shapes a release tag arrives in: a leading `v`,
    /// surrounding whitespace, and a pre-release or build suffix (`-beta.1`,
    /// `+ci`), which is dropped rather than rejected. A tag this cannot parse
    /// at all returns nil, and the caller names that suppression — it must
    /// never be mistaken for "no update available".
    init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        if let suffix = text.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            text = String(text[text.startIndex ..< suffix])
        }

        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }

        var parsed: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            parsed.append(value)
        }
        components = parsed
    }

    var description: String { components.map(String.init).joined(separator: ".") }

    /// Padded rather than zipped, so a shorter version is not automatically the
    /// smaller one: `1.0` and `1.0.0` are equal, `1.0` and `1.0.1` are not.
    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0 ..< max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    /// Written in terms of `<` for the same reason: the synthesized `==` would
    /// compare the arrays, making `1.0` and `1.0.0` different versions.
    static func == (lhs: Self, rhs: Self) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}
