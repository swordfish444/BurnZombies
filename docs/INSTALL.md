# Install once. Keep working.

```sh
curl -fsSL https://raw.githubusercontent.com/swordfish444/BurnZombies/main/install.sh | bash
```

macOS 14+, Apple Silicon or Intel. The installer checks the release checksum and signature, installs `~/Applications/BurnZombies.app`, and connects all detected supported local harnesses with MCP, the skill and one quiet checkpoint. No sudo, Node, Python, API key or BurnZombies account.

Ask: **Tame the horde with BurnZombies and keep this session healthy.** This gives the agent the intended ongoing-cleanup scope; its normal tool permissions still apply. The agent decides which disposable leftovers are safe to stop. Unknown work remains running.

## First connection

No computer reboot is needed. A running client may need its supported MCP/skill reload or a new conversation to discover newly installed tools. Existing jobs can keep running. Codex requires review and trust of new hooks through `/hooks` before automatic checkpoints execute; the installer does not bypass that review or alter tool-approval policy. Claude Desktop's local Code tab shares Claude Code's configuration. Chat and Cowork are separate integrations.

Codex and Claude callbacks reuse the existing MCP connection. No startup or Stop hooks are installed. The app stays in the background when a client connects.

After connection, cleanup runs at natural checkpoints in the ongoing session. **Safe cleanup** in the app queues a review for the next hook; asking the agent directly starts one now. The adapter never launches a hidden model process or requires a harness restart to reclaim resources.

## Installer behavior

The single default command detects Codex, Claude Code, Cursor, GitHub Copilot CLI and Gemini CLI. For deployment tooling, `--mcp` accepts `auto`, `all`, an individual harness name or `none`; `--no-open` skips launching the app. The bundled native installer also accepts `--checkpoints off` to retain on-demand MCP/skill access without callbacks. `BURNZOMBIES_INSTALL_DIR` changes the app destination.

Unrelated MCP servers, settings, hooks and credentials are preserved. Changed config files get private backups; conflicting BurnZombies entries or malformed config are reported instead of overwritten. Re-running installation is idempotent. Existing cleanup history remains in Application Support. Custom harness config roots and JSON-with-comments configuration need explicit validation before installation; do not silently redirect or rewrite them.

This release is locally ad-hoc signed, not Developer ID notarized. The installer does not remove quarantine or disable Gatekeeper. [Build from source](../CONTRIBUTING.md) if local macOS policy blocks the distributed app.

## Installing agent acceptance

Read the installer, run the one command, then verify the configured command, skill and hooks. Call `burnzombies_status` in the actual target client. A configuration file alone does not prove an already-running session loaded it. Respect the client's hook-trust UI. Do not restart the computer, terminate active tasks, change credentials or widen tool permissions to make setup pass.

[Protocol and harness formats](MCP.md) · [Safety](SAFETY.md) · [Uninstall](USER_GUIDE.md#privacy-recovery-and-uninstall)
