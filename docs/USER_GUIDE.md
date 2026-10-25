# Tame the horde

[Install once](INSTALL.md), then tell your agent:

> Tame the horde with BurnZombies and keep this Mac healthy.

Your harness uses its job/computer-wide ownership evidence to identify abandoned helpers, previews exact targets and requests graceful cleanup. Active or uncertain work stays running. No computer reboot, launch wrapper or separate model account.

## Whole-computer observation

BurnZombies watches visible processes owned by your macOS user across every project, terminal, agent and old session. It is not scoped to a conversation or the current working directory. Closing chats does not stop it.

The observer schedules bounded background reviews using one selected installed harness and its existing login. The harness judges abandonment; BurnZombies supplies live evidence, guarded stops and independently verified receipts. Active and uncertain work stays running.

## Menu bar and impact

The flame opens today's impact. **View impact** opens the larger display; **Burn Log** shows receipts. **Safe cleanup** requests a background review without sending a chat message. No computer reboot, harness restart or special job wrapper is required.

## Background reviews

The first complete scan can request a review. Changes in resource buildup are coalesced with a ten-minute cooldown; an hourly review also covers ownership changes without aggregate growth. One review runs at a time, for at most three minutes. The observer continues sampling and verifying receipts throughout.

Use Settings to pause/resume background reviews and enable **Start at login**. Login, permission, unsupported-client or usage errors pause reviews; observation continues. Resolve the issue in the selected harness, then resume. BurnZombies does not retry repeatedly or switch accounts/providers. Review details are available in Settings.

## What the numbers mean

Only verified exits add to burned helpers and released memory. CPU time saved projects observed pre-stop CPU use; agent speed reflects local responsiveness. Pending, uncertain or recurring work gets no verified-cleanup credit.

The Burn Log shows the lifecycle and ownership rationale. A true OS zombie is already exited and must be reaped by its parent; killing that child cannot release memory.

## Privacy, recovery and uninstall

Private state lives in `~/Library/Application Support/BurnZombies`: bounded process identities, executable/working-directory paths, counters, receipts and the most recent review output (at most one MiB). The observer does not collect command arguments, environment variables or credentials. Evidence sent to the selected harness can reach its model provider. The review instructions exclude unrelated private files, browser profiles and conversation contents.

Quit BurnZombies and remove the app to stop the observer. Its supervised reviewer detects owner exit and closes its own workers. Keep private state to retain history. Default setup adds no chat hooks or harness config entries. If you previously used the optional interactive MCP integration, remove only BurnZombies's entries and skill through your harness's supported configuration tools; preserve unrelated settings.
