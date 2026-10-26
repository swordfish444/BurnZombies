# Install once. Watch the whole Mac.

```sh
curl -fsSL https://raw.githubusercontent.com/swordfish444/BurnZombies/main/install.sh | bash
```

macOS 14+, Apple Silicon or Intel. The installer checks the release checksum and signature, installs `~/Applications/BurnZombies.app`, selects an available harness CLI, and starts the menu bar observer in the background. No active chat, special job wrapper or computer reboot is required.

The observer scans visible processes owned by your macOS user across every project and session. Its own schedule requests bounded reviews from the selected harness. Closing your chats does not stop observation or scheduling. Quit BurnZombies to stop the observer; **Start at login** is available in Settings.

## Existing harness, existing login

Codex, Claude Code, Cursor CLI, GitHub Copilot CLI and Gemini CLI have launch adapters. The selected CLI must be installed and signed in. Codex's bundled desktop CLI is detected when available. A desktop app without a usable local CLI is not sufficient by itself. Authentication is reused, never copied or changed.

Default selection order is Codex, Claude, Cursor, Copilot, Gemini. Reinstallation retains the previous provider; a failed or quota-limited provider is never replaced automatically. Reviews use that harness's existing account and usage allowance. Failed authentication, unsupported CLI options, permission refusals or usage errors pause reviews while native observation continues. Resolve the issue in the harness, then use **Resume reviews** in BurnZombies.

Default setup writes BurnZombies's private reviewer configuration and the portable lifecycle skill. It adds the local BurnZombies MCP server to detected harnesses while preserving other settings. It does not install chat hooks, inject reminders, or change persistent tool permissions. Per-run MCP configuration connects the reviewer to the local observer. Legacy BurnZombies hooks become inert when computer-wide review is configured.

## Options

### Model and thinking level

Open **Settings → Review intelligence** to choose a model and thinking level, then **Save**. The selection applies to the next scheduled review; an active review finishes with its original settings. Saving does not start a review or clear a pause. **Use defaults**, followed by Save, returns control to the harness.

Model IDs are supported by all five adapters. Codex offers suggestions from its local model catalog and filters thinking levels for a selected catalog model; custom IDs work too. Codex, Claude Code and GitHub Copilot expose separate thinking controls. Cursor and Gemini manage thinking through the selected model/harness. Unsupported combinations are reported by the harness and never silently replaced by BurnZombies.

Settings live only in BurnZombies's private configuration. Reinstalling preserves them. Codex's default here is its CLI default, because background reviews deliberately skip global Codex configuration; BurnZombies does not claim an inferred default as a pinned model.

An agent can also configure these without opening a window:

```sh
~/Applications/BurnZombies.app/Contents/MacOS/burnzombies setup --harness codex --model MODEL_ID --thinking high
```

Use `--model default --thinking default` to clear the overrides. Choosing a different harness clears the previous harness's model/effort selection unless new values are supplied.

### Installer options

`--mcp codex|claude|cursor|copilot|gemini` selects the review provider; `auto` selects one available provider. The older `all` spelling also selects one provider rather than starting five competing reviewers. `--mcp none` skips reviewer configuration. `--no-open` skips starting the app. `BURNZOMBIES_INSTALL_DIR` changes the app destination.

The native command `burnzombies setup --harness NAME` configures the background reviewer. The older `install` subcommand remains available for explicit interactive MCP/skill integration; chat checkpoints now default off. It is not needed for continuous observation or reviews.

No `--yolo`, blanket permission bypass, account fallback, quarantine removal or Gatekeeper disablement is used. This release is ad-hoc signed, not Developer ID notarized. [Build from source](../CONTRIBUTING.md) if local macOS policy blocks it.

## Acceptance

Check the menu bar observer and its selected harness, then verify a bounded background review and its receipts without sending a chat message. CLI configuration alone is not live model proof. Current validation and remaining harness limits are in [VALIDATION.md](VALIDATION.md).


### Ownership memory without hooks

The one-line installer also installs the BurnZombies skill into `~/.agents/skills/burnzombies` and `~/.claude/skills/burnzombies`. These standard directories cover local Codex, Claude Code, Cursor, Copilot CLI and Gemini CLI. Existing managed legacy copies are refreshed; customized skills are preserved and reported. The installer also connects the standard MCP server to detected local harnesses. It preserves hooks, shell profiles, model selection and permission policies. Codex configuration is parsed and checked before a conditional atomic write; custom conflicting entries are preserved.

New tasks can discover the lifecycle instructions normally. Existing chats follow their harness's skill refresh behavior; skill activation is model-directed, and a harness may request normal tool/skill permission (including Gemini's consent prompt). There is no computer restart requirement. MCP is the normal lifecycle transport. The skill also provides the exact installed native command when MCP is not connected. Sandboxed shells may require normal permission to connect to the observer; a refusal remains a coverage gap rather than being bypassed.

The app continues computer-wide observation regardless of whether a task records ownership. Missing records cannot prove old work finished. For the strongest early cleanup evidence, the working agent must register helpers while using them and release them after actual completion. The reviewer never fabricates a release or silently expires an active claim.
