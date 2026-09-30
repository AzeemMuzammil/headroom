import Charts
import SwiftUI

struct OverviewPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let limits = model.limits
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "Overview", subtitle: headerSubtitle(now: now))

                if let issue = limits.issue {
                    IssueCard(issue: issue)
                }

                if limits.windows.isEmpty {
                    InsightCard {
                        EmptyCardMessage(symbol: "gauge.with.dots.needle.0percent",
                                         text: model.limitsSource == .off
                                            ? "Plan limits are off. Turn them on in Settings."
                                            : "Your plan limits will appear here.")
                    }
                } else {
                    LimitsHero(windows: limits.windows, now: now)
                    HStack(alignment: .top, spacing: 18) {
                        if let session = limits.session {
                            InsightCard(title: "Session", subtitle: "Usage across the current 5-hour window") {
                                BurnChart(windows: [session], now: now)
                            }
                        }
                        if !limits.weekly.isEmpty {
                            InsightCard(title: "This week", subtitle: "Usage across the current 7-day window") {
                                BurnChart(windows: limits.weekly, now: now)
                            }
                        }
                    }
                    .frame(height: 300)
                }

                HStack(alignment: .top, spacing: 18) {
                    if !limits.breakdown.isEmpty {
                        InsightCard(title: "Where this week went", subtitle: "Share of your weekly limit by product") {
                            BreakdownView(shares: limits.breakdown)
                        }
                    }
                    TodayCard()
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func headerSubtitle(now: Date) -> String {
        var parts: [String] = []
        if let plan = model.planName { parts.append("\(plan) plan") }
        parts.append("updated \(Fmt.ago(model.lastUpdated, now: now))")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Hero

private struct LimitsHero: View {
    var windows: [LimitWindow]
    var now: Date

    var body: some View {
        InsightCard {
            HStack(alignment: .center, spacing: 36) {
                ConcentricRings(windows: windows, lineWidth: 20, gap: 5)
                    .frame(width: 190, height: 190)
                    .padding(.leading, 6)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(windows.prefix(3).enumerated()), id: \.element.id) { index, window in
                        if index > 0 { Divider().padding(.vertical, 12) }
                        HeroLimitRow(window: window, now: now)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }
}

private struct HeroLimitRow: View {
    var window: LimitWindow
    var now: Date

    var body: some View {
        let status = LimitStatus(window, now: now)
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    LegendDot(color: Theme.color(for: window), size: 9)
                    Text(window.isSession ? "Current session" : "Weekly · \(window.title)")
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 16)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            if let pace = window.pace(at: now) {
                paceLabel(pace, status: status)
            }

            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(Int(window.utilization.rounded()))")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .contentTransition(.numericText(value: window.utilization))
                Text("%").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .frame(width: 84, alignment: .trailing)
        }
    }

    private var detail: String {
        if window.isSession && !window.isActive { return "No active session — starts with your next message" }
        guard let resets = window.resetsAt else { return "No reset scheduled" }
        return "\(Fmt.resetsIn(resets, now: now)) · \(Fmt.clock(resets, now: now))"
    }

    @ViewBuilder
    private func paceLabel(_ pace: LimitWindow.Pace, status: LimitStatus) -> some View {
        if let hits = pace.hitsLimitIn {
            StatusBadge(status: status == .ok ? .warning : status, text: "Limit in ~\(Fmt.duration(hits)) at this pace")
        } else {
            // Full sentence when there's room, a short form when the window is narrow.
            ViewThatFits(in: .horizontal) {
                Label("On pace for ~\(Int(pace.projected.rounded()))% by reset", systemImage: "speedometer")
                    .fixedSize()
                Label("~\(Int(pace.projected.rounded()))% by reset", systemImage: "speedometer")
                    .fixedSize()
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Burn chart

/// Actual usage over the window, against an even-pace guide and a forecast to the reset.
struct BurnChart: View {
    @Environment(AppModel.self) private var model
    var windows: [LimitWindow]
    var now: Date
    @State private var hover: Date?

    var body: some View {
        if let first = windows.first, let start = first.windowStart, let reset = first.resetsAt, first.isActive {
            let lines = windows.map { ($0, model.series(for: $0, now: now)) }
            let peak = max(100, lines.flatMap { $0.1.map(\.value) }.max() ?? 0)
            VStack(alignment: .leading, spacing: 18) {
                legend(multi: windows.count > 1)
                Chart {
                    // Even pace: 0% at the start → 100% at the reset.
                    ForEach([HistoryPoint(date: start, value: 0), HistoryPoint(date: reset, value: 100)]) { p in
                        LineMark(x: .value("Time", p.date), y: .value("Used", p.value), series: .value("Series", "pace"))
                            .foregroundStyle(Color.secondary.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 4]))
                    }

                    ForEach(lines, id: \.0.id) { window, points in
                        let color = Theme.color(for: window)
                        if windows.count == 1 {
                            ForEach(points) { p in
                                AreaMark(x: .value("Time", p.date), y: .value("Used", p.value))
                                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.22), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                                    .interpolationMethod(.monotone)
                            }
                        }
                        ForEach(points) { p in
                            LineMark(x: .value("Time", p.date), y: .value("Used", p.value), series: .value("Series", window.id))
                                .foregroundStyle(color)
                                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                                .interpolationMethod(.monotone)
                        }
                        if let forecast = forecast(for: window, reset: reset) {
                            ForEach([HistoryPoint(date: now, value: window.utilization), forecast]) { p in
                                LineMark(x: .value("Time", p.date), y: .value("Used", p.value), series: .value("Series", "\(window.id)-forecast"))
                                    .foregroundStyle(color.opacity(0.6))
                                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 4]))
                            }
                        }
                        PointMark(x: .value("Time", now), y: .value("Used", window.utilization))
                            .foregroundStyle(color)
                            .symbolSize(60)
                    }

                    RuleMark(x: .value("Now", now))
                        .foregroundStyle(Color.secondary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .top, alignment: .center, spacing: 2) {
                            Text("now").font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
                        }

                    if let hover, hover >= start, hover <= now {
                        RuleMark(x: .value("Hover", hover))
                            .foregroundStyle(Color.primary.opacity(0.25))
                            .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                ChartTooltip {
                                    Text(Fmt.dateTime(hover, windowIsWeek: first.isWeekly)).foregroundStyle(.secondary)
                                    ForEach(lines, id: \.0.id) { window, points in
                                        if let value = points.last(where: { $0.date <= hover })?.value {
                                            HStack(spacing: 5) {
                                                LegendDot(color: Theme.color(for: window), size: 6)
                                                Text(windows.count > 1 ? window.title : "Used")
                                                Spacer(minLength: 8)
                                                Text(Fmt.percent(value)).fontWeight(.semibold)
                                            }
                                        }
                                    }
                                }
                            }
                    }
                }
                .chartXScale(domain: start...reset)
                .chartYScale(domain: 0...peak)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                        AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
                        AxisValueLabel { if let v = value.as(Int.self) { Text("\(v)%") } }
                    }
                }
                .chartXAxis {
                    if first.isWeekly {
                        AxisMarks(values: .stride(by: .day)) { _ in
                            AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                        }
                    } else {
                        AxisMarks(values: .stride(by: .hour)) { _ in
                            AxisValueLabel(format: .dateTime.hour())
                        }
                    }
                }
                .chartLegend(.hidden)
                .chartOverlay { ChartHover(proxy: $0, value: $hover) }

                if lines.allSatisfy({ $0.1.count < 3 }) {
                    Text("The line fills in as the app records your usage over time.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            EmptyCardMessage(symbol: "moon.zzz", text: "No active window — it starts with your next message.")
        }
    }

    private func forecast(for window: LimitWindow, reset: Date) -> HistoryPoint? {
        guard let pace = window.pace(at: now), window.utilization < 100 else { return nil }
        if let hits = pace.hitsLimitIn { return HistoryPoint(date: now.addingTimeInterval(hits), value: 100) }
        return HistoryPoint(date: reset, value: pace.projected)
    }

    private func legend(multi: Bool) -> some View {
        HStack(spacing: 14) {
            if multi {
                ForEach(windows) { w in
                    HStack(spacing: 5) {
                        LegendDot(color: Theme.color(for: w), size: 7)
                        Text(w.title)
                    }
                }
            } else if let w = windows.first {
                HStack(spacing: 5) {
                    LegendDot(color: Theme.color(for: w), size: 7)
                    Text("Used")
                }
            }
            HStack(spacing: 5) {
                Capsule().fill(Color.secondary.opacity(0.6)).frame(width: 12, height: 2)
                Text("Forecast")
            }
            HStack(spacing: 5) {
                Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 12, height: 1)
                Text("Even pace")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

// MARK: - Breakdown & today

private struct BreakdownView: View {
    var shares: [UsageShare]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Segments in palette order (so neighbouring colours stay distinguishable), not by size.
            let ordered = shares.sorted { (Theme.productOrder.firstIndex(of: $0.key) ?? 99) < (Theme.productOrder.firstIndex(of: $1.key) ?? 99) }
            ShareBar(segments: ordered.map { .init(id: $0.key, value: $0.percent, color: Theme.productColor($0.key)) }, height: 12)
            VStack(spacing: 9) {
                ForEach(shares.sorted { $0.percent > $1.percent }) { share in
                    HStack(spacing: 8) {
                        LegendDot(color: Theme.productColor(share.key))
                        Text(share.name).font(.system(size: 12))
                        Spacer()
                        Text("\(Int(share.percent.rounded()))%")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                }
            }
        }
    }
}

private struct TodayCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        InsightCard(title: "Claude Code today", subtitle: "From your local session logs") {
            Button("Activity") { model.page = .activity }
                .controlSize(.small)
        } content: {
            if let today = model.today {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 24) {
                        MiniStat(label: "Tokens", value: Fmt.tokens(today.tokens.total))
                        MiniStat(label: "API value", value: Fmt.cost(today.cost))
                        MiniStat(label: "Replies", value: "\(today.messages)")
                    }
                    if let days = model.snapshot.local?.days.suffix(14) {
                        Sparkline(values: days.map { Double($0.tokens.total) }, tint: Theme.brand)
                            .frame(height: 44)
                        Text("Daily tokens · last 14 days").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                }
            } else {
                EmptyCardMessage(symbol: "terminal", text: "Reading your Claude Code logs…")
            }
        }
    }
}

struct MiniStat: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }
}

private struct IssueCard: View {
    @Environment(AppModel.self) private var model
    var issue: LimitsState.Issue

    var body: some View {
        let tint = issue.isInformational ? Theme.brand : Theme.warning
        HStack(spacing: 10) {
            Image(systemName: issue.isInformational ? "info.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(tint)
            Text(issue.message).font(.system(size: 12))
            Spacer()
            if issue.kind == .keychainDenied {
                Button("Retry") { Task { await model.refresh(force: true) } }
            } else if issue.kind == .apiChanged {
                Button("Copy API Response") { model.copyLastResponse() }
            } else if issue.kind == .setupNeeded {
                Button("Open Settings") { model.page = .settings }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.12)))
    }
}
