import Foundation

/// One usage window (5h session, weekly, monthly…) shared by Claude and Codex.
struct UsagePool: Equatable, Sendable, Codable {
    var label: String
    var percent: Double
    var resetsAt: Date?
    var windowSeconds: Double

    var resetsIn: TimeInterval? { resetsAt.map { $0.timeIntervalSinceNow } }

    static func label(forWindow seconds: Double) -> String {
        switch seconds {
        case ..<(6 * 3_600): return "Session"
        case ..<(8 * 86_400): return "Weekly"
        default: return "Monthly"
        }
    }
}

/// One "label  value" line in the extra-credits section.
struct CreditRow: Equatable, Sendable, Codable {
    var label: String
    var value: String
}

struct ClaudeSnapshot: Equatable, Sendable, Codable {
    /// Rolling 5-hour session pool, 0…100.
    var sessionPercent: Double
    var sessionResetsAt: Date?
    /// Weekly pool across all models, 0…100.
    var weeklyPercent: Double?
    var weeklyResetsAt: Date?
    /// Weekly per-model pools when the plan reports them.
    var opusPercent: Double?
    var sonnetPercent: Double?
    var planName: String
    var fetchedAt: Date
    var creditRows: [CreditRow] = []

    var pools: [UsagePool] {
        var out = [UsagePool(label: "Session", percent: sessionPercent, resetsAt: sessionResetsAt, windowSeconds: 5 * 3_600)]
        if let weeklyPercent {
            out.append(UsagePool(label: "Weekly", percent: weeklyPercent, resetsAt: weeklyResetsAt, windowSeconds: 7 * 86_400))
        }
        return out
    }

    var sessionResetsIn: TimeInterval? {
        sessionResetsAt.map { $0.timeIntervalSinceNow }
    }

    var weeklyResetsIn: TimeInterval? {
        weeklyResetsAt.map { $0.timeIntervalSinceNow }
    }
}

enum ClaudeError: LocalizedError {
    case notSignedIn
    case expired
    case unauthorized
    case httpStatus(Int)
    case badPayload
    case transport
    case rateLimited(until: Date)

    var errorDescription: String? {
        switch self {
        case .rateLimited(let until):
            let f = DateFormatter()
            f.timeStyle = .short
            return "Claude is rate-limiting usage checks. Trying again at \(f.string(from: until))."
        case .notSignedIn:
            return "Sign in to Claude Code (`claude`, then /login) so AgentStatusBar can read your usage."
        case .expired:
            return "Claude sign-in expired. Open Claude Code once to refresh it."
        case .unauthorized:
            return "Claude rejected the session. Open Claude Code once to refresh it."
        case .httpStatus(let code):
            return "Claude usage returned HTTP \(code)."
        case .badPayload:
            return "Couldn’t parse Claude usage."
        case .transport:
            return "Network error while loading Claude usage."
        }
    }
}

/// Reads the OAuth session Claude Code already keeps on this Mac.
/// AgentStatusBar never refreshes it: Claude Code rotates refresh tokens, so refreshing here could sign you out there.
enum ClaudeAuthStore {
    struct Credential: Sendable {
        var accessToken: String
        var expiresAt: Date?
        var subscriptionType: String?
    }

    private static var credentialsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
    }

    static func load() throws -> Credential {
        if let data = keychainData() ?? (try? Data(contentsOf: credentialsFile)),
           let credential = parse(data)
        {
            if let expiresAt = credential.expiresAt, expiresAt <= Date() {
                throw ClaudeError.expired
            }
            return credential
        }
        throw ClaudeError.notSignedIn
    }

    private static func parse(_ data: Data) -> Credential? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = json["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        let expiresAt = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Credential(
            accessToken: token,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String
        )
    }

    private static func keychainData() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }
}

