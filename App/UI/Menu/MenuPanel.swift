import SwiftUI

/// The menu bar popover: answers "how much is left, and when does it reset?" at a glance.
/// Everything else lives in the Insights window.
struct MenuPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var panel: NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if model.needsSetup {
                SetupPrompt { open(.overview) }
            } else {
                if let issue = model.limits.issue {
                    IssueRow(issue: issue) { open(.settings) }
                }
                if model.limitsSource != .off {
                    LimitsGlance()
                    Divider().opacity(0.6)
                }
            }
            TodayRow()
            footer
        }
        .padding(16)
        .frame(width: 320)
        .background(WindowReader { panel = $0 })
    }

    private var header: some View {
        HStack(spacing: 9) {
            AppMark(size: 22, spinning: model.isRefreshing)
            Text("Headroom").font(.system(size: 14, weight: .semibold))
            if let plan = model.planName {
                PlanBadge(plan: plan)
            }
            Spacer()
            Menu {
                Button("Refresh Now") { Task { await model.refresh(force: true) } }
                    .keyboardShortcut("r")
                Button("Settings…") { open(.settings) }
                    .keyboardShortcut(",")
                Divider()
                Button("Quit Headroom") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .fixedSize()
        }
    }

    private var footer: some View {
        HStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(model.isRefreshing ? "Refreshing…" : "Updated \(Fmt.ago(model.lastUpdated, now: context.date))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                open(.overview)
            } label: {
                Label("Insights", systemImage: "chart.xyaxis.line")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(Theme.brand)
            .keyboardShortcut("i")
        }
    }

    private func open(_ page: InsightsPage) {
        model.page = page
        // The popover only auto-closes on outside clicks, so close it ourselves.
        dismiss()
        panel?.close()
        openWindow(id: "insights")
        NSApp.activate()
    }
}

// MARK: - Limits

private struct LimitsGlance: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let windows = model.limits.windows
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if windows.isEmpty {
                // The issue row above explains why; only show progress while nothing is wrong.
                if model.limits.issue == nil {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Loading your plan limits…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 60)
                }
            } else {
                HStack(alignment: .center, spacing: 18) {
                    ConcentricRings(windows: windows, lineWidth: 11, gap: 3)
                        .frame(width: 104, height: 104)
                    VStack(alignment: .leading, spacing: 11) {
                        ForEach(windows.prefix(3)) { window in
                            LimitLine(window: window, now: context.date)
                        }
                    }
                }
                if let alert = alertText(windows, now: context.date) {
                    StatusBadge(status: alert.status, text: alert.text)
                }
            }
        }
    }

    /// The single most urgent thing, if anything needs attention.
    private func alertText(_ windows: [LimitWindow], now: Date) -> (status: LimitStatus, text: String)? {
        let urgent = windows
            .map { ($0, LimitStatus($0, now: now)) }
            .filter { $0.1 != .ok }
            .sorted { $0.0.utilization > $1.0.utilization }
            .first
        guard let (window, status) = urgent else { return nil }
        if let hits = window.pace(at: now)?.hitsLimitIn {
            return (status, "\(window.title): limit in ~\(Fmt.duration(hits)) at this pace")
        }
        return (status, "\(window.title) is at \(Fmt.percent(window.utilization))")
    }
}

private struct LimitLine: View {
    var window: LimitWindow
    var now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                LegendDot(color: Theme.color(for: window), size: 7)
                Text(window.isSession ? "Session" : window.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(Fmt.percent(window.utilization))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: window.utilization))
            }
            Text(subtitle)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .padding(.leading, 13)
        }
    }

    private var subtitle: String {
        if window.isSession && !window.isActive { return "Starts with your next message" }
        guard let resets = window.resetsAt else { return "No reset scheduled" }
        return window.isSession ? Fmt.resetsIn(resets, now: now) : "Resets \(Fmt.clock(resets, now: now))"
    }
}

// MARK: - Today

private struct TodayRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude Code today")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let today = model.today {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(Fmt.tokens(today.tokens.total))
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                        Text("tokens").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.tertiary)
                        Text(Fmt.cost(today.cost))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                    .monospacedDigit()
                } else {
                    Text("Reading logs…").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let days = model.snapshot.local?.days.suffix(14), days.contains(where: { $0.tokens.total > 0 }) {
                Sparkline(values: days.map { Double($0.tokens.total) }, tint: Theme.brand)
                    .frame(width: 92, height: 30)
                    .help("Daily tokens, last 14 days")
            }
        }
    }
}

// MARK: - Pieces

struct PlanBadge: View {
    var plan: String
    var body: some View {
        Text(plan.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(0.4)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.brand.opacity(0.15)))
            .foregroundStyle(Theme.brand)
    }
}

private struct IssueRow: View {
    @Environment(AppModel.self) private var model
    var issue: LimitsState.Issue
    var openSettings: () -> Void

    var body: some View {
        let tint = issue.isInformational ? Theme.brand : Theme.warning
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: issue.isInformational ? "info.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
            Text(issue.message)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if issue.kind == .keychainDenied {
                Button("Retry") { Task { await model.refresh(force: true) } }
                    .controlSize(.small)
            } else if issue.kind == .setupNeeded {
                Button("Set Up", action: openSettings)
                    .controlSize(.small)
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.12)))
    }
}

private struct SetupPrompt: View {
    var action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Welcome! Choose how Headroom gets your plan limits to finish setting up.")
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Button(action: action) {
                Text("Set Up Headroom").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.brand)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.brand.opacity(0.1)))
    }
}

/// Hands back the NSWindow hosting a view (here: the menu bar popover's panel).
private struct WindowReader: NSViewRepresentable {
    var onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(view.window) }
    }
}
