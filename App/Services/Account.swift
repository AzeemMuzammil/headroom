import Foundation

/// The Claude account Claude Code is signed in to.
struct ClaudeAccount: Equatable {
    /// The name Claude shows (display name, else full name).
    var name: String?
    var fullName: String?
    var email: String?
    /// Only set for team and enterprise accounts; personal plans have an auto-named organization.
    var organization: String?
    /// e.g. "Max 5×".
    var plan: String?

    /// The main line: the name, or the email when there's no name.
    var title: String { name ?? email ?? "" }
    /// The second line: the email, when the title is a name.
    var subtitle: String? { name != nil ? email : nil }

    var initials: String {
        let source = fullName ?? name ?? email.map { String($0.prefix { $0 != "@" }) } ?? ""
        let words = source.split { $0.isWhitespace || $0 == "." }.prefix(2)
        return words.compactMap { $0.first.map { String(String($0).uppercased().prefix(1)) } }.joined()
    }
}

/// Reads the signed-in account from Claude Code's config (`~/.claude.json` → `oauthAccount`).
/// A local file: no login, keychain or network involved. Nothing is stored by Headroom.
enum AccountReader {
    /// The account, or nil when Claude Code has none (not signed in, or signed in with an API key).
    /// Throws when the file exists but can't be read or parsed — e.g. mid-write — so callers can keep
    /// the last good value instead of flashing "signed out".
    static func read() throws -> ClaudeAccount? {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return nil }
        let data = try Data(contentsOf: configURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard let account = root["oauthAccount"] as? [String: Any] else { return nil }

        func string(_ key: String) -> String? {
            (account[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        let type = string("organizationType")
        let isOrganization = type.map { $0.contains("team") || $0.contains("enterprise") } ?? false
        let result = ClaudeAccount(
            name: string("displayName") ?? string("fullName"),
            fullName: string("fullName"),
            email: string("emailAddress"),
            organization: isOrganization ? string("organizationName") : nil,
            plan: type.flatMap { Fmt.planName(type: $0, tier: string("organizationRateLimitTier")) })
        return result.name == nil && result.email == nil ? nil : result
    }

    static var lastModified: Date? {
        (try? FileManager.default.attributesOfItem(atPath: configURL.path))?[.modificationDate] as? Date
    }

    /// `$CLAUDE_CONFIG_DIR/.claude.json` when that exists, otherwise `~/.claude.json`.
    private static var configURL: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(".claude.json")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
