import AppKit
import Observation
import ServiceManagement
import SwiftUI

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case ringAndPercent, percent, ring
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ringAndPercent: "Ring and percentage"
        case .percent: "Percentage only"
        case .ring: "Ring only"
        }
    }
}

/// Where plan limits come from. Chosen on first launch; changeable in Settings.
enum LimitsSource: String, CaseIterable, Identifiable {
    /// Claude Code's status line hands us the limits — the approved way. No login, no network.
    case claudeCode
    /// Reads Claude Code's saved login (via /usr/bin/security) and calls Anthropic's usage endpoint.
    case direct
    /// Local Claude Code stats only.
    case off

    var id: String { rawValue }
    var label: String {
        switch self {
        case .claudeCode: "Through Claude Code"
        case .direct: "Direct (uses Claude Code's login)"
        case .off: "Off"
        }
    }
}

enum InsightsPage: String, CaseIterable, Identifiable {
    case overview, activity, projects, settings
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.50percent"
        case .activity: "chart.bar.xaxis"
        case .projects: "folder"
        case .settings: "gearshape"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    var snapshot: UsageSnapshot
    private(set) var history: [LimitSample]
    var isRefreshing = false
    var page: InsightsPage = .overview
    var range: LocalRange = .week
    /// Ticks every few seconds so countdowns and expired windows update without a refresh.
    private(set) var clock = Date()
    private(set) var bridgeState: StatusLineBridge.State = .notInstalled
    var bridgeError: String?

