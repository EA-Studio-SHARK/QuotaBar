import Foundation
import AppKit

enum ProviderDiscovery {
    static func installed() -> [ProviderKind] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return detected(
            home: home,
            exists: { FileManager.default.fileExists(atPath: $0) },
            hasApp: { bundleId in
                if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil { return true }
                for appName in appBundleNames(for: bundleId) {
                    if FileManager.default.fileExists(atPath: "/Applications/\(appName)")
                        || FileManager.default.fileExists(atPath: home.appendingPathComponent("Applications/\(appName)").path) {
                        return true
                    }
                }
                return false
            }
        )
    }

    private static func appBundleNames(for bundleId: String) -> [String] {
        switch bundleId {
        case "com.anthropic.claudefordesktop": return ["Claude.app"]
        case "com.openai.codex": return ["Codex.app"]
        case "com.openai.chat": return ["ChatGPT.app"]
        case "com.todesktop.230313mzl4w4u92": return ["Cursor.app"]
        case "com.anysphere.sand": return ["Grok.app", "Grok Build.app"]
        case "com.google.antigravity": return ["Antigravity.app"]
        case "com.meta.endo": return ["Muse.app"]
        default: return []
        }
    }

    static func detected(home: URL, exists: (String) -> Bool, hasApp: (String) -> Bool) -> [ProviderKind] {
        func local(_ relative: String) -> Bool { exists(home.appendingPathComponent(relative).path) }
        func cli(_ name: String) -> Bool {
            var dirs = [
                "/opt/homebrew/bin/",
                "/usr/local/bin/",
                home.appendingPathComponent(".local/bin").path + "/",
                home.appendingPathComponent(".grok/bin").path + "/",
                home.appendingPathComponent(".bun/bin").path + "/",
                home.appendingPathComponent(".volta/bin").path + "/",
                home.appendingPathComponent(".cargo/bin").path + "/",
                home.appendingPathComponent(".npm-global/bin").path + "/",
            ]
            let nvmNodes = home.appendingPathComponent(".nvm/versions/node")
            if exists(nvmNodes.path),
               let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmNodes.path) {
                for v in versions {
                    dirs.append(nvmNodes.appendingPathComponent("\(v)/bin").path + "/")
                }
            }
            return dirs.contains { exists($0 + name) }
        }
        return ProviderKind.allCases.filter { kind in
            switch kind {
            case .claude:
                return hasApp("com.anthropic.claudefordesktop") || cli("claude") || local(".claude")
            case .codex:
                return hasApp("com.openai.codex") || hasApp("com.openai.chat") || cli("codex")
            case .cursor:
                return hasApp("com.todesktop.230313mzl4w4u92") || cli("cursor")
            case .copilot:
                return local(".config/github-copilot/apps.json") || local(".config/github-copilot/hosts.json")
                    || copilotExtensionExists(home: home, exists: exists)
            case .grok:
                return hasApp("com.anysphere.sand") || cli("grok") || local(".grok/auth.json")
            case .antigravity:
                return hasApp("com.google.antigravity") || local(".gemini/jetski-standalone-oauth-token")
            case .muse:
                return hasApp("com.meta.endo")
            }
        }
    }

    private static func copilotExtensionExists(home: URL, exists: (String) -> Bool) -> Bool {
        for relative in [".vscode/extensions", ".cursor/extensions"] {
            let directory = home.appendingPathComponent(relative)
            guard exists(directory.path),
                  let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { continue }
            if names.contains(where: { $0.hasPrefix("github.copilot-") || $0.hasPrefix("github.copilot-chat-") }) { return true }
        }
        return false
    }
}

extension ProviderKind {
    func fetchUsage() async -> ProviderUsage {
        switch self {
        case .claude: return await ClaudeProvider.fetch()
        case .codex: return await CodexProvider.fetch()
        case .copilot: return await CopilotProvider.fetch()
        case .cursor: return await CursorProvider.fetch()
        case .grok: return await GrokProvider.fetch()
        case .antigravity: return await AntigravityProvider.fetch()
        case .muse:
            return .unavailable(self, message: "已检测到本机应用；暂未接入额度查询")
        }
    }
}
