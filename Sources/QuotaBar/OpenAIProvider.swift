import Foundation

/// Shared OpenAI / ChatGPT / Codex usage from `~/.codex/auth.json` → wham/usage.
enum OpenAIWham {
    struct AuthFile: Decodable {
        let tokens: Tokens?
        struct Tokens: Decodable {
            let access_token: String
            let account_id: String?
            let refresh_token: String?
        }
    }

    struct Response: Decodable {
        let email: String?
        let plan_type: String?
        let rate_limit: RateLimit?
        let credits: Credits?
        let code_review_rate_limit: RateLimit?
        let additional_rate_limits: [NamedLimit]?
        let promo: Promo?

        struct RateLimit: Decodable {
            let allowed: Bool?
            let limit_reached: Bool?
            let primary_window: Window?
            let secondary_window: Window?
        }

        struct Window: Decodable {
            let used_percent: Double?
            let limit_window_seconds: Int?
            let reset_after_seconds: Int?
            let reset_at: Double?
        }

        struct Credits: Decodable {
            let has_credits: Bool?
            let unlimited: Bool?
            let balance: Double?

            enum CodingKeys: String, CodingKey { case has_credits, unlimited, balance }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                has_credits = try container.decodeIfPresent(Bool.self, forKey: .has_credits)
                unlimited = try container.decodeIfPresent(Bool.self, forKey: .unlimited)
                balance = (try? container.decode(Double.self, forKey: .balance))
                    ?? (try? container.decode(String.self, forKey: .balance)).flatMap(Double.init)
            }
        }

        struct NamedLimit: Decodable {
            let id: String?
            let primary_window: Window?
            let secondary_window: Window?
        }

        struct Promo: Decodable {
            let message: String?
        }
    }

    static func fetch() async throws -> Response {
        let auth = try readAuth()
        guard var token = auth.tokens?.access_token else {
            throw QuotaError.missingCredentials("未找到 Codex/ChatGPT 登录态，请运行 codex login")
        }
        let account = auth.tokens?.account_id
        if let res = try? await requestUsage(token: token, accountId: account) {
            return res
        }
        if let rt = auth.tokens?.refresh_token, !rt.isEmpty,
           let refreshed = try? await refreshAccessToken(refreshToken: rt) {
            token = refreshed
        }
        return try await requestUsage(token: token, accountId: account)
    }

    private static func requestUsage(token: String, accountId: String?) async throws -> Response {
        var headers = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
            "User-Agent": "QuotaBar/1.1",
        ]
        if let account = accountId, !account.isEmpty {
            headers["ChatGPT-Account-Id"] = account
        }
        let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        let (data, http) = try await HTTP.get(url: url, headers: headers)
        _ = try HTTP.requireOK(data, http)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private static func refreshAccessToken(refreshToken: String) async throws -> String {
        let url = URL(string: "https://auth.openai.com/oauth/token")!
        let payload = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "client_id": "app_EMoamEEZ73f0CkXaXp7hrann",
            "refresh_token": refreshToken,
        ])
        let (data, http) = try await HTTP.post(
            url: url,
            headers: ["Content-Type": "application/json", "Accept": "application/json"],
            body: payload
        )
        _ = try HTTP.requireOK(data, http)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccess = obj["access_token"] as? String else {
            throw QuotaError.other("OpenAI token 刷新未返回 access_token")
        }
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        if let rawData = try? Data(contentsOf: path),
           var root = (try? JSONSerialization.jsonObject(with: rawData)) as? [String: Any],
           var tokens = root["tokens"] as? [String: Any] {
            tokens["access_token"] = newAccess
            if let newRefresh = obj["refresh_token"] as? String { tokens["refresh_token"] = newRefresh }
            if let newId = obj["id_token"] as? String { tokens["id_token"] = newId }
            root["tokens"] = tokens
            root["last_refresh"] = ISO8601DateFormatter().string(from: Date())
            if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
                try? out.write(to: path, options: .atomic)
            }
        }
        return newAccess
    }

    private static func readAuth() throws -> AuthFile {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw QuotaError.missingCredentials("未找到 ~/.codex/auth.json，请先安装并登录 Codex CLI")
        }
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(AuthFile.self, from: data)
    }

    static func windowLabel(seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "窗口" }
        let h = seconds / 3600
        if h >= 24 {
            let d = h / 24
            return d >= 28 ? "月度" : "\(d) 天"
        }
        if h > 0 { return "\(h) 小时" }
        return "\(seconds / 60) 分钟"
    }

    static func resetDate(from window: Response.Window?) -> Date? {
        guard let window else { return nil }
        if let ts = window.reset_at { return Date(timeIntervalSince1970: ts) }
        if let after = window.reset_after_seconds {
            return Date().addingTimeInterval(TimeInterval(after))
        }
        return nil
    }
}

enum CodexProvider {
    static func fetch() async -> ProviderUsage {
        do {
            let res = try await OpenAIWham.fetch()
            var metrics: [UsageMetric] = []
            var primary: Double?

            if let w = res.rate_limit?.primary_window, let p = w.used_percent {
                primary = p
                let reset = OpenAIWham.resetDate(from: w)
                metrics.append(UsageMetric(
                    label: OpenAIWham.windowLabel(seconds: w.limit_window_seconds),
                    percent: p,
                    detail: Formatters.countdown(to: reset),
                    resetsAt: reset
                ))
            }
            if let w = res.rate_limit?.secondary_window, let p = w.used_percent {
                primary = max(primary ?? p, p)
                let reset = OpenAIWham.resetDate(from: w)
                metrics.append(UsageMetric(
                    label: OpenAIWham.windowLabel(seconds: w.limit_window_seconds),
                    percent: p,
                    detail: Formatters.countdown(to: reset),
                    resetsAt: reset
                ))
            }
            if let extras = res.additional_rate_limits {
                for item in extras.prefix(3) {
                    if let w = item.primary_window, let p = w.used_percent {
                        metrics.append(UsageMetric(
                            label: item.id ?? "额外",
                            percent: p,
                            detail: Formatters.countdown(to: OpenAIWham.resetDate(from: w)),
                            resetsAt: OpenAIWham.resetDate(from: w)
                        ))
                    }
                }
            }
            if let plan = res.plan_type {
                metrics.insert(UsageMetric(label: "套餐", percent: nil, detail: plan, resetsAt: nil), at: 0)
            }
            if let credits = res.credits {
                if credits.unlimited == true {
                    metrics.append(UsageMetric(label: "Credits", percent: nil, detail: "无限", resetsAt: nil))
                } else if let bal = credits.balance {
                    metrics.append(UsageMetric(label: "Credits", percent: nil, detail: String(format: "%.2f", bal), resetsAt: nil))
                }
            }

            if let p = primary {
                return .fromPercent(.codex, percent: p, metrics: metrics)
            }
            if !metrics.isEmpty {
                return ProviderUsage(
                    kind: .codex,
                    status: .ok,
                    primaryPercent: nil,
                    metrics: metrics,
                    errorMessage: nil,
                    updatedAt: Date()
                )
            }
            throw QuotaError.other("Codex 未返回用量窗口")
        } catch {
            return .unavailable(.codex, message: error.localizedDescription)
        }
    }
}
