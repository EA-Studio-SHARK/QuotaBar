import Foundation

// MARK: - 实时窗口要的事件流：每个动作一条，带代码片段、命令输出、网页截图和点击位置

/// 浏览器里的一步操作。坐标是 AI 看到的截图坐标系里的位置。
struct BrowserStep: Equatable {
    var kind: String          // nav / click / type / key / scroll / read
    var x: Double?
    var y: Double?
    var text: String?
}

/// 从 tool_use 里拿到的动作细节，还没编号。
struct LivePiece: Equatable {
    var kind: String          // read / edit / run / browse / web / done
    var file: String?
    var lines: Int?
    var code: [String] = []
    var del: [String] = []    // 改之前的原文（改动对比用）
    var from: Int?            // 看文件时从第几行开始
    var cmd: String?
    var url: String?
    var steps: [BrowserStep] = []
}

/// 工具执行完的结果：命令输出、浏览器截图和标签页信息。
struct ToolResult: Equatable {
    var toolId: String
    var text: String
    var image: String?        // data URL
    var isError: Bool
}

struct LiveEvent: Equatable {
    let id: Int
    var kind: String
    var file: String?
    var lines: Int?
    var code: [String] = []
    var del: [String] = []
    var from: Int?
    /// 发生时正在做计划的第几步、属于哪一版计划
    var step = 0
    var gen = 0
    var cmd: String?
    var out: [String] = []
    var ok: Bool?
    var url: String?
    var tab: String?
    var steps: [BrowserStep] = []
    var shot: String?
    var shotW: Int?
    var shotH: Int?
    var toolId: String?
    /// 发生的时间
    var at: Date?
    /// 结果回来、内容有变就加 1；比较只看编号和版本，截图很大不逐字比。
    var version = 0

    static func == (a: LiveEvent, b: LiveEvent) -> Bool { a.id == b.id && a.version == b.version }

    init(id: Int, piece: LivePiece, toolId: String?) {
        self.id = id
        kind = piece.kind; file = piece.file; lines = piece.lines; code = piece.code; del = piece.del; from = piece.from
        cmd = piece.cmd; url = piece.url; steps = piece.steps; self.toolId = toolId
    }

