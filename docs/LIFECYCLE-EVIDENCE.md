# Owner evidence without per-chat bookkeeping (0.10)

The observer combines bounded passive Codex/Claude metadata with native producer evidence. Failed passive lookups now retry with bounded backoff, and bundled helper runtimes can supply evidence without losing app-process execution protections.

Supported Gradle 8.14.6 daemons expose exact owner identity, authenticated idle/busy state, last activity, memory and live children. The independent model can select an idle owner for its own stop-when-idle protocol; no session marker or fabricated completion claim is required. Unknown workers remain protected until positive lifecycle evidence or a supported owner operation exists. Whole-machine observation does not imply universal process cleanup coverage.

Storage uses the same division: model selection, exact owner-backed operation, native revalidation and verified receipts. Current scope and limits are in [Disk cleanup](DISK-CLEANUP.md) and [Safety](SAFETY.md).

---

# Passive lifecycle evidence (0.8)

Current implementation: [MCP architecture](MCP.md#passive-lifecycle-evidence-and-usage-08). Local Codex and Claude metadata now supplies bounded ownership/completion facts without per-chat skill calls. Session completion is only a candidate signal, not permission to kill. Missing visibility, a resumed owner, active consumers or insufficient purpose-specific evidence blocks cleanup. Optional explicit lifecycle claims remain supported, and existing active claims never silently expire.

The design below records the earlier 0.6 research and the tradeoffs that led to explicit claims. **Its global skill installation is no longer the default.**

---

# Remember the work, then reclaim its leftovers

Research and implementation plan, 2026-10-26.

## The problem

The computer-wide observer can identify a process precisely but cannot infer the intent of another task. A private background review has no shared chat memory. Repeatedly asking it to prove ownership from idle CPU, a name or an exited parent adds cost without supplying the missing fact. Existing live-harness fixtures supplied completed-job labels from a test controller; they did not prove that a working agent could capture lifecycle evidence itself.

## Decision

Use the portable Agent Skills format to teach working agents to record a helper while it is still needed, define its completion condition, and explicitly release their claim only after observing that condition. Persist those small records locally. Expose the same lifecycle operation through MCP and a native JSON bridge. The installer connects the MCP server to detected local harnesses and installs the skill, without adding hooks. Native shell access alone failed a real Codex sandbox test; MCP is the default working-agent path, with the native bridge as a fallback. Keep computer-wide observation and independent background review.

The native layer stores evidence and enforces boundaries. The selected model still decides whether to clean up. A release is an agent assertion with provenance, not an OS-certified verdict or automatic kill permission.

### Evidence contract

1. Inspect the exact PID and birth identity of a helper this task actually uses. Register it while work is active, with purpose and an observable completion condition. Live ancestry must connect the registering caller and helper; an already orphaned stranger cannot be retroactively claimed.
2. Keep the returned opaque work token in the owning task's context. Read-only status never exposes it. One claim cannot release another. Multiple tasks can retain the same helper; every claim must be released before cleanup is allowed.
3. Release only after the owner observes completion/cancellation, pending work and output have settled, and no consumer still needs the helper. Record that concrete evidence. A new dependency uses retain to revoke release immediately. No expiry or dead owner releases a claim.
4. A background reviewer receives a bounded list of released identities and their statements. It checks fresh identity, executable, live children, protections, descriptor evidence and contradictory active claims. It preserves uncertainty and uses the existing preview/graceful-stop/verified-receipt path.
5. Registration and release never stop a process. An owner crash before release remains uncertain. Unregistered existing processes remain visible computer-wide and can still be reviewed using independent evidence; this feature does not magically reconstruct lost intent.

## Alternatives

- **Stronger prompt alone:** simplest, but cannot recover facts that never reached the reviewer. Retain better bounded instructions, reject this as the whole solution.
- **Lifecycle hooks in five harnesses:** good event delivery but tool completion, turn completion and session exit do not mean a resource is disposable. Adds per-harness configuration/trust surfaces the operator explicitly rejected. Do not reintroduce hooks.
- **Read every harness transcript:** richer context, but private content, unstable formats, ambiguous ownership and substantial token cost. Do not collect transcripts.
- **Wrappers or idle timeouts:** can track children deterministically but require changing launch commands and cannot establish whether a shared helper is still needed. Keep legacy wrappers optional.
- **Skill plus durable ownership claims:** chosen. Small standard interface, provenance and revocable protection, model-directed completion decisions. Skill invocation remains a harness/model behavior, not a universal guaranteed callback.

## Primary sources

- [OpenAI skills](https://learn.chatgpt.com/docs/build-skills): implicit invocation, portable instructions, user skills under `~/.agents/skills`.
- [Claude Code skills](https://code.claude.com/docs/en/skills): description-based activation and personal `~/.claude/skills`.
- [Cursor skills](https://cursor.com/docs/skills): local discovery includes `~/.agents/skills`.
- [Copilot CLI skills](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-skills): personal `~/.agents/skills` supported.
- [Gemini CLI skills](https://geminicli.com/docs/cli/skills/): `~/.agents/skills` alias; activation can require user consent.
- [MCP prompts](https://modelcontextprotocol.io/specification/2025-06-18/server/prompts): prompts are user-controlled templates, not automatic lifecycle notifications.

Inference: standard skills plus MCP/native transport is the smallest common integration, but no standard guarantees every working agent will remember every resource. Report measured behavior and preserve missing evidence rather than claiming guaranteed coverage.

## Acceptance

- Native tests: persistent claims, shared consumers, wrong token, forged peer, stale identity, PID reuse, release/retain race after preview, failed persistence, closed owner, bounded storage and redacted readback.
- MCP and installer tests: identical lifecycle contract, strict arguments, five supported skill discovery paths, no hooks/permission changes, parsed transactional config edits, existing user settings preserved.
- Real Codex and Claude tests: agents register active disposable fixtures, perform/observe a real completion step, release only finished work, then a separate production reviewer discovers the saved evidence without controller-supplied completion labels. Active and uncertain controls survive. No real user workload is targeted.
- Ship only after affected tests pass; publish the release, merge main, install quietly, preserve selected model and recorded history. Record trial restart separately from uninterrupted runtime.


## Integration finding

The real Codex working-agent test first failed because its sandbox denied the native Unix-socket transport. Stronger instructions did not fix that access boundary. The shipped setup therefore connects the local MCP server as well as installing the skill. It does not disable sandboxing or auto-approve foreground tools. Codex TOML is parsed and round-trip checked, with a current-content precondition; machines with the operator's validated config helper use that transaction. No regex table appends.
