import AppKit
import SQLite3

/// 文件在界面里的写法：项目内用相对路径（"app/x.py"），项目外用 ~ 缩写的绝对路径。
struct OrbitKey {
    let dir: String
    let name: String
    var path: String { dir.isEmpty ? name : dir + "/" + name }

    init(_ absolute: String, cwd: String?) {
        let parent = (absolute as NSString).deletingLastPathComponent
        name = (absolute as NSString).lastPathComponent
        if let cwd, parent == cwd { dir = "" }
        else if let cwd, parent.hasPrefix(cwd + "/") { dir = String(parent.dropFirst(cwd.count + 1)) }
        else { dir = (parent as NSString).abbreviatingWithTildeInPath }
    }

    /// 界面点回来的路径还原成绝对路径。
    static func resolve(_ key: String, cwd: String?) -> String {
        if key.hasPrefix("/") { return key }
        if key.hasPrefix("~") { return (key as NSString).expandingTildeInPath }
        guard let cwd else { return key }
        return (cwd as NSString).appendingPathComponent(key)
    }
}

// MARK: - 刘海和 App 窗口共用的数据：每个会话现在在干什么、做到第几步、这一步做过的事

@MainActor
enum OrbitFeed {
    private static var titles: [String: (at: Date, title: String?)] = [:]

    static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    /// 要显示的会话：在干活的、在等你的、10 分钟内刚停下的。
    static func visible(_ sessions: [AgentSession], now: Date) -> [AgentSession] {
        sessions.filter { $0.isActive(now: now) || $0.waiting != nil || now.timeIntervalSince($0.updatedAt) < 600 }
    }

    static func phase(_ s: AgentSession, now: Date) -> String {
        s.waiting != nil ? "need" : s.isActive(now: now) ? "work" : "done"
    }

    /// 一个会话的概要；detail 为 true 时带上计划全文、现在这件事的细节和这一步的经过（App 窗口用）。
    static func session(_ s: AgentSession, now: Date, detail: Bool) -> [String: Any] {
        let ph = phase(s, now: now)
        let pct = progressPercent(s, phase: ph)
        var out: [String: Any] = [
            "id": s.id,
            "title": title(s),
            "tool": s.kind.rawValue,
            "project": s.projectName,
            "phase": ph,
            "pose": pose(s, phase: ph),
            "text": s.waiting ?? (ph == "done" ? s.doneText : s.humanText),
            "mins": max(0, Int(now.timeIntervalSince(s.updatedAt) / 60)),
            "edits": s.editCounts.count,
            "pct": pct,
        ]
        if !s.plan.isEmpty {
            out["step"] = min(s.plan.count, s.currentStep + 1)
            out["steps"] = s.plan.count
            out["done"] = s.plan.filter { $0.status == "completed" }.count
            out["stepText"] = s.plan[min(s.plan.count - 1, s.currentStep)].text
        }
        if let start = s.promptAt {
            out["elapsed"] = max(0, Int(now.timeIntervalSince(start) / 60))
        }
        if let e = s.live.last(where: { $0.kind != "done" }) { out["now"] = event(e, s, full: detail) }
        if detail {
            out["task"] = s.prompt ?? ""
            out["plan"] = s.plan.map { ["text": $0.text, "status": $0.status] }
            // 这一步做过的事：当前这版计划、当前这一步；没有计划就是最近几件
            let cur = s.plan.isEmpty ? s.live : s.live.filter { $0.gen == s.planGen && $0.step == s.currentStep }
            out["timeline"] = cur.filter { $0.kind != "done" }.suffix(12).map { event($0, s, full: false) }
            // 关联文件节点（用于右侧工作舞台连线展示）
            var seen = Set<String>()
            var files: [[String: Any]] = []
            for e in s.live.reversed() {
                guard let f = e.file else { continue }
                let full = s.absolute(f)
                let key = OrbitKey(full, cwd: s.cwd).path
                let name = (full as NSString).lastPathComponent
                guard !seen.contains(name) else { continue }
                seen.insert(name)
                files.append([
                    "name": name,
                    "ext": (full as NSString).pathExtension.lowercased(),
                    "path": key,
                    "kind": e.kind,
                    "lines": e.lines ?? s.editCounts[f] ?? 0,
                ])
                if files.count >= 5 { break }
            }
            out["files"] = files
        }
        return out
    }

