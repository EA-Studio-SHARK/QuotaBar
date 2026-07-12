import Foundation
import SQLite3
import CommonCrypto

enum GrokProvider {
    private struct AuthEntry: Decodable {
        let key: String
        let refresh_token: String?
        let expires_at: String?
        let email: String?
        let team_id: String?
        let oidc_issuer: String?
        let oidc_client_id: String?
    }

    private struct SubscriptionsResponse: Decodable {
        struct Sub: Decodable {
            let tier: String?
            let status: String?
            let billingPeriodEnd: String?
            let cancelAtPeriodEnd: Bool?
        }
        let subscriptions: [Sub]?
    }

    static func fetch() async -> ProviderUsage {
        do {
            var metrics: [UsageMetric] = []
            var primary: Double?

            // Prefer Chrome SSO for live rate-limit / consumer usage
            if let cookie = try? readChromeSSOCookieHeader() {
                if let sub = try? await fetchSubscriptionsWithCookie(cookie: cookie),
                   let first = sub.subscriptions?.first {
                    let tier = friendlyTier(first.tier)
                    let end = ISO8601.parse(first.billingPeriodEnd)
                    metrics.append(UsageMetric(
                        label: "订阅",
                        percent: nil,
                        detail: "\(tier) · 至 \(Formatters.relativeDate(end))"
                            + ((first.cancelAtPeriodEnd == true) ? "（期末取消）" : ""),
                        resetsAt: end
                    ))
                }

                if let fast = try? await fetchRateLimit(cookie: cookie, model: "fast") {
                    primary = fast.percent
                    metrics.insert(UsageMetric(
                        label: "Fast",
                        percent: fast.percent,
                        detail: fast.detail,
                        resetsAt: nil
                    ), at: 0)
                }
                if let expert = try? await fetchRateLimit(cookie: cookie, model: "expert") {
                    metrics.append(UsageMetric(
                        label: "Expert",
                        percent: expert.percent,
                        detail: expert.detail,
                        resetsAt: nil
                    ))
                    if primary == nil { primary = expert.percent }
                }
            }

            // Fallback: Grok Build OAuth subscriptions only
            if metrics.isEmpty, let oauth = try? readOAuthEntry() {
                if let sub = try? await fetchSubscriptions(token: oauth.key),
                   let first = sub.subscriptions?.first {
                    let tier = friendlyTier(first.tier)
                    let end = ISO8601.parse(first.billingPeriodEnd)
                    metrics.append(UsageMetric(
                        label: "订阅",
                        percent: nil,
                        detail: "\(tier) · 至 \(Formatters.relativeDate(end))",
                        resetsAt: end
                    ))
                }
            }

            if let p = primary {
                return .fromPercent(.grok, percent: p, metrics: metrics)
            }
            if !metrics.isEmpty {
                return ProviderUsage(
                    kind: .grok,
                    status: .ok,
                    primaryPercent: nil,
                    metrics: metrics,
                    errorMessage: "已拿到订阅信息；窗口用量需 Chrome 登录 grok.com",
                    updatedAt: Date()
                )
            }

            throw QuotaError.missingCredentials("未找到 Grok 登录态。请在 Chrome 登录 grok.com，或运行 grok login")
        } catch {
            return .unavailable(.grok, message: error.localizedDescription)
        }
    }

    private static func fetchSubscriptionsWithCookie(cookie: String) async throws -> SubscriptionsResponse {
        let url = URL(string: "https://grok.com/rest/subscriptions")!
        let (data, http) = try await HTTP.get(url: url, headers: [
            "Cookie": cookie,
            "Accept": "application/json",
            "User-Agent": "Mozilla/5.0 QuotaBar",
            "Origin": "https://grok.com",
            "Referer": "https://grok.com/",
        ])
        _ = try HTTP.requireOK(data, http)
        return try JSONDecoder().decode(SubscriptionsResponse.self, from: data)
    }

    private static func friendlyTier(_ raw: String?) -> String {
        guard let raw else { return "未知套餐" }
        if raw.contains("HEAVY") { return "SuperGrok Heavy" }
        if raw.contains("PRO") { return "SuperGrok / Pro" }
        if raw.contains("FREE") { return "Free" }
        return raw.replacingOccurrences(of: "SUBSCRIPTION_TIER_", with: "")
    }

    // MARK: - OAuth

    private static func readOAuthEntry() throws -> AuthEntry {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/auth.json")
        let data = try Data(contentsOf: path)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = obj.values.first,
              let entryData = try? JSONSerialization.data(withJSONObject: first),
              let entry = try? JSONDecoder().decode(AuthEntry.self, from: entryData)
        else {
            throw QuotaError.missingCredentials("无法解析 ~/.grok/auth.json")
        }
        return entry
    }

    private static func fetchSubscriptions(token: String) async throws -> SubscriptionsResponse {
        let url = URL(string: "https://grok.com/rest/subscriptions")!
        let (data, http) = try await HTTP.get(url: url, headers: [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
            "User-Agent": "QuotaBar/1.0",
        ])
        _ = try HTTP.requireOK(data, http)
        return try JSONDecoder().decode(SubscriptionsResponse.self, from: data)
    }

    // MARK: - Chrome SSO

