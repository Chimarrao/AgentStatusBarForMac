import AppKit
import Foundation

@MainActor
final class UsageViewModel: ObservableObject {
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var identity: AuthIdentity?
    @Published private(set) var lastError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var serviceStatus: ServiceStatusSnapshot?

    @Published private(set) var cursorSnapshot: CursorSnapshot?
    @Published private(set) var cursorMessage: String?
    @Published private(set) var grokBotSnapshot: GrokBotSnapshot?
    @Published private(set) var grokBotMessage: String?
    @Published private(set) var claudeSnapshot: ClaudeSnapshot?
    @Published private(set) var claudeMessage: String?
    @Published private(set) var codexSnapshot: CodexSnapshot?
    @Published private(set) var codexMessage: String?
    @Published private(set) var antigravitySnapshot: AntigravitySnapshot?
    @Published private(set) var antigravityMessage: String?

    @Published var showGrokUsage: Bool {
        didSet {
            UserDefaults.standard.set(showGrokUsage, forKey: PrefKey.showGrok)
            if didStart { refresh(force: true) }
        }
    }
    @Published var showGrokBotUsage: Bool {
        didSet {
            UserDefaults.standard.set(showGrokBotUsage, forKey: PrefKey.showBot)
            if !showGrokBotUsage {
                grokBotSnapshot = nil
                grokBotMessage = nil
            }
            if didStart { refresh(force: true) }
        }
    }
    @Published var showCursorUsage: Bool {
        didSet {
            UserDefaults.standard.set(showCursorUsage, forKey: PrefKey.showCursor)
            if !showCursorUsage {
                cursorSnapshot = nil
                cursorMessage = nil
            }
            if didStart { refresh(force: true) }
        }
    }

    @Published var showClaudeUsage: Bool {
        didSet {
            UserDefaults.standard.set(showClaudeUsage, forKey: PrefKey.showClaude)
            if !showClaudeUsage {
                claudeSnapshot = nil
                claudeMessage = nil
            }
            if didStart { refresh(force: true) }
        }
    }

    @Published var showAntigravityUsage: Bool {
        didSet {
            UserDefaults.standard.set(showAntigravityUsage, forKey: PrefKey.showAntigravity)
            if !showAntigravityUsage {
                antigravitySnapshot = nil
                antigravityMessage = nil
            }
            if didStart { refresh(force: true) }
        }
    }

    @Published var showCodexUsage: Bool {
        didSet {
            UserDefaults.standard.set(showCodexUsage, forKey: PrefKey.showCodex)
            if !showCodexUsage {
                codexSnapshot = nil
                codexMessage = nil
            }
            if didStart { refresh(force: true) }
        }
    }

    /// Seconds between automatic usage reads (30 s, 1, 5 or 10 min).
    @Published var pollInterval: Double {
        didSet {
            UserDefaults.standard.set(pollInterval, forKey: PrefKey.pollInterval)
            if didStart { scheduleBackgroundPoll() }
        }
    }

    private enum PrefKey {
        static let pollInterval = "pollIntervalSeconds"
        static let showCodex = "showCodexUsage"
        static let showAntigravity = "showAntigravityUsage"
        static let showClaude = "showClaudeUsage"
        static let showGrok = "showGrokUsage"
        static let showBot = "showGrokBotUsage"
        static let showCursor = "showCursorUsage"
    }

    private var fetchTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var didStart = false
    private var lastFetchAttemptAt: Date?

    private var staleAfter: TimeInterval { max(pollInterval - 5, 10) }
    private let setupPollInterval: TimeInterval = 2 * 60
    private let outagePollInterval: TimeInterval = 5 * 60

    @Published private(set) var clockTick: Date = Date()

    init() {
        let defaults = UserDefaults.standard
        showGrokUsage = defaults.object(forKey: PrefKey.showGrok) as? Bool ?? true
        showGrokBotUsage = defaults.bool(forKey: PrefKey.showBot)
        showCursorUsage = defaults.bool(forKey: PrefKey.showCursor)
        let savedInterval = defaults.double(forKey: PrefKey.pollInterval)
        pollInterval = [30, 60, 300, 600].contains(savedInterval) ? savedInterval : 300
        showCodexUsage = defaults.object(forKey: PrefKey.showCodex) as? Bool ?? true
        showAntigravityUsage = defaults.object(forKey: PrefKey.showAntigravity) as? Bool ?? true
        claudeSnapshot = ClaudeAPI.cachedSnapshot()
        showClaudeUsage = defaults.object(forKey: PrefKey.showClaude) as? Bool ?? true
    }

    var hasActiveOutage: Bool {
        serviceStatus?.hasActiveIncident == true
    }