    /// 每个会话都算一个 0~100 的百分比进度：
    /// - 已完成：100%
    /// - 有计划清单：按已完成步数 + 当前步内的实时动作数平滑推进（8%~96%）
    /// - 无显式计划：按本轮已执行的动作数平滑推进（15%~94%，等你回复时 85%）
    static func progressPercent(_ s: AgentSession, phase: String) -> Int {
        if phase == "done" { return 100 }
        if !s.plan.isEmpty {
            let total = Double(s.plan.count)
            let done = Double(s.plan.filter { $0.status == "completed" }.count)
            if done >= total { return 96 }
            let curEvents = s.live.filter { $0.gen == s.planGen && $0.step == s.currentStep && $0.kind != "done" }.count
            let partial = min(0.85, Double(max(1, curEvents)) / 6.0)
            let raw = ((done + partial) / total) * 100.0
            return min(96, max(8, Int(raw.rounded())))
        }
        if phase == "need" { return 85 }
        let turnEvents = max(1, s.liveNext > s.promptLiveStart ? (s.liveNext - s.promptLiveStart) : s.live.count)
        let raw = 15.0 + 79.0 * (1.0 - exp(-Double(turnEvents) / 8.0))
        return min(94, max(15, Int(raw.rounded())))
    }

    /// 一件事：文件、命令、网页。full 时带上改动前后原文和命令输出。截图另外送（很大）。
    static func event(_ e: LiveEvent, _ s: AgentSession, full: Bool) -> [String: Any] {
        var d: [String: Any] = ["id": e.id, "v": e.version, "kind": e.kind]
        if let at = e.at { d["at"] = clock.string(from: at) }
        if let f = e.file {
            let full = s.absolute(f)
            d["name"] = (full as NSString).lastPathComponent
            d["ext"] = (full as NSString).pathExtension.lowercased()
            d["path"] = OrbitKey(full, cwd: s.cwd).path
        }
        if let n = e.lines { d["lines"] = n }
        if let ok = e.ok { d["ok"] = ok }
        switch e.kind {
        case "read": d["text"] = "看了 " + (d["name"] as? String ?? "文件")
        case "edit": d["text"] = (e.del.isEmpty && !e.code.isEmpty ? "写了 " : "改了 ") + (d["name"] as? String ?? "文件")
        case "run":
            let c = e.cmd ?? ""
            let human = AgentSession.humanCommand(c)
            d["text"] = c.hasPrefix("搜索 ") ? "找代码" : human.hasPrefix("在") ? String(human.dropFirst()) : human
            d["cmd"] = c
            d["short"] = AgentSession.primaryCommand(c)
            if let last = e.out.last { d["last"] = last }
        case "browse":
            let host = e.url.map(AgentSession.shortURL) ?? ""
            d["host"] = host
            if let st = e.steps.last(where: { $0.kind != "read" && $0.kind != "scroll" }) ?? e.steps.last {
                var b: [String: Any] = ["kind": st.kind]
                if let t = st.text { b["text"] = String(t.prefix(40)) }
                if let x = st.x, let y = st.y, let w = e.shotW, let h = e.shotH, w > 0, h > 0 { b["fx"] = x / Double(w); b["fy"] = y / Double(h) }
                d["b"] = b
                switch st.kind {
                case "nav": d["text"] = "打开 " + (st.text.map(AgentSession.shortURL) ?? host)
                case "click": d["text"] = "点击网页"
                case "type": d["text"] = "输入 " + String((st.text ?? "").prefix(20))
                case "key": d["text"] = "按键 " + (st.text ?? "")
                default: d["text"] = "看网页"
                }
            } else { d["text"] = "看网页" }
            if e.shot != nil { d["shot"] = "\(e.id).\(e.version)" }
            if let t = e.tab { d["tab"] = t }
        case "web": d["text"] = "查资料"
        default: d["text"] = e.kind
        }
        if full {
            if !e.code.isEmpty { d["code"] = Array(e.code.prefix(12)) }
            if !e.del.isEmpty { d["del"] = Array(e.del.prefix(12)) }
            if let f = e.from { d["from"] = f }
            if !e.out.isEmpty { d["out"] = e.out }
        }
        return d
    }

