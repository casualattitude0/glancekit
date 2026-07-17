import Foundation

/// Thin JSON models + a small client for the slice of the GitHub REST/Search
/// API this glance needs. Kept separate from `GitHubPlugin.swift` so the
/// plugin file stays focused on `GlancePlugin` conformance and UI.
enum GitHubAPI {
    static let baseHeaders: [String: String] = [
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    ]

    static func authHeaders(token: String) -> [String: String] {
        var headers = baseHeaders
        headers["Authorization"] = "Bearer \(token)"
        return headers
    }

    // MARK: - Models

    struct User: Decodable {
        let login: String
    }

    struct Notification: Decodable, Identifiable {
        let id: String
        let unread: Bool
        let subject: Subject
        let repository: Repository

        struct Subject: Decodable {
            let title: String
        }
        struct Repository: Decodable {
            let full_name: String
        }
    }

    struct SearchResult: Decodable {
        let items: [Issue]
    }

    struct Issue: Decodable, Identifiable {
        let id: Int
        let number: Int
        let title: String
        let html_url: String
        let repository_url: String
        let pull_request: PullRequestRef?

        struct PullRequestRef: Decodable {}

        /// "owner/repo" parsed out of the repository_url API link.
        var repoFullName: String {
            let parts = repository_url.split(separator: "/")
            guard parts.count >= 2 else { return repository_url }
            return "\(parts[parts.count - 2])/\(parts[parts.count - 1])"
        }
    }

    /// Combined status for a ref (used to derive a green/yellow/red dot).
    struct CombinedStatus: Decodable {
        let state: String // "success" | "pending" | "failure" | "error"
    }

    // MARK: Contribution calendar (GraphQL)

    /// The year-long contribution heatmap: a total plus one entry per day.
    struct ContributionCalendar: Decodable {
        let totalContributions: Int
        let weeks: [Week]

        struct Week: Decodable, Identifiable {
            let contributionDays: [Day]
            // Stable id: the first day's date (weeks never share a start date).
            var id: String { contributionDays.first?.date ?? UUID().uuidString }
        }
        struct Day: Decodable, Identifiable {
            let date: String
            let contributionCount: Int
            let weekday: Int // 0 = Sunday … 6 = Saturday
            var id: String { date }
        }
    }

    /// GraphQL envelope: a `data` payload and/or an `errors` array.
    private struct GraphQLResponse<T: Decodable>: Decodable {
        let data: T?
        let errors: [GraphQLError]?
        struct GraphQLError: Decodable { let message: String }
    }

    private struct ContributionsPayload: Decodable {
        let viewer: Viewer
        struct Viewer: Decodable {
            let contributionsCollection: Collection
        }
        struct Collection: Decodable {
            let contributionCalendar: ContributionCalendar
        }
    }

    // MARK: - Requests

    static func fetchUser(client: NetworkClient, token: String) async throws -> User {
        try await client.get(User.self, from: "https://api.github.com/user", headers: authHeaders(token: token))
    }

    static func fetchNotifications(client: NetworkClient, token: String) async throws -> [Notification] {
        try await client.get([Notification].self,
                              from: "https://api.github.com/notifications",
                              headers: authHeaders(token: token))
    }

    static func fetchOpenPRs(client: NetworkClient, token: String, login: String) async throws -> [Issue] {
        guard let encodedQuery = "is:open is:pr author:\(login)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return []
        }
        let url = "https://api.github.com/search/issues?q=\(encodedQuery)"
        let result = try await client.get(SearchResult.self, from: url, headers: authHeaders(token: token))
        return result.items
    }

    /// The signed-in user's contribution calendar for the last year, via the
    /// GraphQL API. Requires a token with read access to the user's profile
    /// (classic PATs work out of the box; fine-grained PATs need it granted).
    static func fetchContributions(client: NetworkClient, token: String) async throws -> ContributionCalendar {
        let query = """
        query { viewer { contributionsCollection { contributionCalendar { \
        totalContributions weeks { contributionDays { date contributionCount weekday } } } } } }
        """
        let body = try JSONSerialization.data(withJSONObject: ["query": query])
        var headers = authHeaders(token: token)
        headers["Content-Type"] = "application/json"

        let response = try await client.post(GraphQLResponse<ContributionsPayload>.self,
                                              to: "https://api.github.com/graphql",
                                              body: body,
                                              headers: headers)
        if let message = response.errors?.first?.message {
            throw NetworkClient.NetworkError.http(403, message: message)
        }
        guard let calendar = response.data?.viewer.contributionsCollection.contributionCalendar else {
            throw NetworkClient.NetworkError.decoding("Missing contribution calendar")
        }
        return calendar
    }

    /// Best-effort combined status for a PR's head commit. `repoFullName` is
    /// "owner/repo"; `number` is the PR/issue number used to look up the PR to
    /// find its head ref via the pulls endpoint, then the combined status.
    static func fetchCombinedStatus(client: NetworkClient, token: String, repoFullName: String, prNumber: Int) async -> String? {
        struct PullDetail: Decodable {
            struct Head: Decodable { let sha: String }
            let head: Head
        }
        do {
            let pull = try await client.get(PullDetail.self,
                                             from: "https://api.github.com/repos/\(repoFullName)/pulls/\(prNumber)",
                                             headers: authHeaders(token: token))
            let status = try await client.get(CombinedStatus.self,
                                               from: "https://api.github.com/repos/\(repoFullName)/commits/\(pull.head.sha)/status",
                                               headers: authHeaders(token: token))
            return status.state
        } catch {
            return nil
        }
    }
}