    var limitsSource: LimitsSource? {
        didSet {
            defaults.set(limitsSource?.rawValue, forKey: "limitsSource")
            credentials = nil
            backoffUntil = nil
            // Don't carry one source's numbers over to another.
            if oldValue != limitsSource {
                snapshot.limits = LimitsState()
            }
        }
    }
    var refreshInterval: Double {
        didSet { defaults.set(refreshInterval, forKey: "refreshInterval"); if !isPreview { restartLoop() } }
    }
    var menuBarStyle: MenuBarStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: "menuBarStyle") }
    }
    var launchAtLogin: Bool {
        didSet {
            guard !isPreview, launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var credentials: ClaudeCredentials?
    @ObservationIgnored private let scanner = LogScanner()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var backoffUntil: Date?
    @ObservationIgnored private var pendingForcedRefresh = false
    @ObservationIgnored private var bridgeFileDate: Date?
    @ObservationIgnored private let isPreview: Bool

    init() {
        isPreview = false
        Store.removeStaleFiles()
        snapshot = Store.load(UsageSnapshot.self, "snapshot.json") ?? UsageSnapshot()
        history = Store.load([LimitSample].self, "limit-history.json") ?? []
        limitsSource = LimitsSource(rawValue: defaults.string(forKey: "limitsSource") ?? "")
        refreshInterval = defaults.object(forKey: "refreshInterval") as? Double ?? 180
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: "menuBarStyle") ?? "") ?? .ringAndPercent
        launchAtLogin = SMAppService.mainApp.status == .enabled
        bridgeState = StatusLineBridge.state
        updateModelColors()
        restartLoop()
        startTicker()

        let center = NSWorkspace.shared.notificationCenter
        // Catch up straight away after the Mac wakes.
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        // The log-scan cache is saved at most every 10 minutes; save it on quit too.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [scanner] _ in
            let done = DispatchSemaphore(value: 0)
            Task.detached { await scanner.flush(); done.signal() }
            _ = done.wait(timeout: .now() + 2)
        }
    }

    /// A static model for previews and screenshots; never touches the login, network or disk.
    init(preview: UsageSnapshot, history: [LimitSample]) {
        isPreview = true
        snapshot = preview
        self.history = history
        limitsSource = .direct
        refreshInterval = 180
        menuBarStyle = .ringAndPercent
        launchAtLogin = false
        bridgeState = .installed
        updateModelColors(persist: false)
    }

    // MARK: Refreshing

    private func restartLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(self?.refreshInterval ?? 180))
            }
        }
    }

    /// Every 10 s: move the clock on and pick up new limits from Claude Code's status line.
    private func startTicker() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                self.clock = Date()
                if self.limitsSource == .claudeCode, StatusLineBridge.lastModified != self.bridgeFileDate {
                    self.readBridge()
                    Store.save(self.snapshot, "snapshot.json")
                }
            }
        }
    }

    func refresh(force: Bool = false) async {
        guard !isPreview else { return }
        guard !isRefreshing else {
            // Don't drop a user's "Refresh Now" / "Retry": run it once this one finishes.
            if force { pendingForcedRefresh = true }
            return
        }
        isRefreshing = true
        async let local = scanner.scan()
        await refreshLimits(force: force)
        snapshot.local = await local
        updateModelColors()
        clock = Date()
        Store.save(snapshot, "snapshot.json")
        isRefreshing = false

        if pendingForcedRefresh {
            pendingForcedRefresh = false
            await refresh(force: true)
        }
    }

    func rescanLocal() async {
        await scanner.resetCache()
        await refresh(force: true)
    }

    private func refreshLimits(force: Bool) async {
        bridgeState = StatusLineBridge.state
        switch limitsSource {
        case nil:
            report(.setupNeeded, "Choose how Headroom gets your plan limits.")
        case .off:
            snapshot.limits.windows = []
            snapshot.limits.issue = nil
        case .claudeCode:
            readBridge()
        case .direct:
            await fetchDirect(force: force)
        }
    }

    // MARK: Through Claude Code

    private func readBridge() {
        bridgeFileDate = StatusLineBridge.lastModified
        switch bridgeState {
        case .notInstalled:
            snapshot.limits.windows = []
            report(.setupNeeded, "Connect Headroom to Claude Code to see your plan limits.")
            return
        case .needsRepair:
            snapshot.limits.windows = []
            report(.setupNeeded, "Claude Code is set up with another copy of Headroom. Click Repair to use this one.")
            return
        case .installed:
            break
        }
        guard let reading = StatusLineBridge.read(), !reading.windows.isEmpty else {
            report(.waitingForClaudeCode, "Your limits appear after your next message in Claude Code (Pro and Max plans).")
            return
        }
        let isNew = reading.receivedAt != snapshot.limits.fetchedAt
        snapshot.limits.windows = reading.windows
        snapshot.limits.breakdown = []
        snapshot.limits.plan = nil
        snapshot.limits.fetchedAt = reading.receivedAt
        snapshot.limits.issue = nil
        if isNew { record(reading.windows, at: reading.receivedAt) }
    }

    @discardableResult
    func installBridge() -> Bool {
        var ok = false
        do {
            try StatusLineBridge.install()
            bridgeError = nil
            ok = true
        } catch {
            bridgeError = "Couldn't update ~/.claude/settings.json: \(error.localizedDescription)"
        }
        bridgeState = StatusLineBridge.state
        Task { await refresh(force: true) }
        return ok
    }

    func uninstallBridge() {
        do {
            try StatusLineBridge.uninstall()
            bridgeError = nil
        } catch {
            bridgeError = "Couldn't update ~/.claude/settings.json: \(error.localizedDescription)"
        }
        bridgeState = StatusLineBridge.state
        Task { await refresh(force: true) }
    }

    // MARK: Direct

    private func fetchDirect(force: Bool) async {
        if !force, let until = backoffUntil, until > Date() { return }
        do {
            let creds = try await currentCredentials()
            let raw = try await UsageAPI.fetch(token: creds.accessToken)
            Store.saveRaw(raw, "last-usage-response.json")     // saved before parsing, for "API changed" diagnostics
            let usage = try UsageAPI.parse(usage: raw)
            snapshot.limits.windows = usage.windows
            snapshot.limits.breakdown = usage.breakdown
            snapshot.limits.plan = creds.planName
            snapshot.limits.fetchedAt = Date()
            snapshot.limits.issue = nil
            backoffUntil = nil
            record(usage.windows, at: Date())
        } catch CredentialError.notFound {
            report(.notLoggedIn, "No Claude Code login found. Run `claude` and sign in, then refresh.")
        } catch CredentialError.denied {
            report(.keychainDenied, "macOS didn't allow reading the Claude Code login. Click Retry, and allow access if asked.")
        } catch CredentialError.timedOut {
            report(.keychainDenied, "Reading the Claude Code login timed out — macOS may be waiting for you to unlock the keychain. Click Retry.")
        } catch CredentialError.expired {
            report(.tokenExpired, "Your Claude Code login has expired. Use Claude Code once to renew it.")
        } catch CredentialError.unreadable(let why) {
            report(.notLoggedIn, "Couldn't read the Claude Code login: \(why)")
        } catch UsageAPIError.unauthorized {
            credentials = nil
            backoffUntil = Date().addingTimeInterval(600)
            report(.unauthorized, "Claude rejected the saved login. Use Claude Code once to renew it.")
        } catch UsageAPIError.forbidden {
            backoffUntil = Date().addingTimeInterval(1800)
            report(.forbidden, "Claude refused access to usage data for this account (HTTP 403). Try “Through Claude Code” in Settings.")
        } catch UsageAPIError.rateLimited(let retryAfter) {
            let wait = retryAfter ?? 300
            backoffUntil = Date().addingTimeInterval(wait)
            report(.rateLimited, "The usage service asked us to slow down. Retrying in \(Fmt.duration(wait)).")
        } catch UsageAPIError.apiChanged(let why) {
            report(.apiChanged, "The usage API changed (\(why)). The app needs an update.")
        } catch UsageAPIError.http(let code) {
            report(.network, "The usage service returned HTTP \(code).")
        } catch UsageAPIError.network(let why) {
            report(.network, "Couldn't reach Claude: \(why)")
        } catch {
            report(.network, error.localizedDescription)
        }
    }

    private func report(_ kind: LimitsState.Issue.Kind, _ message: String) {
        snapshot.limits.issue = .init(kind: kind, message: message)
    }

    /// Reads the login only when needed: on first use, after the token expires, or after a 401.
    private func currentCredentials() async throws -> ClaudeCredentials {
        if let credentials, !credentials.isExpired { return credentials }
        let fresh = try await Task.detached(priority: .userInitiated) {
            try CredentialReader.read()
        }.value
        guard !fresh.isExpired else { throw CredentialError.expired }
        credentials = fresh
        return fresh
    }

    /// This week's models claim palette slots first, then the rest of the month's.
    private func updateModelColors(persist: Bool = true) {
        let week = snapshot.local?.summary(.week)?.models.map(\.name) ?? []
        let month = snapshot.local?.summary(.month)?.models.map(\.name) ?? []
        guard !(week + month).isEmpty else { return }
        ModelPalette.update(ranked: week + month, persist: persist)
    }

    // MARK: History

    private func record(_ windows: [LimitWindow], at date: Date) {
        let values = Dictionary(windows.map { ($0.id, $0.utilization) }, uniquingKeysWith: { first, _ in first })
        history.append(LimitSample(t: date, v: values))
        history.removeAll { Date().timeIntervalSince($0.t) > 9 * 86_400 }
        Store.save(history, "limit-history.json")
    }

    /// Recorded utilisation for a limit since the start of its current window, ending at its live value.
    func series(for window: LimitWindow, now: Date = Date()) -> [HistoryPoint] {
        guard let start = window.windowStart else { return [] }
        var points = history
            .filter { $0.t >= start && $0.t < now }
            .compactMap { s in s.v[window.id].map { HistoryPoint(date: s.t, value: $0) } }
        points.append(HistoryPoint(date: now, value: window.utilization))
        return points
    }

    // MARK: Derived

    /// Plan limits as of now: windows whose reset time has passed show as reset.
    var limits: LimitsState { snapshot.limits.current(at: clock) }
    var needsSetup: Bool { limitsSource == nil }

    var summary: PeriodSummary? { snapshot.local?.summary(range) }
    var previousSummary: PeriodSummary? { snapshot.local?.summary(range, periodsAgo: 1) }
    var today: PeriodSummary? { snapshot.local?.summary(.today) }

    var lastUpdated: Date? { snapshot.limits.fetchedAt ?? snapshot.local?.scannedAt }

    func copyLastResponse() {
        let text = Store.loadRaw("last-usage-response.json").map { String(decoding: $0, as: UTF8.self) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text ?? "No response yet", forType: .string)
    }
}

/// JSON files in ~/Library/Application Support/Headroom.
enum Store {
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Headroom", isDirectory: true)

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = loadRaw(name) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        saveRaw(data, name)
    }

    /// Removes outdated log-scan caches, and any URL cache: the app never caches requests, and one
    /// could contain an Authorization header.
    static func removeStaleFiles() {
        let fm = FileManager.default
        if let bundleID = Bundle.main.bundleIdentifier {
            try? fm.removeItem(at: fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(bundleID))
        }
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        where name.hasPrefix("scan-cache-v") && name != LogScanner.cacheFileName {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    static func loadRaw(_ name: String) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(name))
    }

    static func saveRaw(_ data: Data, _ name: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
