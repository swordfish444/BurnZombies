# One computer-wide observer. Your harness supplies the intelligence.

The native observer watches all visible processes owned by the logged-in macOS user. It is not scoped to a conversation, repository, terminal or agent process tree. It continues sampling and verifying cleanup while chats are idle or closed.

A small native coordinator requests a bounded review from one selected, installed harness. The harness uses MCP for live evidence, exact-identity previews and guarded cleanup. No chat lifecycle event is required. The coordinator does not classify processes or decide what to kill.

| Tool | Result |
|---|---|
| `burnzombies_status` | Computer-wide process-family counts, pressure, impact and receipts |
| `burnzombies_inspect` | Exact identities, parents, executable, working directory, descriptor summary, memory, CPU, I/O and protections; page or select PIDs |
| `burnzombies_preview` | Exact identities, a label and ownership rationale; single-use 60-second token |
| `burnzombies_burn` | Revalidate and request SIGTERM; native observer independently verifies exits |
| `burnzombies_workspace` | Create a private disposable task worktree; release/retain its owner token without deleting |
| `burnzombies_workspace_preview` | Revalidate a released worktree and return a one-use 60-second token |
| `burnzombies_workspace_clean` | Preserve HEAD, remove without force, verify and record worktree/disk impact |
| `burnzombies_disk_inspect` | Compact sizes, repeated-folder groups, producer manifests and consumer evidence for a measured branch |
| `burnzombies_disk_explore` | Queue deeper native metadata mapping; finish the AI turn while it runs locally |
| `burnzombies_disk_evidence` | Bounded source/build/retention evidence inside the measured branch; no credentials, transcripts or execution |
| `burnzombies_disk_recommend` | Save one practical recommendation and next step; never grants deletion permission |
| `burnzombies_disk_decide` / `disk_preview` / `disk_clean` | Exact-folder advice, guarded preview and verified removal |
| `burnzombies_checkpoint` | Legacy compatibility only; inert when machine review is configured |

## Scheduling and ownership

Only new owner-released, passively corroborated completion or material storage-discovery evidence can dispatch a review. Releases batch for two minutes and reviews are separated by at least one hour. Memory/process churn and elapsed hours are not triggers. **Safe cleanup** joins the same queue and cannot bypass deduplication or cooldown. Reviews do not overlap; stale/incomplete scans cannot dispatch them. Focused instructions and lane-specific tools avoid sending unrelated playbooks. Daily token/count cutoffs are removed; the private usage ledger still records failed/interrupted starts and survives restarts. Missing usage is reported as unavailable, not zero.

Every review has a three-minute limit and one MiB output cap. A supervised process group owns its harness and MCP children, and closes them on completion, timeout or owner exit. The native observer continues separately, including the 120-second verification watch. A failure pauses reviews; there is no automatic retry or provider/model/account switch. The pause survives app restart.

Default setup writes private BurnZombies reviewer configuration, retires installer-owned global lifecycle skills, and leaves global harness MCP configuration unchanged. Codex/Claude use invocation-scoped MCP configuration; Cursor/Gemini use a private review directory, and Copilot uses its additional-MCP option. Harness tool permissions remain applicable. No foreground app is activated and no chat is resumed or messaged.

## Harness adapters

