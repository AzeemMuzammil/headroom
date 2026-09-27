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
    case timedOut
    case expired
    case unreadable(String)
}

/// Reads — never writes or refreshes — the OAuth login Claude Code keeps in the keychain.
/// Refreshing is left to Claude Code: doing it here would rotate the refresh token and log Claude Code out.
///
/// It reads through `/usr/bin/security`, the tool Claude Code saves the login with. The keychain entry
/// trusts that tool, so there's usually no prompt, even after Claude Code renews the token (which resets
/// any "Always Allow" given to an app directly).
enum CredentialReader {
    static let service = "Claude Code-credentials"

    /// How long to wait for `security`. It only takes long when macOS shows a dialog (e.g. the keychain
    /// is locked); without a limit, an unanswered dialog would stall every refresh.
    private static let timeout: TimeInterval = 60

    static func read() throws -> ClaudeCredentials {
        let data: Data
        do {
            data = try readSecurityTool()
        } catch CredentialError.notFound {
            // Some setups (e.g. older Claude Code versions) keep a plain file instead.
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
        do {
            try process.run()
        } catch {
            throw CredentialError.unreadable("Couldn't run security: \(error.localizedDescription)")
        }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        if process.terminationReason == .uncaughtSignal { throw CredentialError.timedOut }
        switch process.terminationStatus {
        case 0: return data
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
