# AgentStatusBarForMac — Claude | Codex | Antigravity | Grok | Cursor

Usage meters for your AI coding agents, in the Mac menu bar.

> **This is a fork of [pixbroker/grokbar](https://github.com/pixbroker/grokbar).** The architecture, the Grok and Cursor providers, the status-item renderer and the SwiftUI popover are all [@pixbroker](https://github.com/pixbroker)'s work, published under the MIT license. Thank you for the original project. This fork adds more providers and changes the look; see [What changed](#what-changed).

Unofficial. Native AppKit status item + SwiftUI popover, no dependencies, no telemetry.

## Menu bar

Each signed-in provider is its logo followed by its usage, `5h% | weekly%`:

```
✳ 44% | 58%   ☁ 87%   ◭ 12% | 3%   ⊘ 39%
Claude          Codex     Antigravity  Grok
```

Providers you are not signed in to are hidden, in the menu bar and in the popover. A pool that is monthly (Codex Go, Cursor) shows as one number, and extra windows follow the same `a | b` pattern.

## Providers

| Provider | Shows | Reads from |
|----------|-------|-----------|
| **Claude** | Session (5h), Weekly, usage credits spent | Claude Code sign-in (macOS Keychain item `Claude Code-credentials`, or `~/.claude/.credentials.json`) |
| **Codex** | Session / Weekly / Monthly (whatever your plan has), credits | `~/.codex/auth.json` (or `$CODEX_HOME`) |
| **Antigravity** | 5h + weekly for *Gemini* and *Claude & GPT* model groups | the official `agy -p /usage` (Antigravity CLI), no credentials touched |
| **Grok** | SuperGrok weekly pool, per-product split, prepaid balance | `~/.grok/auth.json` |
| **Cursor** | Cursor Models / Other Models monthly pools, Grok Bot | Cursor's local session |

Usage credits / prepaid balances are listed only when the account actually has them.

Settings (gear icon): toggle each provider, and choose how often to read usage (30 s, 1, 5 or 10 min). If a read fails, the last good numbers stay on screen with a note.

## Requirements

- macOS 14+, Xcode command line tools (`swiftc`)
- Be signed in to the tools you want to see: `claude`, `codex`, `agy`, `grok login`, Cursor

## Install

```bash
git clone https://github.com/Chimarrao/AgentStatusBarForMac.git
cd AgentStatusBarForMac
bash build.sh
cp -R build/AgentStatusBarForMac.app /Applications/
open /Applications/AgentStatusBarForMac.app
```

`build.sh` builds for your Mac's architecture (Apple Silicon or Intel). The build is ad-hoc signed: on first launch use **right-click → Open** if Gatekeeper warns. The app registers as a login item.

## What changed

Compared with the original GrokBar:

- New providers: **Claude**, **Codex** and **Antigravity**, with official-style logos in the menu bar.
- Menu bar shows only percentages, as `5h% | weekly%`, per provider; signed-out providers are hidden.
- Cleaner usage bars (no pace marker or day ticks); blue, turning orange at 80% and red at 95%.
- Extra-credits section (Claude, Codex, Grok) when present.
- Configurable refresh interval; last good value kept on errors.
- Builds natively on Intel Macs (the original build script hard-coded `arm64`).
- Renamed to AgentStatusBarForMac.

## Privacy and caveats

- Reads local sign-in files / Keychain items of the tools above, and talks only to those providers' usage endpoints (plus the public xAI status feed). It never sends chats, code or project files and makes no model requests.
- It does **not** refresh Claude, Codex or Antigravity tokens (those tools rotate refresh tokens); if one expires, open that tool once.
- **Claude:** uses Anthropic's undocumented `/api/oauth/usage` endpoint. That endpoint rate-limits unknown clients almost to zero, so the app sends `User-Agent: claude-code/<your installed version>`, like other community usage monitors. This may not be allowed by Anthropic's terms and can break at any time. Use at your own risk.
- **Codex** uses an undocumented ChatGPT backend endpoint (`/backend-api/wham/usage`), also unofficial.
- Claude's usage-credit *balance* is not exposed by the API, so only credits spent are shown.

## License and credits

[MIT](LICENSE). Original work © 2026 pixbroker ([pixbroker/grokbar](https://github.com/pixbroker/grokbar)); modifications © 2026 Lucas Reolon.

Not affiliated with Anthropic, OpenAI, Google, xAI or Anysphere. Claude, Codex, Antigravity, Grok and Cursor names and logos belong to their owners and are used only to identify each provider.
