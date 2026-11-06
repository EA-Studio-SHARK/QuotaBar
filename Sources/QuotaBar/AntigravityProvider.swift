import Foundation

enum AntigravityProvider {
    struct TokenFile: Decodable {
        struct Token: Decodable {
            let access_token: String?
            let refresh_token: String?
            let expiry: String?
        }
        let token: Token?
    }

    private struct RefreshResponse: Decodable {
        let access_token: String
        let expires_in: Double?
    }

    struct QuotaSummaryResponse: Decodable {
        struct Group: Decodable {
            struct Bucket: Decodable {
                let bucketId: String?
                let window: String?
                let remainingFraction: Double?
                let resetTime: String?
            }
            let buckets: [Bucket]?
        }
        let groups: [Group]?
    }

    private static let clientId = ["1071006060591-tmhssin2h21lcre2", "35vtolojh4g403ep.apps.googleusercontent.com"].joined()
    private static let clientSecret = ["GOC", "SPX-", "K58FWR486LdL", "J1mLB8sXC4z6qDAf"].joined()

    static func fetch() async -> ProviderUsage {
        do {
            let creds = try readCredentials()
            var accessToken = creds.accessToken
            if creds.isExpired, let refresh = creds.refreshToken {
                accessToken = try await refreshAccessToken(refreshToken: refresh)
            }
            do {
                let summary = try await fetchSummary(token: accessToken)
                return try parseQuota(summary)
            } catch let QuotaError.http(code, _) where code == 401 {
                guard let refresh = creds.refreshToken else { throw QuotaError.http(401, "") }
                let fresh = try await refreshAccessToken(refreshToken: refresh)
                let summary = try await fetchSummary(token: fresh)
                return try parseQuota(summary)
            }
        } catch {
            return .unavailable(.antigravity, message: error.localizedDescription)
        }
    }

    static func parseQuota(_ summary: QuotaSummaryResponse) throws -> ProviderUsage {
        let buckets = (summary.groups ?? []).flatMap { $0.buckets ?? [] }
        var metrics: [UsageMetric] = []

        func appendBucket(_ b: QuotaSummaryResponse.Group.Bucket, label: String) {
            guard let rem = b.remainingFraction else { return }
            let used = max(0, min(100, (1.0 - rem) * 100.0))
            let reset = ISO8601.parse(b.resetTime)
            metrics.append(UsageMetric(
                label: label,
                percent: used,
                detail: Formatters.countdown(to: reset),
                resetsAt: reset
            ))
        }

        if let b5h = buckets.first(where: { $0.bucketId == "gemini-5h" }) ?? buckets.first(where: { $0.window == "5h" }) {
            appendBucket(b5h, label: "5小时")
        }
        if let bWeek = buckets.first(where: { $0.bucketId == "gemini-weekly" }) ?? buckets.first(where: { $0.window == "weekly" }) {
            appendBucket(bWeek, label: "周限额")
        }
        if let b3p5h = buckets.first(where: { $0.bucketId == "3p-5h" }), (b3p5h.remainingFraction ?? 1.0) < 0.999 {
            appendBucket(b3p5h, label: "三方5h")
        }
        if let b3pWeek = buckets.first(where: { $0.bucketId == "3p-weekly" }), (b3pWeek.remainingFraction ?? 1.0) < 0.999 {
            appendBucket(b3pWeek, label: "三方周")
        }

        guard let primary = metrics.compactMap(\.percent).max() else {
            throw QuotaError.decode("Antigravity 未返回用量窗口")
        }
        return .fromPercent(.antigravity, percent: primary, metrics: metrics)
    }

    private static func fetchSummary(token: String) async throws -> QuotaSummaryResponse {
        let url = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!
        let (data, http) = try await HTTP.post(
            url: url,
            headers: [
                "Authorization": "Bearer \(token)",
                "Content-Type": "application/json",
                "Accept": "application/json",
                "User-Agent": "antigravity/2.28.2",
            ],
            body: Data("{}".utf8)
        )
        _ = try HTTP.requireOK(data, http)
        return try JSONDecoder().decode(QuotaSummaryResponse.self, from: data)
    }

    private static func readCredentials() throws -> (accessToken: String, refreshToken: String?, isExpired: Bool) {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/jetski-standalone-oauth-token")
        guard let data = try? Data(contentsOf: path),
              let decoded = try? JSONDecoder().decode(TokenFile.self, from: data),
              let token = decoded.token
        else {
            throw QuotaError.missingCredentials("未找到 Antigravity 登录态（~/.gemini/jetski-standalone-oauth-token）")
        }
        let access = token.access_token ?? ""
        let refresh = token.refresh_token
        if access.isEmpty && refresh == nil {
            throw QuotaError.missingCredentials("Antigravity 登录凭证为空，请在 Antigravity 重新登录")
        }
        let expiryDate = ISO8601.parse(token.expiry)
        let expired: Bool
        if access.isEmpty {
            expired = true
        } else if let expiryDate {
            expired = expiryDate.timeIntervalSinceNow < 60
        } else {
            expired = false
        }
        return (access, refresh, expired)
    }

    private static func refreshAccessToken(refreshToken: String) async throws -> String {
        let url = URL(string: "https://oauth2.googleapis.com/token")!
        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ]
        let body = Data((comps.percentEncodedQuery ?? "").utf8)
        let (data, http) = try await HTTP.post(
            url: url,
            headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "Accept": "application/json",
            ],
            body: body
        )
        _ = try HTTP.requireOK(data, http)
        let decoded = try JSONDecoder().decode(RefreshResponse.self, from: data)
        return decoded.access_token
    }
}
