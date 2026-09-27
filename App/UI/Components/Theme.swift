import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    /// A colour with separate light- and dark-mode steps.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

enum Theme {
    // Categorical palette, in slot order: blue → terracotta → violet → aqua. The order is validated
    // for colour-vision deficiency on adjacent pairs, light and dark, so anything drawn side by side
    // (rings, stacked bars) follows it. Colour follows the entity, never its rank.
    static let blue = Color(light: 0x2A78D6, dark: 0x3987E5)
    static let terracotta = Color(light: 0xD97757, dark: 0xD0694A)
    static let violet = Color(light: 0x4A3AA7, dark: 0x9085E9)
    static let aqua = Color(light: 0x1BAF7A, dark: 0x199E70)
    static let neutral = Color(light: 0xA3A29C, dark: 0x6B6A64)
    static let slots = [blue, terracotta, violet, aqua]

    static let brand = blue
    static let brandLight = Color(hex: 0x6DA7EC)
    static let brandDeep = Color(hex: 0x1C5CAB)

    // Status — reserved for state, always paired with an icon + label.
    static let warning = Color(hex: 0xFAB219)
    static let critical = Color(hex: 0xD03B3B)
    static let good = Color(hex: 0x0CA30C)

    // Surfaces
    static let canvas = Color(light: 0xF5F4F0, dark: 0x161615)
    static let card = Color(light: 0xFFFFFF, dark: 0x1F1F1D)
    static let cardStroke = Color(light: 0xE7E5DF, dark: 0x2C2C29)
    static let track = Color(light: 0xECEAE4, dark: 0x2E2E2B)

    /// Identity colour for a plan limit.
    static func color(for window: LimitWindow) -> Color {
        if window.isSession { return blue }
        if window.id == "seven_day" { return terracotta }
        return window.id.contains("scoped") || window.id.hasPrefix("seven_day_") ? violet : aqua
    }

    /// Identity colour for a model (e.g. "Opus 5.5"), from `ModelPalette`.
    static func modelColor(_ name: String) -> Color { ModelPalette.color(for: name) }

    /// Claude products in the weekly breakdown, in slot order (draw them in this order).
    static let productOrder = ["claude_code", "chat", "cowork"]

    static func productColor(_ key: String) -> Color {
        productOrder.firstIndex(of: key).map { slots[$0] } ?? neutral
    }
}

// MARK: - Model colours

/// Gives the four most relevant models a palette slot and remembers the assignment, so a model keeps
/// its colour across launches and filters. Everything else is folded into a neutral "Other".
enum ModelPalette {
    static let other = "Other"
    private static let key = "modelColorOrder"
    private static var order: [String] = UserDefaults.standard.stringArray(forKey: key) ?? []

    static func color(for name: String) -> Color {
        guard let index = order.firstIndex(of: name), index < Theme.slots.count else { return Theme.neutral }
        return Theme.slots[index]
    }

    static func hasSlot(_ name: String) -> Bool {
        order.firstIndex(of: name).map { $0 < Theme.slots.count } ?? false
    }

    /// `ranked`: the models to colour, most important first (e.g. this week's, then this month's).
    /// Models no longer in use release their slot; models that keep a slot keep their colour.
    static func update(ranked: [String], persist: Bool = true) {
        var wanted: [String] = []
        for name in ranked where !wanted.contains(name) && wanted.count < Theme.slots.count { wanted.append(name) }
        // Keep existing assignments in place; newcomers take the freed slots.
        var next = [String?](repeating: nil, count: Theme.slots.count)
        for (i, name) in order.prefix(Theme.slots.count).enumerated() where wanted.contains(name) { next[i] = name }
        var newcomers = wanted.filter { !next.contains($0) }
        for i in next.indices where next[i] == nil && !newcomers.isEmpty { next[i] = newcomers.removeFirst() }
        let result = next.map { $0 ?? "" }
        guard result != Array(order.prefix(Theme.slots.count)) else { return }
        order = result
        if persist { UserDefaults.standard.set(order, forKey: key) }
    }

    /// Folds models without a colour into "Other", so charts never show several look-alike greys.
    static func fold(_ models: [NamedUsage]) -> [NamedUsage] {
        var kept = models.filter { hasSlot($0.name) }
        let rest = models.filter { !hasSlot($0.name) }
        if !rest.isEmpty {
            var usage = UsageSlice()
            rest.forEach { usage += $0.usage }
            kept.append(NamedUsage(name: other, usage: usage))
        }
        return kept
    }
}

// MARK: - Status

enum LimitStatus {
    case ok, warning, critical

    init(_ window: LimitWindow, now: Date = Date()) {
        if window.utilization >= 90 { self = .critical }
        else if window.utilization >= 75 || window.pace(at: now)?.hitsLimitIn != nil { self = .warning }
        else { self = .ok }
    }

    var color: Color { self == .critical ? Theme.critical : Theme.warning }
    var symbol: String { self == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill" }

    /// Menu bar ring colour: brand while fine, then the status colour.
    static func menuBarColor(for window: LimitWindow) -> NSColor {
        switch LimitStatus(window) {
        case .ok: NSColor(Theme.brand)
        case .warning: NSColor(Theme.warning)
        case .critical: NSColor(Theme.critical)
        }
    }
}

// MARK: - App mark

/// The app's mark: a ring gauge, about three-quarters full, on a blue tile.
struct AppMark: View {
    var size: CGFloat = 26
    var spinning = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(LinearGradient(colors: [Theme.brandLight, Theme.brandDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
            ZStack {
                Circle().stroke(.white.opacity(0.3), lineWidth: size * 0.12)
                Circle()
                    .trim(from: 0, to: 0.72)
                    .stroke(.white, style: StrokeStyle(lineWidth: size * 0.12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .padding(size * 0.24)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(spinning ? .linear(duration: 1.4).repeatForever(autoreverses: false) : .default, value: spinning)
        }
        .frame(width: size, height: size)
    }
}
