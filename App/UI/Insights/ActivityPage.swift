import Charts
import SwiftUI

struct ActivityPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageHeader(title: "Activity", subtitle: subtitle)
            if let summary = model.summary, let local = model.snapshot.local {
                KPIRow(summary: summary, previous: model.previousSummary)
                InsightCard(title: summary.range == .today ? "Tokens by hour" : "Tokens by day",
                            subtitle: summary.range == .today ? "Today, by hour of day" : "Stacked by model") {
                    TokensChart(summary: summary)
                        .frame(height: 230)
                }
                HStack(alignment: .top, spacing: 18) {
                    InsightCard(title: "Weekly rhythm", subtitle: "When you work with Claude Code · last 4 weeks") {
                        RhythmHeatmap(grid: local.rhythm())
                    }
                    InsightCard(title: "Models", subtitle: "Share of tokens") {
                        ModelDonut(models: ModelPalette.fold(summary.models))
                    }
                    .frame(width: 340)
                }
                .fixedSize(horizontal: false, vertical: true)
                TokenMixCard(summary: summary)
            } else {
                InsightCard {
                    EmptyCardMessage(symbol: "terminal", text: "Reading your Claude Code logs…")
                }
            }
        }
    }

    private var subtitle: String {
        guard let local = model.snapshot.local else { return "Claude Code activity from your local logs" }
        return "Claude Code activity from your local logs · \(local.filesScanned) session files · costs at API list prices"
    }
}

// MARK: - KPIs

private struct KPIRow: View {
    var summary: PeriodSummary
    var previous: PeriodSummary?

    var body: some View {
        let daily = summary.range == .today ? summary.hours.map(Double.init) : summary.days.map { Double($0.tokens.total) }
        let costs = summary.range == .today ? nil : summary.days.map(\.cost)
        let replies = summary.range == .today ? nil : summary.days.map { Double($0.messages) }
        HStack(spacing: 14) {
            KPITile(label: "Tokens", value: Fmt.tokens(summary.tokens.total),
                    current: Double(summary.tokens.total), previous: previous.map { Double($0.tokens.total) },
                    comparedTo: summary.range.previousLabel, spark: daily)
            KPITile(label: "API value", value: Fmt.cost(summary.cost),
                    current: summary.cost, previous: previous?.cost,
                    comparedTo: summary.range.previousLabel, spark: costs)
            KPITile(label: "Replies", value: summary.messages.formatted(),
                    current: Double(summary.messages), previous: previous.map { Double($0.messages) },
                    comparedTo: summary.range.previousLabel, spark: replies)
            KPITile(label: "Cache hit rate", value: "\(Int((summary.tokens.cacheHitRate * 100).rounded()))%",
                    current: summary.tokens.cacheHitRate, previous: previous?.tokens.cacheHitRate,
                    comparedTo: summary.range.previousLabel, spark: nil,
                    footnote: "Saved ≈ \(Fmt.cost(summary.cacheSavings)) vs. uncached")
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct KPITile: View {
    var label: String
    var value: String
    var current: Double
    var previous: Double?
    var comparedTo: String
    var spark: [Double]?
    var footnote: String?

    var body: some View {
        InsightCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                HStack(alignment: .bottom) {
                    Text(value)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Spacer(minLength: 6)
                    if let spark, spark.count > 1, spark.contains(where: { $0 > 0 }) {
                        Sparkline(values: spark, tint: Theme.brand).frame(width: 64, height: 26)
                    }
                }
                if let footnote {
                    Text(footnote).font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    DeltaLabel(current: current, previous: previous, comparedTo: comparedTo)
                }
            }
        }
    }
}

// MARK: - Tokens chart

private struct TokensChart: View {
    var summary: PeriodSummary
    @State private var hoverDate: Date?
    @State private var hoverHour: Int?

    private struct Segment: Identifiable {
        var day: Date
        var model: String
        var start: Double
        var end: Double
        var isTop: Bool
        var id: String { "\(day.timeIntervalSince1970)-\(model)" }
    }

    /// A day's tokens per model, with models that have no colour summed under "Other".
    private func foldedTokens(_ day: DayStat) -> [String: Int] {
        var out: [String: Int] = [:]
        for (name, usage) in day.models {
            out[ModelPalette.hasSlot(name) ? name : ModelPalette.other, default: 0] += usage.tokens
        }
        return out
    }

    /// Stacks each day's models by hand so segments get a surface gap and only the top one is rounded.
    private func segments(names: [String]) -> [Segment] {
        let gap = Double(summary.days.map(\.tokens.total).max() ?? 0) * 0.012
        return summary.days.flatMap { day -> [Segment] in
            let tokens = foldedTokens(day)
            let present = names.filter { (tokens[$0] ?? 0) > 0 }
            var base = 0.0
            return present.enumerated().compactMap { index, name in
                let value = Double(tokens[name] ?? 0)
                let isTop = index == present.count - 1
                defer { base += value }
                let end = base + value - (isTop ? 0 : gap)
                return end > base ? Segment(day: day.day, model: name, start: base, end: end, isTop: isTop) : nil
            }
        }
    }

