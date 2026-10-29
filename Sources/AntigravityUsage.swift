import Foundation

/// One model group (e.g. "Gemini Models") with its 5-hour and weekly pools.
struct AntigravityGroup: Equatable, Sendable, Codable {
    var name: String
    var pools: [UsagePool]
}

struct AntigravitySnapshot: Equatable, Sendable, Codable {
    var groups: [AntigravityGroup]
    var fetchedAt: Date

    /// Menu-bar view: for each window, the group that is closest to running out.
    var barPools: [UsagePool] {
        ["Session", "Weekly"].compactMap { label in
            groups.compactMap { $0.pools.first { $0.label == label } }
                .max { $0.percent < $1.percent }
        }
    }
}

enum AntigravityError: LocalizedError {
    case notInstalled
    case failed(String)
    case timedOut
    case badPayload

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Antigravity CLI (`agy`) isn’t installed."
        case .failed(let detail):
            return detail.isEmpty ? "Antigravity CLI couldn’t read usage. Run `agy` once and sign in." : detail
        case .timedOut:
            return "Antigravity CLI took too long to answer."
        case .badPayload:
            return "Couldn’t parse Antigravity usage."
        }
    }
}

/// Reads quota through the official `agy -p /usage --output-format json` (no model request, no quota used).
/// The CLI owns its sign-in, so this app never touches Antigravity credentials.
enum AntigravityAPI {
    private static let minInterval: TimeInterval = 60
    private static let lock = NSLock()
    private nonisolated(unsafe) static var last: AntigravitySnapshot?

    private static var executable: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/agy", "/usr/local/bin/agy", "/opt/homebrew/bin/agy"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func fetch() async throws -> AntigravitySnapshot {
        let cached = cachedSnapshot()
        // Spawning the CLI is comparatively heavy, so never more than once a minute.
        if let cached, Date().timeIntervalSince(cached.fetchedAt) < minInterval { return cached }

        guard let exe = executable else { throw AntigravityError.notInstalled }
        let output = try await run(exe)
        let snapshot = try parse(output)
        store(snapshot)
        return snapshot
    }

    private static func cachedSnapshot() -> AntigravitySnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return last
    }

    private static func store(_ snapshot: AntigravitySnapshot) {
        lock.lock()
        defer { lock.unlock() }
        last = snapshot
    }

    private static func run(_ exe: URL) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = exe
            process.arguments = ["-p", "/usage", "--output-format", "json"]
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { throw AntigravityError.failed("") }

            let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: killer)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            killer.cancel()
            if process.terminationReason == .uncaughtSignal { throw AntigravityError.timedOut }
            return data
        }.value
    }

    private static func parse(_ data: Data) throws -> AntigravitySnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AntigravityError.badPayload
        }
        guard (root["status"] as? String) == "SUCCESS" else {
            throw AntigravityError.failed((root["response"] as? String) ?? "")
        }
        guard
            let command = root["command"] as? [String: Any],
            let body = command["data"] as? [String: Any],
            let rawGroups = body["groups"] as? [[String: Any]]
        else { throw AntigravityError.badPayload }

        // The plain-text lines ("Group\tBucket\t100%\ttime") back up a bucket whose fraction JSON omitted.
        let textRemaining = textPercents(root["response"] as? String ?? "")

        var groups: [AntigravityGroup] = []
        for raw in rawGroups {
            guard let name = raw["name"] as? String, let buckets = raw["buckets"] as? [[String: Any]] else { continue }
            let pools = buckets.compactMap { bucket -> UsagePool? in
                guard let window = bucket["window"] as? String else { return nil }
                let seconds: Double = window == "5h" ? 5 * 3_600 : 7 * 86_400
                let bucketName = (bucket["name"] as? String) ?? ""
                let remaining = (bucket["remaining_fraction"] as? NSNumber)?.doubleValue
                    ?? textRemaining["\(name)|\(bucketName)"].map { $0 / 100 }
                guard let remaining else { return nil }
                let resets = (bucket["reset_time"] as? String).flatMap { AuthStore.parseDate($0) }
                return UsagePool(
                    label: UsagePool.label(forWindow: seconds),
                    percent: min(100, max(0, (1 - remaining) * 100)),
                    resetsAt: resets,
                    windowSeconds: seconds
                )
            }
            .sorted { $0.windowSeconds < $1.windowSeconds }
            if !pools.isEmpty { groups.append(AntigravityGroup(name: name, pools: pools)) }
        }
        guard !groups.isEmpty else { throw AntigravityError.badPayload }
        return AntigravitySnapshot(groups: groups, fetchedAt: Date())
    }

    private static func textPercents(_ text: String) -> [String: Double] {
        var out: [String: Double] = [:]
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: "\t").map(String.init)
            guard cols.count >= 3, let value = Double(cols[2].replacingOccurrences(of: "%", with: "")) else { continue }
            out["\(cols[0])|\(cols[1])"] = value
        }
        return out
    }
}
