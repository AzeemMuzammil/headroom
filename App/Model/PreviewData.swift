import Foundation

/// Deterministic sample data for `--demo` and `--render-preview`.
enum PreviewData {
    @MainActor
    static func model(now: Date = Date()) -> AppModel {
        let (snapshot, history) = make(now: now)
        let account = ClaudeAccount(name: "Alex Rivera", email: "alex@example.com", organization: nil, plan: "Max 20×")
        return AppModel(preview: snapshot, history: history, account: account)
    }

    static func make(now: Date) -> (UsageSnapshot, [LimitSample]) {
        let session = LimitWindow(id: "five_hour", title: "Current session", utilization: 62,
                                  resetsAt: now.addingTimeInterval(1.6 * 3600), windowLength: 5 * 3600)
        let week = LimitWindow(id: "seven_day", title: "All models", utilization: 41,
                               resetsAt: now.addingTimeInterval(3.3 * 86_400), windowLength: 7 * 86_400)
        let fable = LimitWindow(id: "weekly_scoped:fable", title: "Fable", utilization: 18,
                                resetsAt: now.addingTimeInterval(3.3 * 86_400), windowLength: 7 * 86_400)

        var snapshot = UsageSnapshot()
        snapshot.limits = LimitsState(
            windows: [session, week, fable],
            breakdown: [UsageShare(key: "claude_code", name: "Claude Code", percent: 86),
                        UsageShare(key: "cowork", name: "Cowork", percent: 9),
                        UsageShare(key: "chat", name: "Chats", percent: 5)],
            plan: "Max 20×", fetchedAt: now)

        // Limit history: a stepped climb through the current windows.
        var history: [LimitSample] = []
        for window in [session, week, fable] {
            guard let start = window.windowStart else { continue }
            let steps = window.isSession ? 40 : 160
            let span = now.timeIntervalSince(start)
            for i in 0..<steps {
                let t = start.addingTimeInterval(span * Double(i) / Double(steps))
                let x = Double(i) / Double(steps)
                let wobble = 0.5 + 0.5 * sin(x * 9)
                let value = window.utilization * min(1, pow(x, 1.15) * (0.85 + 0.15 * wobble))
                if let index = history.firstIndex(where: { abs($0.t.timeIntervalSince(t)) < 60 }) {
                    history[index].v[window.id] = value
                } else {
                    history.append(LimitSample(t: t, v: [window.id: value]))
                }
            }
        }
        history.sort { $0.t < $1.t }

        // Local activity: 60 days with a weekday rhythm.
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let projects = ["headroom", "web-app", "backend", "design-system", "dotfiles", "infra"]
        let days: [DayStat] = (0..<60).map { i in
            let day = cal.date(byAdding: .day, value: i - 59, to: today)!
            let weekday = cal.component(.weekday, from: day)
            let weekend = weekday == 1 || weekday == 7
            let intensity = (weekend ? 0.25 : 1.0) * (0.55 + 0.45 * abs(sin(Double(i) * 1.3))) * (0.7 + Double(i) / 200)
            var stat = DayStat(day: day)
            let workHours: [Int: Double] = [9: 0.6, 10: 1, 11: 1, 12: 0.4, 13: 0.7, 14: 1, 15: 0.9, 16: 0.8, 17: 0.5, 21: 0.35, 22: 0.3]
            for (h, w) in workHours { stat.hours[h] = Int(9_000_000 * intensity * w) }
            let total = stat.hours.reduce(0, +)
            stat.tokens = TokenCounts(input: total / 400, output: total / 40, cacheWrite: total / 18,
                                      cacheRead: total - total / 400 - total / 40 - total / 18)
            stat.cost = Double(total) / 1_000_000 * 0.62
            stat.messages = Int(Double(total) / 180_000)
            stat.cacheSavings = stat.cost * 3.1
            stat.models = ["Opus 5.5": UsageSlice(tokens: Int(Double(total) * 0.7), cost: stat.cost * 0.78, messages: stat.messages * 7 / 10, lastActive: day),
                           "Fable 5.1": UsageSlice(tokens: Int(Double(total) * 0.2), cost: stat.cost * 0.19, messages: stat.messages / 5, lastActive: day),
                           "Haiku 4.5": UsageSlice(tokens: Int(Double(total) * 0.1), cost: stat.cost * 0.03, messages: stat.messages / 10, lastActive: day)]
            for (n, name) in projects.enumerated() where (i + n) % (n + 1) == 0 || n < 2 {
                let share = [0.42, 0.24, 0.14, 0.1, 0.06, 0.04][n]
                stat.projects[name] = UsageSlice(tokens: Int(Double(total) * share), cost: stat.cost * share,
                                                 messages: Int(Double(stat.messages) * share),
                                                 lastActive: day.addingTimeInterval(3600 * 17))
            }
            if total == 0 { stat.models = [:]; stat.projects = [:] }
            return stat
        }
        snapshot.local = LocalStats(days: days, scannedAt: now, filesScanned: 418, coverageStart: days.first?.day)
        return (snapshot, history)
    }
}
