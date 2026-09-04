import Foundation

enum CursorAPIError: LocalizedError {
    case unauthorized
    case httpStatus(Int)
    case badPayload
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Cursor session expired. Sign in to Cursor again."
        case .httpStatus(let code):
            return "Cursor usage returned HTTP \(code)."
        case .badPayload:
            return "Couldn’t parse Cursor usage."
        case .transport:
            return "Network error while loading Cursor usage."
        }
    }
}

/// Cursor Connect-RPC dashboard methods used for monthly pools and Grok Bot.
enum CursorAPI {
    private static let base = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService")!

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    static func fetchPeriod(session creds: CursorSession) async throws -> CursorSnapshot {
        let root = try await post("GetCurrentPeriodUsage", token: creds.accessToken)
        guard let plan = root["planUsage"] as? [String: Any] else {
            throw CursorAPIError.badPayload
        }

        async let planName = optionalPlanName(token: creds.accessToken)
        async let account = optionalAccount(token: creds.accessToken)
        let (name, identity) = await (planName, account)

        let membership = (name?.isEmpty == false ? name : nil)
            ?? creds.membershipType
            ?? (root["membershipType"] as? String)
            ?? "Cursor"

        return CursorSnapshot(
            cursorModelsPercent: doubleValue(plan["autoPercentUsed"]) ?? 0,
            otherModelsPercent: doubleValue(plan["apiPercentUsed"]) ?? 0,
            periodStart: parseWhen(root["billingCycleStart"]),
            periodEnd: parseWhen(root["billingCycleEnd"]),
            planName: formatPlan(membership),
            accountName: identity?.name,
            accountEmail: identity?.email ?? creds.email,
            statusMessage: nil,
            fetchedAt: Date()
        )
    }

    static func fetchGrokBot(session creds: CursorSession) async throws -> GrokBotSnapshot {
        let root = try await post("GetSandUsageStatus", token: creds.accessToken)
        let hasLimit = boolValue(root["hasNonZeroIncludedLimit"])
        let label = (root["grokPlanLabel"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Grok Bot"
        let percent = doubleValue(root["usagePercent"])
        let start = parseWhen(root["currentPeriodStart"])
        let end = parseWhen(root["nextResetTimestampUtc"])

        let identity = await optionalAccount(token: creds.accessToken)
        let email = identity?.email ?? creds.email
        let name = identity?.name

        if !hasLimit {
            return GrokBotSnapshot(
                usedPercent: nil,
                periodStart: start,
                periodEnd: end,
                planLabel: label,
                accountName: name,
                accountEmail: email,
                statusMessage: "This Cursor account has no included Grok Bot weekly pool.",
                hasAllowance: false,
                fetchedAt: Date()
            )
        }

        return GrokBotSnapshot(
            usedPercent: percent,
            periodStart: start,
            periodEnd: end ?? start?.addingTimeInterval(7 * 86_400),
            planLabel: label,
            accountName: name,
            accountEmail: email,
            statusMessage: percent == nil ? "Grok Bot usage response did not include a percentage." : nil,
            hasAllowance: percent != nil,
            fetchedAt: Date()
        )
    }

    private static func optionalPlanName(token: String) async -> String? {
        guard let root = try? await post("GetPlanInfo", token: token),
              let info = root["planInfo"] as? [String: Any],
              let name = info["planName"] as? String,
              !name.isEmpty
        else { return nil }
        return name
    }

    private static func optionalAccount(token: String) async -> (name: String?, email: String?)? {
        guard let root = try? await post("GetMe", token: token) else { return nil }
        let email = root["email"] as? String
        if let name = root["name"] as? String, !name.isEmpty {
            return (name, email)
        }
        let first = (root["firstName"] as? String) ?? (root["given_name"] as? String) ?? ""
        let last = (root["lastName"] as? String) ?? (root["family_name"] as? String) ?? ""
        let combined = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
        return (combined.isEmpty ? nil : combined, email)
    }

    private static func post(_ method: String, token: String) async throws -> [String: Any] {
        let url = base.appendingPathComponent(method)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("grokbar/1.1", forHTTPHeaderField: "User-Agent")
        request.httpBody = Data("{}".utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CursorAPIError.transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 401 || status == 403 {
            throw CursorAPIError.unauthorized
        }
        guard (200...299).contains(status) else {
            throw CursorAPIError.httpStatus(status)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CursorAPIError.badPayload
        }
        return root
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let n = value as? Double { return n }
        if let n = value as? Int { return Double(n) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String, let n = Double(s) { return n }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String { return ["true", "1", "yes"].contains(s.lowercased()) }
        return false
    }

    private static func parseWhen(_ value: Any?) -> Date? {
        if let n = value as? Double {
            let seconds = abs(n) >= 1e11 ? n / 1000 : n
            return Date(timeIntervalSince1970: seconds)
        }
        if let n = value as? Int {
            return parseWhen(Double(n))
        }
        if let s = value as? String, !s.isEmpty {
            if let n = Double(s), s.allSatisfy({ $0.isNumber || $0 == "." || $0 == "+" || $0 == "-" }) {
                return parseWhen(n)
            }
            return AuthStore.parseDate(s)
        }
        return nil
    }

    private static func formatPlan(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "Cursor" }
        if text.contains(where: { $0.isUppercase }) && text.contains(" ") {
            return text
        }
        return text
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.localizedCapitalized }
            .joined(separator: " ")
    }
}