    /// 某个会话最新那张网页截图（data URL）。
    static func shot(_ s: AgentSession) -> (key: String, url: String)? {
        guard let e = s.live.last(where: { $0.shot != nil }), let url = e.shot else { return nil }
        return ("\(e.id).\(e.version)", url)
    }

    /// 小人跟着干的事换动作。
    static func pose(_ s: AgentSession, phase: String) -> String {
        if phase == "need" { return "idle-look" }
        if phase == "done" { return "sleeping" }
        switch s.action {
        case .read: return "idle-reading"
        case .edit, .create: return "working-typing"
        case .run: return "working-building"
        case .search: return "working-debugger"
        case .browse, .web: return "working-carrying"
        case .think, .other: return "working-thinking"
        case .done: return "happy"
        }
    }

    /// 会话名：Claude 桌面版 / Grok Build / Antigravity 给会话起的标题，没有就用指令或项目文件夹名。30 秒读一次。
    static func title(_ s: AgentSession) -> String {
        if let c = titles[s.id], Date().timeIntervalSince(c.at) < 30 {
            return c.title ?? s.prompt ?? s.projectName
        }
        var t: String?
        switch s.kind {
        case .claude:
            let root = NSHomeDirectory() + "/Library/Application Support/Claude/claude-code-sessions"
            let fm = FileManager.default
            outer: for a in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
                for org in (try? fm.contentsOfDirectory(atPath: root + "/" + a)) ?? [] {
                    let dir = root + "/" + a + "/" + org
                    for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasPrefix("local_") {
                        guard let data = fm.contents(atPath: dir + "/" + name), data.range(of: Data(s.sessionId.utf8)) != nil,
                              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                              obj["cliSessionId"] as? String == s.sessionId else { continue }
                        t = obj["title"] as? String
                        break outer
                    }
                }
            }
        case .grok:
            let sumPath = (s.id as NSString).deletingLastPathComponent + "/summary.json"
            if let data = try? Data(contentsOf: URL(fileURLWithPath: sumPath)),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                let raw = (obj["generated_title"] as? String) ?? (obj["session_summary"] as? String)
                if let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    t = raw
                }
            }
        case .antigravity:
            t = antigravityTitle(conversationId: s.sessionId)
        case .codex:
            break
        }
        titles[s.id] = (Date(), t)
        return t ?? s.prompt ?? s.projectName
    }

    private static func antigravityTitle(conversationId: String) -> String? {
        let dbPath = NSHomeDirectory() + "/.gemini/antigravity/conversation_summaries.db"
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
        var db: OpaquePointer?
        defer { if db != nil { sqlite3_close(db) } }
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        sqlite3_busy_timeout(db, 200)
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        let sql = "SELECT title FROM conversation_summaries WHERE conversation_id = ? LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        _ = conversationId.withCString { cstr in
            sqlite3_bind_text(stmt, 1, cstr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard sqlite3_step(stmt) == SQLITE_ROW, let cText = sqlite3_column_text(stmt, 0) else { return nil }
        let text = String(cString: cText).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// 额度：每个工具有百分比的那几项（Claude 的 5 小时和本周、Grok、Antigravity 等）。
    static func quota(_ snapshot: UsageSnapshot) -> [[String: Any]] {
        snapshot.providers.flatMap { p -> [[String: Any]] in
            let windows = p.metrics.filter {
                $0.percent != nil && $0.label != "套餐" && $0.label != "订阅" && $0.label != "Auto" && $0.label != "API"
            }
            if windows.isEmpty {
                if let pct = p.primaryPercent {
                    let note = p.metrics.first?.detail ?? ""
                    return [["name": p.kind.rawValue, "pct": pct, "note": note, "stale": p.status == .stale]]
                }
                let note = p.status == .loading ? "正在获取…" : (p.errorMessage ?? "暂不可用")
                return [["name": p.kind.rawValue, "pct": 0, "note": note, "stale": p.status == .stale]]
            }
            return windows.map { m in
                let note = m.resetsAt.map { Formatters.countdown(to: $0) } ?? m.detail
                let label = windows.count > 1 ? p.kind.rawValue + " · " + Self.windowName(m.label) : p.kind.rawValue
                return ["name": label, "pct": m.percent ?? 0, "note": note.hasPrefix("已用") ? "" : note,
                        "stale": p.status == .stale]
            }
        }
    }

    private static func windowName(_ label: String) -> String {
        switch label {
        case "5小时": return "5 小时"
        case "周限额": return "本周"
        default: return label
        }
    }
}

// MARK: - 刘海与主窗口共用的设置（默认 5 秒自动隐藏、外观主题、角色/图标风格、开机自启）

@MainActor
enum OrbitSettings {
    private static let autoHideKey = "orbit.notchAutoHide"
    private static let themeKey = "orbit.theme"
    private static let avatarKey = "orbit.avatarStyle"
    private static let soundKey = "orbit.soundAlert"

    /// 默认 true：启动、新任务开始、任务完成或等你回复时显示 5 秒后自动收缩回硬件刘海；false：一直常驻显示。
    static var notchAutoHide: Bool {
        get {
            if UserDefaults.standard.object(forKey: autoHideKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: autoHideKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: autoHideKey)
        }
    }

    /// 外观主题："system"（跟随系统，默认） | "light"（浅色） | "dark"（深色）
    static var theme: String {
        get { UserDefaults.standard.string(forKey: themeKey) ?? "system" }
        set { UserDefaults.standard.set(newValue, forKey: themeKey) }
    }

    /// 角色与图标风格：
    /// - "byTool"（默认：Claude 显示像素小人，Codex/Grok/Antigravity/Cursor 显示各自官方图标）
    /// - "brand"（全部显示各模型官方图标）
    /// - "clawd"（全部显示像素小人）
    /// - "codex"（统一显示 OpenAI Codex 官方图标）
    static var avatarStyle: String {
        get { UserDefaults.standard.string(forKey: avatarKey) ?? "byTool" }
        set { UserDefaults.standard.set(newValue, forKey: avatarKey) }
    }

    /// 任务完成或等你回复时播放系统轻提示音（默认开启）
    static var soundAlert: Bool {
        get {
            if UserDefaults.standard.object(forKey: soundKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: soundKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: soundKey)
        }
    }

    static var payload: [String: Any] {
        [
            "autoHide": notchAutoHide,
            "theme": theme,
            "avatarStyle": avatarStyle,
            "soundAlert": soundAlert,
            "launchAtLogin": UsageStore.shared.launchAtLogin,
        ]
    }

    static func apply(key: String, value: Any) {
        switch key {
        case "autoHide":
            if let b = value as? Bool { notchAutoHide = b }
        case "theme":
            if let s = value as? String {
                theme = s
                OrbitAppWindow.shared.applyAppearance()
            }
        case "avatarStyle":
            if let s = value as? String { avatarStyle = s }
        case "soundAlert":
            if let b = value as? Bool { soundAlert = b }
        case "launchAtLogin":
            if let b = value as? Bool, UsageStore.shared.launchAtLogin != b {
                UsageStore.shared.toggleLaunchAtLogin()
            }
        default:
            break
        }
        NotchController.shared.refreshSettings()
        OrbitAppWindow.shared.refreshSettings()
    }
}
