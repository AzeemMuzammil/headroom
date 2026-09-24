import Foundation

// headroom-statusline — Claude Code runs this as its status line command.
//
// Claude Code passes session JSON on stdin; for Pro and Max subscribers it includes
// `rate_limits.five_hour` / `rate_limits.seven_day` ({ used_percentage, resets_at }).
// We save only those windows for Headroom to read, then print a status line: either the
// user's previous status line command (chained, so it keeps working) or a short default.
// See https://code.claude.com/docs/en/statusline

// A chained command that exits without reading stdin must not kill us with SIGPIPE.
signal(SIGPIPE, SIG_IGN)

let fm = FileManager.default
let supportDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Headroom", isDirectory: true)
let limitsFile = supportDir.appendingPathComponent("rate-limits.json")
let chainFile = supportDir.appendingPathComponent("statusline-chain.json")

let input = FileHandle.standardInput.readDataToEndOfFile()
let session = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]

// 1. Save the rate-limit windows, merged with what we had (each window may be absent on its own).
if let incoming = session?["rate_limits"] as? [String: Any], !incoming.isEmpty {
    let now = Date().timeIntervalSince1970
    var saved = ((try? Data(contentsOf: limitsFile)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["rate_limits"] as? [String: Any] ?? [:]
    // Drop windows that have already reset.
    saved = saved.filter { (($0.value as? [String: Any])?["resets_at"] as? NSNumber)?.doubleValue ?? .infinity > now }
    for (key, value) in incoming where value is [String: Any] {
        saved[key] = value
    }
    let payload: [String: Any] = ["rate_limits": saved, "received_at": now]
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? data.write(to: limitsFile, options: .atomic)
    }
}

// 2. Print the status line.
if let chain = (try? Data(contentsOf: chainFile)).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any],
   let command = chain["command"] as? String, !command.isEmpty {
    // Run the user's previous status line with the same input and pass its output through.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    let stdin = Pipe()
    process.standardInput = stdin
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    do {
        try process.run()
        try? stdin.fileHandleForWriting.write(contentsOf: input)
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        exit(process.terminationStatus)
    } catch {
        // Fall through to the default line.
    }
}

func percent(_ window: String) -> String? {
    guard let w = (session?["rate_limits"] as? [String: Any])?[window] as? [String: Any],
          let used = (w["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
    return "\(Int(used.rounded()))%"
}

var parts: [String] = []
if let model = (session?["model"] as? [String: Any])?["display_name"] as? String { parts.append(model) }
if let s = percent("five_hour") { parts.append("session \(s)") }
if let w = percent("seven_day") { parts.append("week \(w)") }
print(parts.joined(separator: " · "))
