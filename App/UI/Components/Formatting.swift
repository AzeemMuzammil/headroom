import Foundation

enum Fmt {
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return trim(d / 1_000) + "K"
        case ..<1_000_000_000: return trim(d / 1_000_000) + "M"
        default: return trim(d / 1_000_000_000) + "B"
        }
    }

    private static func trim(_ v: Double) -> String {
        v >= 100 ? String(format: "%.0f", v) : v >= 10 ? String(format: "%.1f", v) : String(format: "%.2f", v)
    }

    static func cost(_ v: Double) -> String {
        if v >= 1_000 { return "$" + String(format: "%.1fK", v / 1_000) }
        if v >= 100 { return String(format: "$%.0f", v) }
        return String(format: "$%.2f", v)
    }

    static func percent(_ utilization: Double) -> String {
        "\(Int(utilization.rounded()))%"
    }

    /// "1h 42m", "3d 4h", "12m", "<1m"
    static func duration(_ t: TimeInterval) -> String {
        guard t.isFinite else { return "–" }
        let s = Int(max(0, min(t, 365 * 86_400)))
        let d = s / 86_400, h = (s % 86_400) / 3_600, m = (s % 3_600) / 60
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return m > 0 ? "\(m)m" : "<1m"
    }

    static func resetsIn(_ date: Date?, now: Date) -> String {
        guard let date else { return "No reset scheduled" }
        let t = date.timeIntervalSince(now)
        return t <= 0 ? "Resetting now" : "Resets in \(duration(t))"
    }

    /// "3:40 PM" today, "Mon 9:00 AM" otherwise.
    static func clock(_ date: Date, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate(Calendar.current.isDate(date, inSameDayAs: now) ? "jmm" : "EEE jmm")
        return f.string(from: date)
    }

    static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        let t = now.timeIntervalSince(date)
        if t < 10 { return "just now" }
        if t < 60 { return "\(Int(t))s ago" }
        return "\(duration(t)) ago"
    }

    /// "14:00" / "2 PM" per locale.
    static func hour(_ h: Int) -> String {
        let date = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }

    /// Tooltip timestamp: "Tue 14:20" for weekly charts, "14:20" for session charts.
    static func dateTime(_ date: Date, windowIsWeek: Bool) -> String {
        windowIsWeek ? date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
                     : date.formatted(.dateTime.hour().minute())
    }

    /// "Today", "Yesterday", "3 days ago".
    static func relativeDay(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day ?? 0
        return "\(days) days ago"
    }

    /// "claude-opus-5-5" → "Opus 5.5", "claude-sonnet-4-5-20250929" → "Sonnet 4.5", "claude-3-5-haiku-20241022" → "Haiku 3.5"
    static func modelName(_ id: String) -> String {
        let families = ["opus", "sonnet", "haiku", "fable", "mythos"]
        let parts = id.lowercased().split(separator: "-").map(String.init).filter { $0 != "claude" }
        guard let family = parts.first(where: { families.contains($0) }) else { return id }
        let version = parts.filter { $0.allSatisfy(\.isNumber) && $0.count <= 2 }.joined(separator: ".")
        return family.capitalized + (version.isEmpty ? "" : " \(version)")
    }
}
