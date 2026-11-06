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

    struct BillingResponse: Decodable {
        struct Config: Decodable {
            struct Period: Decodable {
                let type: String?
                let start: String?
                let end: String?
            }
            struct ProductUsage: Decodable {
                let product: String?
                let usagePercent: Double?
            }
            let currentPeriod: Period?
            let billingPeriodEnd: String?
            let creditUsagePercent: Double?
            let productUsage: [ProductUsage]?
        }
        let config: Config?
    }

    static func fetch() async -> ProviderUsage {
        do {
            var metrics: [UsageMetric] = []
            var primary: Double?
            var usageError: String?

            // 1. Prefer Grok Build local OAuth (~/.grok/auth.json)
            if let oauth = try? readOAuthEntry() {
                do {
                    let billing = try await fetchBillingWithOAuth(token: oauth.key)
                    if let cfg = billing.config, let pct = cfg.creditUsagePercent {
                        primary = pct
                        let end = ISO8601.parse(cfg.currentPeriod?.end ?? cfg.billingPeriodEnd)
                        let isWeekly = (cfg.currentPeriod?.type ?? "").uppercased().contains("WEEK")
                        metrics.append(UsageMetric(
                            label: isWeekly ? "周限额" : "本周期",
                            percent: pct,
                            detail: Formatters.countdown(to: end),
                            resetsAt: end
                        ))
                    }
                } catch {
                    usageError = error.localizedDescription
                }

                if let sub = try? await fetchSubscriptions(token: oauth.key),
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
            }

            // 2. Fallback: Chrome SSO for consumer rate-limits if OAuth has no quota
            if primary == nil {
                do {
                    let cookie = try readChromeSSOCookieHeader()
                    if metrics.isEmpty,
                       let sub = try? await fetchSubscriptionsWithCookie(cookie: cookie),
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

                    do {
                        let fast = try await fetchRateLimit(cookie: cookie, model: "fast")
                        primary = fast.percent
                        metrics.insert(UsageMetric(
                            label: "Fast",
                            percent: fast.percent,
                            detail: fast.detail,
                            resetsAt: nil
                        ), at: 0)
                    } catch { usageError = error.localizedDescription }
                    do {
                        let expert = try await fetchRateLimit(cookie: cookie, model: "expert")
                        metrics.append(UsageMetric(
                            label: "Expert",
                            percent: expert.percent,
                            detail: expert.detail,
                            resetsAt: nil
                        ))
                        primary = max(primary ?? expert.percent, expert.percent)
                    } catch { usageError = error.localizedDescription }
                } catch {
                    if usageError == nil { usageError = error.localizedDescription }
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
                    errorMessage: usageError.map { "额度查询失败：\($0)" },
                    updatedAt: Date()
                )
            }

            throw QuotaError.missingCredentials(usageError ?? "未找到 Grok 登录态。请运行 grok login 或在 Chrome 登录 grok.com")
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

    private static func fetchBillingWithOAuth(token: String) async throws -> BillingResponse {
        let url = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
        let (data, http) = try await HTTP.get(url: url, headers: [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
            "x-grok-client-version": "1.0.70",
            "User-Agent": "grok-shell/1.0.70",
        ])
        _ = try HTTP.requireOK(data, http)
        return try JSONDecoder().decode(BillingResponse.self, from: data)
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
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome")
        let profiles = ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [])
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted()
        var sso: String?
        var ssoRw: String?
        var readError: Error?
        for profile in profiles {
            for relative in ["Cookies", "Network/Cookies"] {
                let dbPath = base.appendingPathComponent(profile).appendingPathComponent(relative).path
                guard FileManager.default.fileExists(atPath: dbPath) else { continue }
                let pairs: [String: String]
                do { pairs = try decryptChromeCookies(dbPath: dbPath) }
                catch { readError = error; continue }
                if let candidate = pairs["sso"], !candidate.isEmpty {
                    sso = candidate
                    ssoRw = pairs["sso-rw"]
                    break
                }
            }
            if sso != nil { break }
        }

        guard let sso else {
            if let readError { throw readError }
            throw QuotaError.missingCredentials("后台未能读取 Chrome 的 Grok 登录态，请检查登录状态和访问权限")
        }
        var parts = ["sso=\(sso)"]
        if let ssoRw { parts.append("sso-rw=\(ssoRw)") }
        return parts.joined(separator: "; ")
    }

    private static func decryptChromeCookies(dbPath: String) throws -> [String: String] {
        var db: OpaquePointer?
        defer { if db != nil { sqlite3_close(db) } }
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw QuotaError.other("无法打开 Chrome Cookies")
        }
        sqlite3_busy_timeout(db, 500)
        var versionStatement: OpaquePointer?
        var version = 0
        if sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = 'version'", -1, &versionStatement, nil) == SQLITE_OK,
           sqlite3_step(versionStatement) == SQLITE_ROW {
            version = Int(sqlite3_column_int(versionStatement, 0))
        }
        sqlite3_finalize(versionStatement)

        let sql = """
        SELECT name, encrypted_value, host_key, value FROM cookies
        WHERE host_key IN ('.grok.com', 'grok.com') AND name IN ('sso', 'sso-rw')
          AND (expires_utc = 0 OR expires_utc > (strftime('%s','now') + 11644473600) * 1000000);
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
            if let value = sqlite3_column_text(stmt, 3) {
                let plain = String(cString: value)
                if !plain.isEmpty { result[name] = plain; continue }
            }
            let host = String(cString: sqlite3_column_text(stmt, 2))
            let blobLen = Int(sqlite3_column_bytes(stmt, 1))
            guard blobLen > 3, let bytes = sqlite3_column_blob(stmt, 1) else { continue }
            let data = Data(bytes: bytes, count: blobLen)
            if let plain = decryptChromeValue(data, key: key, host: host, version: version) {
                result[name] = plain
            }
        }
        return result
    }

    private static func chromeSafeStorageKey() throws -> Data {
        let data = try LocalProcess.output("/usr/bin/security", ["find-generic-password", "-w", "-s", "Chrome Safe Storage", "-a", "Chrome"])
        guard let pw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw QuotaError.other("无法读取 Chrome Safe Storage")
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

    static func decryptChromeValue(_ encrypted: Data, key: Data, host: String, version: Int) -> String? {
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

        return cookieString(out, host: host, version: version)
    }

    static func cookieString(_ decrypted: Data, host: String, version: Int) -> String? {
        var value = decrypted
        if version >= 24 {
            let hostData = Data(host.utf8)
            var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            _ = hostData.withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(hostData.count), &hash) }
            guard value.starts(with: hash) else { return nil }
            value = Data(value.dropFirst(hash.count))
        }
        guard let text = String(data: value, encoding: .utf8), !text.isEmpty,
              !text.contains("\n"), !text.contains("\r") else { return nil }
        return text
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
