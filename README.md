# QuotaBar

macOS menu bar app that shows AI coding quota at a glance — **Claude Code**, **Codex**, **ChatGPT/GPT**, **Cursor**, and **Grok**.

Click the gauge icon → see usage % , reset countdowns, and plan details. No manual token paste: it reuses logins you already have on the machine.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![License: MIT](https://img.shields.io/badge/License-MIT-blue)

## Providers

| Tile | Source | Auth |
|------|--------|------|
| **Claude** | `GET api.anthropic.com/api/oauth/usage` | Keychain `Claude Code-credentials` / `~/.claude/.credentials.json` |
| **Codex** | `GET chatgpt.com/backend-api/wham/usage` | `~/.codex/auth.json` (Codex CLI login) |
| **GPT** | Same OpenAI `wham/usage` (plan / credits / windows) | `~/.codex/auth.json` |
| **Cursor** | `GetCurrentPeriodUsage` on `api2.cursor.sh` | Cursor `state.vscdb` access token |
| **Grok** | `grok.com/rest/rate-limits` + subscriptions | Chrome `.grok.com` SSO cookies (preferred); `~/.grok/auth.json` fallback |

Undocumented provider endpoints may change without notice. QuotaBar degrades per-provider — one failure does not blank the others.

## Install

```bash
git clone https://github.com/EA-Studio-SHARK/QuotaBar.git
cd QuotaBar
./scripts/install.sh
```

Builds a release `.app`, copies it to `~/Applications/QuotaBar.app`, and launches it.

Build only:

```bash
./scripts/build_app.sh
open dist/QuotaBar.app
```

Requirements: macOS 14+, Xcode Command Line Tools / Swift 5.9+.

## Usage

- Menu bar shows the **highest** usage % across providers
- Click for cards with progress bars and details
- **Refresh** (⌘R) · **Launch at login** · **Quit**
- Notification when a provider hits ≥ 90%

First run may prompt for Keychain access (Claude credentials / Chrome Safe Storage). Choose **Always Allow**.

## Privacy

- Runs entirely on your Mac
- Reads local credentials already created by Claude Code / Codex / Cursor / Chrome / Grok CLI
- Calls provider APIs only to fetch your own usage
- Does not upload data to any third-party server
- Single-instance lock under `~/Library/Application Support/QuotaBar/`

## Development

```bash
swift build -c release
./scripts/build_app.sh
```

Layout:

```
Sources/QuotaBar/          # SwiftUI MenuBarExtra app
  ClaudeProvider.swift
  OpenAIProvider.swift     # Codex + GPT (shared wham/usage)
  CursorProvider.swift
  GrokProvider.swift
scripts/install.sh
Info.plist                 # LSUIElement menu-bar app
```

## License

MIT — see [LICENSE](LICENSE).