    var body: some View {
        if summary.range == .today { hourly } else { daily }
    }

    private var hourly: some View {
        let peak = summary.hours.max() ?? 0
        return Chart {
            ForEach(0..<24, id: \.self) { h in
                BarMark(x: .value("Hour", h), y: .value("Tokens", summary.hours[h]), width: .ratio(0.7))
                    .foregroundStyle(hoverHour == nil || hoverHour == h ? Theme.brand : Theme.brand.opacity(0.35))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
            }
            if let h = hoverHour, (0..<24).contains(h) {
                RuleMark(x: .value("Hour", h))
                    .foregroundStyle(.clear)
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartTooltip {
                            Text("\(Fmt.hour(h)) – \(Fmt.hour((h + 1) % 24))").foregroundStyle(.secondary)
                            Text("\(Fmt.tokens(summary.hours[h])) tokens").fontWeight(.semibold)
                        }
                    }
            }
        }
        .chartXScale(domain: -0.5...23.5)
        .chartXAxis {
            AxisMarks(values: Array(stride(from: 0, to: 24, by: 3))) { value in
                AxisValueLabel { if let h = value.as(Int.self) { Text(Fmt.hour(h)) } }
            }
        }
        .chartYAxis { tokenAxis }
        .chartYScale(domain: 0...max(peak, 1))
        .chartOverlay { proxy in
            ChartHover(proxy: proxy, value: Binding(get: { hoverHour.map(Double.init) },
                                                    set: { hoverHour = $0.map { Int($0.rounded()) } }))
        }
    }

    private var daily: some View {
        let names = ModelPalette.fold(summary.models).map(\.name)
        let rows = segments(names: names)
        let hoveredDay = hoverDate.map { Calendar.current.startOfDay(for: $0) }
        let hovered = summary.days.first { $0.day == hoveredDay }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ForEach(names, id: \.self) { name in
                    HStack(spacing: 5) {
                        LegendDot(color: Theme.modelColor(name), size: 7)
                        Text(name)
                    }
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Chart {
                ForEach(rows) { row in
                    BarMark(x: .value("Day", row.day, unit: .day),
                            yStart: .value("Tokens", row.start), yEnd: .value("Tokens", row.end), width: .ratio(0.72))
                        .foregroundStyle(by: .value("Model", row.model))
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: row.isTop ? 4 : 0, topTrailingRadius: row.isTop ? 4 : 0))
                        .opacity(hoveredDay == nil || hoveredDay == row.day ? 1 : 0.4)
                }
                if let hovered {
                    RuleMark(x: .value("Day", hovered.day, unit: .day))
                        .foregroundStyle(.clear)
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            ChartTooltip {
                                Text(hovered.day, format: .dateTime.weekday(.wide).month().day()).foregroundStyle(.secondary)
                                let tokens = foldedTokens(hovered)
                                ForEach(names.filter { tokens[$0] != nil }, id: \.self) { name in
                                    HStack(spacing: 5) {
                                        LegendDot(color: Theme.modelColor(name), size: 6)
                                        Text(name)
                                        Spacer(minLength: 10)
                                        Text(Fmt.tokens(tokens[name] ?? 0)).fontWeight(.semibold)
                                    }
                                }
                                Divider()
                                HStack {
                                    Text("Total")
                                    Spacer(minLength: 10)
                                    Text("\(Fmt.tokens(hovered.tokens.total)) · \(Fmt.cost(hovered.cost))").fontWeight(.semibold)
                                }
                            }
                            .frame(width: 210)
                        }
                }
            }
            .chartForegroundStyleScale(domain: names, range: names.map(Theme.modelColor))
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: summary.range == .month ? 5 : 1)) { _ in
                    AxisValueLabel(format: summary.range == .month ? .dateTime.month(.abbreviated).day() : .dateTime.weekday(.abbreviated))
                }
            }
            .chartYAxis { tokenAxis }
            .chartOverlay { ChartHover(proxy: $0, value: $hoverDate) }
        }
    }

    private var tokenAxis: some AxisContent {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
            AxisGridLine().foregroundStyle(Color.secondary.opacity(0.15))
            AxisValueLabel {
                if let v = value.as(Double.self) { Text(Fmt.tokens(Int(v))) } else if let v = value.as(Int.self) { Text(Fmt.tokens(v)) }
            }
        }
    }
}

// MARK: - Rhythm heatmap

