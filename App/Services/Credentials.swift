import Foundation

struct ClaudeCredentials {
    var accessToken: String
    var expiresAt: Date?
    var subscriptionType: String?
    var rateLimitTier: String?

    var isExpired: Bool { expiresAt.map { $0.timeIntervalSinceNow < 30 } ?? false }

    /// "Max 20×", "Max 5×", "Pro", "Team"…
    var planName: String? {
        guard let sub = subscriptionType?.lowercased(), !sub.isEmpty else { return nil }
        var name = sub.capitalized
        if let tier = rateLimitTier?.lowercased(), let r = tier.range(of: #"(\d+)x"#, options: .regularExpression) {
            name += " " + tier[r].dropLast() + "×"
        }
        return name
    }
}

enum CredentialError: Error {
    case notFound
    case denied
    case expired
    case unreadable(String)
}

/// Reads — never writes or refreshes — the OAuth login Claude Code keeps in the keychain.
///
/// It goes through `/usr/bin/security`, the same tool Claude Code uses to save the login. The keychain
/// entry trusts that tool, so there's no prompt — including after Claude Code renews the token, which
/// would reset an "Always Allow" given to this app directly.
/// Refreshing is left to Claude Code: doing it here would rotate the refresh token and log Claude Code out.
enum CredentialReader {
    static let service = "Claude Code-credentials"

    static func read() throws -> ClaudeCredentials {
        let data: Data
        do {
            data = try readSecurityTool()
        } catch CredentialError.notFound {
            // Some setups (e.g. CLAUDE_CONFIG_DIR / older versions) keep a plain file instead.
            let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
            guard let fileData = try? Data(contentsOf: file) else { throw CredentialError.notFound }
            data = fileData
        }
        return try parse(data)
    }

    private static func readSecurityTool() throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        switch process.terminationStatus {
        case 0: return Data(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        case 44: throw CredentialError.notFound          // errSecItemNotFound
        case 128, 51, 36: throw CredentialError.denied   // cancelled / auth failed / interaction not allowed
        default: throw CredentialError.unreadable("security exited with \(process.terminationStatus)")
        }
    }

    private static func parse(_ data: Data) throws -> ClaudeCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { throw CredentialError.unreadable("Unrecognised credentials format") }

        let expires = (oauth["expiresAt"] as? NSNumber).map { n -> Date in
            // Milliseconds since epoch; tolerate seconds too.
            let v = n.doubleValue
            return Date(timeIntervalSince1970: v > 10_000_000_000 ? v / 1000 : v)
        }
        return ClaudeCredentials(accessToken: token,
                                 expiresAt: expires,
                                 subscriptionType: oauth["subscriptionType"] as? String,
                                 rateLimitTier: oauth["rateLimitTier"] as? String)
    }
}
