# Install BurnZombies

macOS 14 or later, Apple Silicon or Intel:

```sh
curl -fsSL https://raw.githubusercontent.com/swordfish444/BurnZombies/main/install.sh | bash
```

This downloads the universal app, checks its SHA-256 and local code signature, installs it in `~/Applications`, and opens it. No sudo, compiler, Node or Python. Existing BurnZombies data is preserved.

The installer connects **Codex** if its CLI is available, otherwise **Claude Code**. It preserves an existing `burnzombies` MCP entry. Start a new agent session after installation, then ask **“Tame the horde with BurnZombies.”** If neither client is installed, the app still works normally.

## Choose a client

```sh
# Claude Code
curl -fsSL https://raw.githubusercontent.com/swordfish444/BurnZombies/main/install.sh | bash -s -- --mcp claude
# Codex
curl -fsSL https://raw.githubusercontent.com/swordfish444/BurnZombies/main/install.sh | bash -s -- --mcp codex
# Mac app only
curl -fsSL https://raw.githubusercontent.com/swordfish444/BurnZombies/main/install.sh | bash -s -- --mcp none
```

For another local MCP client, use this executable as its stdio server command, with no arguments:

```sh
"$HOME/Applications/BurnZombies.app/Contents/MacOS/burnzombies-mcp"
```

Use the fully expanded absolute path in JSON configuration. The server opens the app when needed. [Tools and usage](MCP.md).

## Instructions for an installing agent

1. Check that this is macOS 14+. Read `install.sh` from this repository.
2. Run the installer with `--mcp codex` or `--mcp claude` for your client; use `--mcp none` if your client needs a different configuration flow. Do not change unrelated MCP entries.
3. Verify the installed app and the `burnzombies` server entry. If a previous entry points elsewhere, preserve it and explain the mismatch before replacing it.
4. Tell the user to start a new agent session, then call `burnzombies_status`. Installation alone does not authorize termination of arbitrary processes or registration of existing unknown workloads.

## Updates and installation details

Quit BurnZombies, run the same command, and reopen your agent session. The installer uses a versioned GitHub release and retains the previous app until replacement succeeds. `BURNZOMBIES_INSTALL_DIR` selects another app directory; `--no-open` skips launching it.

Version 0.2 uses an ad-hoc signature, not Developer ID notarization. The installer does not remove quarantine attributes, change Gatekeeper, or install a privileged helper. If macOS blocks a manually downloaded copy, use a local source build or wait for a notarized release; do not disable system protections.

[Build from source](../CONTRIBUTING.md) · [Uninstall](USER_GUIDE.md#privacy-recovery-and-uninstall)
