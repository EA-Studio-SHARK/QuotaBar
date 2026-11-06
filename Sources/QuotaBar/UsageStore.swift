import Foundation
import AppKit
import UserNotifications

@MainActor
final class UsageStore: ObservableObject {
    /// 菜单栏额度和 Orbit 窗口共用一份。
    static let shared = UsageStore()

    @Published var snapshot: UsageSnapshot
    @Published var isRefreshing = false
    @Published var launchAtLogin: Bool
    @Published var lastError: String?

    private var timer: Timer?
    private var appLaunchObserver: Any?
    private var lastNotifiedBucket: [ProviderKind: Int] = [:]
    private var lastSuccessful: [ProviderKind: ProviderUsage] = [:]
    private let refreshInterval: TimeInterval = 180

    init() {
        self.snapshot = UsageSnapshot(
            providers: ProviderDiscovery.installed().map { .loading($0) },
            fetchedAt: Date()
        )
        self.launchAtLogin = LaunchAtLogin.isEnabled
        if let data = try? Data(contentsOf: diagnosticsDirectory.appendingPathComponent("last-success.json")) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let saved = try? decoder.decode([ProviderUsage].self, from: data) {
                for usage in saved where usage.status == .ok || usage.status == .warning || usage.status == .critical {
                    lastSuccessful[usage.kind] = usage
                }
            }
        }
        requestNotificationPermission()
    }

    func start() {
        guard timer == nil else { return }
        Task { await refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
        appLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let current = self.snapshot.providers.map(\.kind)
                if ProviderDiscovery.installed() != current {
                    await self.refresh()
                }
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

        let installed = ProviderDiscovery.installed()
        snapshot.providers = installed.map { kind in
            snapshot.providers.first(where: { $0.kind == kind }) ?? .loading(kind)
        }
        await withTaskGroup(of: ProviderUsage.self) { group in
            for kind in installed {
                group.addTask { await kind.fetchUsage() }
            }
            for await result in group {
                if result.status != .unavailable { lastSuccessful[result.kind] = result }
                if let index = snapshot.providers.firstIndex(where: { $0.kind == result.kind }) {
                    snapshot.providers[index] = result.retaining(lastSuccessful[result.kind])
                }
                persistDiagnostics()
                notifyIfNeeded([result])
            }
        }
        snapshot.fetchedAt = Date()
        persistDiagnostics()
    }

    private func persistDiagnostics() {
        // Local status only: provider responses and credentials are never stored.
        let directory = diagnosticsDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: directory.appendingPathComponent("last-status.json"), options: .atomic)
            let successful = try encoder.encode(lastSuccessful.values.sorted { $0.kind.rawValue < $1.kind.rawValue })
            try successful.write(to: directory.appendingPathComponent("last-success.json"), options: .atomic)
        } catch {
            lastError = "本机诊断记录保存失败：\(error.localizedDescription)"
        }
    }

    private var diagnosticsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QuotaBar", isDirectory: true)
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
            guard let percent = p.primaryPercent else { continue }
            if percent < 90 {
                lastNotifiedBucket.removeValue(forKey: p.kind)
                continue
            }
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
    private static let label = "com.orbit.QuotaBar"
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
            "ProgramArguments": [program, "--background"],
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
