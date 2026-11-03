# Tame the horde

[Install once](INSTALL.md), then tell your agent:

> Tame the horde with BurnZombies and keep this Mac healthy.

Your harness uses its job/computer-wide ownership evidence to identify abandoned helpers, previews exact targets and requests graceful cleanup. Active or uncertain work stays running. No computer reboot, launch wrapper or separate model account.

## Autopilot and Teach BZ

BurnZombies sweeps every 15 minutes and burns zombies, old copies and junk folders it is sure about. When it isn't sure, the menu shows **BZ has N quick questions**; **Teach BZ** shows one card at a time with **Yes, burn them** / **No, keep them**. Every answer becomes a rule. **Findings** lists everything in plain words with **Burn now**, **Keep forever** and **Restore**. Settings → **Autopilot** sets the frequency, shows **What BZ has learned**, the starter rules and **Start training over**. [How Autopilot decides](AUTOPILOT.md).

## Whole-computer observation

BurnZombies watches visible processes owned by your macOS user across every project, terminal, agent and old session. It is not scoped to a conversation or the current working directory. Closing chats does not stop it.

The observer schedules bounded background reviews using one selected installed harness and its existing login. The harness judges abandonment; BurnZombies supplies live evidence, guarded stops and independently verified receipts. Active and uncertain work stays running.

## Menu bar and impact

The flame opens today's impact; the **Today**, **7 days** and **All time** tabs switch its four totals. **View impact** opens the larger display; **Burn Log** shows receipts. **Hunt Zombies** starts a deep review now without sending a chat message. While it runs, **Hunting Zombies →** opens the live hunt scene and activity log. No computer reboot, harness restart or special job wrapper is required.

## Zombie hunts

The observer watches the whole Mac without model calls. Automatic deep hunts run every **4 hours** by default. Change the frequency or turn automatic hunts off under **Settings → Zombie hunts**; an explicit **Hunt Zombies** click can start sooner and remains available when automatic hunts are off. One hunt runs at a time. Saving a schedule does not start a hunt or clear an error pause.

Each hunt reviews eligible process, worktree, cache and disk evidence in focused batches. Ordinary process churn is not evidence that a helper is disposable. Unchanged, resolved evidence is remembered across restarts; new completion or ownership evidence can be reconsidered. Active claims and exited helpers do not become cleanup targets. Unfinished branches remain queued, and repeated read-only attempts without progress back off. A native deeper scan can continue after the model returns instead of keeping an agent waiting.

Open **Hunting Zombies →** to watch the side-scrolling search. Scanner percentages animate the scene; the activity log below carries actual findings, safety decisions and resource totals. **Detected** identifies a candidate, while the flamethrower celebration and **eradicated** announcement follow a verified cleanup. Process and worktree receipts use the same celebration. Closing this window does not stop the hunt. Scheduled hunts never open a window or take focus.

There is no fixed daily token or review-count cutoff. Usage is recorded by model, including cached versus uncached input and output; missing usage stays unknown. Each harness invocation remains bounded to three minutes and eight tool calls. Native observation and receipt verification continue during the hunt, and the animated display makes no model calls. Autopilot sweeps back off after a failure (15 → 120 minutes) instead of pausing; rules you taught keep working meanwhile.

Codex reviews load a focused cleanup policy and only BurnZombies MCP tools, without optional apps, plugins, memories or host skill discovery. The existing account, selected model/thinking and managed security controls remain in place. Review mode returns only task-relevant evidence and preserves every native cleanup guard. The collapsed **Settings → Usage & estimated cost** panel shows 1, 7 or 30 days, hourly/daily charts, all-model or individual-model usage, uncached input, cache reads, cache writes, output and approximate API-equivalent USD. The private `review-usage.json` retains 32 days of bounded per-model receipts and rate snapshots. Codex reports its resolved model and cache-aware usage through its supervised ephemeral app-server turn; Claude reports `modelUsage`. Unknown models remain unpriced, unavailable usage stays unknown, and subscription credits or hidden approval overhead are not inferred. Historical receipts without model attribution are retained without inventing a model or cost.

