import Foundation

// MARK: - Plan limits (from the usage endpoint)

struct LimitWindow: Codable, Hashable, Identifiable {
    var id: String              // "five_hour", "seven_day", "weekly_scoped:fable", …
    var title: String
    var utilization: Double     // percent, 0...100 (can exceed 100)
    var resetsAt: Date?
    var windowLength: TimeInterval?

    var fraction: Double { max(0, utilization / 100) }
    var isSession: Bool { id == "five_hour" }
    var isWeekly: Bool { windowLength == 7 * 86_400 }
    var isActive: Bool { utilization > 0 || resetsAt != nil }
    var windowStart: Date? {
        guard let resetsAt, let windowLength else { return nil }
        return resetsAt.addingTimeInterval(-windowLength)
    }

    /// The window as of `now`: once its reset time has passed, it's back to 0% (the data we hold
    /// may be older than the reset, e.g. after a night with no refresh).
    func current(at now: Date) -> LimitWindow {
        guard let resetsAt, resetsAt <= now else { return self }
        var w = self
        w.utilization = 0
        w.resetsAt = nil
        return w
    }

    /// How far through the window we are (0...1), if the window length and reset time are known.
    func elapsedFraction(at now: Date) -> Double? {
        guard let resetsAt, let windowLength, windowLength > 0 else { return nil }
        return min(1, max(0, 1 - resetsAt.timeIntervalSince(now) / windowLength))
    }

    struct Pace: Hashable {
        var projected: Double           // percent you'd reach at reset if you keep going like this
        var hitsLimitIn: TimeInterval?  // set when you're on course to run out before reset
    }

    func pace(at now: Date) -> Pace? {
        guard let e = elapsedFraction(at: now), e > 0.03, let windowLength, utilization > 0 else { return nil }
        let projected = utilization / e
        guard projected > 100, utilization < 100 else { return Pace(projected: projected, hitsLimitIn: nil) }
        let ratePerSecond = utilization / (e * windowLength)
        return Pace(projected: projected, hitsLimitIn: (100 - utilization) / ratePerSecond)
    }
}

/// Share of the weekly limit used by each Claude product ("Claude Code 94%").
struct UsageShare: Codable, Hashable, Identifiable {
    var key: String
    var name: String
    var percent: Double
    var id: String { key }
}

struct LimitsState: Codable, Hashable {
    var windows: [LimitWindow] = []
    var breakdown: [UsageShare] = []
    var plan: String?
    var fetchedAt: Date?
    var issue: Issue?

    struct Issue: Codable, Hashable {
        enum Kind: String, Codable {
            case setupNeeded, waitingForClaudeCode
            case notLoggedIn, keychainDenied, tokenExpired, unauthorized, forbidden, rateLimited, apiChanged, network
        }
        var isInformational: Bool { kind == .waitingForClaudeCode }
        var kind: Kind
        var message: String
    }

    var session: LimitWindow? { windows.first { $0.isSession } }
    var weekly: [LimitWindow] { windows.filter { !$0.isSession } }

    /// Windows whose reset time has passed shown as reset.
    func current(at now: Date) -> LimitsState {
        var s = self
        s.windows = windows.map { $0.current(at: now) }
        return s
    }
}

// MARK: - Limit history (recorded by the app on every refresh)

struct LimitSample: Codable, Hashable {
    var t: Date
    var v: [String: Double]     // window id → utilization
}

struct HistoryPoint: Hashable, Identifiable {
    var date: Date
    var value: Double
    var id: Date { date }
}

// MARK: - Local Claude Code activity (from ~/.claude/projects logs)

struct TokenCounts: Codable, Hashable {
    var input = 0
    var output = 0
    var cacheWrite = 0
    var cacheRead = 0

    var total: Int { input + output + cacheWrite + cacheRead }

    /// Share of prompt tokens that were served from cache.
    var cacheHitRate: Double {
        let prompt = input + cacheWrite + cacheRead
        return prompt > 0 ? Double(cacheRead) / Double(prompt) : 0
    }

    static func += (lhs: inout TokenCounts, rhs: TokenCounts) {
        lhs.input += rhs.input
        lhs.output += rhs.output
        lhs.cacheWrite += rhs.cacheWrite
        lhs.cacheRead += rhs.cacheRead
    }
}

