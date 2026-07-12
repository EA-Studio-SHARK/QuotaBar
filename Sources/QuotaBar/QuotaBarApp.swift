import SwiftUI
import AppKit

@main
struct QuotaBarApp: App {
    @StateObject private var store = UsageStore()

    init() {
        // 开机启动 / 重复 open 时可能拉起第二个进程；已有实例则立刻退出。
        if !SingleInstance.tryAcquire() {
            exit(0)
        }
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        let worst = store.snapshot.worstPercent
        let color: Color = {
            guard let w = worst else { return .primary }
            if w >= 90 { return .red }
            if w >= 75 { return .orange }
            return .primary
        }()

        HStack(spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.67percent")
            Text(store.snapshot.menuTitle)
                .monospacedDigit()
        }
        .foregroundStyle(color)
        .onAppear { store.start() }
    }
}

struct PopoverView: View {
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AI 用量")
                    .font(.headline)
                Spacer()
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(timeString(store.snapshot.fetchedAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(store.snapshot.providers) { provider in
                        ProviderCard(usage: provider)
                    }
                }
            }
            .frame(maxHeight: 420)

            Divider()

            HStack(spacing: 12) {
                Button("刷新") {
                    Task { await store.refresh() }
                }
                .keyboardShortcut("r")

                Toggle("开机启动", isOn: Binding(
                    get: { store.launchAtLogin },
                    set: { _ in store.toggleLaunchAtLogin() }
                ))
                .toggleStyle(.checkbox)

                Spacer()

                Button("退出") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .font(.caption)
        }
        .padding(14)
        .frame(width: 300)
        .background(.background)
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}

struct ProviderCard: View {
    let usage: ProviderUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(usage.kind.rawValue)
                    .font(.subheadline.weight(.semibold))
                Text(usage.kind.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(usage.displayPercent)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(statusColor)
            }

            if let p = usage.primaryPercent {
                ProgressView(value: min(max(p, 0), 100), total: 100)
                    .tint(statusColor)
            }

            if usage.status == .unavailable || usage.status == .loading {
                Text(usage.errorMessage ?? (usage.status == .loading ? "加载中…" : "不可用"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(usage.metrics.enumerated()), id: \.offset) { _, m in
                    HStack(alignment: .firstTextBaseline) {
                        Text(m.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 72, alignment: .leading)
                        if let p = m.percent {
                            Text(String(format: "%.0f%%", p))
                                .font(.caption.monospacedDigit())
                                .frame(width: 36, alignment: .trailing)
                        }
                        Text(m.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                }
                if let err = usage.errorMessage {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var statusColor: Color {
        switch usage.status {
        case .critical: return .red
        case .warning: return .orange
        case .ok: return .accentColor
        case .unavailable, .loading: return .secondary
        }
    }
}
