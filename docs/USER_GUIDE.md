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

The observer watches the whole Mac without model calls. A review starts only for new owner-released or passively corroborated completion evidence, after a two-minute batching window and at least one hour since the last review. Ordinary CPU, memory or process churn and the passage of an hour never start reviews. Unchanged evidence is remembered across restarts; a new release or changed child relationship can be reconsidered. Active claims and exited helpers do not enter the queue.

Reviews run at most hourly when new evidence needs attention. Focused instructions and relevant tools keep each review small; unfinished branches remain queued and repeated read-only attempts without progress back off. There is no fixed daily token or review-count cutoff. Usage is still recorded by model, including cached versus uncached input and output. Missing usage stays unknown. Review failures remain paused until explicitly resumed. One review runs at a time for at most three minutes and eight tool calls; native observation and receipt verification continue while waiting.

Codex reviews load a focused cleanup policy and only BurnZombies MCP tools, without optional apps, plugins, memories or host skill discovery. The existing account, selected model/thinking and managed security controls remain in place. Review mode returns only task-relevant evidence and preserves every native cleanup guard. The collapsed **Settings → Usage & estimated cost** panel shows 1, 7 or 30 days, hourly/daily charts, all-model or individual-model usage, uncached input, cache reads, cache writes, output and approximate API-equivalent USD. The private `review-usage.json` retains 32 days of bounded per-model receipts and rate snapshots. Codex reports its resolved model and cache-aware usage through its supervised ephemeral app-server turn; Claude reports `modelUsage`. Unknown models remain unpriced, unavailable usage stays unknown, and subscription credits or hidden approval overhead are not inferred. Historical receipts without model attribution are retained without inventing a model or cost.

Use Settings to pause/resume background reviews and enable **Start at login**. Login, permission, unsupported-client or usage errors pause reviews; observation continues. Resolve the issue in the selected harness, then resume. BurnZombies does not retry repeatedly or switch accounts/providers. Review details are available in Settings.

## What the numbers mean

The main views show zombies burned, memory released, disk reclaimed and worktrees cleaned. Only verified exits add to burned helpers and released memory. Disposable-worktree receipts add to disk/worktree counters only after guarded native removal; existing and Codex-managed checkouts are excluded. [Worktree safety and recovery](WORKTREE-CLEANUP.md). CPU time remains in impact details. CPU time saved accumulates from observed pre-stop CPU use during awake observation after verified exit, up to 24 hours per cleanup. Sleep, downtime, reboot and detected replacement helpers add no credit. Previously credited one-hour estimates remain intact until observed time catches up. Agent speed stays neutral when local timing samples are noisy, unchanged or slower. Pending, uncertain or recurring work gets no verified-cleanup credit.

The Burn Log shows the lifecycle and ownership rationale. A true OS zombie is already exited and must be reaped by its parent; killing that child cannot release memory.

## Privacy, recovery and uninstall

Private state lives in `~/Library/Application Support/BurnZombies`: bounded process identities, executable/working-directory paths, counters, receipts and the most recent review output (at most one MiB). The observer does not collect command arguments, environment variables or credentials. Evidence sent to the selected harness can reach its model provider. The review instructions exclude unrelated private files, browser profiles and conversation contents.

Quit BurnZombies and remove the app to stop the observer. Its supervised reviewer detects owner exit and closes its own workers. Keep private state to retain history. Default setup adds no chat hooks or harness config entries. If you previously used the optional interactive MCP integration, remove only BurnZombies's entries and skill through your harness's supported configuration tools; preserve unrelated settings.

## Disk cleanup

Expand **Settings → Disk cleanup** for AI recommendations on items of 10 GB or more. Choose Keep to protect a folder, or Approve cleanup to confirm that exact output is replaceable and allow guarded automatic cleanup. Advice can arrive before deletion permission; approval never overrides active consumers or incomplete visibility. Detailed retention, presets and preferences live under Advanced. See [the cleanup boundary and research](DISK-CLEANUP.md).
