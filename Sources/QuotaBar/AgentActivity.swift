import Foundation
import AppKit

/// Orbit：实时读取本机 AI 编码工具自己写的会话日志，得出"谁在哪个项目、对哪个文件做什么"。
/// 零配置：不装 hook，只读 Claude Code 和 Codex 本来就会写的 jsonl。

enum AgentKind: String, Equatable {
    case claude = "Claude Code"
    case codex = "Codex"
    case grok = "Grok Build"
    case antigravity = "Antigravity"

    var glyph: String {
        switch self {
        case .claude: return "C"
        case .codex: return "X"
        case .grok: return "G"
        case .antigravity: return "A"
        }
    }
}

enum AgentAction: Equatable {
    case read(String)
    case edit(String)
    case create(String)
    case run(String)
    case search(String)
    case browse(String?)
    case web(String)
    case think
    case done
    case other(String)

    var verb: String {
        switch self {
        case .read: return "读取"
        case .edit: return "编辑"
        case .create: return "新建"
        case .run: return "运行"
        case .search: return "搜索"
        case .browse: return "操控浏览器"
        case .web: return "查网页"
        case .think: return "思考中"
        case .done: return "已完成"
        case .other(let name): return name
        }
    }

    var symbol: String {
        switch self {
        case .read: return "eye"
        case .edit: return "pencil"
        case .create: return "doc.badge.plus"
        case .run: return "terminal"
        case .search: return "magnifyingglass"
        case .browse: return "globe"
        case .web: return "network"
        case .think: return "ellipsis"
        case .done: return "checkmark"
        case .other: return "wrench.and.screwdriver"
        }
    }

    var isWriting: Bool {
        switch self {
        case .edit, .create: return true
        default: return false
        }
    }

    var filePath: String? {
        switch self {
        case .read(let p), .edit(let p), .create(let p): return p
        default: return nil
        }
    }
}

/// AI 自己列的计划里的一步。status：pending / in_progress / completed
struct PlanStep: Equatable {
    var text: String
    var status: String
    var id: String? = nil
}

struct PlanPatch: Equatable {
    var id: String
    var text: String?
    var status: String
}

enum PlanUpdate: Equatable {
    case set([PlanStep])
    case merge([PlanPatch])
    case advance
    case mark(done: [Int], start: Int?)   // 1 开始的序号
    case finish
}

struct AgentSession: Identifiable, Equatable {
    let id: String          // 日志文件路径
    let kind: AgentKind
    var sessionId: String
    var cwd: String?
    var action: AgentAction
    var lastURL: String?
    var updatedAt: Date
    /// 工具已发出、结果还没回来（比如长时间编译），这段时间也算在干活。
    var pending = false
    /// 最近改过的文件，新的在前，最多 12 个。动作一闪而过，这里留住"它在改哪个文件"。
    var recentEdits: [String] = []
    var editCounts: [String: Int] = [:]
    var recentReads: [String] = []
    var lastRead: String? { recentReads.first }
    var editedAt: Date?
    var browsedAt: Date?
    var plan: [PlanStep] = []
    /// AI 最近说的一句话（截短），小窗里当气泡。
    var say: String?
    var sayAt: Date?
    /// 这次改动新写了几行。
    var lines: Int?
    /// 每来一个新动作加 1，小窗靠它知道该"蹦"了。
    var seq = 0
    /// 实时窗口的事件流（最近 40 条）和下一个编号。
    var live: [LiveEvent] = []
    var liveNext = 0
    /// 计划换了一版就加 1；这次指令开始时的事件编号（计划列出来之前的动作也归到新计划第 1 步）
    var planGen = 0
    var promptLiveStart = 0
    var currentStep: Int {
        plan.firstIndex { $0.status == "in_progress" } ?? plan.firstIndex { $0.status == "pending" } ?? max(0, plan.count - 1)
    }
    /// 用户最近一次下的指令（截短），当这次任务的主题。
    var prompt: String?
    /// 用户下这次指令的时间（算「已经几分钟」）
    var promptAt: Date?
    /// AI 停下来等用户回答的那句话（收尾提问、AskUserQuestion、最后一句是问句）；用户回了或它又动起来就清掉。
    var waiting: String?

    /// 45 秒内有新动作且没结束，或有工具还在跑（最长 10 分钟），算"正在干活"。
    func isActive(now: Date = Date()) -> Bool {
        guard action != .done else { return false }
        return now.timeIntervalSince(updatedAt) < (pending ? 600 : 45)
    }

    var projectName: String {
        guard let cwd, !cwd.isEmpty else { return "未知项目" }
        if cwd == NSHomeDirectory() { return "~" }
        return (cwd as NSString).lastPathComponent
    }

    /// 相对路径按项目目录补全，才能点开。
    func absolute(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        if path.hasPrefix("~/") { return NSHomeDirectory() + path.dropFirst(1) }
        guard let cwd else { return path }
        return (cwd as NSString).appendingPathComponent(path)
    }

    /// 文件拆成"所在文件夹 / 文件名"，文件夹相对项目根目录。
    func parts(_ path: String) -> (folder: String, name: String) {
        let full = absolute(path)
        var rel = full
        if let cwd, full.hasPrefix(cwd + "/") { rel = String(full.dropFirst(cwd.count + 1)) }
        else if full.hasPrefix(NSHomeDirectory()) { rel = "~" + full.dropFirst(NSHomeDirectory().count) }
        let name = (rel as NSString).lastPathComponent
        let folder = (rel as NSString).deletingLastPathComponent
        return (folder.isEmpty ? "" : folder + "/", name)
    }

    var fileParts: (folder: String, name: String)? { action.filePath.map(parts) }

    /// 盯住的文件：最近改过的优先，还没改过就是最近在看的。
    var focusFile: String? { recentEdits.first ?? lastRead }
    var focusIsEdit: Bool { !recentEdits.isEmpty }
    /// 当前这一步就是在动盯住的那个文件（这时不用再单独写一行"现在"）。
    var actionOnFocus: Bool { action.filePath.map(absolute) == focusFile.map(absolute) }

    /// 最近 10 分钟内操控过浏览器，就一直显示那个页面。
    var page: String? {
        guard let lastURL, let browsedAt, updatedAt.timeIntervalSince(browsedAt) < 600 else { return nil }
        return Self.shortURL(lastURL)
    }

    /// AI 在项目里 `cd 子目录` 后，项目还是原来那个；退到上级就以上级为准；去了不相干的目录才算换项目。
    static func projectRoot(current: String?, new: String, home: String = NSHomeDirectory()) -> String {
        guard let current, current != home else { return new }
        if new == home || new == current || new.hasPrefix(current + "/") { return current }
        return new
    }

