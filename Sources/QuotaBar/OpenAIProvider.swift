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

    private static var cached: (Date, Response)?
    private static let cacheTTL: TimeInterval = 30

    static func fetch() async throws -> Response {
        if let cached, Date().timeIntervalSince(cached.0) < cacheTTL {
            return cached.1
        }
        let auth = try readAuth()
        guard let token = auth.tokens?.access_token else {
            throw QuotaError.missingCredentials("未找到 Codex/ChatGPT 登录态，请运行 codex login")
        }
        var headers = [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
            "User-Agent": "QuotaBar/1.1",
        ]
        if let account = auth.tokens?.account_id, !account.isEmpty {
            headers["ChatGPT-Account-Id"] = account
        }
        let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        let (data, http) = try await HTTP.get(url: url, headers: headers)
        _ = try HTTP.requireOK(data, http)
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        cached = (Date(), decoded)
        return decoded
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
                if primary == nil { primary = p }
                let reset = OpenAIWham.resetDate(from: w)
                metrics.append(UsageMetric(
                    label: "周额度",
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
                metrics.append(UsageMetric(label: "套餐", percent: nil, detail: plan, resetsAt: nil))
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

enum GPTProvider {
    static func fetch() async -> ProviderUsage {
        do {
            let res = try await OpenAIWham.fetch()
            var metrics: [UsageMetric] = []
            var primary: Double?

            let plan = res.plan_type ?? "unknown"
            metrics.append(UsageMetric(
                label: "套餐",
                percent: nil,
                detail: plan,
                resetsAt: nil
            ))

            // ChatGPT / OpenAI account windows (same backend as Codex for ChatGPT-linked accounts)
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
                if primary == nil { primary = p }
                metrics.append(UsageMetric(
                    label: "周额度",
                    percent: p,
                    detail: Formatters.countdown(to: OpenAIWham.resetDate(from: w)),
                    resetsAt: OpenAIWham.resetDate(from: w)
                ))
            }

            if let credits = res.credits {
                if credits.unlimited == true {
                    metrics.append(UsageMetric(label: "Credits", percent: nil, detail: "无限", resetsAt: nil))
                } else if let bal = credits.balance {
                    metrics.append(UsageMetric(label: "Credits", percent: nil, detail: String(format: "%.2f", bal), resetsAt: nil))
                } else if credits.has_credits == false {
                    metrics.append(UsageMetric(label: "Credits", percent: nil, detail: "无", resetsAt: nil))
                }
            }

            if let msg = res.promo?.message, !msg.isEmpty {
                metrics.append(UsageMetric(label: "提示", percent: nil, detail: String(msg.prefix(80)), resetsAt: nil))
            }

            if let p = primary {
                return .fromPercent(.gpt, percent: p, metrics: metrics)
            }
            return ProviderUsage(
                kind: .gpt,
                status: .ok,
                primaryPercent: nil,
                metrics: metrics,
                errorMessage: nil,
                updatedAt: Date()
            )
        } catch {
            return .unavailable(.gpt, message: error.localizedDescription)
        }
    }
}
