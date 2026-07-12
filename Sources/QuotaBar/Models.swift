import Foundation

enum ProviderKind: String, CaseIterable, Identifiable {
    case claude = "Claude"
    case codex = "Codex"
    case copilot = "Copilot"
    case cursor = "Cursor"
    case grok = "Grok"

    var id: String { rawValue }

    var shortHint: String {
        switch self {
        case .claude: return "Code"
        case .codex: return "OpenAI"
        case .copilot: return "GitHub"
        case .cursor: return "IDE"
        case .grok: return "xAI"
        }
    }
}

struct UsageMetric: Equatable {
    var label: String
    var percent: Double?
    var detail: String
    var resetsAt: Date?
}

struct ProviderUsage: Identifiable, Equatable {
    var id: ProviderKind { kind }
    var kind: ProviderKind
    var status: Status
    var primaryPercent: Double?
    var metrics: [UsageMetric]
    var errorMessage: String?
    var updatedAt: Date

    enum Status: Equatable {
        case ok
        case warning
        case critical
        case unavailable
        case loading
    }

    var displayPercent: String {
        guard let p = primaryPercent else { return "—" }
        return String(format: "%.0f%%", p)
    }

    /// One-line secondary text for minimal UI.
    var summaryLine: String {
        if status == .loading { return "…" }
        if status == .unavailable {
            return errorMessage ?? "未登录"
        }
        if let first = metrics.first(where: { $0.percent != nil && $0.label != "套餐" }) {
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

    static func fromPercent(_ kind: ProviderKind, percent: Double, metrics: [UsageMetric]) -> ProviderUsage {
        let status: Status
        if percent >= 90 { status = .critical }
        else if percent >= 75 { status = .warning }
        else { status = .ok }
        return ProviderUsage(kind: kind, status: status, primaryPercent: percent, metrics: metrics, errorMessage: nil, updatedAt: Date())
    }
}

struct UsageSnapshot: Equatable {
    var providers: [ProviderUsage]
    var fetchedAt: Date

    var worstPercent: Double? {
        providers.compactMap(\.primaryPercent).max()
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
        case .http(let code, let body): return "HTTP \(code): \(body)"
        case .decode(let s): return s
        case .other(let s): return s
        }
    }
}
