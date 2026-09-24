import Foundation

/// Reads Claude Code session logs (`~/.claude/projects/<project>/**/*.jsonl`) and totals token usage.
///
/// Logs can run to gigabytes, so each file is parsed incrementally: we remember how far we read
/// and only parse newly appended lines. The per-file results are cached on disk between launches.
actor LogScanner {
    /// One assistant response. Short keys keep the on-disk cache small.
    private struct Entry: Codable {
        var i: String   // message id + request id (dedupe key)
        var t: Double   // unix timestamp
        var m: String   // model id
        var a: Int      // input tokens
        var o: Int      // output tokens
        var w: Int      // cache write tokens
        var r: Int      // cache read tokens
        var c: Double   // API-equivalent cost
        var s: Double   // what cache reads saved vs. paying full input price
    }

    private struct FileState: Codable {
        var size: Int64 = 0
        var mtime: Double = 0
        var inode: UInt64 = 0
        var created: Double = 0
        var offset: Int64 = 0
        /// Folder name of the first working directory seen in this file (a project's display name).
        var root: String?
        var entries: [Entry] = []
    }

    private static let cacheVersion = 3
    static let cacheFileName = "scan-cache-v\(cacheVersion).json"
    private let lookbackDays = 61
    private let saveInterval: TimeInterval = 600
    private var files: [String: FileState] = [:]
    private var loaded = false
    private var dirty = false
    private var lastSave = Date.distantPast
    private let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let iso = ISO8601DateFormatter()

    private var roots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var dirs = [home.appendingPathComponent(".claude/projects"),
                    home.appendingPathComponent(".config/claude/projects")]
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            dirs.insert(URL(fileURLWithPath: custom).appendingPathComponent("projects"), at: 0)
        }
        return dirs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The first existing logs folder, for "Show in Finder".
    nonisolated static var logsFolder: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent(".claude/projects"), home.appendingPathComponent(".config/claude/projects")]
            .first { FileManager.default.fileExists(atPath: $0.path) } ?? home.appendingPathComponent(".claude/projects")
    }

    private var cacheURL: URL { Store.directory.appendingPathComponent(Self.cacheFileName) }

    // MARK: Public

    func scan() -> LocalStats {
        loadCacheIfNeeded()
        let cutoff = Date().addingTimeInterval(-Double(lookbackDays) * 86_400)
        var seen = Set<String>()
        var coverageStart: Date?
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey, .fileSizeKey, .isRegularFileKey]

        for root in roots {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                if let created = values.creationDate, created < (coverageStart ?? .distantFuture) { coverageStart = created }
                guard let modified = values.contentModificationDate, modified >= cutoff,
                      let size = values.fileSize.map(Int64.init) else { continue }

                let path = url.path
                seen.insert(path)
                let inode = (try? FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
                let created = values.creationDate?.timeIntervalSince1970 ?? 0
                var state = files[path] ?? FileState()
                // A replaced or rewritten file starts over.
                if size < state.offset || (state.inode != 0 && state.inode != inode) || (state.created != 0 && state.created != created) {
                    state = FileState()
                }
                if size != state.size || modified.timeIntervalSince1970 != state.mtime {
                    parse(url, into: &state, cutoff: cutoff.timeIntervalSince1970)
                    state.size = size
                    state.mtime = modified.timeIntervalSince1970
                    state.inode = inode
                    state.created = created
                    files[path] = state
                    dirty = true
                }
            }
        }

        if files.count != seen.count {
            files = files.filter { seen.contains($0.key) }
            dirty = true
        }
        if Date().timeIntervalSince(lastSave) > saveInterval { saveCacheIfNeeded() }
        return aggregate(coverageStart: coverageStart)
    }

    /// Writes the cache now (called when the app quits); otherwise it's saved at most every 10 minutes.
    func flush() {
        saveCacheIfNeeded()
    }

    func resetCache() {
        files = [:]
        dirty = true
        try? FileManager.default.removeItem(at: cacheURL)
    }

    // MARK: Parsing

    private func parse(_ url: URL, into state: inout FileState, cutoff: Double) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: UInt64(state.offset)) } catch { return }

        // Claude Code writes one line per content block, repeating the message's usage: keep one
        // entry per message, the one with the most output (the most complete).
        var index = [String: Int](minimumCapacity: state.entries.count)
        for (i, e) in state.entries.enumerated() { index[e.i] = i }
        func add(_ entry: Entry) {
            guard entry.t >= cutoff else { return }
            if let i = index[entry.i] {
                if entry.o > state.entries[i].o { state.entries[i] = entry }
            } else {
                index[entry.i] = state.entries.count
                state.entries.append(entry)
            }
        }

        let needle = Array("\"usage\"".utf8)
        let cwdNeedle = Array("\"cwd\"".utf8)
        var pending = Data()
        var reachedEnd = false

        while !reachedEnd {
            autoreleasepool {
                guard let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty else {
                    reachedEnd = true
                    return
                }
                pending.append(chunk)
                var consumed = 0
                pending.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    guard let base = raw.baseAddress else { return }
                    let count = raw.count
                    var start = 0
                    while start < count, let nl = memchr(base + start, 0x0A, count - start) {
                        let end = base.distance(to: UnsafeRawPointer(nl))
                        let length = end - start
                        if length > 0 {
                            if state.root == nil, memmem(base + start, length, cwdNeedle, cwdNeedle.count) != nil {
                                state.root = workingDirectory(Data(bytes: base + start, count: length))
                            }
                            // Cheap byte search first; only lines mentioning "usage" get JSON-decoded.
                            if memmem(base + start, length, needle, needle.count) != nil,
                               let entry = decode(Data(bytes: base + start, count: length)) {
                                add(entry)
                            }
                        }
                        start = end + 1
                    }
                    consumed = start
                }
                state.offset += Int64(consumed)
                pending = consumed == pending.count ? Data() : Data(pending[pending.startIndex.advanced(by: consumed)...])
            }
        }

        // A last line without a trailing newline: count it if it's complete JSON, but don't move the
        // offset past it — if it's still being written, it's re-read (and deduped) next time.
        if !pending.isEmpty, let entry = decode(pending) {
            add(entry)
        }
        state.entries.removeAll { $0.t < cutoff }
    }

    private func workingDirectory(_ line: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let cwd = obj["cwd"] as? String, !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    private func decode(_ line: Data) -> Entry? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return nil }

        let model = message["model"] as? String ?? "unknown"
        guard model != "<synthetic>" else { return nil }

        let stamp = obj["timestamp"] as? String ?? ""
        guard let date = isoFractional.date(from: stamp) ?? iso.date(from: stamp) else { return nil }

        func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
        let input = int(usage["input_tokens"])
        let output = int(usage["output_tokens"])
        let cacheWrite = int(usage["cache_creation_input_tokens"])
        let cacheRead = int(usage["cache_read_input_tokens"])
        let write1h = min(cacheWrite, int((usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"]))
        let fast = usage["speed"] as? String == "fast"
        let id = "\(message["id"] as? String ?? UUID().uuidString):\(obj["requestId"] as? String ?? "")"

        return Entry(i: id, t: date.timeIntervalSince1970, m: model,
                     a: input, o: output, w: cacheWrite, r: cacheRead,
                     c: Pricing.cost(model: model, input: input, output: output,
                                     cacheWrite5m: cacheWrite - write1h, cacheWrite1h: write1h,
                                     cacheRead: cacheRead, fast: fast),
                     s: Pricing.cacheSavings(model: model, cacheRead: cacheRead, fast: fast))
    }

    // MARK: Aggregation

    /// The project folder a log belongs to: the first path component under its logs root
    /// (Claude Code keeps one folder per project; the working directory can change mid-session).
    private func projectFolder(of path: String, roots: [String]) -> String {
        for root in roots where path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count + 1).split(separator: "/").first ?? "")
        }
        return URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
    }

    private func aggregate(coverageStart: Date?) -> LocalStats {
        // Name each project folder after its most common starting directory.
        var rootVotes: [String: [String: Int]] = [:]
        var folderOf: [String: String] = [:]
        // Both spellings, since the file enumerator may hand back symlink-resolved paths.
        let rootPaths = roots.flatMap { [$0.path, $0.resolvingSymlinksInPath().path] }
        for (path, state) in files {
            let folder = projectFolder(of: path, roots: rootPaths)
            folderOf[path] = folder
            if let root = state.root { rootVotes[folder, default: [:]][root, default: 0] += 1 }
        }
        let displayName = rootVotes.mapValues { votes in
            votes.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }!.key
        }

        // Dedupe across files (resumed sessions repeat messages), keeping the most complete entry.
        var unique: [String: (entry: Entry, project: String)] = [:]
        for (path, state) in files {
            let folder = folderOf[path] ?? ""
            let project = displayName[folder] ?? folder
            for e in state.entries where (unique[e.i]?.entry.o ?? -1) < e.o {
                unique[e.i] = (e, project)
            }
        }

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let dayCount = lookbackDays - 1
        let first = cal.date(byAdding: .day, value: -(dayCount - 1), to: today)!
        var days = (0..<dayCount).map { DayStat(day: cal.date(byAdding: .day, value: $0, to: first)!) }

        for (e, project) in unique.values {
            let date = Date(timeIntervalSince1970: e.t)
            guard let index = cal.dateComponents([.day], from: first, to: cal.startOfDay(for: date)).day,
                  days.indices.contains(index) else { continue }
            let total = e.a + e.o + e.w + e.r
            let slice = UsageSlice(tokens: total, cost: e.c, messages: 1, lastActive: date)
            days[index].tokens += TokenCounts(input: e.a, output: e.o, cacheWrite: e.w, cacheRead: e.r)
            days[index].cost += e.c
            days[index].messages += 1
            days[index].cacheSavings += e.s
            days[index].hours[cal.component(.hour, from: date)] += total
            days[index].models[Fmt.modelName(e.m), default: UsageSlice()] += slice
            days[index].projects[project, default: UsageSlice()] += slice
        }
        return LocalStats(days: days, scannedAt: Date(), filesScanned: files.count, coverageStart: coverageStart)
    }

    // MARK: Cache

    private func loadCacheIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode([String: FileState].self, from: data) else { return }
        files = cached
    }

    private func saveCacheIfNeeded() {
        guard dirty else { return }
        dirty = false
        lastSave = Date()
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(files) {
            try? data.write(to: cacheURL, options: .atomic)
        }
    }
}
