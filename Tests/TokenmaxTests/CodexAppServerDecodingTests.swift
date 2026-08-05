import Foundation
import Testing

@testable import Tokenmax

@Suite("Codex App Server decoding")
struct CodexAppServerDecodingTests {
    @Test("Maps ChatGPT primary and secondary limits to resettable windows")
    func decodesRateLimits() throws {
        let result: [String: Any] = [
            "rateLimits": [
                "primary": ["usedPercent": 25.0, "windowDurationMins": 300, "resetsAt": 1_785_500_000.0],
                "secondary": ["usedPercent": 60.0, "windowDurationMins": 10_080, "resetsAt": 1_786_000_000.0],
            ],
            "rateLimitsByLimitId": [
                "codex-spark": [
                    "limitName": "Codex Spark",
                    "primary": ["usedPercent": 10.0, "resetsAt": 1_785_500_000.0],
                ],
            ],
        ]

        let limits = try CodexAppServerClient.decodeLimits(result)
        #expect(limits.primary?.usedPercent == 25)
        #expect(limits.primary?.resetsAt == Date(timeIntervalSince1970: 1_785_500_000))
        #expect(limits.secondary?.durationMinutes == 10_080)
        #expect(limits.additional.first?.id == "codex-spark")
    }

    @Test("Recognizes ChatGPT managed authentication")
    func decodesAccount() {
        let account = CodexAppServerClient.decodeAccount([
            "account": ["authMode": "chatgpt", "planType": "plus", "email": "person@example.com"],
        ])
        #expect(account.isChatGPTManaged)
        #expect(account.planName == "plus")
    }

    @Test("Recognizes the current account type field")
    func decodesCurrentAccountType() {
        let account = CodexAppServerClient.decodeAccount([
            "account": ["type": "chatgpt", "planType": "plus"],
        ])
        #expect(account.authMode == "chatgpt")
        #expect(account.isChatGPTManaged)
    }
}
