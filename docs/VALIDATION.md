# Harness-first validation

Local validation on macOS 15.8.1 / Apple Silicon. The 0.3 source replaces the fixed abandonment classifier with harness-selected exact targets and quiet lifecycle transport.

## Verified

- 18 native checks passed, including 32 real unreaped OS children with eight live controls across five scans, 4,096 mixed mechanical safety cases, corrupt storage, identity protection, unknown IPC peer refusal, and active-work preservation.
- Three real detached helpers completed the production graceful-exit/120-second watch, with persistent, deduplicated impact accounting.
- Real Claude Code CLI and Codex CLI used the MCP server to inspect three real Node workers, select the two completed/cancelled disposable jobs from controller-provided lifecycle evidence, and preserve the live job. The controller verified exits and receipts afterward. This is controlled lifecycle evidence, not a claim that process age proves abandonment.
- Codex's first noninteractive run correctly refused a destructive MCP call under its `never` approval policy. The acceptance run routes requests through the client's supported automatic approval reviewer. No approval bypass flags, credential changes, or persistent permission widening.
- MCP initialize accepts object-valued experimental client capabilities; discovery, strict arguments, protected inspection, forged/reused preview refusal, prompts and EOF shutdown passed.
- 100 unchanged MCP checkpoints produced empty output; the local debug run measured 11.08 ms median / 12.57 ms p95, including stdio transport. A callback reads cached aggregates only.
- Native installer tests cover all five harness configuration formats, exact legacy-hook migration, unrelated settings/tool/hook preservation, repeat-install idempotence, conflict refusal before writes, and checkpoint opt-out.
- The universal release executable passed the same MCP protocol proof. The local release archive passed signature, repeat install, path-with-spaces, corrupt-download and archive-traversal checks without launching an app.

## Boundaries

Source skips reopening an already-running app, launches background connections without activation, and never presents UI from reopen events. **Desktop UI acceptance was not performed in this validation run.** No claim of end-to-end desktop UI validation is made.

The five configuration formats are tested; live model cleanup is verified only for Claude Code CLI and Codex CLI on this machine. Cursor, Copilot CLI and Gemini CLI were not installed for live tests. Desktop Code/Codex share their documented local configuration, but that does not replace UI execution proof. Hook trust remains owned by the client and is not bypassed.

The native package includes arm64 and x86_64 slices; local execution was on Apple Silicon, not Intel hardware. Release builds are ad-hoc signed, not Developer ID notarized. Packaging/installer checks use a local archive and mocked download only; they do not prove that a new public release has been published.

## Reproduce without displaying an app

```sh
scripts/test.sh --integration
python3 scripts/test-mcp.py
python3 scripts/test-harness-install.py
scripts/build-app.sh --universal
COPYFILE_DISABLE=1 tar -czf /tmp/BurnZombies-test.tar.gz -C dist BurnZombies.app
python3 scripts/test-install.py /tmp/BurnZombies-test.tar.gz
```

Real-client tests are opt-in, use existing login state, private monitor storage and disposable workers, and clean up their owned processes. They never open the menu-bar app. Use `scripts/test-harness-e2e.py --help`; keep account/client outputs private. A no-op or a policy refusal is not a successful cleanup.
