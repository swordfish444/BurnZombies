# Privacy Policy

BurnZombies is a local-first, open-source macOS utility licensed under MIT.

## What BurnZombies Collects

**Nothing.** BurnZombies has:

- **No telemetry, analytics, crash reporting, or tracking.**
- **No user accounts, sign-ups, or backend servers.**
- **No background network polling.** Update checks contact GitHub only when you click **Check for Updates**.

## Local Storage

BurnZombies stores its private catalog, rules, receipts, and optional encrypted worktree backups locally on your Mac under `~/Library/Application Support/BurnZombies` (`0700` directory, `0600` files). It does not store raw command-line arguments, environment variables, browser profiles, credentials, or terminal contents.

## Optional AI Sweeps

If you enable AI sweeps using your own signed-in **Claude Code** or **Codex** CLI, BurnZombies invokes that CLI locally with shell/edit/web tools disabled and sends only compact, allowlisted process/worktree/folder metadata and bounded project manifest excerpts (never `.env` files, keys, or credentials) through your own AI provider login. You can turn AI sweeps off at any time in **Settings → Which AI → Off** or with `--observe-only`.

## Optional Full Disk Access

Full Disk Access is optional. Without it, BurnZombies skips macOS-protected folders (Desktop, Documents, Downloads, iCloud Drive, Mail, Messages, Photos, other apps' data, and external drives) by path check alone and never triggers macOS privacy prompts.

## Contact

Questions or privacy reports: open an issue at https://github.com/swordfish444/BurnZombies/issues.
