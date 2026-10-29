import Foundation

struct CodexSnapshot: Equatable, Sendable {
    var pools: [UsagePool]
    var planName: String
    var fetchedAt: Date
    var creditRows: [CreditRow] = []
}

enum CodexError: LocalizedError {
    case notSignedIn
    case expired
    case unauthorized
    case httpStatus(Int)
    case badPayload
    case transport

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in with Codex (`codex login`) so AgentStatusBar can read your usage."
        case .expired:
            return "Codex sign-in expired. Run `codex` once to refresh it."
        case .unauthorized:
            return "ChatGPT rejected the session. Run `codex` once to refresh it."
        case .httpStatus(let code):
            return "Codex usage returned HTTP \(code)."
        case .badPayload:
            return "Couldn’t parse Codex usage."
        case .transport:
            return "Network error while loading Codex usage."
        }
    }
}

/// Reads the ChatGPT session the Codex CLI keeps in `$CODEX_HOME/auth.json` (default `~/.codex`).
/// Never refreshes it: Codex rotates refresh tokens, so refreshing here could sign you out there.
enum CodexAuthStore {
    struct Credential: Sendable {
        var accessToken: String
        var accountID: String?
    }

    private static var authFile: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        return home.appendingPathComponent("auth.json")
    }

    static func load() throws -> Credential {
        guard
            let data = try? Data(contentsOf: authFile),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = json["tokens"] as? [String: Any],
            let token = tokens["access_token"] as? String, !token.isEmpty
        else { throw CodexError.notSignedIn }

        if let exp = jwtExpiry(token), exp <= Date() { throw CodexError.expired }
        return Credential(accessToken: token, accountID: tokens["account_id"] as? String)
    }

    private static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard
            let data = Data(base64Encoded: payload),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let exp = (json["exp"] as? NSNumber)?.doubleValue
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}

enum CodexAPI {
    private static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    static func fetch() async throws -> CodexSnapshot {
        let credential = try CodexAuthStore.load()

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 20
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        if let id = credential.accountID, !id.isEmpty {
            request.setValue(id, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("agentstatusbar/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CodexError.transport
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 401 || status == 403 { throw CodexError.unauthorized }
        guard (200...299).contains(status) else { throw CodexError.httpStatus(status) }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let limits = root["rate_limit"] as? [String: Any]
        else { throw CodexError.badPayload }

        let pools = ["primary_window", "secondary_window"].compactMap { window(limits[$0]) }
        guard !pools.isEmpty else { throw CodexError.badPayload }

        return CodexSnapshot(
            pools: pools,
            planName: planName(root["plan_type"] as? String),
            fetchedAt: Date(),
            creditRows: creditRows(root["credits"])
        )
    }

    /// ChatGPT credits; hidden when the account has none.
    private static func creditRows(_ value: Any?) -> [CreditRow] {
        guard let credits = value as? [String: Any], (credits["has_credits"] as? Bool) == true else { return [] }
        if (credits["unlimited"] as? Bool) == true { return [CreditRow(label: "Credits", value: "Unlimited")] }
        let raw = credits["balance"]
        let text = (raw as? String) ?? (raw as? NSNumber).map { "\($0)" } ?? ""
        guard !text.isEmpty, (Double(text) ?? 1) > 0 else { return [] }
        return [CreditRow(label: "Balance", value: text)]
    }

    private static func window(_ value: Any?) -> UsagePool? {
        guard let dict = value as? [String: Any],
              let percent = (dict["used_percent"] as? NSNumber)?.doubleValue
        else { return nil }
        let resets: Date?
        if let at = (dict["reset_at"] as? NSNumber)?.doubleValue {
            resets = Date(timeIntervalSince1970: at)
        } else if let after = (dict["reset_after_seconds"] as? NSNumber)?.doubleValue {
            resets = Date().addingTimeInterval(after)
        } else {
            resets = nil
        }
        let seconds = (dict["limit_window_seconds"] as? NSNumber)?.doubleValue ?? 5 * 3_600
        return UsagePool(label: UsagePool.label(forWindow: seconds), percent: percent, resetsAt: resets, windowSeconds: seconds)
    }

    private static func planName(_ raw: String?) -> String {
        let text = (raw ?? "").trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "Codex" : "Codex " + text.capitalized
    }
}