    mutating func apply(_ update: PlanUpdate) {
        switch update {
        case .set(let steps):
            if steps.map(\.text) != plan.map(\.text) {
                planGen += 1
                for i in live.indices where live[i].id > promptLiveStart { live[i].gen = planGen; live[i].step = 0; live[i].version += 1 }
            }
            plan = steps
        case .merge(let patches):
            for p in patches {
                if let i = plan.firstIndex(where: { $0.id == p.id }) {
                    plan[i].status = p.status
                    if let t = p.text, !t.isEmpty { plan[i].text = t }
                } else if let idx = Int(p.id), plan.indices.contains(idx - 1) {
                    plan[idx - 1].status = p.status
                    if let t = p.text, !t.isEmpty { plan[idx - 1].text = t }
                } else if let t = p.text, !t.isEmpty {
                    plan.append(PlanStep(text: t, status: p.status, id: p.id))
                }
            }
        case .advance:
            if let i = plan.firstIndex(where: { $0.status == "in_progress" }) { plan[i].status = "completed" }
            if let j = plan.firstIndex(where: { $0.status == "pending" }) { plan[j].status = "in_progress" }
        case .mark(let done, let start):
            for n in done where plan.indices.contains(n - 1) { plan[n - 1].status = "completed" }
            if let n = start, plan.indices.contains(n - 1) { plan[n - 1].status = "in_progress" }
        case .finish:
            for i in plan.indices { plan[i].status = "completed" }
        }
    }

    /// 一句话说现在这一步在干嘛。
    var stepText: String {
        switch action {
        case .read(let p): return "在看 " + parts(p).name
        case .edit(let p): return "在改 " + parts(p).name
        case .create(let p): return "新建 " + parts(p).name
        case .run(let cmd): return "运行 " + Self.meaningfulCommand(cmd)
        case .search(let q): return "搜索 " + Self.meaningfulCommand(q)
        case .web(let q): return "查网页 " + String(q.prefix(60))
        case .browse: return "操控浏览器"
        case .think, .done, .other: return action.verb
        }
    }

    var targetText: String? {
        switch action {
        case .run(let cmd): return Self.meaningfulCommand(cmd)
        case .search(let q), .web(let q): return String(q.prefix(80))
        case .browse(let url): return (url ?? lastURL).map(Self.shortURL)
        default: return nil
        }
    }

