import Foundation

enum ProviderKind: String, CaseIterable, Identifiable {
    case claude = "Claude"
    case codex = "Codex"
    case gpt = "GPT"
    case cursor = "Cursor"
    case grok = "Grok"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "OpenAI Codex CLI"
        case .gpt: return "ChatGPT / OpenAI 账号"
        case .cursor: return "Cursor 会员"
        case .grok: return "本地 Grok / SuperGrok"
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

    static func loading(_ kind: ProviderKind) -> ProviderUsage {
        ProviderUsage(
            kind: kind,
            status: .loading,
            primaryPercent: nil,
            metrics: [],
            errorMessage: nil,
            updatedAt: Date()
        )
    }

    static func unavailable(_ kind: ProviderKind, message: String) -> ProviderUsage {
        ProviderUsage(
            kind: kind,
            status: .unavailable,
            primaryPercent: nil,
            metrics: [],
            errorMessage: message,
            updatedAt: Date()
        )
    }

    static func fromPercent(_ kind: ProviderKind, percent: Double, metrics: [UsageMetric]) -> ProviderUsage {
        let status: Status
        if percent >= 90 { status = .critical }
        else if percent >= 75 { status = .warning }
        else { status = .ok }
        return ProviderUsage(
            kind: kind,
            status: status,
            primaryPercent: percent,
            metrics: metrics,
            errorMessage: nil,
            updatedAt: Date()
        )
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
