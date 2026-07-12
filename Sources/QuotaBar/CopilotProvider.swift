import Foundation

enum CopilotProvider {
    static func fetch() async -> ProviderUsage {
        do {
            let token = try readToken()
            let url = URL(string: "https://api.github.com/copilot_internal/user")!
            let (data, http) = try await HTTP.get(url: url, headers: [
                "Authorization": "Bearer \(token)",
                "Accept": "application/json",
                "Editor-Version": "vscode/1.96.0",
                "Editor-Plugin-Version": "copilot/1.270.0",
                "User-Agent": "GithubCopilot/1.270.0",
                "X-Github-Api-Version": "2025-05-01",
            ])
            _ = try HTTP.requireOK(data, http)

            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw QuotaError.decode("Copilot JSON 无效")
            }

            let plan = (obj["copilot_plan"] as? String)
                ?? (obj["access_type_sku"] as? String)
                ?? "copilot"
            let reset = ISO8601.parse(obj["quota_reset_date"] as? String)
                ?? parseDateOnly(obj["quota_reset_date"] as? String)

            var metrics: [UsageMetric] = [
                UsageMetric(label: "套餐", percent: nil, detail: shortPlan(plan), resetsAt: reset)
            ]
            var primary: Double?

            if let snaps = obj["quota_snapshots"] as? [String: Any] {
                let order = ["premium_interactions", "chat", "completions"]
                let labels = [
                    "premium_interactions": "Premium",
                    "chat": "Chat",
                    "completions": "补全",
                ]
                for key in order {
                    guard let snap = snaps[key] as? [String: Any] else { continue }
                    let unlimited = snap["unlimited"] as? Bool ?? false
                    if unlimited {
                        metrics.append(UsageMetric(label: labels[key] ?? key, percent: nil, detail: "无限", resetsAt: reset))
                        continue
                    }
                    let hasQuota = snap["has_quota"] as? Bool ?? true
                    if !hasQuota { continue }

                    let usedPercent: Double
                    if let rem = snap["percent_remaining"] as? Double {
                        usedPercent = max(0, min(100, 100 - rem))
                    } else if let ent = number(snap, "entitlement"), ent > 0,
                              let remaining = number(snap, "remaining") ?? number(snap, "quota_remaining") {
                        usedPercent = max(0, min(100, (ent - remaining) / ent * 100))
                    } else {
                        continue
                    }

                    if primary == nil { primary = usedPercent }
                    var detail = String(format: "%.0f%%", usedPercent)
                    if let ent = number(snap, "entitlement"), let rem = number(snap, "remaining") ?? number(snap, "quota_remaining") {
                        detail = String(format: "%.0f / %.0f", ent - rem, ent)
                    }
                    if let reset {
                        detail += " · \(Formatters.countdown(to: reset))"
                    }
                    metrics.append(UsageMetric(
                        label: labels[key] ?? key,
                        percent: usedPercent,
                        detail: detail,
                        resetsAt: reset
                    ))
                }
            }

            if let p = primary {
                return .fromPercent(.copilot, percent: p, metrics: metrics)
            }
            return ProviderUsage(
                kind: .copilot,
                status: .ok,
                primaryPercent: nil,
                metrics: metrics,
                errorMessage: nil,
                updatedAt: Date()
            )
        } catch {
            return .unavailable(.copilot, message: error.localizedDescription)
        }
    }

    private static func shortPlan(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "free_limited_copilot", with: "Free")
            .replacingOccurrences(of: "individual", with: "Pro")
            .replacingOccurrences(of: "_", with: " ")
    }

    private static func number(_ obj: [String: Any], _ key: String) -> Double? {
        if let n = obj[key] as? Double { return n }
        if let n = obj[key] as? Int { return Double(n) }
        if let n = obj[key] as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func parseDateOnly(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    private static func readToken() throws -> String {
        if let t = readGitHubInternetPassword() { return t }
        if let t = readAppsJSON() { return t }
        if let t = readHostsJSON() { return t }
        if let t = readGHConfig() { return t }
        throw QuotaError.missingCredentials("未找到 GitHub / Copilot 登录态（需要 gh 登录或 Copilot 插件）")
    }

    private static func readGitHubInternetPassword() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-internet-password", "-s", "github.com", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let raw, raw.count >= 20 else { return nil }
            return raw
        } catch {
            return nil
        }
    }

    private static func readAppsJSON() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/github-copilot/apps.json")
        return tokenFromCopilotJSON(path)
    }

    private static func readHostsJSON() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/github-copilot/hosts.json")
        return tokenFromCopilotJSON(path)
    }

    private static func tokenFromCopilotJSON(_ path: URL) -> String? {
        guard let data = try? Data(contentsOf: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for (_, value) in obj {
            if let dict = value as? [String: Any] {
                if let t = dict["oauth_token"] as? String { return t }
                if let t = dict["token"] as? String { return t }
            }
        }
        return nil
    }

    private static func readGHConfig() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/gh/hosts.yml")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("oauth_token:") {
                return s.replacingOccurrences(of: "oauth_token:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return nil
    }
}