    /// 去掉开头的 `export ...`、`cd 某目录 &&`、管道后半段和输出重定向，只留真正在跑的命令。
    static func meaningfulCommand(_ cmd: String) -> String {
        let nonSetupLines = cmd.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { line in
            !line.isEmpty && !line.hasPrefix("export ") && !line.hasPrefix("set ") && !line.hasPrefix("#")
                && line.range(of: #"^cd\s+("[^"]*"|'[^']*'|\S+)(\s+2>/dev/null)?\s*$"#, options: .regularExpression) == nil
        }
        var s = nonSetupLines.first ?? cmd.components(separatedBy: .newlines).first ?? cmd
        let cdPrefix = #"^\s*(?:export\s+[^;&]+\s*(?:&&|;)\s*|cd\s+("[^"]*"|'[^']*'|\S+)(\s+2>/dev/null)?\s*(?:&&|;)\s*)+"#
        while let r = s.range(of: cdPrefix, options: .regularExpression) { s.removeSubrange(r) }
        if let r = s.range(of: " | ") { s = String(s[..<r.lowerBound]) }
        s = s.replacingOccurrences(of: #"\s+\d?>\s*(&\d|/dev/null)"#, with: "", options: .regularExpression)
        return String(s.trimmingCharacters(in: .whitespaces).prefix(200))
    }

    static func shortURL(_ s: String) -> String {
        guard let u = URL(string: s), let host = u.host else { return s }
        let path = u.path == "/" ? "" : u.path
        return host.replacingOccurrences(of: "www.", with: "") + path
    }
}

// MARK: - 解析

enum ActivityParser {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func date(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }

    struct Event {
        var cwd: String?
        var action: AgentAction?
        var url: String?
        var date: Date?
        /// true：工具发出待返回；false：工具结果已返回；nil：无关
        var pending: Bool?
        var plan: PlanUpdate?
        var lines: Int?
        var say: String?
        var piece: LivePiece?
        var toolId: String?
        var results: [ToolResult] = []
        var prompt: String?
        var ask: String?
    }

    /// 计划清单：Claude 的 TodoWrite / update_plan / wrap_up，Codex 的 update_plan，Grok 的 todo_write。
    static func planUpdate(_ name: String, _ input: [String: Any]) -> PlanUpdate? {
        func steps(_ list: [[String: Any]], text: String) -> [PlanStep] {
            list.compactMap { item in
                (item[text] as? String).map {
                    PlanStep(text: $0, status: item["status"] as? String ?? "pending",
                             id: (item["id"] as? String) ?? (item["id"] as? NSNumber)?.stringValue)
                }
            }
        }
        switch name {
        case "TodoWrite":
            return (input["todos"] as? [[String: Any]]).map { .set(steps($0, text: "content")) }
        case "todo_write":
            guard let list = input["todos"] as? [[String: Any]] else { return nil }
            if input["merge"] as? Bool == true {
                let patches = list.compactMap { item -> PlanPatch? in
                    guard let id = (item["id"] as? String) ?? (item["id"] as? NSNumber)?.stringValue,
                          let status = item["status"] as? String else { return nil }
                    return PlanPatch(id: id, text: item["content"] as? String, status: status)
                }
                return patches.isEmpty ? nil : .merge(patches)
            }
            let s = steps(list, text: "content")
            return s.isEmpty ? nil : .set(s)
        case "mcp__ccd_turn__update_plan":
            if let items = input["items"] as? [[String: Any]] { return .set(steps(items, text: "content")) }
            if input["advance"] as? Bool == true { return .advance }
            let done = (input["done"] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
            let start = (input["start"] as? NSNumber)?.intValue
            return done.isEmpty && start == nil ? nil : .mark(done: done, start: start)
        case "mcp__ccd_turn__wrap_up":
            return .finish
        case "update_plan":
            return (input["plan"] as? [[String: Any]]).map { .set(steps($0, text: "step")) }
        default:
            return nil
        }
    }

    /// 这次改动新写了几行。
    static func editLines(_ name: String, _ input: [String: Any]) -> Int? {
        func count(_ s: Any?) -> Int { (s as? String).map { $0.components(separatedBy: "\n").count } ?? 0 }
        switch name {
        case "Edit", "search_replace": return count(input["new_string"])
        case "Write", "write": return count(input["content"])
        case "edit_file", "replace_file_content":
            return count(input["Replacement"] ?? input["ReplacementContent"] ?? input["new_string"])
        case "write_file", "write_to_file":
            return count(input["Content"] ?? input["CodeContent"] ?? input["content"])
        case "MultiEdit": return (input["edits"] as? [[String: Any]])?.reduce(0) { $0 + count($1["new_string"]) }
        default: return nil
        }
    }

    static func patchLines(_ patch: String) -> Int? {
        let text = patch.replacingOccurrences(of: "\\n", with: "\n")
        let n = text.components(separatedBy: "\n").filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
        return n > 0 ? n : nil
    }

    /// 用户指令当主题：系统附加的内容（<system-reminder> 之类）不算，取第一句，最多 40 个宽度。
    static func promptTitle(_ text: String) -> String? {
        if text.hasPrefix("This session is being continued from a previous conversation")
            && !text.contains("<user_query>") && !text.contains("<USER_REQUEST>") {
            return nil
        }
        let extracted = LiveParse.lastGroups(#"<(?:user_query|USER_REQUEST)>\s*([\s\S]*?)\s*</(?:user_query|USER_REQUEST)>"#, in: text)?.first ?? text
        let clean = extracted.replacingOccurrences(of: #"<[A-Za-z_-]+>[\s\S]*?</[A-Za-z_-]+>"#, with: "", options: .regularExpression)
        guard let first = clean.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty && !$0.hasPrefix("<") }) else { return nil }
        var width = 0, out = ""
        for ch in first {
            width += ch.unicodeScalars.first.map { $0.value > 0x2E80 } == true ? 2 : 1
            if width > 40 { return out + "…" }
            out.append(ch)
        }
        return out.isEmpty ? nil : out
    }

    /// AI 说的话取第一句，去掉 Markdown 符号，太长就截断。
    static func shortSay(_ text: String) -> String? {
        guard var line = text.components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        line = line.replacingOccurrences(of: #"[*#`>_]|\[|\]\([^)]*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if let r = line.range(of: #"[。！？!?：:]"#, options: .regularExpression) { line = String(line[..<r.lowerBound]) }
        guard !line.isEmpty else { return nil }
        // 气泡宽度有限：中文按 2 个宽度算，最多 34
        var width = 0, out = ""
        for ch in line {
            width += ch.unicodeScalars.first.map { $0.value > 0x2E80 } == true ? 2 : 1
            if width > 34 { return out + "…" }
            out.append(ch)
        }
        return out
    }

    /// AI 主动问用户：Claude 桌面版收尾时的提问（wrap_up 的 ask）、AskUserQuestion 的第一个问题。
    static func askText(_ name: String, _ input: [String: Any]) -> String? {
        switch name {
        case "mcp__ccd_turn__wrap_up": return (input["ask"] as? String).flatMap { clip($0, 60) }
        case "AskUserQuestion", "ask_question", "ask_user_question":
            return ((input["questions"] as? [[String: Any]])?.first?["question"] as? String).flatMap { clip($0, 60) }
        default: return nil
        }
    }

    /// 这一轮最后一句是问句，就当在等用户回答。
    static func trailingQuestion(_ text: String) -> String? {
        guard let last = text.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespaces) })
            .last(where: { !$0.isEmpty }), last.hasSuffix("？") || last.hasSuffix("?") else { return nil }
        let clean = last.replacingOccurrences(of: #"[*#`>_]|\[|\]\([^)]*\)"#, with: "", options: .regularExpression)
        return clip(clean.trimmingCharacters(in: .whitespaces), 60)
    }

    /// 按显示宽度截断（中文算 2）。
    static func clip(_ text: String, _ limit: Int) -> String? {
        let line = text.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return nil }
        var width = 0, out = ""
        for ch in line {
            width += ch.unicodeScalars.first.map { $0.value > 0x2E80 } == true ? 2 : 1
            if width > limit { return out + "…" }
            out.append(ch)
        }
        return out
    }

    // Claude Code: ~/.claude/projects/<项目>/<会话>.jsonl
    static func claude(_ obj: [String: Any]) -> Event? {
        guard let type = obj["type"] as? String, type == "assistant" || type == "user" else { return nil }
        var ev = Event(cwd: obj["cwd"] as? String, date: date(obj["timestamp"]))
        guard let message = obj["message"] as? [String: Any] else { return ev }

        if type == "user" {
            // 用户发来新指令 → AI 开始干活；tool_result 不算
            if let text = message["content"] as? String { ev.action = .think; ev.prompt = promptTitle(text) }
            else if let parts = message["content"] as? [[String: Any]] {
                if parts.contains(where: { $0["type"] as? String == "tool_result" }) {
                    ev.pending = false
                    ev.results = LiveParse.results(parts)
                } else if let t = parts.first(where: { $0["type"] as? String == "text" })?["text"] as? String {
                    ev.action = .think; ev.prompt = promptTitle(t)
                }
            }
            return ev
        }

        let parts = message["content"] as? [[String: Any]] ?? []
        for part in parts {
            switch part["type"] as? String {
            case "tool_use":
                let name = part["name"] as? String ?? ""
                let input = part["input"] as? [String: Any] ?? [:]
                if let p = planUpdate(name, input) { ev.plan = p }
                if let q = askText(name, input) { ev.ask = q }
                if let n = editLines(name, input) { ev.lines = n }
                if let mapped = claudeTool(name, input) {
                    ev.action = mapped.action
                    ev.pending = mapped.action != .done
                    if let url = mapped.url { ev.url = url }
                    ev.piece = LiveParse.piece(name, input, action: mapped.action)
                    ev.toolId = part["id"] as? String
                }
            case "thinking":
                if ev.action == nil { ev.action = .think }
            case "text":
                if let t = part["text"] as? String, let s = shortSay(t) { ev.say = s }
                if message["stop_reason"] as? String == "end_turn" {
                    ev.action = .done; ev.piece = LivePiece(kind: "done")
                    if let t = part["text"] as? String, let q = trailingQuestion(t) { ev.ask = q }
                }
            default:
                break
            }
        }
        return ev
    }

    static func claudeTool(_ name: String, _ input: [String: Any]) -> (action: AgentAction, url: String?)? {
        let path = (input["file_path"] ?? input["notebook_path"] ?? input["path"]) as? String
        switch name {
        case "Read": return path.map { (.read($0), nil) }
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return path.map { (.edit($0), nil) }
        case "Bash": return (command(input["command"] as? String ?? "命令", workdir: nil), nil)
        case "Grep", "Glob": return (.search(input["pattern"] as? String ?? ""), nil)
        case "WebFetch": return (.web(input["url"] as? String ?? ""), nil)
        case "WebSearch": return (.web(input["query"] as? String ?? ""), nil)
        case "Agent", "Task": return (.other("派出子任务"), nil)
        case "TodoWrite", "ToolSearch", "mcp__ccd_turn__update_plan": return nil
        case "mcp__ccd_turn__wrap_up": return (.done, nil)
        default: break
        }
        let lower = name.lowercased()
        if lower.contains("browser") || lower.contains("chrome") || lower.hasSuffix("__computer") || lower.hasSuffix("__navigate") {
            let url = (input["url"] as? String) ?? firstURL(in: input)
            return (.browse(url), url)
        }
        let short = name.components(separatedBy: "__").last ?? name
        return (.other(short), nil)
    }

    // Codex: ~/.codex/sessions/年/月/日/rollout-*.jsonl
    static func codex(_ obj: [String: Any]) -> Event? {
        let type = obj["type"] as? String
        let payload = obj["payload"] as? [String: Any] ?? [:]
        var ev = Event(date: date(obj["timestamp"]))
        switch type {
        case "session_meta", "turn_context":
            ev.cwd = payload["cwd"] as? String
            return ev
        case "event_msg":
            switch payload["type"] as? String {
            case "task_complete": ev.action = .done
            case "task_started", "user_message": ev.action = .think
            case "agent_message": ev.say = (payload["message"] as? String).flatMap(shortSay)
            default: return nil
            }
            return ev
        case "response_item":
            break
        default:
            return nil
        }
        let name = payload["name"] as? String ?? ""
        let input = (payload["input"] as? String) ?? (payload["arguments"] as? String) ?? ""
        switch payload["type"] as? String {
        case "function_call", "custom_tool_call":
            if name == "update_plan" {
                let args = (try? JSONSerialization.jsonObject(with: Data(input.utf8))) as? [String: Any] ?? [:]
                ev.plan = planUpdate(name, args)
                return ev
            }
            if let (action, cwd, url) = codexTool(name, input) {
                ev.action = action; ev.url = url; ev.pending = true
                if let cwd { ev.cwd = cwd }
                if action.isWriting { ev.lines = patchLines(input) }
            }
        case "function_call_output", "custom_tool_call_output":
            ev.pending = false
        case "web_search_call":
            ev.action = .web("搜索网页")
        case "reasoning":
            ev.action = .think
        default:
            return nil
        }
        return ev
    }

    static func codexTool(_ name: String, _ input: String) -> (AgentAction, String?, String?)? {
        switch name {
        case "apply_patch":
            return patchFile(input).map { ($0, nil, nil) }
        case "exec_command", "shell":
            let obj = (try? JSONSerialization.jsonObject(with: Data(input.utf8))) as? [String: Any] ?? [:]
            let cmd = (obj["cmd"] as? String) ?? (obj["command"] as? [String])?.joined(separator: " ") ?? ""
            let workdir = obj["workdir"] as? String
            return (command(cmd, workdir: workdir), workdir, nil)
        case "view_image":
            let obj = (try? JSONSerialization.jsonObject(with: Data(input.utf8))) as? [String: Any] ?? [:]
            return (obj["path"] as? String).map { (.read($0), nil, nil) }
        case "js":
            let url = firstURL(in: input)
            return (.browse(url), nil, url)
        case "exec":
            if input.contains("*** Begin Patch") { return patchFile(input).map { ($0, nil, nil) } }
            if let cmd = capture(#"tools\.exec_command\(\{\s*cmd:\s*"((?:[^"\\]|\\.)*)""#, in: input) {
                let workdir = capture(#""?workdir"?\s*:\s*"((?:[^"\\]|\\.)*)""#, in: input).map(unescape)
                return (command(unescape(cmd), workdir: workdir), workdir, nil)
            }
            if input.contains("tools.web__run") { return (.web("搜索网页"), nil, nil) }
            if input.contains("tools.view_image"), let p = capture(#"(/[^"\s]+\.(?:png|jpe?g|gif|webp|svg))"#, in: input) {
                return (.read(p), nil, nil)
            }
            if input.contains("tools.write_stdin") { return nil }
            return (.other("执行脚本"), nil, nil)
        case "wait", "sleep", "write_stdin", "request_user_input_async":
            return nil
        default:
            return (.other(name), nil, nil)
        }
    }

    /// 补丁里第一个被改的文件。
    static func patchFile(_ patch: String) -> AgentAction? {
        guard let m = captureGroups(#"\*\*\* (Update|Add|Delete) File: (.+?)(?:\\n|\n|"|$)"#, in: patch), m.count == 2 else { return nil }
        return m[0] == "Add" ? .create(m[1]) : .edit(m[1])
    }

    /// 把 shell 命令归类：看文件 → 读取；rg/grep/find → 搜索；其余 → 运行。
    static func command(_ cmd: String, workdir: String?) -> AgentAction {
        let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        // `cd 目录 && sed -n 1,50p 文件 | grep …` 也算在看那个文件
        let workdir = capture(#"^\s*cd\s+["']?(/[^"'&;]+?)["']?\s*(?:&&|;)"#, in: trimmed) ?? workdir
        let tokens = AgentSession.meaningfulCommand(trimmed).split(separator: " ").map(String.init)
        guard let head = tokens.first.map({ ($0 as NSString).lastPathComponent }) else { return .run(trimmed) }
        if ["sed", "cat", "head", "tail", "nl", "less", "bat"].contains(head) {
            if let file = tokens.dropFirst().last(where: { !$0.hasPrefix("-") && ($0.contains("/") || $0.contains(".")) && !$0.contains(",") }) {
                let clean = file.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                let full = clean.hasPrefix("/") ? clean : workdir.map { ($0 as NSString).appendingPathComponent(clean) } ?? clean
                return .read(full)
            }
        }
        if ["rg", "grep", "find", "fd", "ls"].contains(head) { return .search(trimmed) }
        return .run(trimmed)
    }

    static func firstURL(in any: Any) -> String? {
        let text: String
        if let s = any as? String { text = s }
        else if let d = try? JSONSerialization.data(withJSONObject: any), let s = String(data: d, encoding: .utf8) { text = s }
        else { return nil }
        return capture(#"(https?://[^\s"'\\)]+)"#, in: text.replacingOccurrences(of: "\\/", with: "/"))
    }

    static func capture(_ pattern: String, in text: String) -> String? {
        captureGroups(pattern, in: text)?.first
    }

    static func captureGroups(_ pattern: String, in text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<m.numberOfRanges).compactMap { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) }
        }
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    static func events(_ obj: [String: Any], kind: AgentKind) -> [Event] {
        switch kind {
        case .claude: return claude(obj).map { [$0] } ?? []
        case .codex: return codex(obj).map { [$0] } ?? []
        case .grok: return grok(obj)
        case .antigravity: return antigravity(obj)
        }
    }

    // Grok Build: ~/.grok/sessions/<项目>/<会话>/chat_history.jsonl
    static func grok(_ obj: [String: Any]) -> [Event] {
        guard let type = obj["type"] as? String else { return [] }
        let ts = date(obj["timestamp"] ?? obj["ts"])
        switch type {
        case "user":
            var ev = Event(action: .think, date: ts)
            if let text = obj["content"] as? String {
                ev.prompt = promptTitle(text)
            } else if let parts = obj["content"] as? [[String: Any]],
                      let t = parts.first(where: { $0["type"] as? String == "text" })?["text"] as? String {
                ev.prompt = promptTitle(t)
            }
            return [ev]
        case "reasoning":
            return [Event(action: .think, date: ts)]
        case "tool_result":
            let id = obj["tool_call_id"] as? String ?? ""
            let text = obj["content"] as? String ?? ""
            let isErr = obj["is_error"] as? Bool == true
            var ev = Event(date: ts, pending: false)
            if !id.isEmpty { ev.results = [ToolResult(toolId: id, text: text, image: nil, isError: isErr)] }
            return [ev]
        case "assistant":
            let content = obj["content"] as? String ?? ""
            let say = content.isEmpty ? nil : shortSay(content)
            let calls = obj["tool_calls"] as? [[String: Any]] ?? []
            if calls.isEmpty {
                var ev = Event(action: .done, date: ts, pending: false, say: say, piece: LivePiece(kind: "done"))
                if !content.isEmpty, let q = trailingQuestion(content) { ev.ask = q }
                return [ev]
            }
            var out: [Event] = []
            for (idx, tc) in calls.enumerated() {
                let name = tc["name"] as? String ?? ""
                let argsStr = tc["arguments"] as? String ?? "{}"
                let input = (try? JSONSerialization.jsonObject(with: Data(argsStr.utf8))) as? [String: Any] ?? [:]
                var ev = Event(date: ts, say: idx == 0 ? say : nil)
                if let p = planUpdate(name, input) { ev.plan = p }
                if let q = askText(name, input) { ev.ask = q }
                if let n = editLines(name, input) { ev.lines = n }
                if let mapped = grokTool(name, input) {
                    ev.action = mapped.action
                    ev.pending = mapped.action != .done
                    if let cwd = mapped.cwd { ev.cwd = cwd }
                    if let url = mapped.url { ev.url = url }
                    ev.piece = LiveParse.piece(name, input, action: mapped.action)
                    ev.toolId = tc["id"] as? String
                }
                if ev.action != nil || ev.plan != nil || ev.ask != nil || ev.say != nil {
                    out.append(ev)
                }
            }
            return out
        default:
            return []
        }
    }

    static func grokTool(_ name: String, _ input: [String: Any]) -> (action: AgentAction, cwd: String?, url: String?)? {
        let path = (input["file_path"] ?? input["target_file"] ?? input["path"]) as? String
        let inferredCwd = path.flatMap(inferProjectRoot(fromPath:))
            ?? (input["target_directory"] as? String).flatMap(inferProjectRoot(fromPath:))
        switch name {
        case "read_file":
            return path.map { (.read($0), inferredCwd, nil) }
        case "search_replace", "edit_file", "MultiEdit":
            return path.map { (.edit($0), inferredCwd, nil) }
        case "write", "write_file":
            return path.map { (.create($0), inferredCwd, nil) }
        case "run_terminal_command", "bash":
            let cmd = input["command"] as? String ?? "命令"
            let cdDir = capture(#"cd\s+["']?(/[^"'&;\n]+?)["']?\s*(?:&&|;|\n)"#, in: cmd)
            let cwd = cdDir.flatMap(inferProjectRoot(fromPath:)) ?? inferredCwd
            return (command(cmd, workdir: cwd), cwd, nil)
        case "grep", "search_tool", "glob":
            let q = (input["pattern"] ?? input["query"] ?? input["path"]) as? String ?? ""
            return (.search(q), inferredCwd, nil)
        case "list_dir":
            let q = (input["target_directory"] ?? input["path"]) as? String ?? ""
            return (.search(q), inferredCwd, nil)
        case "web_fetch":
            let u = input["url"] as? String ?? ""
            return (.web(u), nil, u)
        case "web_search":
            return (.web(input["query"] as? String ?? ""), nil, nil)
        case "todo_write", "kill_command_or_subagent", "check_command_or_subagent", "wait_for_command":
            return nil
        default:
            return (.other(name), inferredCwd, nil)
        }
    }

    // Antigravity: ~/.gemini/antigravity/brain/<会话>/.system_generated/logs/transcript.jsonl
    static func antigravity(_ obj: [String: Any]) -> [Event] {
        guard let type = obj["type"] as? String else { return [] }
        let ts = date(obj["created_at"] ?? obj["timestamp"])
        switch type {
        case "USER_INPUT":
            let content = obj["content"] as? String ?? ""
            return [Event(action: .think, date: ts, prompt: promptTitle(content))]
        case "GENERIC":
            var content = obj["content"] as? String ?? ""
            if let r = content.range(of: "Command output:\n") {
                content = String(content[r.upperBound...])
            } else if content.contains("No output from the command.") {
                content = ""
            }
            let isErr = (obj["status"] as? String) == "ERROR"
            var ev = Event(date: ts, pending: false)
            if !content.isEmpty {
                ev.results = [ToolResult(toolId: "__last__", text: content, image: nil, isError: isErr)]
            }
            return [ev]
        case "PLANNER_RESPONSE":
            let content = obj["content"] as? String ?? ""
            let say = content.isEmpty ? nil : shortSay(content)
            let calls = obj["tool_calls"] as? [[String: Any]] ?? []
            if calls.isEmpty {
                if !content.isEmpty && (obj["status"] as? String == "DONE") {
                    var ev = Event(action: .done, date: ts, pending: false, say: say, piece: LivePiece(kind: "done"))
                    if let q = trailingQuestion(content) { ev.ask = q }
                    return [ev]
                }
                return [Event(action: .think, date: ts, say: say)]
            }
            let stepIdx = obj["step_index"] as? Int ?? 0
            var out: [Event] = []
            for (idx, tc) in calls.enumerated() {
                let name = (tc["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                let rawArgs = tc["args"] as? [String: Any] ?? [:]
                let input = unquoteArgs(rawArgs)
                var ev = Event(date: ts, say: idx == 0 ? say : nil)
                if let q = askText(name, input) { ev.ask = q }
                if let n = editLines(name, input) { ev.lines = n }
                if let mapped = antigravityTool(name, input) {
                    ev.action = mapped.action
                    ev.pending = mapped.action != .done
                    if let cwd = mapped.cwd { ev.cwd = cwd }
                    if let url = mapped.url { ev.url = url }
                    ev.piece = LiveParse.piece(name, input, action: mapped.action)
                    ev.toolId = (tc["id"] as? String) ?? "agy-\(stepIdx)-\(idx)"
                }
                if ev.action != nil || ev.ask != nil || ev.say != nil {
                    out.append(ev)
                }
            }
            return out
        default:
            return []
        }
    }

    static func antigravityTool(_ name: String, _ input: [String: Any]) -> (action: AgentAction, cwd: String?, url: String?)? {
        let path = (input["Path"] ?? input["TargetFile"] ?? input["File"] ?? input["AbsolutePath"] ?? input["SearchPath"] ?? input["DirectoryPath"]) as? String
        let inferredCwd = path.flatMap(inferProjectRoot(fromPath:))
        switch name {
        case "read_file", "view_file_outline", "view_code_item":
            return path.map { (.read($0), inferredCwd, nil) }
        case "edit_file", "replace_file_content", "multi_replace_file_content":
            return path.map { (.edit($0), inferredCwd, nil) }
        case "write_file", "write_to_file":
            return path.map { (.create($0), inferredCwd, nil) }
        case "run_command":
            let cmd = (input["CommandLine"] ?? input["command"]) as? String ?? "命令"
            let cdDir = (input["Cwd"] as? String) ?? capture(#"cd\s+["']?(/[^"'&;\n]+?)["']?\s*(?:&&|;|\n)"#, in: cmd)
            let cwd = cdDir.flatMap(inferProjectRoot(fromPath:)) ?? inferredCwd
            return (command(cmd, workdir: cwd), cwd, nil)
        case "grep_search", "find_by_name", "list_dir":
            let q = ((input["Query"] ?? input["Pattern"]) as? String) ?? path ?? ""
            return (.search(q), inferredCwd, nil)
        case "search_web", "read_url_content":
            let q = (input["query"] ?? input["Url"] ?? input["url"]) as? String ?? ""
            return (.web(q), nil, q.hasPrefix("http") ? q : nil)
        case "invoke_subagent":
            return (.other("派出子任务"), inferredCwd, nil)
        case "ask_question":
            return nil
        default:
            return (.other(name), inferredCwd, nil)
        }
    }

    static func unquoteArgs(_ raw: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in raw {
            if let s = v as? String {
                if let parsed = try? JSONSerialization.jsonObject(with: Data(s.utf8), options: .fragmentsAllowed) {
                    out[k] = parsed
                } else {
                    out[k] = s.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
            } else {
                out[k] = v
            }
        }
        return out
    }

    static func inferProjectRoot(fromPath rawPath: String) -> String? {
        let home = NSHomeDirectory()
        let path = (rawPath as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { return nil }
        for skip in ["/.gemini/", "/.grok/", "/.claude/", "/.codex/", "/Library/", "/private/var/", "/tmp/"] {
            if path.contains(skip) { return nil }
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: path, isDirectory: &isDir)
        let startDir = (exists && isDir.boolValue) ? path : (path as NSString).deletingLastPathComponent
        var cur = startDir
        let markers = ["Package.swift", ".git", "package.json", "pyproject.toml", "Cargo.toml", "go.mod"]
        for _ in 0..<6 {
            guard cur.count > home.count, cur.hasPrefix(home + "/") else { break }
            if markers.contains(where: { fm.fileExists(atPath: cur + "/" + $0) }) {
                return cur
            }
            cur = (cur as NSString).deletingLastPathComponent
        }
        return (startDir.count > home.count && startDir.hasPrefix(home + "/")) ? startDir : nil
    }
}

// MARK: - 追踪日志文件

/// 只在后台串行队列上使用。
final class ActivityScanner {
    private struct Tail {
        var offset: UInt64
        var partial = Data()
    }

    private var tails: [String: Tail] = [:]
    private var sessions: [String: AgentSession] = [:]
    private let window: TimeInterval = 15 * 60
    /// 第一次读一个会话时往回读这么多，找回最近改过、看过的文件（只读一次，之后只读新增）；计划另外往回找。
    private let tailBytes: UInt64 = 1024 * 1024

    func scan(now: Date = Date()) -> [AgentSession] {
        let home = NSHomeDirectory()
        var files: [(String, AgentKind, Date)] = []
        files += recentFiles(in: home + "/.claude/projects", depth: 1, kind: .claude, now: now)
        files += recentFiles(in: home + "/.codex/sessions", depth: 3, kind: .codex, now: now)
        files += recentGrokFiles(in: home + "/.grok/sessions", now: now)
        files += recentAntigravityFiles(in: home + "/.gemini/antigravity/brain", now: now)

        let live = Set(files.map(\.0))
        tails = tails.filter { live.contains($0.key) }
        sessions = sessions.filter { live.contains($0.key) }

        for (path, kind, mtime) in files {
            for line in newLines(path, kind: kind) {
                apply(line, path: path, kind: kind, mtime: mtime)
            }
            if kind == .grok {
                syncGrokMetadata(path: path, mtime: mtime)
            } else if kind == .antigravity {
                syncAntigravityMetadata(path: path)
            }
        }
        return sessions.values
            .filter { now.timeIntervalSince($0.updatedAt) < window }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func recentFiles(in root: String, depth: Int, kind: AgentKind, now: Date) -> [(String, AgentKind, Date)] {
        let fm = FileManager.default
        var dirs = [root]
        for _ in 0..<depth {
            dirs = dirs.flatMap { dir -> [String] in
                ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).map { dir + "/" + $0 }.filter {
                    var isDir: ObjCBool = false
                    return fm.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue
                }
            }
        }
        // Codex 按日期分目录，只看最近的两天
        if kind == .codex { dirs = Array(dirs.sorted().suffix(2)) }
        var out: [(String, AgentKind, Date)] = []
        for dir in dirs {
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".jsonl") {
                let path = dir + "/" + name
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mtime = attrs[.modificationDate] as? Date,
                      now.timeIntervalSince(mtime) < window else { continue }
                out.append((path, kind, mtime))
            }
        }
        return out
    }

    private func recentGrokFiles(in root: String, now: Date) -> [(String, AgentKind, Date)] {
        let fm = FileManager.default
        var out: [(String, AgentKind, Date)] = []
        for ws in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let wsDir = root + "/" + ws
            for sid in (try? fm.contentsOfDirectory(atPath: wsDir)) ?? [] {
                let dir = wsDir + "/" + sid
                let chatPath = dir + "/chat_history.jsonl"
                guard let chatAttrs = try? fm.attributesOfItem(atPath: chatPath),
                      let chatMtime = chatAttrs[.modificationDate] as? Date else { continue }
                let evMtime = ((try? fm.attributesOfItem(atPath: dir + "/events.jsonl"))?[.modificationDate] as? Date) ?? chatMtime
                let mtime = max(chatMtime, evMtime)
                guard now.timeIntervalSince(mtime) < window else { continue }
                out.append((chatPath, .grok, mtime))
            }
        }
        return out
    }

    private func recentAntigravityFiles(in root: String, now: Date) -> [(String, AgentKind, Date)] {
        let fm = FileManager.default
        var out: [(String, AgentKind, Date)] = []
        for cid in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            let path = root + "/" + cid + "/.system_generated/logs/transcript.jsonl"
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date,
                  now.timeIntervalSince(mtime) < window else { continue }
            out.append((path, .antigravity, mtime))
        }
        return out
    }

    private func newLines(_ path: String, kind: AgentKind) -> [Data] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        var tail = tails[path] ?? Tail(offset: size > tailBytes ? size - tailBytes : 0)
        let firstRead = tails[path] == nil
        if size < tail.offset { tail = Tail(offset: 0) }   // 文件被截断或重写
        guard size > tail.offset else { tails[path] = tail; return [] }
        try? handle.seek(toOffset: tail.offset)
        var chunk = tail.partial + (handle.readDataToEndOfFile())
        tail.offset = size
        var lines = chunk.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).map { Data($0) }
        if chunk.last != UInt8(ascii: "\n"), let last = lines.popLast() { tail.partial = last } else { tail.partial = Data() }
        if firstRead && tail.offset > tailBytes && !lines.isEmpty { lines.removeFirst() }  // 从中间切入，第一行不完整
        chunk.removeAll()
        tails[path] = tail
        if firstRead && size > tailBytes { lines = planHistory(handle, before: size - tailBytes, kind: kind) + lines }
        return lines
    }

    private static let userMarkers = ["\"type\":\"user\"", "\"type\":\"USER_INPUT\""].map { Data($0.utf8) }
    private static let toolResultMarker = Data("tool_result".utf8)
    private static let planMarkers = ["\"name\":\"TodoWrite\"", "\"name\":\"todo_write\"", "\"name\":\"mcp__ccd_turn__update_plan\"",
                                      "\"name\":\"mcp__ccd_turn__wrap_up\"", "\"name\":\"update_plan\""].map { Data($0.utf8) }

    /// 计划往往在很早就列好了。第一次读时从切入点往回找，直到找到最近一次完整的计划（最多往回 64MB）。
    private func planHistory(_ handle: FileHandle, before end: UInt64, kind: AgentKind) -> [Data] {
        let step: UInt64 = 1 << 20
        let limit: UInt64 = end > 64 << 20 ? end - (64 << 20) : 0
        var pos = end, carry = Data(), found: [Data] = []
        var gotPlan = false, gotPrompt = false
        while pos > limit {
            let start = max(limit, pos > step ? pos - step : 0)
            try? handle.seek(toOffset: start)
            let data = ((try? handle.read(upToCount: Int(pos - start))) ?? nil) ?? Data()
            var lines = (data + carry).split(separator: UInt8(ascii: "\n")).map { Data($0) }
            carry = start > limit && !lines.isEmpty ? lines.removeFirst() : Data()   // 不完整的行留给前一块
            for line in lines.reversed() {
                let isPlan = Self.planMarkers.contains(where: { line.range(of: $0) != nil })
                // 用户最近一次下的指令（当主题），只要找到一条
                let isPrompt = !gotPrompt && Self.userMarkers.contains(where: { line.range(of: $0) != nil }) && line.range(of: Self.toolResultMarker) == nil
                guard isPlan || isPrompt,
                      let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                let evs = ActivityParser.events(obj, kind: kind)
                guard !evs.isEmpty else { continue }
                if isPrompt, evs.contains(where: { $0.prompt != nil }) { gotPrompt = true; found.append(line) }
                if isPlan, !gotPlan {
                    found.append(line)
                    if evs.contains(where: { if case .set? = $0.plan { return true }; return false }) { gotPlan = true }
                }
                if gotPlan && gotPrompt { return found.reversed() }
            }
            pos = start
        }
        return found.reversed()
    }

    private static let claudeMarkers = ["\"type\":\"assistant\"", "\"type\":\"user\""].map { Data($0.utf8) }
    private static let codexMarkers = ["session_meta", "turn_context", "function_call", "custom_tool_call",
                                       "task_complete", "task_started", "user_message", "web_search_call", "\"reasoning\"",
                                       "agent_message"].map { Data($0.utf8) }
    private static let grokMarkers = ["\"type\":\"assistant\"", "\"type\":\"user\"", "\"type\":\"tool_result\"", "\"type\":\"reasoning\""].map { Data($0.utf8) }
    private static let antigravityMarkers = ["\"USER_INPUT\"", "\"PLANNER_RESPONSE\"", "\"GENERIC\""].map { Data($0.utf8) }

    private static func extractSessionId(path: String, kind: AgentKind) -> String {
        switch kind {
        case .grok:
            return ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        case .antigravity:
            let p1 = (path as NSString).deletingLastPathComponent // logs
            let p2 = (p1 as NSString).deletingLastPathComponent   // .system_generated
            let p3 = (p2 as NSString).deletingLastPathComponent   // <conversation-id>
            return (p3 as NSString).lastPathComponent
        case .claude, .codex:
            return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        }
    }

    private func apply(_ line: Data, path: String, kind: AgentKind, mtime: Date) {
        let markers: [Data]
        switch kind {
        case .claude: markers = Self.claudeMarkers
        case .codex: markers = Self.codexMarkers
        case .grok: markers = Self.grokMarkers
        case .antigravity: markers = Self.antigravityMarkers
        }
        guard markers.contains(where: { line.range(of: $0) != nil }),
              let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        let evs = ActivityParser.events(obj, kind: kind)
        guard !evs.isEmpty else { return }

        for ev in evs {
            var s = sessions[path] ?? AgentSession(
                id: path, kind: kind,
                sessionId: Self.extractSessionId(path: path, kind: kind),
                cwd: nil, action: .think, lastURL: nil, updatedAt: ev.date ?? mtime)
            if let cwd = ev.cwd { s.cwd = AgentSession.projectRoot(current: s.cwd, new: cwd) }
            if let url = ev.url { s.lastURL = url }
            if let say = ev.say { s.say = say; s.sayAt = ev.date ?? mtime }
            if let prompt = ev.prompt { s.prompt = prompt; s.promptLiveStart = s.liveNext; s.promptAt = ev.date ?? mtime }
            if let ask = ev.ask { s.waiting = ask }
            else if ev.prompt != nil || (ev.action != nil && ev.action != .done) { s.waiting = nil }
            if let piece = ev.piece, !(piece.kind == "done" && s.live.last?.kind == "done") {
                s.liveNext += 1
                var e = LiveEvent(id: s.liveNext, piece: piece, toolId: ev.toolId)
                e.step = s.currentStep; e.gen = s.planGen; e.at = ev.date ?? mtime
                s.live.append(e)
                if s.live.count > 40 { s.live.removeFirst(s.live.count - 40) }
            }
            for r in ev.results {
                let idx = r.toolId == "__last__"
                    ? s.live.lastIndex(where: { $0.kind == "run" && $0.ok == nil })
                    : s.live.lastIndex(where: { $0.toolId == r.toolId })
                guard let i = idx else { continue }
                s.live[i].absorb(r)
                // 截图很大，只留最新那一张
                if r.image != nil { for j in s.live.indices where j != i && s.live[j].shot != nil { s.live[j].shot = nil; s.live[j].version += 1 } }
            }
            if let plan = ev.plan { s.apply(plan) }
            if let action = ev.action {
                let when = ev.date ?? mtime
                s.action = action
                s.updatedAt = when
                s.pending = ev.pending ?? false
                s.seq += 1
                s.lines = action.isWriting ? ev.lines : nil
                switch action {
                case .edit(let p), .create(let p):
                    let full = s.absolute(p)
                    s.recentEdits.removeAll { $0 == full }
                    s.recentEdits = Array(([full] + s.recentEdits).prefix(12))
                    s.editCounts[full, default: 0] += 1
                    s.editedAt = when
                case .read(let p):
                    let full = s.absolute(p)
                    s.recentReads.removeAll { $0 == full }
                    s.recentReads = Array(([full] + s.recentReads).prefix(8))
                case .browse:
                    s.browsedAt = when
                default:
                    break
                }
            } else if ev.pending == false, s.pending {
                // 工具跑完了：从这一刻重新计 45 秒
                s.pending = false
                s.updatedAt = ev.date ?? mtime
            }
            if ev.action != nil || ev.plan != nil || ev.piece != nil || sessions[path] != nil { sessions[path] = s }
        }
    }

    private func syncGrokMetadata(path: String, mtime: Date) {
        guard var s = sessions[path] else { return }
        let dir = (path as NSString).deletingLastPathComponent
        if s.cwd == nil,
           let sumData = try? Data(contentsOf: URL(fileURLWithPath: dir + "/summary.json")),
           let sumObj = (try? JSONSerialization.jsonObject(with: sumData)) as? [String: Any],
           let info = sumObj["info"] as? [String: Any],
           let cwd = info["cwd"] as? String {
            s.cwd = cwd
        }
        let eventsPath = dir + "/events.jsonl"
        if let handle = FileHandle(forReadingAtPath: eventsPath) {
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            if size > 0 {
                let offset = size > 2048 ? size - 2048 : 0
                try? handle.seek(toOffset: offset)
                if let tail = String(data: handle.readDataToEndOfFile(), encoding: .utf8),
                   let lastLine = tail.components(separatedBy: .newlines).last(where: { !$0.isEmpty }),
                   let obj = (try? JSONSerialization.jsonObject(with: Data(lastLine.utf8))) as? [String: Any] {
                    let evDate = ActivityParser.date(obj["ts"]) ?? mtime
                    let evType = obj["type"] as? String ?? ""
                    if evType == "turn_ended" {
                        s.action = .done
                        s.pending = false
                    } else if evDate > s.updatedAt {
                        s.updatedAt = evDate
                        if s.action == .done { s.action = .think }
                    }
                }
            }
        }
        sessions[path] = s
    }

    private func syncAntigravityMetadata(path: String) {
        guard var s = sessions[path], s.plan.isEmpty else { return }
        let p1 = (path as NSString).deletingLastPathComponent
        let p2 = (p1 as NSString).deletingLastPathComponent
        let convDir = (p2 as NSString).deletingLastPathComponent
        let taskPath = convDir + "/task.md"
        guard let text = try? String(contentsOfFile: taskPath, encoding: .utf8) else { return }
        var steps: [PlanStep] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let g = ActivityParser.captureGroups(#"^- \[([ xX/])\]\s+(.+)$"#, in: trimmed), g.count == 2 else { continue }
            let mark = g[0]
            let status = (mark == "x" || mark == "X") ? "completed" : mark == "/" ? "in_progress" : "pending"
            steps.append(PlanStep(text: g[1], status: status))
        }
        if !steps.isEmpty {
            s.apply(.set(steps))
            sessions[path] = s
        }
    }
}

@MainActor
final class AgentActivityStore: ObservableObject {
    static let shared = AgentActivityStore()
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var now = Date()

    private let scanner = ActivityScanner()
    private let queue = DispatchQueue(label: "com.orbit.QuotaBar.activity", qos: .utility)
    private var timer: Timer?

    var activeCount: Int { sessions.filter { $0.isActive(now: now) }.count }

    func start() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private var scanning = false
    private func refresh() {
        guard !scanning else { return }
        scanning = true
        queue.async { [scanner] in
            let result = scanner.scan()
            DispatchQueue.main.async {
                self.scanning = false
                self.now = Date()
                if result != self.sessions { self.sessions = result }
            }
        }
    }
}

// MARK: - 点击后的去处

enum ActivityActions {
    /// 点文件名：用默认编辑器打开。
    static func openFile(_ s: AgentSession, _ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: s.absolute(path)))
    }

    /// 点页面：用浏览器打开 AI 正在操控的那个网址。
    static func openPage(_ s: AgentSession) {
        if let url = s.lastURL, let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    static func openTarget(_ s: AgentSession) {
        if let path = s.focusFile {
            openFile(s, path)
        } else if s.page != nil {
            openPage(s)
        } else {
            openProject(s)
        }
    }

    static func openProject(_ s: AgentSession) {
        guard let cwd = s.cwd else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
    }

    static func reveal(_ s: AgentSession) {
        if let path = s.focusFile {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.absolute(path))])
        } else {
            openProject(s)
        }
    }

