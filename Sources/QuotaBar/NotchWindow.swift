import AppKit
import Combine
import WebKit

// MARK: - 刘海：没人干活时缩进硬件刘海，有会话在跑或等你时才从两侧长出来

/// 默认缩在硬件刘海里。有会话在干活 / 等你时两侧长出耳朵；做完或等你时往下弹一下。
/// 窗口只盖住当前样子那么大，别处的点击照常落到菜单栏和桌面上。
@MainActor
final class NotchController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = NotchController()

    private var panel: NotchPanel?
    private var web: WKWebView?
    private weak var activity: AgentActivityStore?
    private var observer: AnyCancellable?
    private var quotaObserver: AnyCancellable?
    private var screenObserver: Any?
    private var clickMonitor: Any?
    private var loaded = false
    private var lastJSON = ""
    private var state = "collapsed"
    private var prevPhases: [String: String] = [:]

    func attach(_ activity: AgentActivityStore) {
        guard self.activity == nil else { return }
        self.activity = activity
        build()
        observer = activity.$now.sink { [weak self] _ in
            Task { @MainActor in self?.push() }
        }
        quotaObserver = UsageStore.shared.$snapshot.sink { [weak self] _ in
            Task { @MainActor in self?.push(force: true) }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resize(self?.lastSize ?? .zero) }
        }
    }

    // MARK: 刘海位置

    /// 有刘海的屏幕（内建屏）优先；外接屏没有刘海，就在顶部正中假装一个。
    private var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    /// 刘海本身的宽高（点）。
    private var notch: NSSize {
        guard let screen else { return NSSize(width: 180, height: 32) }
        if screen.safeAreaInsets.top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            return NSSize(width: screen.frame.width - l.width - r.width, height: screen.safeAreaInsets.top)
        }
        return NSSize(width: 180, height: max(24, screen.frame.maxY - screen.visibleFrame.maxY))
    }

    private func build() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "notch")
        let web = NotchWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        if let url = Self.pageURL() { web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }

        let panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // 盖在菜单栏之上，所有桌面、全屏应用里都在
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.contentView = web
        panel.acceptsMouseMovedEvents = true
        self.panel = panel
        self.web = web
        // 启动先贴齐硬件刘海；没人干活时保持缩进去，有会话再由页面把耳朵长出来
        resize(NSSize(width: notch.width, height: notch.height))
        panel.orderFrontRegardless()
    }

    private var lastSize: NSSize = .zero

    /// 窗口贴着屏幕顶边、以刘海为中心。
    private func resize(_ size: NSSize) {
        guard let panel, let screen, size.width > 0 else { return }
        lastSize = size
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        panel.setFrame(frame.integral, display: true)
    }

    private static func pageURL() -> URL? {
        if let url = Bundle.main.url(forResource: "notch", withExtension: "html") { return url }
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../orbit-panel/notch.html").standardizedFileURL
        return FileManager.default.fileExists(atPath: src.path) ? src : nil
    }

    // MARK: 推数据

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        let n = notch
        web?.evaluateJavaScript("window.notch && window.notch.setup({w:\(n.width),h:\(n.height)})")
        push(force: true)
    }

    func refreshSettings() {
        push(force: true)
    }

    private func push(force: Bool = false) {
        guard loaded, let activity else { return }
        let now = activity.now
        let list = OrbitFeed.visible(activity.sessions, now: now).prefix(6)
        let rows = list.map { OrbitFeed.session($0, now: now, detail: false) }
        let quota = OrbitFeed.quota(UsageStore.shared.snapshot)

        var shouldChime = false
        for s in list {
            let ph = OrbitFeed.phase(s, now: now)
            if let old = prevPhases[s.id], old == "work", (ph == "done" || ph == "need") {
                shouldChime = true
            }
            prevPhases[s.id] = ph
        }
        if shouldChime && OrbitSettings.soundAlert {
            NSSound(named: NSSound.Name("Glass"))?.play()
        }

        let payload: [String: Any] = [
            "rows": rows,
            "quota": quota,
            "settings": OrbitSettings.payload,
            "time": OrbitFeed.clock.string(from: now),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              var json = String(data: data, encoding: .utf8) else { return }
        json = json.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        guard force || json != lastJSON else { return }
        lastJSON = json
        web?.evaluateJavaScript("window.notch && window.notch.update(\(json))")
        sendShots(Array(list))
    }

    /// 网页截图很大，只在变了的时候单独送一次（小浏览器里显示）。
    private var sentShots: [String: String] = [:]
    private func sendShots(_ sessions: [AgentSession]) {
        for s in sessions {
            guard let (key, url) = OrbitFeed.shot(s), sentShots[s.id] != key else { continue }
            sentShots[s.id] = key
            let id = (try? JSONSerialization.data(withJSONObject: [s.id, key, url])).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            web?.evaluateJavaScript("window.notch && window.notch.shot(...\(id))")
        }
    }

    // MARK: 页面回来的消息

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let session = (body["id"] as? String).flatMap { id in activity?.sessions.first { $0.id == id } }
        switch type {
        case "size":
            // 页面换样子前后告诉这里要多大
            if let w = body["w"] as? Double, let h = body["h"] as? Double { resize(NSSize(width: w, height: h)) }
            if let st = body["state"] as? String { setState(st) }
        case "app":
            OrbitAppWindow.shared.show(select: session?.id)
            collapse()
        case "jump":
            if let session { ActivityActions.jumpToSession(session) }
            collapse()
        case "refresh":
            Task { await UsageStore.shared.refresh() }
        case "setting":
            if let key = body["key"] as? String, let val = body["value"] {
                OrbitSettings.apply(key: key, value: val)
            }
        default:
            break
        }
    }

    private func setState(_ st: String) {
        state = st
        // 展开时，点刘海以外的地方就收起
        if st == "expanded", clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.collapse() }
            }
        } else if st != "expanded", let m = clickMonitor {
            NSEvent.removeMonitor(m)
            clickMonitor = nil
        }
    }

    private func collapse() {
        web?.evaluateJavaScript("window.notch && window.notch.collapse()")
    }
}

