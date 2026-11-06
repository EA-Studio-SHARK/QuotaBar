import Foundation

enum ProviderKind: String, CaseIterable, Identifiable, Codable {
    case claude = "Claude"
    case codex = "Codex"
    case copilot = "Copilot"
    case cursor = "Cursor"
    case grok = "Grok"
    case antigravity = "Antigravity"
    case muse = "Muse"

    var id: String { rawValue }

    var shortHint: String {
        switch self {
        case .claude: return "Code"
        case .codex: return "OpenAI"
        case .copilot: return "GitHub"
        case .cursor: return "IDE"
        case .grok: return "xAI"
        case .antigravity: return "Google"
        case .muse: return "Meta"
        }
    }
}

struct UsageMetric: Equatable, Codable {
    var label: String
    var percent: Double?
    var detail: String
    var resetsAt: Date?
}

struct ProviderUsage: Identifiable, Equatable, Codable {
    var id: ProviderKind { kind }
    var kind: ProviderKind
    var status: Status
    var primaryPercent: Double?
    var metrics: [UsageMetric]
    var errorMessage: String?
    var updatedAt: Date

    enum Status: String, Equatable, Codable {
        case ok
        case warning
        case critical
        case unavailable
        case loading
        case stale
    }

    var displayPercent: String {
        guard let p = primaryPercent else { return "—" }
        return String(format: "%.0f%%", p) + (status == .stale ? "（上次）" : "")
    }

    /// Secondary text: all rate windows when present (e.g. Claude 5h + weekly).
    var summaryLine: String {
        if status == .loading { return "…" }
        if status == .unavailable {
            return errorMessage ?? "未登录"
        }
        let windows = metrics.filter { $0.percent != nil && $0.label != "套餐" }
        if windows.count > 1 {
            return windows.map { m in
                let pct = String(format: "%.0f%%", m.percent ?? 0)
                if m.detail.isEmpty { return "\(m.label) \(pct)" }
                return "\(m.label) \(pct) · \(m.detail)"
            }.joined(separator: "  ")
        }
        if let first = windows.first {
            let bits = [first.label, first.detail].filter { !$0.isEmpty }
            return bits.joined(separator: " · ")
        }
        if let plan = metrics.first(where: { $0.label == "套餐" }) {
            return plan.detail
        }
        return metrics.first?.detail ?? ""
    }

    static func loading(_ kind: ProviderKind) -> ProviderUsage {
        ProviderUsage(kind: kind, status: .loading, primaryPercent: nil, metrics: [], errorMessage: nil, updatedAt: Date())
    }

    static func unavailable(_ kind: ProviderKind, message: String) -> ProviderUsage {
        ProviderUsage(kind: kind, status: .unavailable, primaryPercent: nil, metrics: [], errorMessage: message, updatedAt: Date())
    }

    func retaining(_ previous: ProviderUsage?) -> ProviderUsage {
        guard status == .unavailable, let previous, previous.kind == kind,
              previous.status != .unavailable, previous.status != .loading else { return self }
        var retained = previous
        retained.status = .stale
        retained.errorMessage = "更新失败，显示上次数据：" + (errorMessage ?? "请稍后刷新")
        return retained
    }

    static func fromPercent(_ kind: ProviderKind, percent: Double, metrics: [UsageMetric]) -> ProviderUsage {
        guard percent.isFinite else { return .unavailable(kind, message: "接口返回了无效的用量百分比") }
        let percent = max(0, percent)
        let status: Status
        if percent >= 90 { status = .critical }
        else if percent >= 75 { status = .warning }
        else { status = .ok }
        return ProviderUsage(kind: kind, status: status, primaryPercent: percent, metrics: metrics, errorMessage: nil, updatedAt: Date())
    }
}

struct UsageSnapshot: Equatable, Codable {
    var providers: [ProviderUsage]
    var fetchedAt: Date

    var worstPercent: Double? {
        providers.filter { $0.status != .stale }.compactMap(\.primaryPercent).max()
    }

    var menuTitle: String {
        if let worst = worstPercent {
            return String(format: "%.0f%%", worst)
        }
        return "AI"
    }
}

enum QuotaError: LocalizedError {
    case missingCredentials(String)
    case http(Int, String)
    case decode(String)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials(let s): return s
        case .http(let code, _):
            switch code {
            case 401: return "登录已失效，请在对应应用重新登录后刷新"
            case 403: return "用量接口拒绝访问（403），请检查账号权限或稍后重试"
            case 429: return "查询过于频繁（429），请稍后刷新"
            default: return "用量查询失败（HTTP \(code)）"
            }
        case .decode(let s): return s
        case .other(let s): return s
        }
    }
}