Use **Settings → Zombie hunts** to control automatic hunts and enable **Start at login** in Settings. Login, permission, unsupported-client or usage errors pause hunts; observation continues. Resolve the issue in the selected harness, then explicitly start a new hunt. BurnZombies does not retry repeatedly or switch accounts/providers. Review details are available in Settings.

## What the numbers mean

The main views show zombies burned, memory released, disk reclaimed and worktrees cleaned. Only verified exits add to burned helpers and released memory. Worktree receipts add to disk/worktree counters only after guarded native removal. Old copies and junk folders Autopilot burns count too, and a restore takes its share back out. Click Worktrees cleaned to discover and review linked checkouts, explicitly manage eligible existing worktrees, and restore verified encrypted snapshots. Codex-managed checkouts remain with Codex. [Worktree safety and recovery](WORKTREE-CLEANUP.md). CPU time remains in impact details. CPU time saved accumulates from observed pre-stop CPU use during awake observation after verified exit, up to 24 hours per cleanup. Sleep, downtime, reboot and detected replacement helpers add no credit. Previously credited one-hour estimates remain intact until observed time catches up. Agent speed stays neutral when local timing samples are noisy, unchanged or slower. Pending, uncertain or recurring work gets no verified-cleanup credit.

The Burn Log shows the lifecycle and ownership rationale. A true OS zombie is already exited and must be reaped by its parent; killing that child cannot release memory.

## Privacy, recovery and uninstall

Private state lives in `~/Library/Application Support/BurnZombies`: bounded process identities, executable/working-directory paths, counters, receipts and the most recent review output (at most one MiB). The observer does not collect command arguments, environment variables or credentials. Evidence sent to the selected harness can reach its model provider. The review instructions exclude unrelated private files, browser profiles and conversation contents.

Quit BurnZombies and remove the app to stop the observer. Its supervised reviewer detects owner exit and closes its own workers. Keep private state to retain history. Default setup adds no chat hooks or harness config entries. If you previously used the optional interactive MCP integration, remove only BurnZombies's entries and skill through your harness's supported configuration tools; preserve unrelated settings.

## Disk cleanup

Expand **Settings → Disk cleanup** for AI recommendations on items of 100 MB or more (automatic cache removal still has a separate 10 GB floor). Choose Keep to protect a folder, or Approve cleanup to confirm that exact output is replaceable and allow guarded automatic cleanup. Advice can arrive before deletion permission; approval never overrides active consumers or incomplete visibility. Detailed retention, presets and preferences live under Advanced. See [the cleanup boundary and research](DISK-CLEANUP.md).

## Findings and personal workflows

Open **Findings** directly from the menu panel, even when the cleanup counter is zero. Each item shows why it was found, current blockers, exact scope and recovery. Unsupported or owner-managed resources remain visible. The app does not claim that an idle or old item is abandoned.

**Approve once** rechecks the current evidence. Worktrees use a separate explicit **Manage, preserve and retire** sheet: this can adopt the exact checkout and includes ignored/local files in independently verified encrypted recovery. It cannot override active owners or incomplete inspection. **Keep** protects that identity across all cleanup routes until cleared; **Tomorrow** changes prompting only.

Notifications start with a private digest. The configurable budget is 1–5 prompts per day (default 3), with an hour between prompts. Details are off by default; only recognizable supported Gradle owners offer a direct notification stop action. Worktree adoption and local-file decisions stay in the review sheet. Notification submission is not proof of delivery or approval.

For a repeated Gradle workflow, **Review recurring rule** shows its exact producer/home/distribution, current matches, blockers and past decisions. Shadow mode shows what would match without permitting execution. An enabled rule has an explicit daily limit and expiry, starts with one verified canary, and still requires independent AI review plus current native checks. Pause affects future dispatches; it cannot cancel an already dispatched operation. **I needed this** or restoration pauses the affected workflow. **Forget workflow preferences** also pauses its automation; recovery records remain.