    var needsCursorSession: Bool {
        showCursorUsage || showGrokBotUsage
    }

    var menuBarTitle: String {
        _ = clockTick
        let outage = hasActiveOutage
        var parts: [String] = []
        if showCodexUsage {
            if let snap = codexSnapshot {
                parts.append(Self.poolsBarText(snap.pools))
            }
        }
        if showAntigravityUsage, let snap = antigravitySnapshot {
            parts.append(Self.poolsBarText(snap.barPools))
        }
        if showGrokUsage {
            switch state {
            case .loaded(let snap):
                parts.append(formatBar(percent: snap.usedPercent, resetsIn: snap.resetsIn))
            case .unavailable:
                parts.append(outage ? "⚠" : "—")
            case .failed:
                parts.append(outage ? "⚠" : "!")
            case .idle, .loading:
                parts.append(outage ? "⚠" : "…")
            }
        }
        if showGrokBotUsage {
            if let snap = grokBotSnapshot, let percent = snap.usedPercent, snap.hasAllowance {
                parts.append(formatBar(percent: percent, resetsIn: snap.resetsIn))
            } else if let grokBotMessage, !grokBotMessage.isEmpty {
                parts.append("—")
            }
        }
        if showCursorUsage {
            if let snap = cursorSnapshot {
                let auto = "\(Int(snap.cursorModelsPercent.rounded()))%"
                let api = "\(Int(snap.otherModelsPercent.rounded()))%"
                if let countdown = formatCountdown(snap.resetsIn, compact: true) {
                    parts.append("\(auto) \(api) \(countdown)")
                } else {
                    parts.append("\(auto) \(api)")
                }
            } else if cursorMessage != nil {
                parts.append("—")
            }
        }
        if showClaudeUsage {
            if let snap = claudeSnapshot {
                parts.append(Self.poolsBarText(snap.pools))
            }
        }
        if parts.isEmpty {
            return outage ? "⚠" : "—"
        }
        let joined = parts.joined(separator: "  ")
        if outage, showGrokUsage == false {
            return "⚠ \(joined)"
        }
        return joined
    }

    var menuBarAccessibilityLabel: String {
        _ = clockTick
        var parts: [String] = []
        if let status = serviceStatus, status.hasActiveIncident {
            parts.append("xAI status issue: \(status.headline)")
        }
        if showCodexUsage {
            if let snap = codexSnapshot {
                let text = snap.pools.map { pool -> String in
                    var t = "Codex \(pool.label.lowercased()) \(Int(pool.percent.rounded()))% used"
                    if let reset = formatCountdown(pool.resetsIn) { t += ", resets in \(reset)" }
                    return t
                }
                parts.append(text.joined(separator: ". "))
            } else if let codexMessage {
                parts.append("Codex: \(codexMessage)")
            }
        }
        if showAntigravityUsage {
            if let snap = antigravitySnapshot {
                let text = snap.groups.map { group in
                    group.name + ": " + group.pools.map { "\($0.label.lowercased()) \(Int($0.percent.rounded()))% used" }.joined(separator: ", ")
                }
                parts.append("Antigravity " + text.joined(separator: "; "))
            } else if let antigravityMessage {
                parts.append("Antigravity: \(antigravityMessage)")
            }
        }
        if showGrokUsage {
            switch state {
            case .loaded(let snap):
                let reset = formatCountdown(snap.resetsIn) ?? "unknown"
                parts.append(
                    "Grok \(Int(snap.usedPercent.rounded()))% used, \(snap.cycleLabel.lowercased()) pool, resets in \(reset)"
                )
            case .unavailable(let title, let hint):
                parts.append("Grok: \(title). \(hint)")
            case .failed(let message):
                parts.append("Grok usage error: \(message)")
            default:
                break
            }
        }
        if showGrokBotUsage {
            if let snap = grokBotSnapshot, let percent = snap.usedPercent {
                let reset = formatCountdown(snap.resetsIn) ?? "unknown"
                parts.append("Grok Bot \(Int(percent.rounded()))% used, weekly pool, resets in \(reset)")
            } else if let grokBotMessage {
                parts.append("Grok Bot: \(grokBotMessage)")
            }
        }
        if showCursorUsage {
            if let snap = cursorSnapshot {
                let reset = formatCountdown(snap.resetsIn) ?? "unknown"
                parts.append(
                    "Cursor Models \(Int(snap.cursorModelsPercent.rounded()))%, Other Models \(Int(snap.otherModelsPercent.rounded()))%, resets in \(reset)"
                )
            } else if let cursorMessage {
                parts.append("Cursor: \(cursorMessage)")
            }
        }
        if showClaudeUsage {
            if let snap = claudeSnapshot {
                let text = snap.pools.map { pool -> String in
                    var t = "Claude \(pool.label.lowercased()) \(Int(pool.percent.rounded()))% used"
                    if let reset = formatCountdown(pool.resetsIn) { t += ", resets in \(reset)" }
                    return t
                }
                parts.append(text.joined(separator: ". "))
            } else if let claudeMessage {
                parts.append("Claude: \(claudeMessage)")
            }
        }
        if parts.isEmpty {
            parts.append("AgentStatusBar. Open to choose what to show.")
        }
        return parts.joined(separator: ". ")
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        LoginItemService.ensureEnabled()
        loadCacheIntoState()
        refreshIfStale()
        scheduleBackgroundPoll()
        scheduleClockTick()
    }