/// 刘海窗口不抢焦点，第一下点击也要算数；鼠标进出也要知道（网页自己在非焦点窗口里收不到）。
final class NotchWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        evaluateJavaScript("window.notch && window.notch.hover(true)")
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        evaluateJavaScript("window.notch && window.notch.hover(false)")
    }
}

/// 不抢焦点的面板，但点得到。
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - 一句人话

extension AgentSession {
    /// 正在干的事，用人话说：不出现原始命令。
    var humanText: String {
        let name = { (p: String) in (p as NSString).lastPathComponent }
        switch action {
        case .read(let p): return "在看 " + name(p)
        case .edit(let p): return "正在改 " + name(p)
        case .create(let p): return "新建 " + name(p)
        case .run(let c): return Self.humanCommand(c)
        case .search: return "在代码里找东西"
        case .browse: return page.map { "在操作网页 " + $0 } ?? "在操作浏览器"
        case .web: return "在网上查资料"
        case .think: return "在想下一步"
        case .done: return doneText
        case .other(let n): return n == "派出子任务" ? n : "在用 " + n
        }
    }

    var doneText: String {
        let n = editCounts.count
        return n > 0 ? "做完了 · 改了 \(n) 个文件" : "做完了"
    }

    /// 一串命令里真正干活的那一段：跳过 `X=值` 赋值、sleep、cd、export。
    static func primaryCommand(_ cmd: String) -> String {
        let c = meaningfulCommand(cmd)
        let lines = c.components(separatedBy: .newlines)
        for line in lines {
            for seg in line.components(separatedBy: ";").flatMap({ $0.components(separatedBy: "&&") }) {
                var toks = seg.split(separator: " ").map(String.init)
                while let f = toks.first, f.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil { toks.removeFirst() }
                guard let head = toks.first, !["sleep", "cd", "export", "set", "true", ":"].contains(head) else { continue }
                return toks.joined(separator: " ")
            }
        }
        return c
    }

    /// 命令翻译成人话：测试、编译、装依赖、git、脚本……认不出的只说是哪个工具。
    static func humanCommand(_ cmd: String) -> String {
        let c = primaryCommand(cmd).lowercased()
        let head = (c.split(separator: " ").first.map(String.init) ?? "")
        let has = { (words: [String]) in words.contains { c.contains($0) } }
        if has(["pytest", "swift test", "npm test", "npm run test", "jest", "vitest", "go test", "cargo test", "xcodebuild test", "unittest"]) { return "在跑测试" }
        if has(["build", "make", "xcodebuild", "tsc", "webpack", "vite build", "cargo b"]) { return "在编译打包" }
        if has(["pip install", "pip3 install", "npm install", "npm i ", "pnpm add", "pnpm install", "yarn add", "brew install", "cargo add", "go get"]) { return "在装依赖" }
        if has(["install.sh", "install_app", "make install"]) { return "在安装程序" }
        if head == "git" || head == "gh" { return "在处理代码提交" }
        if head == "curl" || head == "wget" { return "在请求接口" }
        if has(["screencapture", "--screenshot", "headless"]) { return "在截图检查" }
        if has(["open ", "pkill", "killall", "launchctl"]) { return "在启动程序" }
        if ["osascript", "cliclick"].contains(head) { return "在操作界面" }
        if ["python", "python3", "node", "ruby", "swift", "bash", "sh", "zsh", "for", "while", "if"].contains(head)
            || head.hasPrefix("./") || head.hasPrefix("/") || head.hasPrefix("$") || head.hasSuffix(".sh") || head.hasSuffix(".py") { return "在跑脚本" }
        if ["rm", "mv", "cp", "mkdir", "ln", "chmod"].contains(head) { return "在整理文件" }
        if ["sleep", "ps", "pgrep", "lsof", "top"].contains(head) { return "在看程序状态" }
        return head.isEmpty ? "在跑命令" : "在跑 " + head
    }
}
