# Your harness is the brain

BurnZombies uses two portable standards: [Agent Skills](https://agentskills.io) for the cleanup workflow and [MCP](https://modelcontextprotocol.io/specification/2025-11-25/server/tools) for local evidence and guarded actions. Small lifecycle adapters deliver a review reminder to the active agent. They do not diagnose processes, call another model, or kill anything.

The agent uses its task context and normal investigation tools to distinguish finished, abandoned work from active dependencies. There are no mandatory wrappers, fixed idle thresholds or process-name kill lists. Native protection of OS services and current harness ancestry is an execution boundary, not a classifier.

| Tool | Result |
|---|---|
| `burnzombies_checkpoint` | Quiet lifecycle transport; cached aggregates only, empty unless attention is due |
| `burnzombies_status` | Process-family counts, pressure, impact and recent receipts |
| `burnzombies_inspect` | Bounded process evidence: exact identity, parent, executable, memory, CPU, I/O and protections; page or select PIDs |
| `burnzombies_preview` | The agent supplies exact identities, a label and ownership rationale; returns a single-use token valid for 60 seconds |
| `burnzombies_burn` | Revalidates the preview and requests SIGTERM; the app verifies exits and watches recurrence |

The skill is [short and instruction-first](../skills/burnzombies/SKILL.md). It asks the model to prefer owner-native teardown, preserve active/uncertain work, and continue the original task while receipts settle. A true OS zombie is an exited child awaiting its parent's reap; killing that child cannot release memory.

## Alongside a long-running session

Codex and Claude Code use **one PostToolUse MCP callback** on the existing connection. No shell launch per tool, startup hook, Stop hook or forced continuation. Cursor and Copilot CLI use one postToolUse native callback; Gemini uses one AfterTool callback. These callbacks read a small cached aggregate signal, never scan or invoke a model. Normal/unchanged state returns `{}`. A pending **Safe cleanup** request or meaningful pressure/buildup change can add a short review context, at most once per ten minutes across harnesses for automatic signals. The signal does not select a process or establish abandonment.

The installer can disable all callbacks with `--checkpoints off` while keeping the skill and on-demand MCP tools. This quieter mode cannot guarantee periodic automatic reviews. MCP callbacks run synchronously with a one-second timeout; their result never blocks a turn or replaces tool output. A timeout/error leaves the original work running.

Hooks run at harness lifecycle boundaries: they cannot interrupt a tool that never returns or wake an entirely idle/disconnected model. The app continues observation and receipt verification between agent turns. First-use hook trust and tool approvals remain with the harness. MCP alone cannot force a client to run a model; optional MCP sampling is not a portable scheduling guarantee.

## Local boundary

The native stdio server uses the official MCP Swift SDK and a private same-user Unix socket. The menu bar app owns the catalog and syscall execution. There is no HTTP listener or root helper. Inspect results include local executable paths and become visible to the configured harness/model provider; arguments, environments and file contents are not collected. Labels and paths are untrusted evidence.

A cleanup request needs current user authorization (including standing session-hygiene authorization). A process count, age, low CPU or parent PID 1 alone does not establish abandonment. The app checks identity/start time/boot, same user, protections, current caller ancestry, complete scan coverage and reviewed children. No SIGKILL, bulk executable-name kill, file cleanup or credential operation is exposed. Pending receipts earn no credit. [Safety and residual limitations](SAFETY.md).

## Supported local harness formats

| Harness | MCP configuration | Skill | Lifecycle configuration |
|---|---|---|---|
| Codex CLI / desktop local tasks | `~/.codex/config.toml` | `~/.agents/skills/burnzombies` | `~/.codex/hooks.json` |
| Claude Code CLI / Desktop Code tab | `~/.claude.json` | `~/.claude/skills/burnzombies` | `~/.claude/settings.json` |
| Cursor local agent | `~/.cursor/mcp.json` | `~/.cursor/skills/burnzombies` | `~/.cursor/hooks.json` |
| GitHub Copilot CLI | `~/.copilot/mcp-config.json` | `~/.copilot/skills/burnzombies` | `~/.copilot/hooks/burnzombies.json` |
| Gemini CLI | `~/.gemini/settings.json` | `~/.gemini/skills/burnzombies` | `~/.gemini/settings.json` |

Local integrations cannot reach a different computer or a cloud-only agent sandbox. Claude Desktop's **Code tab** uses Claude Code configuration; Chat and Cowork are separate surfaces. A desktop-chat MCP bundle alone does not install the lifecycle skill.

Primary references: [Codex skills](https://learn.chatgpt.com/docs/build-skills), [Codex MCP](https://learn.chatgpt.com/docs/extend/mcp), [Codex hooks and trust](https://learn.chatgpt.com/docs/hooks), [Claude skills](https://code.claude.com/docs/en/skills), [Claude Desktop configuration sharing](https://code.claude.com/docs/en/desktop), [Claude hooks](https://code.claude.com/docs/en/hooks), [Cursor hooks](https://cursor.com/docs/hooks), [Copilot hooks](https://docs.github.com/en/copilot/reference/hooks-reference), [Gemini skills](https://geminicli.com/docs/cli/tutorials/skills-getting-started/), [Gemini hooks](https://geminicli.com/docs/hooks/reference/).