    func panelDidOpen() {
        start()
        refreshIfStale()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        tickTask?.cancel()
        tickTask = nil
        fetchTask?.cancel()
        fetchTask = nil
        isRefreshing = false
    }

    func refresh() {
        refresh(force: true)
    }

    func refreshIfStale() {
        if !isStale { return }
        refresh(force: false)
    }

    private var isStale: Bool {
        if hasActiveOutage { return true }
        if showClaudeUsage, claudeSnapshot == nil { return true }
        if showCodexUsage, codexSnapshot == nil { return true }
        if showAntigravityUsage, antigravitySnapshot == nil { return true }
        if showGrokUsage, case .loaded(let snap) = state {
            if Date().timeIntervalSince(snap.fetchedAt) < staleAfter {
                // Still stale if an enabled extra has no snapshot yet.
                if showCursorUsage && cursorSnapshot == nil { return true }
                if showGrokBotUsage && grokBotSnapshot == nil { return true }
                return false
            }
        }
        if case .unavailable = state { return true }
        if case .failed = state { return true }
        if let last = lastFetchAttemptAt, Date().timeIntervalSince(last) < staleAfter {
            return false
        }
        return true
    }

    private func refresh(force: Bool) {
        if isRefreshing { return }
        if !force, !isStale { return }

        let hadLoadedData: Bool = {
            if case .loaded = state { return true }
            return false
        }()

        if showGrokUsage, !hadLoadedData {
            if case .idle = state {
                state = .loading
            } else if case .failed = state {
                state = .loading
            }
        }

        isRefreshing = true
        lastFetchAttemptAt = Date()

        let includeGrok = showGrokUsage
        let includeCursor = showCursorUsage
        let includeBot = showGrokBotUsage
        let includeClaude = showClaudeUsage
        let includeCodex = showCodexUsage
        let includeAntigravity = showAntigravityUsage

        fetchTask = Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isRefreshing = false
                    self.fetchTask = nil
                }
            }

            let result = await Task.detached(priority: .utility) {
                await Self.fetchInBackground(
                    includeGrok: includeGrok,
                    includeCursor: includeCursor,
                    includeGrokBot: includeBot,
                    includeClaude: includeClaude,
                    includeCodex: includeCodex,
                    includeAntigravity: includeAntigravity
                )
            }.value

            guard let self, !Task.isCancelled else { return }
            await self.apply(result: result, hadLoadedData: hadLoadedData)
        }
    }

    private func loadCacheIntoState() {
        guard let cached = UsageCache.load() else { return }
        if identity == nil, let email = cached.email {
            identity = AuthIdentity(
                email: email,
                teamID: nil,
                principalType: nil,
                authMode: nil,
                accessToken: "",
                expiresAt: nil,
                tier: cached.snapshot.subscriptionTier
            )
        }
        if case .loaded = state { return }
        state = .loaded(cached.snapshot)
    }

    private func apply(
        result: CombinedFetch,
        hadLoadedData: Bool
    ) async {
        if let status = result.serviceStatus {
            self.serviceStatus = status
        }

        if showGrokUsage {
            switch result.usage {
            case .success(let (identity, snapshot)):
                self.identity = identity
                self.state = .loaded(snapshot)
                self.lastError = nil
                UsageCache.save(snapshot, email: identity.email)

            case .failure(let error):
                let classified = classify(error, outage: result.serviceStatus)
                self.lastError = classified.menuMessage

                switch classified.kind {
                case .setup:
                    self.identity = nil
                    self.state = .unavailable(title: classified.menuMessage, hint: classified.hint)
                    UsageCache.clear()

                case .transient, .hard:
                    if !hadLoadedData {
                        if case .loaded = state {
                            // keep
                        } else {
                            state = .failed(classified.menuMessage)
                        }
                    }
                }
            case .none:
                break
            }
        }

        if showCursorUsage {
            switch result.cursor {
            case .success(let snap):
                cursorSnapshot = snap
                cursorMessage = snap.statusMessage
            case .failure(let error):
                cursorMessage = error.localizedDescription
            case .none:
                break
            }
        } else {
            cursorSnapshot = nil
            cursorMessage = nil
        }

        if showClaudeUsage {
            switch result.claude {
            case .success(let snap):
                claudeSnapshot = snap
                claudeMessage = nil
            case .failure(let error):
                // Keep the last good numbers on any error; only sign-out clears them.
                if case ClaudeError.notSignedIn = error {
                    claudeSnapshot = nil
                    claudeMessage = nil
                } else {
                    claudeMessage = error.localizedDescription
                }
            case .none:
                break
            }
        } else {
            claudeSnapshot = nil
            claudeMessage = nil
        }

        if showCodexUsage {
            switch result.codex {
            case .success(let snap):
                codexSnapshot = snap
                codexMessage = nil
            case .failure(let error):
                if case CodexError.notSignedIn = error {
                    codexSnapshot = nil
                    codexMessage = nil
                } else {
                    codexMessage = error.localizedDescription
                }
            case .none:
                break
            }
        } else {
            codexSnapshot = nil
            codexMessage = nil
        }

        if showAntigravityUsage {
            switch result.antigravity {
            case .success(let snap):
                antigravitySnapshot = snap
                antigravityMessage = nil
            case .failure(let error):
                if case AntigravityError.notInstalled = error {
                    antigravitySnapshot = nil
                    antigravityMessage = nil
                } else {
                    antigravityMessage = error.localizedDescription
                }
            case .none:
                break
            }
        } else {
            antigravitySnapshot = nil
            antigravityMessage = nil
        }

        if showGrokBotUsage {
            switch result.grokBot {
            case .success(let snap):
                grokBotSnapshot = snap
                grokBotMessage = snap.statusMessage
            case .failure(let error):
                grokBotSnapshot = nil
                grokBotMessage = error.localizedDescription
            case .none:
                break
            }
        } else {
            grokBotSnapshot = nil
            grokBotMessage = nil
        }
    }

    private enum FailureKind {
        case setup
        case transient
        case hard
    }

    private struct ClassifiedError {
        var kind: FailureKind
        var menuMessage: String
        var hint: String
    }

    private func classify(_ error: Error, outage: ServiceStatusSnapshot?) -> ClassifiedError {
        let outageHint: String? = {
            guard let outage, outage.hasActiveIncident else { return nil }
            return "xAI status: \(outage.headline). See status.x.ai"
        }()

        if let auth = error as? AuthStoreError {
            var hint = auth.recoveryHint
            if let outageHint, !auth.isSetupIssue {
                hint = outageHint
            }
            return ClassifiedError(
                kind: auth.isSetupIssue ? .setup : .transient,
                menuMessage: auth.errorDescription ?? "Not signed in to Grok.",
                hint: hint
            )
        }
        if let fetch = error as? UsageFetcherError {
            if fetch.isAuthIssue {
                return ClassifiedError(
                    kind: .setup,
                    menuMessage: "Grok session expired.",
                    hint: "Run `grok login` again. AgentStatusBar will recover on the next check."
                )
            }
            if fetch.isTransient {
                return ClassifiedError(
                    kind: .transient,
                    menuMessage: outageHint != nil
                        ? "Usage unreachable (possible outage)."
                        : (fetch.errorDescription ?? "Network error."),
                    hint: outageHint ?? "Will retry automatically."
                )
            }
            return ClassifiedError(
                kind: .hard,
                menuMessage: fetch.errorDescription ?? "Couldn’t load usage.",
                hint: outageHint ?? "Will retry automatically."
            )
        }
        return ClassifiedError(
            kind: .transient,
            menuMessage: error.localizedDescription,
            hint: outageHint ?? "Will retry automatically."
        )
    }

    private struct CombinedFetch: @unchecked Sendable {
        var usage: Result<(AuthIdentity, UsageSnapshot), Error>?
        var cursor: Result<CursorSnapshot, Error>?
        var grokBot: Result<GrokBotSnapshot, Error>?
        var claude: Result<ClaudeSnapshot, Error>?
        var codex: Result<CodexSnapshot, Error>?
        var antigravity: Result<AntigravitySnapshot, Error>?
        var serviceStatus: ServiceStatusSnapshot?
    }

    private nonisolated static func fetchInBackground(
        includeGrok: Bool,
        includeCursor: Bool,
        includeGrokBot: Bool,
        includeClaude: Bool,
        includeCodex: Bool,
        includeAntigravity: Bool
    ) async -> CombinedFetch {
        async let statusTask: ServiceStatusSnapshot? = {
            try? await StatusFetcher.fetch()
        }()

        var usage: Result<(AuthIdentity, UsageSnapshot), Error>?
        if includeGrok {
            usage = await fetchGrok()
        }

        var cursor: Result<CursorSnapshot, Error>?
        var grokBot: Result<GrokBotSnapshot, Error>?
        if includeCursor || includeGrokBot {
            do {
                let session = try CursorAuthStore.loadMatchingGrok()
                if includeCursor {
                    cursor = await captured { try await CursorAPI.fetchPeriod(session: session) }
                }
                if includeGrokBot {
                    grokBot = await captured { try await CursorAPI.fetchGrokBot(session: session) }
                }
            } catch {
                if includeCursor { cursor = .failure(error) }
                if includeGrokBot { grokBot = .failure(error) }
            }
        }

        var claude: Result<ClaudeSnapshot, Error>?
        if includeClaude {
            claude = await captured { try await ClaudeAPI.fetch() }
        }

        var codex: Result<CodexSnapshot, Error>?
        if includeCodex {
            codex = await captured { try await CodexAPI.fetch() }
        }

        var antigravity: Result<AntigravitySnapshot, Error>?
        if includeAntigravity {
            antigravity = await captured { try await AntigravityAPI.fetch() }
        }

        let status = await statusTask
        return CombinedFetch(usage: usage, cursor: cursor, grokBot: grokBot, claude: claude, codex: codex, antigravity: antigravity, serviceStatus: status)
    }

    private nonisolated static func fetchGrok() async -> Result<(AuthIdentity, UsageSnapshot), Error> {
        do {
            var identity = try await AuthStore.loadValidIdentity()
            do {
                let snapshot = try await UsageFetcher.fetch(
                    token: identity.accessToken,
                    subscriptionTier: identity.tier
                )
                return .success((identity, snapshot))
            } catch let fetch as UsageFetcherError {
                if case .unauthorized = fetch {
                    do {
                        let cred = try AuthStore.loadCredential()
                        let refreshed = try await AuthStore.refreshCredential(cred)
                        identity = refreshed.identity
                        let snapshot = try await UsageFetcher.fetch(
                            token: identity.accessToken,
                            subscriptionTier: identity.tier
                        )
                        return .success((identity, snapshot))
                    } catch let auth as AuthStoreError {
                        return .failure(auth)
                    } catch {
                        return .failure(AuthStoreError.sessionExpired)
                    }
                }
                return .failure(fetch)
            }
        } catch {
            return .failure(error)
        }
    }

    func openUsagePage() {
        if let url = URL(string: "https://grok.com/?_s=usage") {
            NSWorkspace.shared.open(url)
        }
    }

    func openBillingPage() {
        if let url = URL(string: "https://grok.com/?_s=billing") {
            NSWorkspace.shared.open(url)
        }
    }

    func openClaudeUsagePage() {
        if let url = URL(string: "https://claude.ai/settings/usage") {
            NSWorkspace.shared.open(url)
        }
    }

    static func poolsBarText(_ pools: [UsagePool]) -> String {
        pools.map { pool in
            "\(Int(pool.percent.rounded()))%"
        }.joined(separator: " | ")
    }

    func openCursorDashboard() {
        if let url = URL(string: "https://cursor.com/dashboard/usage") {
            NSWorkspace.shared.open(url)
        }
    }

    func openStatusPage() {
        if let link = serviceStatus?.activeIncidents.first?.link {
            NSWorkspace.shared.open(link)
            return
        }
        NSWorkspace.shared.open(StatusFetcher.statusPageURL)
    }

    func quit() {
        stop()
        NSApp.terminate(nil)
    }

    private var currentPollInterval: TimeInterval {
        if hasActiveOutage {
            return min(outagePollInterval, pollInterval)
        }
        if case .unavailable = state {
            return min(setupPollInterval, pollInterval)
        }
        return pollInterval
    }

    private func scheduleBackgroundPoll() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = await MainActor.run { self?.currentPollInterval ?? 20 * 60 }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.refresh(force: true)
            }
        }
    }

    private func scheduleClockTick() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.clockTick = Date()
            }
        }
    }

    private func formatBar(percent: Double, resetsIn: TimeInterval?) -> String {
        "\(Int(percent.rounded()))%"
    }
}

private func captured<T>(_ body: () async throws -> T) async -> Result<T, Error> {
    do {
        return .success(try await body())
    } catch {
        return .failure(error)
    }
}
