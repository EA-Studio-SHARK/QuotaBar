import AppKit

@main
@MainActor
final class QuotaAppDelegate: NSObject, NSApplicationDelegate {
    private static var retainedDelegate: QuotaAppDelegate?

    static func main() {
        if CommandLine.arguments.contains("--dump-activity") {
            // 调试：打印当前识别到的 AI 会话后退出
            for s in ActivityScanner().scan() {
                let focus = s.focusFile.map { (s.focusIsEdit ? "改 " : "看 ") + $0 } ?? "-"
                print("\(s.kind.rawValue)\t\(s.projectName)\t\(s.stepText)\t\(focus)\t页面=\(s.page ?? "-")\t改过=\(s.recentEdits.count)\t计划=\(s.plan.filter { $0.status == "completed" }.count)/\(s.plan.count)\t实时=\(s.live.count):\(s.live.suffix(6).map { "\($0.kind)\($0.shot != nil ? "📷" : "")\($0.out.isEmpty ? "" : "→\($0.out.count)")" }.joined(separator: ","))\t\(Int(-s.updatedAt.timeIntervalSinceNow))s\tactive=\(s.isActive())")
            }
            exit(0)
        }
        if !SingleInstance.tryAcquire() {
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = QuotaAppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// 启动即挂载刘海、App 窗口与后台额度刷新，不在右上角菜单栏显示图标。
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let iconImg = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = iconImg
        }
        let activity = AgentActivityStore.shared
        activity.start()
        NotchController.shared.attach(activity)
        OrbitAppWindow.shared.attach(activity)
        UsageStore.shared.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        OrbitAppWindow.shared.show(select: nil)
        return true
    }
}
