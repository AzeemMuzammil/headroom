import Foundation

/// Gets plan limits the approved way: Claude Code passes `rate_limits` to its status line command,
/// and our bundled helper (`headroom-statusline`) saves them to a file this app reads.
/// No login, no network. See https://code.claude.com/docs/en/statusline
enum StatusLineBridge {
    enum State: Equatable {
        case notInstalled
        case installed
        /// Our helper is configured, but from another copy of the app (moved or rebuilt elsewhere).
        case needsRepair
    }

    struct Reading {
        var windows: [LimitWindow]
        var receivedAt: Date
    }

    static let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/headroom-statusline")
    static let limitsURL = Store.directory.appendingPathComponent("rate-limits.json")
    private static let chainURL = Store.directory.appendingPathComponent("statusline-chain.json")
    private static let helperName = "headroom-statusline"

    /// Claude Code's user settings. Resolved, so a symlinked settings.json (e.g. from dotfiles) is
    /// edited in place rather than replaced.
    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json").resolvingSymlinksInPath()
    }

    private static var backupURL: URL { settingsURL.appendingPathExtension("headroom-backup") }

    /// The helper path, single-quoted for the shell.
    private static var helperCommand: String {
        "'" + helperURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Setup

    static var state: State {
        guard let command = currentStatusLine()?["command"] as? String, command.contains(helperName) else { return .notInstalled }
        return command.contains(helperURL.path) ? .installed : .needsRepair
    }

    /// Points Claude Code's status line at our helper. An existing status line keeps working: the
    /// helper runs it and shows its output. A backup of settings.json is kept next to it.
    static func install() throws {
        var settings = try readSettings()
        let previous = settings["statusLine"] as? [String: Any]
        let previousCommand = previous?["command"] as? String
        let alreadyOurs = previousCommand?.contains(helperName) ?? false
        let fm = FileManager.default

        if !alreadyOurs {
            // Back up the settings as they are before we change them.
            if fm.fileExists(atPath: settingsURL.path) {
                try? fm.removeItem(at: backupURL)
                try fm.copyItem(at: settingsURL, to: backupURL)
            }
            // Remember the user's own status line so the helper can keep running it.
            if let previous, let previousCommand, !previousCommand.isEmpty {
                let data = try JSONSerialization.data(withJSONObject: previous, options: [.prettyPrinted, .withoutEscapingSlashes])
                try fm.createDirectory(at: Store.directory, withIntermediateDirectories: true)
                try data.write(to: chainURL, options: .atomic)
            } else {
                try? fm.removeItem(at: chainURL)
            }
        }
        var statusLine = previous ?? [:]
        statusLine["type"] = "command"
        statusLine["command"] = helperCommand
        settings["statusLine"] = statusLine
        try writeSettings(settings)
    }

    /// Restores the status line that was there before (or removes ours).
    static func uninstall() throws {
        var settings = try readSettings()
        if let data = try? Data(contentsOf: chainURL),
           let previous = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings["statusLine"] = previous
        } else {
            settings.removeValue(forKey: "statusLine")
        }
        try writeSettings(settings)
        try? FileManager.default.removeItem(at: chainURL)
    }

    // MARK: Reading

    /// The latest limits the helper saved (Unix-seconds `resets_at`, 0–100 `used_percentage`).
    static func read() -> Reading? {
        guard let data = try? Data(contentsOf: limitsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any] else { return nil }
        let received = Date(timeIntervalSince1970: (root["received_at"] as? NSNumber)?.doubleValue ?? 0)

        var windows: [LimitWindow] = []
        for (key, id, title, length) in [("five_hour", "five_hour", "Current session", 5 * 3600.0),
                                         ("seven_day", "seven_day", "All models", 7 * 86_400.0)] {
            guard let w = limits[key] as? [String: Any],
                  let used = (w["used_percentage"] as? NSNumber)?.doubleValue else { continue }
            let resets = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            windows.append(LimitWindow(id: id, title: title, utilization: used, resetsAt: resets, windowLength: length))
        }
        return Reading(windows: windows, receivedAt: received)
    }

    static var lastModified: Date? {
        (try? FileManager.default.attributesOfItem(atPath: limitsURL.path))?[.modificationDate] as? Date
    }

    // MARK: settings.json

    private static func currentStatusLine() -> [String: Any]? {
        (try? readSettings())?["statusLine"] as? [String: Any]
    }

    private static func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: settingsURL.path])
        }
        return object
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }
}
