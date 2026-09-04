import Foundation
import SQLite3

struct CursorSession: Equatable, Sendable {
    var accessToken: String
    var email: String
    var membershipType: String?
}

enum CursorAuthError: LocalizedError {
    case missingStateDB
    case databaseOpenFailed
    case missingAccessToken
    case grokEmailMissing
    case accountMismatch

    var errorDescription: String? {
        switch self {
        case .missingStateDB:
            return "Cursor isn’t installed or signed in on this Mac."
        case .databaseOpenFailed:
            return "Couldn’t read the Cursor session."
        case .missingAccessToken:
            return "Sign in to Cursor, then try again."
        case .grokEmailMissing:
            return "Sign in to Grok so Cursor usage can match the same account."
        case .accountMismatch:
            return "Cursor is signed in as a different account than Grok."
        }
    }
}

/// Cursor IDE + CLI session, shown only when the email matches Grok.
enum CursorAuthStore {
    private static var ideStateDB: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    private static var cliAuthCandidates: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".config", isDirectory: true)
        return [
            xdg.appendingPathComponent("cursor/auth.json"),
            home.appendingPathComponent(".cursor/auth.json"),
        ]
    }

    static func grokEmail() -> String {
        (try? AuthStore.loadCredential())?.identity.email?.normalizedEmail() ?? ""
    }

    static func loadMatchingGrok() throws -> CursorSession {
        let grok = grokEmail()
        guard !grok.isEmpty else { throw CursorAuthError.grokEmailMissing }

        let cli = loadCLI(matching: grok)
        let ide = loadIDE(matching: grok)
        if let session = cli ?? ide {
            return session
        }
        if cli == nil && ide == nil {
            // Session exists but belongs to someone else, or nothing is signed in.
            if hasAnyCursorSession() {
                throw CursorAuthError.accountMismatch
            }
            throw CursorAuthError.missingAccessToken
        }
        throw CursorAuthError.missingAccessToken
    }

    private static func hasAnyCursorSession() -> Bool {
        loadCLI(matching: nil) != nil || loadIDE(matching: nil) != nil
    }

    private static func loadCLI(matching grok: String?) -> CursorSession? {
        for url in cliAuthCandidates where FileManager.default.fileExists(atPath: url.path) {
            guard
                let data = try? Data(contentsOf: url),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let token = (json["accessToken"] as? String) ?? (json["access_token"] as? String) ?? ""
            guard !token.isEmpty else { continue }
            let email = cliProfileEmail(authURL: url, subject: jwtSubject(token))
                ?? (json["email"] as? String)
                ?? ""
            if let grok, !email.emailsMatch(grok) { continue }
            return CursorSession(
                accessToken: token,
                email: email,
                membershipType: json["membershipType"] as? String
            )
        }
        return nil
    }

    private static func cliProfileEmail(authURL: URL, subject: String?) -> String? {
        let config = authURL.deletingLastPathComponent().appendingPathComponent("cli-config.json")
        guard
            let data = try? Data(contentsOf: config),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let info = json["authInfo"] as? [String: Any]
        else { return nil }
        if let subject, let authID = info["authId"] as? String, !authID.isEmpty, authID != subject {
            return nil
        }
        return info["email"] as? String
    }

    private static func loadIDE(matching grok: String?) -> CursorSession? {
        let path = ideStateDB.path
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else { return nil }
        _ = sqlite3_exec(db, "PRAGMA query_only = ON;", nil, nil, nil)

        guard let token = stringValue(db: db, key: "cursorAuth/accessToken"), !token.isEmpty else {
            return nil
        }
        let email = stringValue(db: db, key: "cursorAuth/cachedEmail") ?? ""
        if let grok, !email.emailsMatch(grok) { return nil }
        return CursorSession(
            accessToken: token,
            email: email,
            membershipType: stringValue(db: db, key: "cursorAuth/stripeMembershipType")
        )
    }

    private static func stringValue(db: OpaquePointer?, key: String) -> String? {
        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW, let cString = sqlite3_column_text(stmt, 0) else {
            return nil
        }
        return String(cString: cString)
    }

    private static func jwtSubject(_ token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - payload.count % 4) % 4
        if pad > 0 { payload += String(repeating: "=", count: pad) }
        guard
            let data = Data(base64Encoded: payload),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["sub"] as? String
    }
}

private extension String {
    func normalizedEmail() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func emailsMatch(_ other: String) -> Bool {
        let a = normalizedEmail()
        let b = other.normalizedEmail()
        return !a.isEmpty && a == b
    }
}