    private static func readChromeSSOCookieHeader() throws -> String {
        let profiles = [
            "Default",
            "Profile 1",
            "Profile 2",
        ]
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome")

        var sso: String?
        var ssoRw: String?

        for profile in profiles {
            let dbPath = base.appendingPathComponent(profile).appendingPathComponent("Cookies").path
            guard FileManager.default.fileExists(atPath: dbPath) else { continue }
            let pairs = (try? decryptChromeCookies(dbPath: dbPath)) ?? [:]
            if sso == nil { sso = pairs["sso"] }
            if ssoRw == nil { ssoRw = pairs["sso-rw"] }
            if sso != nil { break }
        }

        guard let sso else {
            throw QuotaError.missingCredentials("Chrome 中无 grok.com SSO cookie")
        }
        var parts = ["sso=\(sso)"]
        if let ssoRw { parts.append("sso-rw=\(ssoRw)") }
        return parts.joined(separator: "; ")
    }

    private static func decryptChromeCookies(dbPath: String) throws -> [String: String] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-cookies-\(UUID().uuidString)")
        try FileManager.default.copyItem(atPath: dbPath, toPath: tmp.path)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var db: OpaquePointer?
        defer { if db != nil { sqlite3_close(db) } }
        guard sqlite3_open_v2(tmp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw QuotaError.other("无法打开 Chrome Cookies")
        }

        let sql = """
        SELECT name, encrypted_value FROM cookies
        WHERE host_key = '.grok.com' AND name IN ('sso', 'sso-rw');
        """
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw QuotaError.other("查询 Chrome cookies 失败")
        }

        let key = try chromeSafeStorageKey()
        var result: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 0))
            let blobLen = Int(sqlite3_column_bytes(stmt, 1))
            guard blobLen > 3, let bytes = sqlite3_column_blob(stmt, 1) else { continue }
            let data = Data(bytes: bytes, count: blobLen)
            if let plain = decryptChromeValue(data, key: key) {
                result[name] = plain
            }
        }
        return result
    }

    private static func chromeSafeStorageKey() throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-w", "-s", "Chrome Safe Storage", "-a", "Chrome"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let pw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw QuotaError.other("无法读取 Chrome Safe Storage（首次可能需允许钥匙串访问）")
        }

        // PBKDF2-SHA1, salt "saltysalt", 1003 iterations, 16 bytes
        let password = Data(pw.utf8)
        let salt = Data("saltysalt".utf8)
        var derived = Data(count: 16)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        password.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                        16
                    )
                }
            }
        }
        guard status == 0 else { throw QuotaError.other("派生 Chrome cookie 密钥失败") }
        return derived
    }

    private static func decryptChromeValue(_ encrypted: Data, key: Data) -> String? {
        guard encrypted.count > 3 else { return nil }
        let prefix = String(data: encrypted.prefix(3), encoding: .utf8) ?? ""
        guard prefix == "v10" || prefix == "v11" else { return nil }
        let ciphertext = encrypted.dropFirst(3)
        let iv = Data(repeating: 0x20, count: 16)

        var outLength = 0
        var out = Data(count: ciphertext.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        let status = out.withUnsafeMutableBytes { outBytes in
            ciphertext.withUnsafeBytes { cipherBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            cipherBytes.baseAddress, ciphertext.count,
                            outBytes.baseAddress, outCapacity,
                            &outLength
                        )
                    }
                }
            }
        }
        guard status == 0 else { return nil }
        out.count = outLength

        // Newer Chrome may prepend a hash; extract JWT if present
        if let idx = out.range(of: Data("eyJ".utf8)) {
            let jwtData = out[idx.lowerBound...]
            if let s = String(data: jwtData, encoding: .utf8) {
                let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_=")
                let cleaned = String(s.unicodeScalars.prefix(while: { allowed.contains($0) }))
                if cleaned.count > 20 { return cleaned }
            }
        }
        return String(data: out, encoding: .utf8)
    }

    private struct UsageHit {
        var percent: Double
        var detail: String
        var resetsAt: Date?
    }

    private static func fetchRateLimit(cookie: String, model: String) async throws -> UsageHit {
        let url = URL(string: "https://grok.com/rest/rate-limits")!
        let body = try JSONSerialization.data(withJSONObject: ["modelName": model])
        let (data, http) = try await HTTP.post(
            url: url,
            headers: [
                "Cookie": cookie,
                "Accept": "application/json",
                "Content-Type": "application/json",
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
                "Origin": "https://grok.com",
                "Referer": "https://grok.com/",
            ],
            body: body
        )
        _ = try HTTP.requireOK(data, http)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rem = number(obj, keys: ["remainingQueries", "remainingTokens", "remaining", "remainingRequests"]),
              let lim = number(obj, keys: ["totalQueries", "limitTokens", "limit", "limitRequests"]),
              lim > 0
        else {
            throw QuotaError.decode("rate-limits 无 remaining/total")
        }
        let used = max(0, lim - rem)
        let p = used / lim * 100
        let windowHours = number(obj, keys: ["windowSizeSeconds"]).map { Int($0 / 3600) }
        let detail: String
        if let h = windowHours, h > 0 {
            detail = String(format: "%.0f / %.0f · %dh 窗", used, lim, h)
        } else {
            detail = String(format: "%.0f / %.0f", used, lim)
        }
        return UsageHit(percent: p, detail: detail, resetsAt: nil)
    }

    private static func number(_ obj: [String: Any], keys: [String]) -> Double? {
        for k in keys {
            if let n = obj[k] as? Double { return n }
            if let n = obj[k] as? Int { return Double(n) }
            if let n = obj[k] as? NSNumber { return n.doubleValue }
        }
        return nil
    }
}
