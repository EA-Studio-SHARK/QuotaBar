# QuotaBar

macOS menu bar — glance AI coding quotas for **Claude**, **Codex**, **Copilot**, **Cursor**, and **Grok**.

Minimal list UI. Zero config: reuses logins already on your Mac.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black) ![Swift](https://img.shields.io/badge/Swift-5.9-orange) ![License: MIT](https://img.shields.io/badge/License-MIT-blue)

## Providers

| | Auth |
|--|--|
| **Claude** | Claude Code Keychain / `~/.claude` |
| **Codex** | `~/.codex/auth.json` (OpenAI / ChatGPT-linked) |
| **Copilot** | GitHub token (`github.com` Keychain / Copilot `apps.json` / `gh`) |
| **Cursor** | Cursor `state.vscdb` |
| **Grok** | Chrome `grok.com` SSO / `~/.grok/auth.json` |

## Install

```bash
git clone https://github.com/EA-Studio-SHARK/QuotaBar.git
cd QuotaBar
./scripts/install.sh
```

## Privacy

Runs locally. Reads credentials your CLIs/IDEs already stored. Does not phone home except to each provider’s own usage API. No secrets are hardcoded in this repo.

## License

MIT
