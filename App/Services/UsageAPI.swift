import Foundation

// ⚠️ Undocumented endpoint — the same one Claude Code's /usage screen uses.
// If Anthropic changes it, this file is the only place that should need updating.
// Settings → "Copy last API response" shows exactly what came back.

enum UsageAPIError: Error {
    case unauthorized
    case forbidden
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int, String)
    case network(String)
    case apiChanged(String)
}

struct ParsedUsage {
    var windows: [LimitWindow]
    var breakdown: [UsageShare]
}

enum UsageAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let betaHeader = "oauth-2025-04-20"

    /// A dedicated session that never persists anything: the default `URLSession.shared` keeps an
    /// on-disk URLCache, which would store the request — Authorization header included.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: RefuseRedirects(), delegateQueue: nil)
    }()

    /// Fetches the raw response body. Parse it with `parse(usage:)` — kept separate so the raw body
    /// can be saved for diagnostics even when parsing fails.
    static func fetch(token: String) async throws -> Data {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Headroom/1.0 (+https://github.com/AzeemMuzammil/headroom)", forHTTPHeaderField: "User-Agent")

        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageAPIError.network(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: return data
        case 401: throw UsageAPIError.unauthorized
        case 403: throw UsageAPIError.forbidden
        case 429:
            let retry = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after")
                .flatMap(TimeInterval.init).flatMap { $0.isFinite ? min(max($0, 60), 3600) : nil }
            throw UsageAPIError.rateLimited(retryAfter: retry)
        case 404, 410: throw UsageAPIError.apiChanged("Endpoint returned \(status)")
        default: throw UsageAPIError.http(status, String(decoding: data.prefix(300), as: UTF8.self))
        }
    }

    /// Prefers the `limits` array (what Claude's own UI renders: display names, reset times for every
    /// limit). Falls back to the legacy top-level keys, where model-scoped limits hide behind internal
    /// internal code names without reset times.
    static func parse(_ data: Data) throws -> [LimitWindow] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageAPIError.apiChanged("Response is not a JSON object")
        }
        if let limits = root["limits"] as? [[String: Any]] {
            let windows = uniqued(limits.compactMap(window(fromLimit:)))
            if !windows.isEmpty { return windows }
        }
        return try parseLegacy(root)
    }

    static func parse(usage data: Data) throws -> ParsedUsage {
        ParsedUsage(windows: try parse(data), breakdown: parseBreakdown(data))
    }

    /// `seven_day_breakdown.rows`: how the weekly limit splits across Claude products.
    static func parseBreakdown(_ data: Data) -> [UsageShare] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = (root["seven_day_breakdown"] as? [String: Any])?["rows"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let key = row["key"] as? String, let percent = (row["percent"] as? NSNumber)?.doubleValue else { return nil }
            return UsageShare(key: key, name: row["display_name"] as? String ?? key.capitalized, percent: percent)
        }
    }

    /// One entry of `limits`, e.g.
    /// `{"kind":"weekly_scoped","group":"weekly","percent":0,"resets_at":"…","scope":{"model":{"display_name":"Fable"}}}`
    private static func window(fromLimit limit: [String: Any]) -> LimitWindow? {
        guard let percent = (limit["percent"] as? NSNumber)?.doubleValue else { return nil }
        let kind = limit["kind"] as? String ?? "unknown"
        let group = limit["group"] as? String ?? kind
        let scope = limit["scope"] as? [String: Any]
        let modelName = displayName(scope?["model"]), surfaceName = displayName(scope?["surface"])
        let scopeName = [modelName, surfaceName].compactMap { $0 }.joined(separator: " · ").nilIfEmpty

        let id: String, title: String
        switch kind {
        case "session":
            id = "five_hour"; title = "Current session"
        case "weekly_all":
            id = "seven_day"; title = "All models"
        default:
            let name = scopeName ?? kind.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
            id = "\(kind):\(name.lowercased())"; title = name
        }
        let length: TimeInterval? = switch group {
        case "session": 5 * 3600
        case "weekly": 7 * 86400
        default: kind == "session" ? 5 * 3600 : kind.hasPrefix("weekly") ? 7 * 86400 : nil
        }
        return LimitWindow(id: id, title: title, utilization: percent,
                           resetsAt: date(from: limit["resets_at"]), windowLength: length)
    }

    /// Ids must be unique (they key the history and SwiftUI lists): suffix any repeats.
    private static func uniqued(_ windows: [LimitWindow]) -> [LimitWindow] {
        var seen: [String: Int] = [:]
        return windows.map { w in
            var w = w
            seen[w.id, default: 0] += 1
            if let n = seen[w.id], n > 1 { w.id += "#\(n)" }
            return w
        }
    }

    private static func displayName(_ value: Any?) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        guard let obj = value as? [String: Any] else { return nil }
        return (obj["display_name"] as? String) ?? (obj["name"] as? String) ?? (obj["id"] as? String)
    }

    /// Legacy shape: any top-level object with a numeric `utilization` becomes a window.
    private static func parseLegacy(_ root: [String: Any]) throws -> [LimitWindow] {
        var windows: [LimitWindow] = []
        for (key, value) in root {
            guard let obj = value as? [String: Any],
                  let utilization = (obj["utilization"] as? NSNumber)?.doubleValue else { continue }
            if let enabled = obj["is_enabled"] as? Bool, !enabled { continue }
            windows.append(LimitWindow(id: key,
                                       title: title(for: key),
                                       utilization: utilization,
                                       resetsAt: date(from: obj["resets_at"]),
                                       windowLength: windowLength(for: key)))
        }
        guard !windows.isEmpty else {
            throw UsageAPIError.apiChanged("No usage windows found (keys: \(root.keys.sorted().joined(separator: ", ")))")
        }
        return windows.sorted { order($0.id) == order($1.id) ? $0.id < $1.id : order($0.id) < order($1.id) }
    }

    private static func order(_ key: String) -> Int {
        switch key {
        case "five_hour": 0
        case "seven_day": 1
        case _ where key.hasPrefix("seven_day"): 2
        default: 3
        }
    }

    private static func title(for key: String) -> String {
        switch key {
        case "five_hour": return "Current session"
        case "seven_day": return "All models"
        case "seven_day_opus": return "Opus"
        case "seven_day_sonnet": return "Sonnet"
        case "seven_day_oauth_apps": return "Connected apps"
        case "extra_usage": return "Extra usage"
        default:
            let trimmed = key.hasPrefix("seven_day_") ? String(key.dropFirst("seven_day_".count)) : key
            return trimmed.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
        }
    }

    private static func windowLength(for key: String) -> TimeInterval? {
        if key.hasPrefix("five_hour") { return 5 * 3600 }
        if key.hasPrefix("seven_day") { return 7 * 86400 }
        return nil
    }

    static func date(from value: Any?) -> Date? {
        if let n = value as? NSNumber {
            let v = n.doubleValue
            return Date(timeIntervalSince1970: v > 10_000_000_000 ? v / 1000 : v)
        }
        guard var s = value as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        // Fractional seconds with more than 3 digits (e.g. microseconds) trip ISO8601DateFormatter.
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) { s.removeSubrange(r) }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// Never follow redirects, so the bearer token can't be forwarded to another host.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