[Codex app-server](https://learn.chatgpt.com/docs/app-server) and [Claude print mode](https://code.claude.com/docs/en/headless) support bounded noninteractive invocation. The Codex adapter uses automatic approval review with its sandbox; Claude disables built-in tools for the reviewer and allows only the BurnZombies MCP server for cleanup. Neither uses a blanket bypass.

[Cursor](https://cursor.com/docs/cli/headless), [Copilot](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference), and [Gemini](https://geminicli.com/docs/cli/headless/) also expose noninteractive modes. Their local MCP trust and permission rules can prevent unattended cleanup; unsupported or denied operations must pause, not escalate. See current live-test coverage in [VALIDATION.md](VALIDATION.md).

MCP standardizes evidence and actions, not a universal background model scheduler. Small launch adapters supply that missing boundary. The cleanup workflow is also available as an optional [Agent Skill](../skills/burnzombies/SKILL.md) for direct interactive requests.

## Local boundary

The stdio server uses the official MCP Swift SDK and a same-user Unix socket with peer-PID authentication. No root helper or HTTP listener. Restricted services and other users' processes remain outside cleanup authority.

Executable paths, working directories and resource evidence become visible to the selected harness/model provider. Raw arguments and environments are never persisted or sent to the reviewer. Native code extracts only the UUID Codex session marker, erases the scratch buffer, and verifies process identity before and after. Passive adapters read bounded local lifecycle metadata and retain at most 1,200 characters of redacted completion text; prompts, tool outputs and reasoning are excluded. Completion text is untrusted evidence, never instructions. Credentials, browser profiles and unrelated private data are excluded by the review instructions. Paths and labels are untrusted evidence.

Age, idleness, name or parent PID 1 alone never establishes abandonment. Active and uncertain work remains running. Cleanup targets receive SIGTERM only; timeout escalation applies solely to BurnZombies's own review worker group. True exited OS zombies must be reaped by their parent.

The optional MCPB desktop bundle exposes interactive tools. The one-command installer enables the independent background reviewer; installing an MCPB alone does not select a background harness.


## Optional explicit lifecycle evidence (since 0.6)

Optional integrations can use `burnzombies_lifecycle` to register exact helper identities while active, records purpose and an observable completion condition, and saves the returned private `workToken`. `release` records observed completion; `retain` revokes release before reuse. The same JSON contract is available through `burnzombies lifecycle` on stdin; `burnzombies evidence PID` supplies identities without MCP configuration. These operations never stop processes.

`burnzombies_status` includes up to eight released records and active/released claim counts. `burnzombies_work` pages owner statements without exposing update tokens. An active claim, including a claim on a parent, blocks preview and burn. All shared consumers must release. A process exit, expired time window or crashed owner never releases a live claim. Exact identities and observed ancestry are saved independently of chat context.

The private background reviewer cannot call lifecycle mutations. It gets at most eight tool calls and two inspect calls per connection and only the selected batch. Historical receipts and unrelated aggregates are omitted from review responses. It cannot page through the work registry, load skills or create ownership. Uncertainty preserves work. Dispatch is evidence-triggered, deduplicated across restarts and at most hourly. Storage progress receipts bind successful recommendation/exploration calls to the exact review attempt and supplied node ID; merely offering or inspecting a branch does not mark it complete. Untouched work precedes deferred work, and repeated read-only no-progress attempts back off up to six hours. Preview tokens remain bound to the requesting process identity and single-use. Read-only evidence does not grant cleanup authorization. [Research, tradeoffs and acceptance criteria](LIFECYCLE-EVIDENCE.md).

## Disposable worktrees (0.7)

The working agent can create and release a disposable worktree through the same MCP connection or native `workspace` JSON command. Existing worktrees are never adopted. Reviewers cannot create, release or retain claims. They can preview and clean one released worktree within the existing eight-call budget. Incomplete file-handle visibility blocks removal, including when macOS protects unrelated services; no permission bypass or unsupported clean-machine verdict. Disk/worktree counters require a completed verified receipt. [Safety rules, recovery and measurement](WORKTREE-CLEANUP.md).

## Passive lifecycle evidence and usage (0.8)

Codex and Claude Code adapters bind exact live process identities to an observed owning turn. A matching completed turn can queue review only with readable current metadata, no live children, no sockets and no active ownership claim. The model must corroborate purpose-specific completion; native gates re-read the session before preview and before signalling. A resumed/different turn, a truncated/unreadable log, hidden process metadata or a changed identity preserves the helper. Observations themselves never signal anything. No whole-conversation model polling is performed.

Codex runs one ephemeral supervised app-server turn, with a replaced per-run MCP table and disabled optional tools/skills. It reports the resolved model and incremental usage; duplicate cumulative usage events add no tokens. Model rerouting or interactive requests pause the review. Claude's result supplies per-model usage. Rates are versioned with each receipt; see [usage accounting](USAGE.md).