enum ClaudeAPI {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// Installed Claude Code version (this endpoint gives `claude-code/*` clients a far higher allowance).
    private static let cliVersion: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in ["\(home)/.local/bin/claude", "/usr/local/bin/claude", "/opt/homebrew/bin/claude"]
        where FileManager.default.isExecutableFile(atPath: path) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["--version"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()
            if let v = out.split(separator: " ").first, v.contains(".") { return String(v) }
        }
        return "2.1.0"
    }()

    private static let cacheKey = "claudeUsageCache"
    private static let backoffKey = "claudeUsageBackoffUntil.v2"

    /// Last good reading, kept across launches so errors can still show something.
    static func cachedSnapshot() -> ClaudeSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(ClaudeSnapshot.self, from: data)
    }

    /// Polls as often as asked; only pauses when Anthropic answers 429 (honouring Retry-After).
    static func fetch() async throws -> ClaudeSnapshot {
        let defaults = UserDefaults.standard
        if let backoff = defaults.object(forKey: backoffKey) as? Date, backoff > Date() {
            throw ClaudeError.rateLimited(until: backoff)
        }
        do {
            let snapshot = try await fetchRemote()
            if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: cacheKey) }
            defaults.removeObject(forKey: backoffKey)
            return snapshot
        } catch ClaudeError.rateLimited(let until) {
            defaults.set(until, forKey: backoffKey)
            throw ClaudeError.rateLimited(until: until)
        }
    }

    private static func fetchRemote() async throws -> ClaudeSnapshot {
        let credential = try ClaudeAuthStore.load()

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 20
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("claude-code/\(cliVersion)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClaudeError.transport
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 429 {
            let wait = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
                .flatMap { Double($0) } ?? 60
            throw ClaudeError.rateLimited(until: Date().addingTimeInterval(max(wait, 30)))
        }
        if status == 401 || status == 403 { throw ClaudeError.unauthorized }
        guard (200...299).contains(status) else { throw ClaudeError.httpStatus(status) }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeError.badPayload
        }

        guard let session = pool(root["five_hour"]) ?? pool(root["seven_day"]) else {
            throw ClaudeError.badPayload
        }
        let weekly = pool(root["seven_day"])
        return ClaudeSnapshot(
            sessionPercent: session.percent,
            sessionResetsAt: session.resetsAt,
            weeklyPercent: weekly?.percent,
            weeklyResetsAt: weekly?.resetsAt,
            opusPercent: pool(root["seven_day_opus"])?.percent,
            sonnetPercent: pool(root["seven_day_sonnet"])?.percent,
            planName: planName(credential.subscriptionType),
            fetchedAt: Date(),
            creditRows: creditRows(root)
        )
    }

    /// Usage credits (spent beyond the plan). Hidden unless enabled and actually in use.
    private static func creditRows(_ root: [String: Any]) -> [CreditRow] {
        guard let extra = root["extra_usage"] as? [String: Any],
              (extra["is_enabled"] as? Bool) == true
        else { return [] }
        let currency = (extra["currency"] as? String) ?? "USD"
        let places = (extra["decimal_places"] as? NSNumber)?.intValue ?? 2
        let spent = (extra["used_credits"] as? NSNumber)?.doubleValue ?? 0
        let limit = (extra["monthly_limit"] as? NSNumber)?.doubleValue
        let balance = minorAmount((root["spend"] as? [String: Any])?["balance"])

        func money(_ minor: Double) -> String {
            let f = NumberFormatter()
            f.numberStyle = .currency
            f.currencyCode = currency
            f.minimumFractionDigits = places
            f.maximumFractionDigits = places
            return f.string(from: NSNumber(value: minor / pow(10, Double(places)))) ?? "\(minor)"
        }

        guard spent > 0 || (balance ?? 0) > 0 else { return [] }
        var rows: [CreditRow] = []
        if let balance, balance > 0 { rows.append(CreditRow(label: "Balance", value: money(balance))) }
        rows.append(CreditRow(label: "Spent this month", value: money(spent)))
        rows.append(CreditRow(label: "Spend limit", value: limit.map(money) ?? "No limit"))
        return rows
    }

    private static func minorAmount(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let d = value as? [String: Any] { return (d["amount_minor"] as? NSNumber)?.doubleValue }
        return nil
    }

    private static func pool(_ value: Any?) -> (percent: Double, resetsAt: Date?)? {
        guard let dict = value as? [String: Any],
              let percent = (dict["utilization"] as? NSNumber)?.doubleValue
        else { return nil }
        let resets = (dict["resets_at"] as? String).flatMap { AuthStore.parseDate($0) }
        return (percent, resets)
    }

    private static func planName(_ raw: String?) -> String {
        let text = (raw ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if text.isEmpty { return "Claude" }
        if text.contains("max") {
            let tier = text.filter(\.isNumber)
            return tier.isEmpty ? "Claude Max" : "Claude Max \(tier)x"
        }
        return "Claude " + text.capitalized
    }
}
