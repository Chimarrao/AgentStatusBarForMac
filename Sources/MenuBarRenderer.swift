import AppKit

enum MenuBarRenderer {
    @MainActor
    static func image(model: UsageViewModel) -> NSImage {
        let barHeight = NSStatusBar.system.thickness
        let iconSide: CGFloat = 16
        let gap: CGFloat = 5
        let clusterGap: CGFloat = 10
        let font = NSFont.menuBarFont(ofSize: 0)
        let color = menuBarTextColor()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let dimAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color.withAlphaComponent(0.7),
        ]

        struct Cluster {
            var icon: NSImage?
            var primary: NSAttributedString
            var extra: [NSAttributedString]
        }

        var clusters: [Cluster] = []

        if model.showClaudeUsage, let snap = model.claudeSnapshot {
            let text = poolText(snap.pools.map { ($0.percent, $0.resetsIn) }, attrs: attrs, dimAttrs: dimAttrs)
            clusters.append(Cluster(icon: ProviderIcons.claude, primary: text, extra: []))
        }

        if model.showCodexUsage, let snap = model.codexSnapshot {
            let text = poolText(snap.pools.map { ($0.percent, $0.resetsIn) }, attrs: attrs, dimAttrs: dimAttrs)
            clusters.append(Cluster(icon: ProviderIcons.codex, primary: text, extra: []))
        }

        if model.showAntigravityUsage, let snap = model.antigravitySnapshot {
            let text = poolText(snap.barPools.map { ($0.percent, $0.resetsIn) }, attrs: attrs, dimAttrs: dimAttrs)
            clusters.append(Cluster(icon: ProviderIcons.antigravity, primary: text, extra: []))
        }

        if model.showGrokUsage {
            let text: String
            switch model.state {
            case .loaded(let snap):
                text = barText(percent: snap.usedPercent, resetsIn: snap.resetsIn)
            case .unavailable:
                text = "-"
            case .failed:
                text = model.hasActiveOutage ? "⚠" : "!"
            case .idle, .loading:
                text = model.hasActiveOutage ? "⚠" : "…"
            }
            if text != "-" {
                clusters.append(Cluster(icon: ProviderIcons.grok, primary: NSAttributedString(string: text, attributes: attrs), extra: []))
            }
        }

        if model.showGrokBotUsage {
            if let snap = model.grokBotSnapshot, let percent = snap.usedPercent, snap.hasAllowance {
                let text = barText(percent: percent, resetsIn: snap.resetsIn)
                clusters.append(Cluster(icon: ProviderIcons.grokBot, primary: NSAttributedString(string: text, attributes: attrs), extra: []))
            }
        }

        if model.showCursorUsage, let snap = model.cursorSnapshot {
            let text = poolText(
                [(snap.cursorModelsPercent, snap.resetsIn), (snap.otherModelsPercent, snap.resetsIn)],
                attrs: attrs,
                dimAttrs: dimAttrs
            )
            clusters.append(Cluster(icon: ProviderIcons.cursor, primary: text, extra: []))
        }

        if clusters.isEmpty {
            clusters.append(Cluster(
                icon: ProviderIcons.grok,
                primary: NSAttributedString(string: model.hasActiveOutage ? "⚠" : "—", attributes: attrs),
                extra: []
            ))
        }

        var width: CGFloat = 0
        for (i, cluster) in clusters.enumerated() {
            if i > 0 { width += clusterGap }
            if cluster.icon != nil { width += iconSide + gap }
            width += cluster.primary.size().width
            for extra in cluster.extra {
                width += gap + extra.size().width
            }
        }
        width += 2

        let size = NSSize(width: ceil(width), height: barHeight)
        let image = NSImage(size: size, flipped: false) { _ in
            var x: CGFloat = 0
            for (i, cluster) in clusters.enumerated() {
                if i > 0 { x += clusterGap }
                if let icon = cluster.icon {
                    let iconY = (barHeight - iconSide) / 2
                    (icon.isTemplate ? tinted(icon, color: color) : icon).draw(
                        in: NSRect(x: x, y: iconY, width: iconSide, height: iconSide),
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1,
                        respectFlipped: true,
                        hints: [.interpolation: NSImageInterpolation.high]
                    )
                    x += iconSide + gap
                }
                let primarySize = cluster.primary.size()
                cluster.primary.draw(at: NSPoint(x: x, y: (barHeight - primarySize.height) / 2))
                x += primarySize.width
                for extra in cluster.extra {
                    x += gap
                    let extraSize = extra.size()
                    extra.draw(at: NSPoint(x: x, y: (barHeight - extraSize.height) / 2))
                    x += extraSize.width
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// "0% 4h | 40% 2d": each pool with its own reset, separated by a dim pipe.
    private static func poolText(
        _ pools: [(percent: Double, resetsIn: TimeInterval?)],
        attrs: [NSAttributedString.Key: Any],
        dimAttrs: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for pool in pools {
            if out.length > 0 { out.append(NSAttributedString(string: " | ", attributes: dimAttrs)) }
            out.append(NSAttributedString(string: "\(Int(pool.percent.rounded()))%", attributes: attrs))
        }
        return out
    }

    private static func barText(percent: Double, resetsIn: TimeInterval?) -> String {
        "\(Int(percent.rounded()))%"
    }

    private static func menuBarTextColor() -> NSColor {
        .labelColor
    }

    private static func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        let size = image.size
        let out = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            image.draw(in: rect)
            ctx.setBlendMode(.sourceIn)
            color.setFill()
            ctx.fill(rect)
            return true
        }
        return out
    }
}
