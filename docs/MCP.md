# One computer-wide observer. Your harness supplies the intelligence.

The native observer watches all visible processes owned by the logged-in macOS user. It is not scoped to a conversation, repository, terminal or agent process tree. It continues sampling and verifying cleanup while chats are idle or closed.

A small native coordinator requests a bounded review from one selected, installed harness. The harness uses MCP for live evidence, exact-identity previews and guarded cleanup. No chat lifecycle event is required. The coordinator does not classify processes or decide what to kill.

| Tool | Result |
|---|---|
| `burnzombies_status` | Computer-wide process-family counts, pressure, impact and receipts |
| `burnzombies_inspect` | Exact identities, parents, executable, working directory, descriptor summary, memory, CPU, I/O and protections; page or select PIDs |
| `burnzombies_preview` | Exact identities, a label and ownership rationale; single-use 60-second token |
| `burnzombies_burn` | Revalidate and request SIGTERM; native observer independently verifies exits |
| `burnzombies_checkpoint` | Legacy compatibility only; inert when machine review is configured |

## Scheduling and ownership

The first complete scan can request a review. Subsequent pressure/buildup changes are coalesced with a ten-minute minimum interval; an hourly review also catches lifecycle changes without aggregate growth. **Safe cleanup** requests a review directly, without waiting for a chat. Reviews do not overlap. Stale/incomplete scans cannot dispatch them.

Every review has a three-minute limit and one MiB output cap. A supervised process group owns its harness and MCP children, and closes them on completion, timeout or owner exit. The native observer continues separately, including the 120-second verification watch. A failure pauses reviews; there is no automatic retry or provider/model/account switch. The pause survives app restart.

Default setup writes private BurnZombies reviewer configuration, installs portable lifecycle skills, and adds the local MCP server to detected working harnesses. Codex/Claude use invocation-scoped MCP configuration; Cursor/Gemini use a private review directory, and Copilot uses its additional-MCP option. Harness tool permissions remain applicable. No foreground app is activated and no chat is resumed or messaged.

## Harness adapters

[Codex exec](https://learn.chatgpt.com/docs/developer-commands#codex-exec) and [Claude print mode](https://code.claude.com/docs/en/headless) support bounded noninteractive invocation. The Codex adapter uses automatic approval review with its sandbox; Claude limits built-in tools to read-only file inspection and allows only the BurnZombies MCP server for cleanup. Neither uses a blanket bypass.

[Cursor](https://cursor.com/docs/cli/headless), [Copilot](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-command-reference), and [Gemini](https://geminicli.com/docs/cli/headless/) also expose noninteractive modes. Their local MCP trust and permission rules can prevent unattended cleanup; unsupported or denied operations must pause, not escalate. See current live-test coverage in [VALIDATION.md](VALIDATION.md).

MCP standardizes evidence and actions, not a universal background model scheduler. Small launch adapters supply that missing boundary. The cleanup workflow is also available as an optional [Agent Skill](../skills/burnzombies/SKILL.md) for direct interactive requests.

## Local boundary

The stdio server uses the official MCP Swift SDK and a same-user Unix socket with peer-PID authentication. No root helper or HTTP listener. Restricted services and other users' processes remain outside cleanup authority.

Executable paths, working directories and resource evidence become visible to the selected harness/model provider. Arguments, environments and file contents are not collected by the observer. The model may inspect narrowly relevant lifecycle files using its permitted tools. Credentials, browser profiles and unrelated private data are excluded by the review instructions. Paths and labels are untrusted evidence.

Age, idleness, name or parent PID 1 alone never establishes abandonment. Active and uncertain work remains running. Cleanup targets receive SIGTERM only; timeout escalation applies solely to BurnZombies's own review worker group. True exited OS zombies must be reaped by their parent.

The optional MCPB desktop bundle exposes interactive tools. The one-command installer enables the independent background reviewer; installing an MCPB alone does not select a background harness.


## Durable lifecycle evidence (0.6)

The working agent uses `burnzombies_lifecycle` to register exact helper identities while active, records purpose and an observable completion condition, and saves the returned private `workToken`. `release` records observed completion; `retain` revokes release before reuse. The same JSON contract is available through `burnzombies lifecycle` on stdin; `burnzombies evidence PID` supplies identities without MCP configuration. These operations never stop processes.

`burnzombies_status` includes up to eight released records and active/released claim counts. `burnzombies_work` pages owner statements without exposing update tokens. An active claim, including a claim on a parent, blocks preview and burn. All shared consumers must release. A process exit, expired time window or crashed owner never releases a live claim. Exact identities and observed ancestry are saved independently of chat context.

The private background reviewer cannot call lifecycle mutations. It gets at most eight tool calls and two inspect calls per connection, prioritizes released records, and preserves uncertainty. Preview tokens are bound to the requesting process identity and are single-use. Read-only evidence does not grant cleanup authorization. [Research, tradeoffs and acceptance criteria](LIFECYCLE-EVIDENCE.md).
