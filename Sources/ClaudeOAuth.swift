import CryptoKit
import Foundation

/// AgentStatusBar's own Claude sign-in, separate from Claude Code's.
///
/// Claude Code's access token lives ~8 h and only Claude Code renews it (when it makes a real request),
/// so a menu-bar reader that borrows it goes stale a few times a day. Renewing Claude Code's token from
/// here would spend its single-use refresh token and could sign Claude Code out. Instead the user
/// authorizes this app once (browser + paste a code); it then keeps its *own* refresh token, renews it
/// on its own, never touches Claude Code's credentials and never makes a model request.
struct ClaudeOwnSession: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var planName: String?
}

enum ClaudeOwnAuth {
    struct Pending: Sendable {
        let url: URL
        let verifier: String
        let state: String
    }

    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let authorizeURL = "https://claude.com/cai/oauth/authorize"
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    private static let redirectURI = "https://platform.claude.com/oauth/code/callback"
    /// Enough for the usage endpoint; deliberately no inference scope.
    private static let scope = "user:profile"

    // MARK: Storage (0600 file, so a rebuilt/ad-hoc-signed app never triggers Keychain prompts)

    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentStatusBar/claude-session.json")
    }

    static func load() -> ClaudeOwnSession? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(ClaudeOwnSession.self, from: data)
    }

    static func save(_ session: ClaudeOwnSession) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(session) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: Authorization (OAuth code + PKCE, same public client as Claude Code)

    static func begin() -> Pending {
        let verifier = randomURLSafe(32)
        let state = randomURLSafe(32)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        var components = URLComponents(string: authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return Pending(url: components.url!, verifier: verifier, state: state)
    }

    /// `pasted` is what the browser shows after authorizing: `CODE#STATE`.
    static func complete(pasted: String, pending: Pending) async throws -> ClaudeOwnSession {
        let parts = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .map(String.init)
        guard let code = parts.first, !code.isEmpty else { throw ClaudeError.connectFailed }
        if parts.count > 1, !parts[1].isEmpty, parts[1] != pending.state { throw ClaudeError.connectFailed }

        let tokens = try await post([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": pending.verifier,
            "state": pending.state,
        ])
        guard let refresh = tokens.refresh else { throw ClaudeError.connectFailed }
        var session = ClaudeOwnSession(
            accessToken: tokens.access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(tokens.expiresIn)
        )
        session.planName = await fetchPlanName(accessToken: tokens.access)
        return session
    }

    /// Renews with this app's own refresh token. The new refresh token replaces the old one,
    /// so callers must persist the result before using it.
    static func refresh(_ session: ClaudeOwnSession) async throws -> ClaudeOwnSession {
        let tokens = try await post([
            "grant_type": "refresh_token",
            "refresh_token": session.refreshToken,
            "client_id": clientID,
            "scope": scope,
        ])
        var updated = session
        updated.accessToken = tokens.access
        if let refresh = tokens.refresh, !refresh.isEmpty { updated.refreshToken = refresh }
        updated.expiresAt = Date().addingTimeInterval(tokens.expiresIn)
        return updated
    }

    // MARK: HTTP

    private struct Tokens {
        var access: String
        var refresh: String?
        var expiresIn: Double
    }

    private static func post(_ body: [String: String]) async throws -> Tokens {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("claude-code/\(ClaudeAPI.cliVersion)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClaudeError.transport
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        // 400/401 from the token endpoint means the code or refresh token is no longer valid.
        if status == 400 || status == 401 { throw ClaudeError.expired }
        guard (200...299).contains(status) else { throw ClaudeError.httpStatus(status) }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let access = json["access_token"] as? String, !access.isEmpty
        else { throw ClaudeError.badPayload }
        return Tokens(
            access: access,
            refresh: json["refresh_token"] as? String,
            expiresIn: (json["expires_in"] as? NSNumber)?.doubleValue ?? 8 * 3_600
        )
    }

    /// Best effort: the usage endpoint doesn't say which plan this is, the profile endpoint does.
    private static func fetchPlanName(accessToken: String) async -> String? {
        var request = URLRequest(url: profileURL)
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/\(ClaudeAPI.cliVersion)", forHTTPHeaderField: "User-Agent")
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let org = json["organization"] as? [String: Any]
        let type = ((org?["organization_type"] as? String) ?? "").lowercased()
        let tier = ((org?["rate_limit_tier"] as? String) ?? "").lowercased()
        if type.contains("max") || tier.contains("max") {
            let multiplier = ["20x", "5x"].first { tier.contains($0) }
            return multiplier.map { "Claude Max \($0)" } ?? "Claude Max"
        }
        if type.contains("pro") { return "Claude Pro" }
        if type.contains("team") { return "Claude Team" }
        if type.contains("enterprise") { return "Claude Enterprise" }
        return nil
    }

    // MARK: PKCE helpers

    private static func randomURLSafe(_ bytes: Int) -> String {
        base64URL(Data((0..<bytes).map { _ in UInt8.random(in: 0...255) }))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Hands out a valid access token for the app's own Claude session, renewing it ahead of expiry.
/// An actor so two polls can never spend the same single-use refresh token.
actor ClaudeOwnTokenProvider {
    static let shared = ClaudeOwnTokenProvider()
    private var lastFailure = Date.distantPast

    /// nil when the user hasn't connected Claude.
    func session() async throws -> ClaudeOwnSession? {
        guard let current = ClaudeOwnAuth.load() else { return nil }
        if current.expiresAt.timeIntervalSinceNow > 600 { return current }
        if Date().timeIntervalSince(lastFailure) < 60 { throw ClaudeError.transport }

        do {
            let renewed = try await ClaudeOwnAuth.refresh(current)
            ClaudeOwnAuth.save(renewed) // persist before anything else: the old refresh token is now spent
            return renewed
        } catch ClaudeError.expired {
            // The refresh token itself was revoked: drop the session so the user can reconnect.
            ClaudeOwnAuth.clear()
            throw ClaudeError.expired
        } catch {
            lastFailure = Date()
            throw error
        }
    }
}
