import Foundation
import SQLite3

enum CursorProvider {
    private struct PeriodUsage: Decodable {
        struct PlanUsage: Decodable {
            let totalSpend: Int?
            let includedSpend: Int?
            let bonusSpend: Int?
            let limit: Int?
            let autoPercentUsed: Double?
            let apiPercentUsed: Double?
            let totalPercentUsed: Double?
        }
        let billingCycleStart: String?
        let billingCycleEnd: String?
        let planUsage: PlanUsage?
        let displayMessage: String?
        let autoModelSelectedDisplayMessage: String?
    }

    static func fetch() async -> ProviderUsage {
        do {
            let token = try readAccessToken()
            let url = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
            let (data, http) = try await HTTP.post(
                url: url,
                headers: [
                    "Authorization": "Bearer \(token)",
                    "Content-Type": "application/json",
                    "Connect-Protocol-Version": "1",
                    "User-Agent": "QuotaBar/1.0",
                    "Accept": "application/json",
                ],
                body: Data("{}".utf8)
            )
            _ = try HTTP.requireOK(data, http)
            let decoded = try JSONDecoder().decode(PeriodUsage.self, from: data)
            guard let plan = decoded.planUsage else {
                return .unavailable(.cursor, message: "Cursor 未返回 planUsage")
            }

            let percent = plan.totalPercentUsed
                ?? plan.autoPercentUsed
                ?? {
                    guard let limit = plan.limit, limit > 0, let used = plan.includedSpend else { return 0.0 }
                    return Double(used) / Double(limit) * 100.0
                }()

            let cycleEnd = parseMillis(decoded.billingCycleEnd)
            let limit = plan.limit ?? 0
            let included = plan.includedSpend ?? 0
            let bonus = plan.bonusSpend ?? 0
            let remainingIncluded = max(0, limit - included)

            var metrics: [UsageMetric] = [
                UsageMetric(
                    label: "本周期",
                    percent: percent,
                    detail: "已用 \(Formatters.moneyCents(included)) / \(Formatters.moneyCents(limit))",
                    resetsAt: cycleEnd
                )
            ]
            if bonus > 0 {
                metrics.append(UsageMetric(
                    label: "赠送",
                    percent: nil,
                    detail: Formatters.moneyCents(bonus),
                    resetsAt: nil
                ))
            }
            metrics.append(UsageMetric(
                label: "剩余 included",
                percent: nil,
                detail: Formatters.moneyCents(remainingIncluded) + (cycleEnd.map { " · 至 \(Formatters.relativeDate($0))" } ?? ""),
                resetsAt: cycleEnd
            ))
            if let auto = plan.autoPercentUsed {
                metrics.append(UsageMetric(label: "Auto", percent: auto, detail: String(format: "%.0f%%", auto), resetsAt: nil))
            }
            if let api = plan.apiPercentUsed {
                metrics.append(UsageMetric(label: "API", percent: api, detail: String(format: "%.0f%%", api), resetsAt: nil))
            }

            return .fromPercent(.cursor, percent: percent, metrics: metrics)
        } catch {
            return .unavailable(.cursor, message: error.localizedDescription)
        }
    }

    private static func parseMillis(_ s: String?) -> Date? {
        guard let s, let ms = Double(s) else { return nil }
        return Date(timeIntervalSince1970: ms / 1000.0)
    }

    private static func readAccessToken() throws -> String {
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            .path
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw QuotaError.missingCredentials("未找到 Cursor 本地数据库，请先登录 Cursor")
        }

        var db: OpaquePointer?
        defer { if db != nil { sqlite3_close(db) } }
        let uri = "file:\(dbPath)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            throw QuotaError.other("无法打开 Cursor state.vscdb")
        }

        let sql = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1;"
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw QuotaError.other("查询 Cursor token 失败")
        }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cStr = sqlite3_column_text(stmt, 0)
        else {
            throw QuotaError.missingCredentials("Cursor 未登录（无 accessToken）")
        }
        return String(cString: cStr)
    }
}
