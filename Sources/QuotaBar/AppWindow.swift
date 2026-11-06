import AppKit
import Combine
import WebKit

// MARK: - 点刘海打开的 App 窗口：左边会话和额度，右边选中会话的进度、现在在做什么、这一步的经过

@MainActor
final class OrbitAppWindow: NSObject, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = OrbitAppWindow()

    private var window: NSWindow?
    private var web: WKWebView?
    private weak var activity: AgentActivityStore?
    private var observers: [AnyCancellable] = []
    private var loaded = false
    private var lastJSON = ""
    private var selected: String?
    private var sentShot: String?

    func attach(_ activity: AgentActivityStore) {
        guard self.activity == nil else { return }
        self.activity = activity
        observers = [
            activity.$now.sink { [weak self] _ in Task { @MainActor in self?.push() } },
            UsageStore.shared.$snapshot.sink { [weak self] _ in Task { @MainActor in self?.push(force: true) } },
        ]
    }

    func show(select id: String?) {
        if let id { selected = id }
        NSApp.setActivationPolicy(.regular)
        if window == nil { build() }
        if loaded, let id { web?.evaluateJavaScript("window.app && window.app.select(\(Self.js(id)))") }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        push(force: true)
    }

    private func build() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "app")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1060, height: 680), configuration: config)
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Orbit"
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.isMovableByWindowBackground = true
        window.contentView = web
        window.minSize = NSSize(width: 820, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        if !window.setFrameUsingName("OrbitAppMain") { window.center() }
        window.setFrameAutosaveName("OrbitAppMain")
        if let url = Self.pageURL() { web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
        self.window = window
        self.web = web
        applyAppearance()
    }

    func applyAppearance() {
        switch OrbitSettings.theme {
        case "light":
            window?.appearance = NSAppearance(named: .aqua)
        case "dark":
            window?.appearance = NSAppearance(named: .darkAqua)
        default:
            window?.appearance = nil
        }
    }

    private static func pageURL() -> URL? {
        if let url = Bundle.main.url(forResource: "app", withExtension: "html") { return url }
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../orbit-panel/app.html").standardizedFileURL
        return FileManager.default.fileExists(atPath: src.path) ? src : nil
    }

    private static func js(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]), let s = String(data: data, encoding: .utf8) else { return "null" }
        return String(s.dropFirst().dropLast())
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        lastJSON = ""
        sentShot = nil
        let isFS = window?.styleMask.contains(.fullScreen) == true
        web?.evaluateJavaScript("window.app && window.app.setFullscreen && window.app.setFullscreen(\(isFS))")
        if let selected { web?.evaluateJavaScript("window.app && window.app.select(\(Self.js(selected)))") }
        push(force: true)
    }

    func refreshSettings() {
        push(force: true)
    }

    /// 窗口开着时每秒看一次，变了才推。
    private func push(force: Bool = false) {
        guard loaded, let activity, let web, window?.isVisible == true else { return }
        let now = activity.now
        let sessions = activity.sessions.prefix(8).map { OrbitFeed.session($0, now: now, detail: true) }
        let payload: [String: Any] = [
            "sessions": sessions,
            "quota": OrbitFeed.quota(UsageStore.shared.snapshot),
            "settings": OrbitSettings.payload,
        ]
        let json = Self.js(payload)
        if force || json != lastJSON {
            lastJSON = json
            web.evaluateJavaScript("window.app && window.app.update(\(json))")
        }
        // 选中会话的网页截图：变了才单独送
        let sel = selected.flatMap { id in activity.sessions.first { $0.id == id } } ?? activity.sessions.first
        if let s = sel, let (key, url) = OrbitFeed.shot(s), sentShot != s.id + key {
            sentShot = s.id + key
            web.evaluateJavaScript("window.app && window.app.shot(\(Self.js(s.id)), \(Self.js(key)), \(Self.js(url)))")
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let session = (body["id"] as? String).flatMap { id in activity?.sessions.first { $0.id == id } }
        switch type {
        case "select":
            selected = body["id"] as? String
            sentShot = nil
            push()
        case "jump":
            if let session { ActivityActions.jumpToSession(session) }
        case "open":
            if let session, let key = body["path"] as? String {
                NSWorkspace.shared.open(URL(fileURLWithPath: OrbitKey.resolve(key, cwd: session.cwd)))
            }
        case "openProject":
            if let cwd = session?.cwd {
                NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
            }
        case "copyImage":
            if let dataURL = body["data"] as? String,
               let comma = dataURL.firstIndex(of: ","),
               let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
               let img = NSImage(data: data) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([img])
            }
        case "saveImage":
            if let dataURL = body["data"] as? String,
               let comma = dataURL.firstIndex(of: ","),
               let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) {
                let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
                let outURL = desktop.appendingPathComponent("Orbit-战报-\(Int(Date().timeIntervalSince1970)).png")
                try? data.write(to: outURL)
                NSWorkspace.shared.activateFileViewerSelecting([outURL])
            }
        case "page":
            if let url = (body["url"] as? String).flatMap({ URL(string: $0.contains("://") ? $0 : "http://" + $0) }) {
                NSWorkspace.shared.open(url)
            }
        case "refresh":
            Task { await UsageStore.shared.refresh() }
        case "setting":
            if let key = body["key"] as? String, let val = body["value"] {
                OrbitSettings.apply(key: key, value: val)
            }
        case "fullscreen":
            window?.toggleFullScreen(nil)
        default:
            break
        }
    }

    func windowDidBecomeKey(_ notification: Notification) { push(force: true) }

    func windowDidEnterFullScreen(_ notification: Notification) {
        web?.evaluateJavaScript("window.app && window.app.setFullscreen && window.app.setFullscreen(true)")
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        web?.evaluateJavaScript("window.app && window.app.setFullscreen && window.app.setFullscreen(false)")
    }

    /// 关掉就整个拆掉，网页里的小人动画不在后台耗电；再打开重新建。
    func windowWillClose(_ notification: Notification) {
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "app")
        window?.delegate = nil
        window = nil
        web = nil
        loaded = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if self.window == nil {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
