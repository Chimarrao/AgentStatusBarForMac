import AppKit

enum ProviderIcons {
    static let grok = GrokMenuIcon.image

    static let claude: NSImage = colorIcon("ClaudeIcon") ?? claudeDrawn
    static let codex: NSImage = colorIcon("CodexIcon") ?? codexDrawn
    static let antigravity: NSImage = colorIcon("AntigravityIcon") ?? colorIcon("CodexIcon") ?? codexDrawn

    /// Full-colour (non-template) PNG from the bundle, 1x/2x/3x.
    private static func colorIcon(_ name: String) -> NSImage? {
        let img = NSImage(size: NSSize(width: 16, height: 16))
        for suffix in ["", "@2x", "@3x"] {
            guard let url = Bundle.main.url(forResource: name + suffix, withExtension: "png"),
                  let data = try? Data(contentsOf: url),
                  let rep = NSBitmapImageRep(data: data)
            else { continue }
            rep.size = NSSize(width: 16, height: 16)
            img.addRepresentation(rep)
        }
        guard !img.representations.isEmpty else { return nil }
        img.isTemplate = false
        return img
    }

    private static let claudeDrawn: NSImage = {
        let side: CGFloat = 16
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let c = NSPoint(x: rect.midX, y: rect.midY)
            let rays = 12
            NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1).setStroke()
            for i in 0..<rays {
                let angle = CGFloat(i) * 2 * .pi / CGFloat(rays) + .pi / 2
                let outer: CGFloat = i % 2 == 0 ? 7.6 : 6.0
                let path = NSBezierPath()
                path.lineWidth = 1.7
                path.lineCapStyle = .round
                path.move(to: NSPoint(x: c.x + cos(angle) * 1.6, y: c.y + sin(angle) * 1.6))
                path.line(to: NSPoint(x: c.x + cos(angle) * outer, y: c.y + sin(angle) * outer))
                path.stroke()
            }
            return true
        }
        img.isTemplate = false
        return img
    }()

    /// Blue cloud with a `>_` prompt, like the Codex mark.
    private static let codexDrawn: NSImage = {
        let side: CGFloat = 16
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            NSColor(srgbRed: 0.27, green: 0.45, blue: 0.97, alpha: 1).setFill()
            for r in [
                NSRect(x: 0.8, y: 3.2, width: 6.6, height: 6.6),
                NSRect(x: 4.2, y: 5.6, width: 8.0, height: 8.0),
                NSRect(x: 8.6, y: 3.4, width: 6.6, height: 6.6),
            ] { NSBezierPath(ovalIn: r).fill() }
            NSBezierPath(roundedRect: NSRect(x: 3.4, y: 2.4, width: 9.4, height: 5.2), xRadius: 2.6, yRadius: 2.6).fill()

            NSColor.white.setStroke()
            let chevron = NSBezierPath()
            chevron.lineWidth = 1.3
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            chevron.move(to: NSPoint(x: 5.2, y: 9.4))
            chevron.line(to: NSPoint(x: 7.2, y: 7.4))
            chevron.line(to: NSPoint(x: 5.2, y: 5.4))
            chevron.stroke()
            let underscore = NSBezierPath()
            underscore.lineWidth = 1.3
            underscore.lineCapStyle = .round
            underscore.move(to: NSPoint(x: 8.8, y: 5.4))
            underscore.line(to: NSPoint(x: 11, y: 5.4))
            underscore.stroke()
            return true
        }
        img.isTemplate = false
        return img
    }()

    static let grokBot: NSImage = templateIcon(
        names: ["GrokBotIcon", "GrokBotIcon@2x", "GrokBotIcon@3x"],
        svgName: "GrokBotIcon",
        symbol: "face.smiling",
        accessibility: "Grok Bot"
    )

    static let cursor: NSImage = templateIcon(
        names: ["CursorIcon", "CursorIcon@2x"],
        svgName: "CursorIcon",
        symbol: "chevron.right.2",
        accessibility: "Cursor"
    )

    private static func templateIcon(
        names: [String],
        svgName: String,
        symbol: String,
        accessibility: String
    ) -> NSImage {
        let pointSize = NSSize(width: 16, height: 16)
        let img = NSImage(size: pointSize)
        img.isTemplate = true

        for name in names {
            let url = Bundle.main.url(forResource: name, withExtension: "png")
                ?? Bundle.main.resourceURL?.appendingPathComponent("\(name).png")
            guard let url,
                  FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let rep = NSBitmapImageRep(data: data)
            else { continue }
            rep.size = pointSize
            img.addRepresentation(rep)
        }

        if img.representations.isEmpty,
           let svg = Bundle.main.url(forResource: svgName, withExtension: "svg"),
           let svgImage = NSImage(contentsOf: svg)
        {
            svgImage.size = pointSize
            svgImage.isTemplate = true
            return svgImage
        }

        if img.representations.isEmpty {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            if let symbol = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)?
                .withSymbolConfiguration(config)
            {
                symbol.isTemplate = true
                return symbol
            }
        }

        img.isTemplate = true
        return img
    }
}
