import Foundation

enum UpdateCheckError: Error, Equatable {
    case http(Int)
    case schemaDrift
    case transport(String)

    /// Shown in Settings → About, so it has to read as a status rather than a
    /// stack trace.
    var summary: String {
        switch self {
        case let .http(code): "GitHub replied \(code)."
        case .schemaDrift: "GitHub's reply was not in the expected shape."
        case let .transport(message): message
        }
    }
}

/// Reads the newest published release from GitHub.
///
/// The only request Tokenmax makes that is not about quota, and the only one
/// that leaves anything at a host the user did not already have an account
/// with — hence the switch in Settings, and the entry in the README's privacy
/// section. It sends no credentials and no identifying information; it is the
/// same unauthenticated GET a browser makes.
///
/// `/releases/latest` rather than `/releases`: GitHub already excludes drafts
/// and pre-releases from it, which is one rule this does not have to own or
/// keep in step with how releases are actually cut.
actor GitHubReleaseClient {
    struct Release: Sendable, Equatable {
        let tag: String
        let page: URL
    }

    private let endpoint = URL(
        string: "https://api.github.com/repos/danieldrinhausen/Tokenmax/releases/latest"
    )!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func latestRelease() async throws -> Release {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        // Short: nobody is waiting on this, and a hung check must not keep a
        // connection open for the life of the app.
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Tokenmax/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateCheckError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckError.schemaDrift
        }
        guard http.statusCode == 200 else {
            // 403 here is the unauthenticated rate limit, and it is a postpone
            // rather than a failure of the feature — see `UsageRefreshCoordinator`
            // for the same rule applied to quota.
            throw UpdateCheckError.http(http.statusCode)
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let page = (object["html_url"] as? String).flatMap(URL.init(string:))
        else {
            throw UpdateCheckError.schemaDrift
        }

        return Release(tag: tag, page: page)
    }
}
