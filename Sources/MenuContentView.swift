import AppKit
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var model: UsageViewModel
    @State private var showingSettings = false
    @State private var grokIdentityOpen = false
    @State private var grokBotIdentityOpen = false
    @State private var cursorIdentityOpen = false
    @State private var claudeIdentityOpen = false
    @State private var codexIdentityOpen = false
    @State private var antigravityIdentityOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if showingSettings {
                settingsPage
            } else {
                usagePage
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if showingSettings {
                Button {
                    showingSettings = false
                } label: {
                    Label("Settings", systemImage: "chevron.backward")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Back")
                Spacer()
            } else {
                Spacer()
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
                .accessibilityLabel("Settings")

                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isRefreshing)
                .help("Refresh")
                .accessibilityLabel("Refresh")
            }
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var usagePage: some View {
        let _ = model.clockTick

        if model.hasActiveOutage {
            outageBanner
        }

        let cards: [(id: String, card: AnyView)] = visibleCards
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider() }
                item.card
            }
            if cards.isEmpty {
                Text("No signed-in agents found. Sign in to Claude Code, Codex, Grok or Cursor.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        Divider()
        HStack {
            Button("Quit AgentStatusBar") {
                model.quit()
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .font(.callout)
            .keyboardShortcut("q")
            Spacer()
        }
    }

    /// Only providers that are enabled and signed in (or still loading / needing a refresh).
    private var visibleCards: [(id: String, card: AnyView)] {
        var out: [(id: String, card: AnyView)] = []
        if model.showClaudeUsage, model.claudeSnapshot != nil || model.claudeMessage != nil {
            out.append(("claude", AnyView(claudeCard)))
        }
        if model.showCodexUsage, model.codexSnapshot != nil || model.codexMessage != nil {
            out.append(("codex", AnyView(codexCard)))
        }
        if model.showAntigravityUsage, model.antigravitySnapshot != nil || model.antigravityMessage != nil {
            out.append(("antigravity", AnyView(antigravityCard)))
        }
        if model.showGrokUsage {
            var signedOut = false
            if case .unavailable = model.state { signedOut = true }
            if !signedOut { out.append(("grok", AnyView(grokCard))) }
        }
        if model.showGrokBotUsage, model.grokBotSnapshot != nil || model.grokBotMessage != nil {
            out.append(("bot", AnyView(grokBotCard)))
        }
        if model.showCursorUsage, model.cursorSnapshot != nil || model.cursorMessage != nil {
            out.append(("cursor", AnyView(cursorCard)))
        }
        return out
    }

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Show in Menu Bar")
                .font(.headline)
            Toggle("Claude", isOn: $model.showClaudeUsage)
            Toggle("Codex", isOn: $model.showCodexUsage)
            Toggle("Antigravity", isOn: $model.showAntigravityUsage)
            Toggle("SuperGrok", isOn: $model.showGrokUsage)
            Toggle("Grok Bot", isOn: $model.showGrokBotUsage)
            Toggle("Cursor", isOn: $model.showCursorUsage)
            Divider()
            HStack {
                Text("Refresh usage every")
                    .font(.callout)
                Spacer()
                Picker("", selection: $model.pollInterval) {
                    Text("30 sec").tag(30.0)
                    Text("1 min").tag(60.0)
                    Text("5 min").tag(300.0)
                    Text("10 min").tag(600.0)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            Text("Grok Bot and Cursor use your Cursor session when it matches the Grok account.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.checkbox)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var claudeCard: some View {
        if let snap = model.claudeSnapshot {
            providerHeader(
                icon: ProviderIcons.claude,
                title: snap.planName,
                name: nil,
                email: nil,
                identityOpen: $claudeIdentityOpen
            )
            ForEach(snap.pools, id: \.label) { pool in
                poolBlock(pool)
            }
            creditsBlock(snap.creditRows)
            staleNote(snap.fetchedAt, model.claudeMessage)
        } else if let message = model.claudeMessage {
            providerHeader(
                icon: ProviderIcons.claude,
                title: "Claude",
                name: nil,
                email: nil,
                identityOpen: $claudeIdentityOpen
            )
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.isRefreshing {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading Claude…")
                    .foregroundStyle(.secondary)
            }
        }
    }



    @ViewBuilder
    private func creditsBlock(_ rows: [CreditRow]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Extra credits")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(rows, id: \.label) { row in
                    HStack {
                        Text(row.label)
                            .font(.callout)
                        Spacer(minLength: 8)
                        Text(row.value)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func grokCreditRows(_ snap: UsageSnapshot) -> [CreditRow] {
        guard let cents = snap.prepaidBalanceCents, cents > 0 else { return [] }
        return [CreditRow(label: "Balance", value: formatUSD(cents: cents))]
    }

    private func staleNote(_ fetchedAt: Date, _ message: String?) -> some View {
        Group {
            if let message, !message.isEmpty {
                Text("Showing last update from \(fetchedAt.formatted(date: .omitted, time: .shortened)). \(message)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func poolBlock(_ pool: UsagePool) -> some View {
        let start = pool.resetsAt.map { $0.addingTimeInterval(-pool.windowSeconds) }
        return usageBlock(
            usedLabel: "\(pool.label) · \(Int(pool.percent.rounded()))% used",
            reset: pool.resetsAt,
            usedFraction: pool.percent / 100,
            pace: expectedPace(start: start, end: pool.resetsAt, fallbackDays: pool.windowSeconds / 86_400),
            dayCount: pool.label == "Weekly" ? 7 : 0
        )
    }

    private func claudeSubRow(_ name: String, _ percent: Double) -> some View {
        HStack {
            Text("\(name) weekly")
                .font(.callout)
            Spacer(minLength: 8)
            Text("\(Int(percent.rounded()))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var codexCard: some View {
        if let snap = model.codexSnapshot {
            providerHeader(
                icon: ProviderIcons.codex,
                title: snap.planName,
                name: nil,
                email: nil,
                identityOpen: $codexIdentityOpen
            )
            ForEach(snap.pools, id: \.label) { pool in
                poolBlock(pool)
            }
            creditsBlock(snap.creditRows)
            staleNote(snap.fetchedAt, model.codexMessage)
        } else if let message = model.codexMessage {
            providerHeader(
                icon: ProviderIcons.codex,
                title: "Codex",
                name: nil,
                email: nil,
                identityOpen: $codexIdentityOpen
            )
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.isRefreshing {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading Codex…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var antigravityCard: some View {
        if let snap = model.antigravitySnapshot {
            providerHeader(
                icon: ProviderIcons.antigravity,
                title: "Antigravity",
                name: nil,
                email: nil,
                identityOpen: $antigravityIdentityOpen
            )
            ForEach(snap.groups, id: \.name) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(group.pools, id: \.label) { pool in
                        poolBlock(pool)
                    }
                }
            }
            staleNote(snap.fetchedAt, model.antigravityMessage)
        } else if let message = model.antigravityMessage {
            providerHeader(
                icon: ProviderIcons.antigravity,
                title: "Antigravity",
                name: nil,
                email: nil,
                identityOpen: $antigravityIdentityOpen
            )
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var grokCard: some View {
        switch model.state {
        case .loaded(let snap):
            providerHeader(
                icon: ProviderIcons.grok,
                title: snap.subscriptionLabel,
                name: snap.accountName,
                email: snap.accountEmail ?? model.identity?.email,
                identityOpen: $grokIdentityOpen
            )
            usageBlock(
                usedLabel: "\(Int(snap.usedPercent.rounded()))% of weekly limit used",
                reset: snap.periodEnd,
                usedFraction: snap.usedPercent / 100,
                pace: expectedPace(start: snap.periodStart, end: snap.periodEnd, fallbackDays: 7),
                dayCount: 7
            )
            if !snap.productUsage.isEmpty {
                VStack(spacing: 4) {
                    ForEach(snap.productUsage) { item in
                        HStack {
                            Text(item.displayName)
                                .font(.callout)
                            Spacer(minLength: 8)
                            Text("\(Int(item.usagePercent.rounded()))%")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            creditsBlock(grokCreditRows(snap))

        case .unavailable(let title, let hint):
            Text(title)
                .font(.callout)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

        case .failed(let message):
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)

        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading SuperGrok…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var grokBotCard: some View {
        if let snap = model.grokBotSnapshot {
            providerHeader(
                icon: ProviderIcons.grokBot,
                title: snap.planLabel,
                name: snap.accountName,
                email: snap.accountEmail,
                identityOpen: $grokBotIdentityOpen
            )
            if let percent = snap.usedPercent, snap.hasAllowance {
                usageBlock(
                    usedLabel: "\(Int(percent.rounded()))% of weekly limit used",
                    reset: snap.periodEnd,
                    usedFraction: percent / 100,
                    pace: expectedPace(start: snap.periodStart, end: snap.periodEnd, fallbackDays: 7),
                    dayCount: 7
                )
            }
            if let message = snap.statusMessage ?? model.grokBotMessage, !message.isEmpty, !snap.hasAllowance || snap.usedPercent == nil {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let message = model.grokBotMessage {
            providerHeader(
                icon: ProviderIcons.grokBot,
                title: "Grok Bot",
                name: nil,
                email: nil,
                identityOpen: $grokBotIdentityOpen
            )
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.isRefreshing {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading Grok Bot…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var cursorCard: some View {
        if let snap = model.cursorSnapshot {
            providerHeader(
                icon: ProviderIcons.cursor,
                title: snap.planName,
                name: snap.accountName,
                email: snap.accountEmail,
                identityOpen: $cursorIdentityOpen
            )
            poolRow(
                title: "Cursor Models",
                percent: snap.cursorModelsPercent,
                reset: snap.periodEnd,
                start: snap.periodStart,
                showReset: true
            )
            poolRow(
                title: "Other Models",
                percent: snap.otherModelsPercent,
                reset: snap.periodEnd,
                start: snap.periodStart,
                showReset: false
            )
            staleNote(snap.fetchedAt, model.cursorMessage)
        } else if let message = model.cursorMessage {
            providerHeader(
                icon: ProviderIcons.cursor,
                title: "Cursor",
                name: nil,
                email: nil,
                identityOpen: $cursorIdentityOpen
            )
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.isRefreshing {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading Cursor…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func providerHeader(
        icon: NSImage,
        title: String,
        name: String?,
        email: String?,
        identityOpen: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 8) {
                Image(nsImage: icon)
                    .resizable()
                    .renderingMode(icon.isTemplate ? .template : .original)
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.primary)
                Button {
                    if name != nil || email != nil {
                        identityOpen.wrappedValue.toggle()
                    }
                } label: {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("Show account")
            }
            if identityOpen.wrappedValue {
                if let name, !name.isEmpty, name != email {
                    Text(name)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if let email, !email.isEmpty {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private func usageBlock(
        usedLabel: String,
        reset: Date?,
        usedFraction: Double,
        pace: Double?,
        dayCount: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(usedLabel)
                    .font(.callout)
                Spacer(minLength: 8)
                if let reset {
                    Text("Resets \(Formatters.resetDateTime.string(from: reset))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            UsageMeter(
                used: usedFraction,
                pace: pace,
                overPace: {
                    if let pace { return usedFraction > pace + 0.0001 }
                    return false
                }(),
                dayCount: dayCount
            )
        }
    }

    private func poolRow(
        title: String,
        percent: Double,
        reset: Date?,
        start: Date?,
        showReset: Bool
    ) -> some View {
        let pace = expectedPace(start: start, end: reset, fallbackDays: 30)
        let used = percent / 100
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(title) · \(Int(percent.rounded()))% of monthly limit used")
                    .font(.callout)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if showReset, let reset {
                    Text("Resets \(Formatters.resetDateTime.string(from: reset))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            UsageMeter(
                used: used,
                pace: pace,
                overPace: {
                    if let pace { return used > pace + 0.0001 }
                    return false
                }(),
                dayCount: 0
            )
        }
    }

    private var outageBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("xAI status issue")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            if let headline = model.serviceStatus?.headline {
                Text(headline)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Open status.x.ai") {
                model.openStatusPage()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct UsageMeter: View {
    var used: Double
    var pace: Double?
    var overPace: Bool
    var dayCount: Int

    /// Plain blue; warms up only when the pool is nearly gone.
    private var fill: Color {
        switch used {
        case 0.95...: return .red
        case 0.8...: return .orange
        default: return .accentColor
        }
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                if used > 0 {
                    Capsule()
                        .fill(fill)
                        .frame(width: max(8, width * min(max(used, 0), 1)))
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}