    /// 工具结果回来后补上输出 / 截图 / 标签页标题。
    mutating func absorb(_ r: ToolResult) {
        version += 1
        switch kind {
        case "run":
            out = Array(r.text.components(separatedBy: .newlines)
                .map { String($0.trimmingCharacters(in: .whitespaces).prefix(140)) }
                .filter { !$0.isEmpty }.suffix(6))
            ok = !r.isError
        case "browse":
            if let m = LiveParse.lastGroups(#"tabId [^:\s]+: "((?:[^"\\]|\\.)*)" \("([^"]*)"\)"#, in: r.text) {
                tab = m[0]
                if !m[1].isEmpty, m[1] != "data:" { url = m[1] }
            }
            if let m = LiveParse.lastGroups(#"coordinate frame: (\d+)x(\d+)"#, in: r.text)
                ?? LiveParse.lastGroups(#"Screenshot size: (\d+)x(\d+)"#, in: r.text) {
                shotW = Int(m[0]); shotH = Int(m[1])
            }
            // 用 ref 点击时输入里没有坐标，结果里有 "left_click at (x, y)"
            let at = LiveParse.allGroups(#"(?:left|right|double)_click at \((\d+), (\d+)\)"#, in: r.text)
            var k = 0
            for i in steps.indices where steps[i].kind == "click" && steps[i].x == nil && k < at.count {
                steps[i].x = Double(at[k][0]); steps[i].y = Double(at[k][1]); k += 1
            }
            if let img = r.image { shot = img }
            ok = !r.isError
        default:
            ok = !r.isError
        }
    }
}

enum LiveParse {
    /// tool_use → 动作细节。action 是 claudeTool 已经归好类的动作。
    static func piece(_ name: String, _ input: [String: Any], action: AgentAction) -> LivePiece? {
        switch action {
        case .read(let p):
            let offset = max(1, ((input["offset"] ?? input["StartLine"]) as? NSNumber)?.intValue ?? 1)
            return LivePiece(kind: "read", file: p, code: diskLines(p, from: offset, count: 10), from: offset)
        case .edit(let p), .create(let p):
            let first = (input["edits"] as? [[String: Any]])?.first
            let new = (input["new_string"] ?? input["content"] ?? input["new_source"] ?? input["Replacement"] ?? input["Content"] ?? input["ReplacementContent"] ?? input["CodeContent"]) as? String ?? first?["new_string"] as? String ?? ""
            let old = (input["old_string"] ?? input["Target"] ?? input["TargetContent"]) as? String ?? first?["old_string"] as? String ?? ""
            let lines = { (t: String) in t.isEmpty ? [] : Array(t.components(separatedBy: "\n").prefix(14)) }
            return LivePiece(kind: "edit", file: p, lines: ActivityParser.editLines(name, input), code: lines(new), del: lines(old))
        case .run(let c):
            return LivePiece(kind: "run", cmd: AgentSession.meaningfulCommand(c))
        case .search(let q):
            let cmd = name == "Grep" || name == "Glob" ? "搜索 \(q)" : AgentSession.meaningfulCommand(q)
            return LivePiece(kind: "run", cmd: cmd)
        case .web(let q):
            return LivePiece(kind: "web", url: q)
        case .browse(let url):
            return LivePiece(kind: "browse", url: url, steps: browserSteps(name, input))
        case .done:
            return LivePiece(kind: "done")
        case .think, .other:
            return nil
        }
    }

    /// 浏览器工具的输入 → 一串操作。browser_batch 里有多步。
    static func browserSteps(_ name: String, _ input: [String: Any]) -> [BrowserStep] {
        if name.hasSuffix("browser_batch"), let actions = input["actions"] as? [[String: Any]] {
            return actions.compactMap { a in step(a["name"] as? String ?? "", a["input"] as? [String: Any] ?? [:]) }
        }
        return step(name.components(separatedBy: "__").last ?? name, input).map { [$0] } ?? []
    }

    private static func step(_ name: String, _ input: [String: Any]) -> BrowserStep? {
        switch name {
        case "navigate":
            return BrowserStep(kind: "nav", text: input["url"] as? String)
        case "computer":
            let coord = (input["coordinate"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue }
            let (x, y) = coord.map { $0.count == 2 ? ($0[0], $0[1]) : (nil, nil) } ?? (nil, nil)
            switch input["action"] as? String ?? "" {
            case "left_click", "right_click", "double_click", "triple_click": return BrowserStep(kind: "click", x: x, y: y)
            case "type": return BrowserStep(kind: "type", text: input["text"] as? String)
            case "key": return BrowserStep(kind: "key", text: input["text"] as? String)
            case "scroll", "scroll_to": return BrowserStep(kind: "scroll", x: x, y: y)
            default: return nil
            }
        case "form_input":
            return BrowserStep(kind: "type", text: (input["value"] as? String) ?? (input["value"].map { "\($0)" }))
        case "find", "read_page", "get_page_text":
            return BrowserStep(kind: "read")
        default:
            return nil
        }
    }

    /// user 消息里的 tool_result → 结果列表（文字合起来，最后一张图转成 data URL）。
    static func results(_ parts: [[String: Any]]) -> [ToolResult] {
        parts.compactMap { part in
            guard part["type"] as? String == "tool_result", let id = part["tool_use_id"] as? String else { return nil }
            var text = "", image: String?
            if let s = part["content"] as? String { text = s }
            else if let list = part["content"] as? [[String: Any]] {
                for item in list {
                    if item["type"] as? String == "text", let t = item["text"] as? String { text += t + "\n" }
                    if item["type"] as? String == "image", let src = item["source"] as? [String: Any],
                       let data = src["data"] as? String {
                        image = "data:\(src["media_type"] as? String ?? "image/png");base64,\(data)"
                    }
                }
            }
            return ToolResult(toolId: id, text: text, image: image, isError: part["is_error"] as? Bool == true)
        }
    }

    /// 看文件时直接读磁盘上那几行。
    static func diskLines(_ path: String, from line: Int, count: Int = 6) -> [String] {
        guard path.hasPrefix("/"), let h = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: 64 * 1024)) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let lines = text.components(separatedBy: "\n")
        let start = max(0, min(lines.count - 1, line - 1))
        return Array(lines[start...].prefix(count))
    }

    static func lastGroups(_ pattern: String, in text: String) -> [String]? { allGroups(pattern, in: text).last }

    static func allGroups(_ pattern: String, in text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { m in
            (1..<m.numberOfRanges).map { i in Range(m.range(at: i), in: text).map { String(text[$0]) } ?? "" }
        }
    }
}
