# Tame the horde

[Install once](INSTALL.md), then tell your agent:

> Tame the horde with BurnZombies and keep this session healthy.

Your harness uses its job/session context to identify abandoned helpers, previews exact targets and requests graceful cleanup. Active or uncertain work stays running. No computer reboot, launch wrapper or separate model account.

## Everyday use

The flame in the menu bar opens today's impact. **View impact** shows the larger display; **Burn Log** shows receipts. **Safe cleanup** queues a review at your agent's next checkpoint. You can ask the agent directly to start one now.

BurnZombies stays in the background. Connecting an agent, finishing cleanup or reconnecting MCP never opens its panel. Cleanup celebration animates only in an already-visible view.

A quiet callback checks cached aggregate signals at tool boundaries. Unchanged state adds no model context. Codex and Claude use the existing MCP connection; the other supported local clients use a short native callback. Client-owned first-use trust still applies. A disconnected or idle model cannot be awakened universally through MCP; queued requests wait for the next active boundary.

Counts reflect verified exits. Pending and failed cleanups earn no credit. Memory uses pre-stop resident footprints; CPU time and speed summarize local impact. Details remain in the log.

## Build and check

Source builds require macOS 14+ and Swift 6.2. Downloaded builds require no compiler or language runtime.

```sh
scripts/build-app.sh --universal
scripts/test.sh --integration
python3 scripts/test-mcp.py
python3 scripts/test-harness-install.py
```

The integration proof creates only disposable owned fixtures and waits through the production receipt window. Real-client acceptance scripts are opt-in and use the existing account; they never run in CI.

## Privacy, recovery and uninstall

State lives in `~/Library/Application Support/BurnZombies`. It includes process identities, paths, bounded counters and cleanup receipts. No environment variables, command arguments, prompts, browser content or credentials are collected. Evidence sent to MCP is available to your configured harness/model provider.

To stop callbacks while keeping on-demand tools, run the bundled `burnzombies install --harness auto --checkpoints off`. Quit BurnZombies, remove its MCP entry/skill and only its own hooks from the harness configuration, then remove the app. Keep the private state directory if you want to retain history. Configuration backups sit beside changed files; restoring a whole backup may overwrite later unrelated edits, so prefer a targeted removal.

The local build is ad-hoc signed, not notarized. The installer preserves Gatekeeper and quarantine policy. [Safety](SAFETY.md) · [Architecture](ARCHITECTURE.md).