private struct RhythmHeatmap: View {
    var grid: [[Int]]   // Mon…Sun × 24h
    @State private var hovered: (row: Int, hour: Int)?
    private let weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        let peak = max(grid.flatMap { $0 }.max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let h = hovered {
                    Text("\(weekdays[h.row]) \(Fmt.hour(h.hour)) – \(Fmt.hour((h.hour + 1) % 24))").foregroundStyle(.secondary)
                    Text("\(Fmt.tokens(grid[h.row][h.hour])) tokens").fontWeight(.semibold)
                } else if let busiest {
                    Text("Busiest:").foregroundStyle(.secondary)
                    Text("\(weekdays[busiest.row]) around \(Fmt.hour(busiest.hour))").fontWeight(.semibold)
                }
                Spacer()
            }
            .font(.system(size: 11.5))
            .monospacedDigit()

            Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                ForEach(0..<7, id: \.self) { row in
                    GridRow {
                        Text(weekdays[row])
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, alignment: .leading)
                        ForEach(0..<24, id: \.self) { hour in
                            let v = grid[row][hour]
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(v == 0 ? Theme.track : Theme.brand.opacity(0.18 + 0.82 * sqrt(Double(v) / Double(peak))))
                                .overlay {
                                    if hovered?.row == row && hovered?.hour == hour {
                                        RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.primary, lineWidth: 1.5)
                                    }
                                }
                                .aspectRatio(1, contentMode: .fit)
                                .onHover { inside in
                                    if inside { hovered = (row, hour) } else if hovered?.row == row && hovered?.hour == hour { hovered = nil }
                                }
                        }
                    }
                }
                GridRow {
                    Color.clear.frame(width: 26, height: 1)
                    ForEach(0..<24, id: \.self) { hour in
                        Text(hour % 6 == 0 ? Fmt.hour(hour) : "")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            HStack(spacing: 6) {
                Text("Less")
                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { f in
                    RoundedRectangle(cornerRadius: 2).fill(f == 0 ? Theme.track : Theme.brand.opacity(0.18 + 0.82 * f)).frame(width: 10, height: 10)
                }
                Text("More")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
    }

    private var busiest: (row: Int, hour: Int)? {
        var best: (row: Int, hour: Int, v: Int)?
        for r in 0..<7 { for h in 0..<24 where grid[r][h] > (best?.v ?? 0) { best = (r, h, grid[r][h]) } }
        return best.map { ($0.row, $0.hour) }
    }
}

// MARK: - Models

private struct ModelDonut: View {
    var models: [NamedUsage]

    var body: some View {
        let total = max(models.reduce(0) { $0 + $1.usage.tokens }, 1)
        VStack(spacing: 16) {
            ZStack {
                Chart(models) { m in
                    SectorMark(angle: .value("Tokens", m.usage.tokens), innerRadius: .ratio(0.64), angularInset: 1.5)
                        .cornerRadius(4)
                        .foregroundStyle(Theme.modelColor(m.name))
                }
                .chartLegend(.hidden)
                VStack(spacing: 0) {
                    Text(Fmt.tokens(total)).font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("tokens").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .frame(height: 150)

            VStack(spacing: 8) {
                ForEach(models) { m in
                    HStack(spacing: 8) {
                        LegendDot(color: Theme.modelColor(m.name))
                        Text(m.name).font(.system(size: 12))
                        Spacer()
                        Text("\(Int((Double(m.usage.tokens) / Double(total) * 100).rounded()))%")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                        Text(Fmt.cost(m.usage.cost))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .frame(width: 58, alignment: .trailing)
                    }
                    .monospacedDigit()
                }
            }
        }
    }
}

// MARK: - Token mix

private struct TokenMixCard: View {
    var summary: PeriodSummary

    var body: some View {
        let t = summary.tokens
        let parts: [(key: String, label: String, value: Int, color: Color, note: String)] = [
            ("input", "Fresh input", t.input, Theme.blue, "New, uncached prompt tokens"),
            ("output", "Output", t.output, Theme.terracotta, "What Claude wrote, including thinking"),
            ("write", "Cache writes", t.cacheWrite, Theme.violet, "Context stored for reuse"),
            ("read", "Cache reads", t.cacheRead, Theme.aqua, "Context reused from cache (cheapest)"),
        ]
        InsightCard(title: "Token mix", subtitle: "What your \(Fmt.tokens(t.total)) tokens were made of") {
            VStack(alignment: .leading, spacing: 16) {
                ShareBar(segments: parts.map { .init(id: $0.key, value: Double($0.value), color: $0.color) }, height: 14)
                HStack(alignment: .top, spacing: 0) {
                    ForEach(parts, id: \.key) { p in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                LegendDot(color: p.color)
                                Text(p.label).font(.system(size: 12, weight: .medium))
                            }
                            Text(Fmt.tokens(p.value))
                                .font(.system(size: 18, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                            Text(p.note).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: "bolt.badge.checkmark").foregroundStyle(Theme.brand)
                    Text("Prompt caching saved about \(Text(Fmt.cost(summary.cacheSavings)).fontWeight(.semibold)) at API list prices this period.")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
        }
    }
}
