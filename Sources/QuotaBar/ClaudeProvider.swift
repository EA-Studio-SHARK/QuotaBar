import Foundation

enum ClaudeProvider {
    private struct KeychainBlob: Decodable {
        let claudeAiOauth: OAuth
        struct OAuth: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresAt: Double?
            let subscriptionType: String?
        }
    }

    private struct UsageResponse: Decodable {
        struct Window: Decodable {
            let utilization: Double?
            let resets_at: String?
        }
        let five_hour: Window?
        let seven_day: Window?
        let seven_day_opus: Window?
        let seven_day_sonnet: Window?
    }

    static func fetch() async -> ProviderUsage {
        do {
            let token = try readAccessToken()
            let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
            let (data, http) = try await HTTP.get(url: url, headers: [
                "Authorization": "Bearer \(token)",
                "anthropic-beta": "oauth-2025-04-20",
                "User-Agent": "claude-code/2.0.32",
                "Accept": "application/json",
                "Content-Type": "application/json",
            ])
            _ = try HTTP.requireOK(data, http)
            let decoded = try JSONDecoder().decode(UsageResponse.self, from: data)

            var metrics: [UsageMetric] = []
            if let w = decoded.five_hour, let p = w.utilization {
                let reset = ISO8601.parse(w.resets_at)
                metrics.append(UsageMetric(
                    label: "5 小时",
                    percent: p,
                    detail: Formatters.countdown(to: reset),
                    resetsAt: reset
                ))
            }
            if let w = decoded.seven_day, let p = w.utilization {
                let reset = ISO8601.parse(w.resets_at)
                metrics.append(UsageMetric(
                    label: "7 天",
                    percent: p,
                    detail: Formatters.countdown(to: reset),
                    resetsAt: reset
                ))
            }
            if let w = decoded.seven_day_opus, let p = w.utilization {
                metrics.append(UsageMetric(
                    label: "Opus 周",
                    percent: p,
                    detail: Formatters.countdown(to: ISO8601.parse(w.resets_at)),
                    resetsAt: ISO8601.parse(w.resets_at)
                ))
            }
            if let w = decoded.seven_day_sonnet, let p = w.utilization {
                metrics.append(UsageMetric(
                    label: "Sonnet 周",
                    percent: p,
                    detail: Formatters.countdown(to: ISO8601.parse(w.resets_at)),
                    resetsAt: ISO8601.parse(w.resets_at)
                ))
            }

            let primary = metrics.first?.percent ?? 0
            return .fromPercent(.claude, percent: primary, metrics: metrics)
        } catch {
            return .unavailable(.claude, message: error.localizedDescription)
        }
    }

    private static func readAccessToken() throws -> String {
        if let token = readFromKeychain() { return token }
        if let token = readFromCredentialsFile() { return token }
        throw QuotaError.missingCredentials("未找到 Claude Code 登录态，请先运行 claude /login")
    }

    private static func readFromKeychain() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let blob = try? JSONDecoder().decode(KeychainBlob.self, from: Data(raw.utf8))
            else { return nil }
            return blob.claudeAiOauth.accessToken
        } catch {
            return nil
        }
    }

    private static func readFromCredentialsFile() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: path),
              let blob = try? JSONDecoder().decode(KeychainBlob.self, from: data)
        else { return nil }
        return blob.claudeAiOauth.accessToken
    }
}
