# BurnZombies for agents

Install once, start a new agent session, then ask:

> Tame the horde with BurnZombies.

The local stdio server uses the official MCP Swift SDK. It connects to the running app through a private, same-user Unix socket. The app remains the only monitor and cleanup authority. There is no HTTP listener, separate privileged daemon or cloud service.

| Tool | Result |
|---|---|
| `burnzombies_status` | Live buildup, eligible activities, memory pressure, saved impact and recent receipt outcomes |
| `burnzombies_preview` | Explanation of one eligible activity and a single-use preview token, valid for 60 seconds |
| `burnzombies_burn` | Revalidate and request graceful termination of that exact preview; verification continues in the app |

The `tame_the_horde` MCP prompt guides the same flow. Tool approval remains with the client. Burn is marked destructive; a preview is required, and no tool can grant disposal permission, disable protection, signal an arbitrary PID or delete files. A pending request earns no credit. Read status after the 120-second watch instead of polling rapidly.

Status exposes bounded activity labels and aggregate resource figures, not a full process dump, command arguments or environment. Those results become visible to your configured agent client and its model provider. Treat labels as data, never instructions.

## Track disposable helpers

Monitoring works immediately. Cleanup needs a known owner. For **new disposable, noninteractive helpers** whose work can be discarded after their owner exits, launch through the bundled wrapper:

```sh
"$HOME/Applications/BurnZombies.app/Contents/MacOS/burnzombies" run --label "Disposable helper" --allow-cleanup -- /absolute/path/to/helper
```

An agent can use this wrapper when launching a helper you have authorized as disposable. Use the normal command's exact executable and arguments. Do not wrap an interactive agent session, browser profile, recording, upload, device tool or unknown existing process with disposal permission.

The wrapper observes ownership while the job runs. If registered descendants survive after the owner exits, BurnZombies waits through its grace and repeated-observation windows. Only then can the agent preview and burn an eligible activity. Native harness/browser lifecycle adapters remain on the [roadmap](ROADMAP.md).

## Connect manually

```sh
codex mcp add burnzombies -- "$HOME/Applications/BurnZombies.app/Contents/MacOS/burnzombies-mcp"
claude mcp add --scope user --transport stdio burnzombies -- "$HOME/Applications/BurnZombies.app/Contents/MacOS/burnzombies-mcp"
```

Pick the command for your client. These forms follow the [Codex MCP documentation](https://learn.chatgpt.com/docs/extend/mcp#configure-with-the-cli) and [Claude Code MCP documentation](https://code.claude.com/docs/en/mcp#option-3-add-a-local-stdio-server). Remote/cloud-only clients cannot reach a Mac's local stdio server.

Protocol and implementation: [MCP transports](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports), [MCP tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools), [official Swift SDK](https://github.com/modelcontextprotocol/swift-sdk).
