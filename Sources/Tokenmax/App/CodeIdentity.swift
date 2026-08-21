import Foundation
import Security

/// The running binary's cdhash, for the launch log line.
///
/// Keychain consent grants are keyed to exactly this value (the bundle carries
/// no Team ID, so macOS has nothing more stable to key on). Logging it at
/// every launch turns "the prompt came back and I don't know why" into a
/// visible correlation: a prompt following a launch whose hash differs from
/// the previous launch's is the per-build re-ask, not a bug.
enum CodeIdentity {
    static var cdhash: String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let unique = dictionary[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }
}
