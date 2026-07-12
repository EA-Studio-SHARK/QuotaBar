import Foundation
import AppKit
import UserNotifications

@MainActor
final class UsageStore: ObservableObject {
    @Published var snapshot: UsageSnapshot
    @Published var isRefreshing = false
    @Published var launchAtLogin: Bool
    @Published var lastError: String?

    private var timer: Timer?
    private var lastNotifiedBucket: [ProviderKind: Int] = [:]
    private let refreshInterval: TimeInterval = 180

    init() {
        self.snapshot = UsageSnapshot(
            providers: ProviderKind.allCases.map { .loading($0) },
            fetchedAt: Date()
        )
        self.launchAtLogin = LaunchAtLogin.isEnabled
        requestNotificationPermission()
    }

    func start() {
        Task { await refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        async let claude = ClaudeProvider.fetch()
        async let codex = CodexProvider.fetch()
        async let copilot = CopilotProvider.fetch()
        async let cursor = CursorProvider.fetch()
        async let grok = GrokProvider.fetch()
        let results = await [claude, codex, copilot, cursor, grok]

        snapshot = UsageSnapshot(providers: results, fetchedAt: Date())
        notifyIfNeeded(results)
    }

    func toggleLaunchAtLogin() {
        LaunchAtLogin.isEnabled.toggle()
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyIfNeeded(_ providers: [ProviderUsage]) {
        for p in providers {
            guard let percent = p.primaryPercent, percent >= 90 else { continue }
            let bucket = Int(percent / 5) * 5
            if lastNotifiedBucket[p.kind] == bucket { continue }
            lastNotifiedBucket[p.kind] = bucket

            let content = UNMutableNotificationContent()
            content.title = "\(p.kind.rawValue) 用量告警"
            content.body = String(format: "已使用 %.0f%%，注意额度。", percent)
            content.sound = .default
            let req = UNNotificationRequest(
                identifier: "quota-\(p.kind.rawValue)-\(bucket)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(req)
        }
    }
}

enum LaunchAtLogin {
    private static let label = "com.eakeji.QuotaBar"
    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        get { FileManager.default.fileExists(atPath: plistURL.path) }
        set {
            if newValue { enable() } else { disable() }
        }
    }

    private static func enable() {
        let exe = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/QuotaBar").path
        let program = FileManager.default.fileExists(atPath: exe)
            ? exe
            : CommandLine.arguments.first ?? exe

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [program],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        else { return }
        try? FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: plistURL)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["load", "-w", plistURL.path]
        try? p.run()
        p.waitUntilExit()
    }

    private static func disable() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["unload", "-w", plistURL.path]
        try? p.run()
        p.waitUntilExit()
        try? FileManager.default.removeItem(at: plistURL)
    }
}
