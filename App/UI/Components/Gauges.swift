import Charts
import SwiftUI

// MARK: - Rings

struct RingGauge: View {
    var fraction: Double
    var lineWidth: CGFloat
    var tint: Color

    var body: some View {
        let f = min(max(fraction, 0), 1)
        ZStack {
            Circle()
                .stroke(tint.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(f, 0.0001))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(f > 0 ? 1 : 0)
        }
        .padding(lineWidth / 2)
        .animation(.spring(duration: 0.9, bounce: 0.15), value: f)
    }
}

/// Activity-style concentric rings, outermost first.
struct ConcentricRings: View {
    var windows: [LimitWindow]
    var lineWidth: CGFloat
    var gap: CGFloat

    var body: some View {
        ZStack {
            ForEach(Array(windows.prefix(3).enumerated()), id: \.element.id) { index, window in
                RingGauge(fraction: window.fraction, lineWidth: lineWidth, tint: Theme.color(for: window))
                    .padding(CGFloat(index) * (lineWidth + gap))
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - Bars

struct LimitBar: View {
    var fraction: Double
    var tint: Color
    /// Tick showing how far through the window we are.
    var marker: Double? = nil
    var height: CGFloat = 6

    var body: some View {
        let f = min(max(fraction, 0), 1)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                if f > 0 {
                    Capsule().fill(tint).frame(width: max(height, geo.size.width * f))
                }
                if let marker {
                    Capsule()
                        .fill(.primary.opacity(0.45))
                        .frame(width: 2, height: height + 4)
                        .offset(x: geo.size.width * min(max(marker, 0), 1) - 1)
                }
            }
        }
        .frame(height: height)
        .animation(.spring(duration: 0.9, bounce: 0.15), value: f)
    }
}

/// A 100% stacked bar with 2pt surface gaps between segments.
struct ShareBar: View {
    struct Segment: Identifiable {
        var id: String
        var value: Double
        var color: Color
    }
    var segments: [Segment]
    var height: CGFloat = 10

    var body: some View {
        let visible = segments.filter { $0.value > 0 }
        let total = max(visible.reduce(0) { $0 + $1.value }, 0.0001)
        GeometryReader { geo in
            let available = geo.size.width - CGFloat(max(visible.count - 1, 0)) * 2
            HStack(spacing: 2) {
                ForEach(visible) { s in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(s.color)
                        .frame(width: max(3, available * s.value / total))
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

// MARK: - Sparkline

struct Sparkline: View {
    var values: [Double]
    var tint: Color

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { point in
            AreaMark(x: .value("i", point.offset), y: .value("v", point.element))
                .foregroundStyle(LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("i", point.offset), y: .value("v", point.element))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...max(values.max() ?? 1, 1))
        .chartLegend(.hidden)
    }
}

// MARK: - Small pieces

struct LegendDot: View {
    var color: Color
    var size: CGFloat = 8
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

struct StatusBadge: View {
    var status: LimitStatus
    var text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: status.symbol).foregroundStyle(status.color)
            Text(text).foregroundStyle(.primary)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(status.color.opacity(0.14)))
    }
}

/// "↑ 23% vs prev. 7 days" — neutral ink: more usage isn't good or bad.
struct DeltaLabel: View {
    var current: Double
    var previous: Double?
    var comparedTo: String

    var body: some View {
        if let previous, previous > 0 {
            let change = (current - previous) / previous
            if abs(change) < 0.005 {
                Text("Same as \(comparedTo)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
            HStack(spacing: 3) {
                Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 9, weight: .bold))
                Text("\(Int((abs(change) * 100).rounded()))%").fontWeight(.semibold)
                Text("vs \(comparedTo)").foregroundStyle(.tertiary)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            }
        } else {
            Text("No earlier data to compare")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }
}

struct ChartTooltip<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) { content }
            .font(.system(size: 11))
            .monospacedDigit()
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}

/// Hover tracking for Swift Charts on macOS (selection modifiers only react to clicks there).
struct ChartHover<Value: Plottable>: View {
    let proxy: ChartProxy
    @Binding var value: Value?

    var body: some View {
        GeometryReader { geo in
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        guard let plot = proxy.plotFrame else { return }
                        value = proxy.value(atX: point.x - geo[plot].origin.x, as: Value.self)
                    case .ended:
                        value = nil
                    }
                }
        }
    }
}