    /// 点整行：跳到这个会话去操控。Claude 桌面版的 Code 会话有 claude:// 链接；找不到就打开项目文件夹。
    static func jumpToSession(_ s: AgentSession) {
        if s.kind == .claude, let local = claudeDesktopSession(cliSessionId: s.sessionId),
           let url = URL(string: "claude://claude.ai/epitaxy/\(local)") {
            NSWorkspace.shared.open(url)
            return
        }
        if s.kind == .codex, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            NSWorkspace.shared.open(app)
            return
        }
        if s.kind == .grok, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anysphere.sand") {
            NSWorkspace.shared.open(app)
            return
        }
        if s.kind == .antigravity, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.antigravity") {
            NSWorkspace.shared.open(app)
            return
        }
        openProject(s)
    }

    static func claudeDesktopSession(cliSessionId: String) -> String? {
        let root = NSHomeDirectory() + "/Library/Application Support/Claude/claude-code-sessions"
        let fm = FileManager.default
        guard let accounts = try? fm.contentsOfDirectory(atPath: root) else { return nil }
        for a in accounts {
            for org in (try? fm.contentsOfDirectory(atPath: root + "/" + a)) ?? [] {
                let dir = root + "/" + a + "/" + org
                for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasPrefix("local_") && name.hasSuffix(".json") {
                    guard let data = fm.contents(atPath: dir + "/" + name), data.range(of: Data(cliSessionId.utf8)) != nil,
                          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          obj["cliSessionId"] as? String == cliSessionId else { continue }
                    return obj["sessionId"] as? String ?? (name as NSString).deletingPathExtension
                }
            }
        }
        return nil
    }
}
