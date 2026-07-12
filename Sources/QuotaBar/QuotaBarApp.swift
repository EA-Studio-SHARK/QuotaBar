import SwiftUI
import AppKit

@main
struct QuotaBarApp: App {
    @StateObject private var store = UsageStore()

    init() {
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
        Text(store.snapshot.menuTitle)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(menuColor)
            .onAppear { store.start() }
    }

    private var menuColor: Color {
        guard let w = store.snapshot.worstPercent else { return .primary }
        if w >= 90 { return Color(red: 0.62, green: 0.18, blue: 0.18) }
        if w >= 75 { return Color(red: 0.58, green: 0.39, blue: 0.0) }
        return .primary
    }
}

struct PopoverView: View {
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)

            VStack(spacing: 0) {
                ForEach(Array(store.snapshot.providers.enumerated()), id: \.element.id) { index, provider in
                    ProviderRow(usage: provider)
                    if index < store.snapshot.providers.count - 1 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.06))
                            .frame(height: 1)
                            .padding(.leading, 12)
                    }
                }
            }

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)

            footer
        }
        .frame(width: 280)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("用量")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(red: 0.12, green: 0.12, blue: 0.12))
            Spacer()
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Text(timeString(store.snapshot.fetchedAt))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(red: 0.47, green: 0.47, blue: 0.45))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Button("刷新") {
                Task { await store.refresh() }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(red: 0.12, green: 0.12, blue: 0.12))

            Toggle("登录启动", isOn: Binding(
                get: { store.launchAtLogin },
                set: { _ in store.toggleLaunchAtLogin() }
            ))
            .toggleStyle(.checkbox)
            .foregroundStyle(Color(red: 0.47, green: 0.47, blue: 0.45))

            Spacer()

            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(red: 0.47, green: 0.47, blue: 0.45))
        }
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

struct ProviderRow: View {
    let usage: ProviderUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(usage.kind.rawValue)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(red: 0.12, green: 0.12, blue: 0.12))
                Text(usage.kind.shortHint)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.52))
                Spacer(minLength: 8)
                Text(usage.displayPercent)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(percentColor)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                    Capsule(style: .continuous)
                        .fill(barColor)
                        .frame(width: max(4, geo.size.width * CGFloat((usage.primaryPercent ?? 0) / 100.0)))
                }
            }
            .frame(height: 3)
            .opacity(usage.primaryPercent == nil ? 0.35 : 1)

            Text(usage.summaryLine)
                .font(.system(size: 11))
                .foregroundStyle(Color(red: 0.47, green: 0.47, blue: 0.45))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var percentColor: Color {
        switch usage.status {
        case .critical: return Color(red: 0.62, green: 0.18, blue: 0.18)
        case .warning: return Color(red: 0.58, green: 0.39, blue: 0.0)
        case .ok: return Color(red: 0.12, green: 0.12, blue: 0.12)
        case .unavailable, .loading: return Color(red: 0.55, green: 0.55, blue: 0.52)
        }
    }

    private var barColor: Color {
        switch usage.status {
        case .critical: return Color(red: 0.62, green: 0.18, blue: 0.18).opacity(0.85)
        case .warning: return Color(red: 0.58, green: 0.39, blue: 0.0).opacity(0.8)
        default: return Color(red: 0.18, green: 0.18, blue: 0.18).opacity(0.75)
        }
    }
}