struct UsageSlice: Codable, Hashable {
    var tokens = 0
    var cost = 0.0
    var messages = 0
    var lastActive: Date?

    static func += (lhs: inout UsageSlice, rhs: UsageSlice) {
        lhs.tokens += rhs.tokens
        lhs.cost += rhs.cost
        lhs.messages += rhs.messages
        lhs.lastActive = [lhs.lastActive, rhs.lastActive].compactMap { $0 }.max()
    }
}

struct DayStat: Codable, Hashable, Identifiable {
    var day: Date
    var tokens = TokenCounts()
    var cost = 0.0
    var messages = 0
    var cacheSavings = 0.0
    var hours = [Int](repeating: 0, count: 24)      // tokens per hour of day
    var models: [String: UsageSlice] = [:]
    var projects: [String: UsageSlice] = [:]
    var id: Date { day }
}

struct LocalStats: Codable, Hashable {
    var days: [DayStat] = []    // oldest first, one per calendar day
    var scannedAt = Date()
    var filesScanned = 0
    /// Creation date of the oldest log file: how far back the logs go (Claude Code prunes old ones).
    var coverageStart: Date?
}

enum LocalRange: String, CaseIterable, Identifiable, Codable {
    case today, week, month
    var id: String { rawValue }
    var days: Int { switch self { case .today: 1; case .week: 7; case .month: 30 } }
    var label: String { switch self { case .today: "Today"; case .week: "7 Days"; case .month: "30 Days" } }
    var previousLabel: String { switch self { case .today: "yesterday"; case .week: "prev. 7 days"; case .month: "prev. 30 days" } }
}

struct NamedUsage: Hashable, Identifiable {
    var name: String
    var usage: UsageSlice
    var id: String { name }
}

struct PeriodSummary {
    var range: LocalRange
    var days: [DayStat]
    var tokens = TokenCounts()
    var cost = 0.0
    var messages = 0
    var cacheSavings = 0.0
    var hours = [Int](repeating: 0, count: 24)
    var models: [NamedUsage] = []
    var projects: [NamedUsage] = []
}

extension LocalStats {
    /// Totals for a range. `periodsAgo: 1` gives the period before it (for deltas); nil when the
    /// logs don't reach back that far (Claude Code prunes old transcripts).
    func summary(_ range: LocalRange, periodsAgo: Int = 0, now: Date = Date()) -> PeriodSummary? {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        guard let end = cal.date(byAdding: .day, value: 1 - range.days * periodsAgo, to: today),
              let start = cal.date(byAdding: .day, value: -range.days, to: end) else { return nil }
        if periodsAgo > 0 {
            guard let coverageStart, coverageStart <= start.addingTimeInterval(86_400) else { return nil }
        }

        var s = PeriodSummary(range: range, days: days.filter { $0.day >= start && $0.day < end })
        var models: [String: UsageSlice] = [:], projects: [String: UsageSlice] = [:]
        for d in s.days {
            s.tokens += d.tokens
            s.cost += d.cost
            s.messages += d.messages
            s.cacheSavings += d.cacheSavings
            for h in 0..<24 { s.hours[h] += d.hours[h] }
            for (k, v) in d.models { models[k, default: UsageSlice()] += v }
            for (k, v) in d.projects { projects[k, default: UsageSlice()] += v }
        }
        s.models = models.map { NamedUsage(name: $0.key, usage: $0.value) }.sorted { $0.usage.tokens > $1.usage.tokens }
        s.projects = projects.map { NamedUsage(name: $0.key, usage: $0.value) }.sorted { $0.usage.tokens > $1.usage.tokens }
        return s
    }

    /// Tokens by weekday (Mon…Sun) × hour over the last `lastDays` days (a whole number of weeks,
    /// so every weekday is counted equally often).
    func rhythm(lastDays: Int = 28, now: Date = Date()) -> [[Int]] {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -(lastDays - 1), to: cal.startOfDay(for: now))!
        var grid = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        for d in days where d.day >= start {
            let row = (cal.component(.weekday, from: d.day) + 5) % 7     // Monday = 0
            for h in 0..<24 { grid[row][h] += d.hours[h] }
        }
        return grid
    }
}

// MARK: - Snapshot (persisted between launches)

struct UsageSnapshot: Codable, Hashable {
    var limits = LimitsState()
    var local: LocalStats?
}
