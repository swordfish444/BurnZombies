# BurnZombies

**Know what is accumulating. Preserve active work. Stop disposable leftovers with evidence.**

A small native macOS menu bar utility for machines that run agent tools for long stretches. Monitoring starts immediately. Cleanup starts with explicit ownership, not a guess about a process name.

**0.2.0 includes a universal Mac app and local MCP server.** [Install in one command](INSTALL.md). It has no privileged daemon, account, cloud service, telemetry, or LLM dependency. It does not promise to safely kill arbitrary orphan processes. Read the [safety boundaries](SAFETY.md) before opting into cleanup.

## Build and run

Source builds require macOS 14 or later and Swift 6.2 (Apple Command Line Tools or Xcode). The separate MCP executable uses the official Swift SDK. The downloaded app does not require a compiler.

```sh
git clone https://github.com/swordfish444/BurnZombies.git
cd BurnZombies
scripts/build-app.sh
open dist/BurnZombies.app
```

Look for the flame in the menu bar. The bundle includes the `burnzombies` command-line wrapper and `burnzombies-mcp` server in `Contents/MacOS/`. The build and universal download have a local ad-hoc signature; **Developer ID signing and notarization are not provided yet**. Do not disable Gatekeeper to install an untrusted binary.

```sh
scripts/test.sh                 # dependency-free deterministic and native checks
scripts/test.sh --integration   # real detached helper, full grace and verification windows
swift run burnzombies scan      # aggregate scanner visibility and elapsed time
swift run burnzombies status    # aggregate saved catalog counts
```

The standalone proof runner works with Command Line Tools installations that do not include XCTest. The integration test takes roughly five minutes because it uses the production safety windows. It creates and stops only its own sacrificial helpers.

## Everyday use

1. Open the menu bar panel for today’s impact. Select **View impact** for the larger window or **Burn Log** to review activities.
2. Select an activity to see the observed evidence, uncertainty, and resident footprint. Descriptor inspection is optional and lazy.
3. Protect an executable to protect future instances too, or snooze those process identities for 24 hours.
4. For an eligible disposable helper, select **Preview cleanup**, read the irreversible-action notice, then **Request graceful stop**.
5. Open **Burn Log**. A request is initially uncredited. Verification records exit, failure, uncertainty, or suspected recurrence.

Automatic cleanup and notifications are off initially. Automatic cleanup uses exactly the same eligibility rules and requires both a per-session disposable-helper grant and the global opt-in. Every session receives at most one attempt. No SIGKILL escalation is offered.

## Establish ownership for disposable helpers

Existing agent sessions do not become cleanup targets merely by installing this app. To register a **new** command, use:

```sh
cli="$PWD/dist/BurnZombies.app/Contents/MacOS/burnzombies"
"$cli" run --label "Local tool session" -- /absolute/path/to/your/tool
```

That observes ownership and protects the activity. Add `--allow-cleanup` **only** when the command and all its descendants are disposable, noninteractive helpers that may be stopped after the wrapper exits:

```sh
"$cli" run --label "Disposable test worker" --allow-cleanup -- /absolute/path/to/helper
```

The wrapper passes standard input/output/error through and never stores command arguments, environment variables, session contents, or workspace contents. It records exact identities and parent edges it actually observes. It polls while the command lives; a child that detaches before observation may escape registration. Such a child is never targeted by a name or process-group guess.

Use the owning application's normal teardown first: MCP stdin EOF, a browser context's close method, or the supervisor's stop command. Browser engines, app bundles, known agent executables, devices, recordings, transfers, credentials, system services, and ambiguous identities remain outside cleanup eligibility. Do not wrap interactive shells, general-purpose agent sessions, or tools holding important work with `--allow-cleanup`.

## What it detects

| Finding | Result |
|---|---|
| Registered disposable helpers surviving a confirmed owner exit | Review, then one graceful stop when every safety predicate passes |
| Sustained resident-memory or descriptor-table capacity growth | Investigate; no stop permission inferred |
| Large same-parent helper family | One grouped finding; may be an intentional pool |
| Repeated starts and exits | Suspected restart loop; fix the creator, never a kill loop |
| Actual OS zombie | Explain parent reaping; never try to kill a dead process |
| Active owned work, protected executable, uncertain visibility | Preserve it |

See the [detection matrix](DETECTION_MATRIX.md) for thresholds, non-signals, and limits.

## Impact totals

The panel shows verified helper exits, resident-footprint release totals, CPU time saved, and agent speed. Today and seven-day views filter verified receipts; all-time counts and resident totals survive detailed-history pruning. Memory is attributed from pre-stop resident footprint; shared pages can overlap. CPU time saved is a one-hour projection of the observed pre-stop CPU rate, credited once after a verified cleanup. It does not count CPU already used. Missing older measurements appear as a dash. The app does not delete user files.

Before and after a cleanup, the app times a small local command-launch probe and saves the median of seven runs after warm-up. Agent speed uses `(before / after - 1) × 100`, with `~` in the UI. This is a local responsiveness estimate, not a measurement of remote model or network speed. Unavailable data appears as a dash. **View impact details** holds the explanation so the default panel stays simple.

See [validation and measured overhead](VALIDATION.md), [research](RESEARCH.md), [architecture](ARCHITECTURE.md), and the [roadmap](ROADMAP.md).

## Privacy, recovery, and uninstall

State lives in `~/Library/Application Support/BurnZombies`, owned by your user with private directory/file modes. It contains executable paths, labels you provide, process identities, bounded samples, preferences, and cleanup receipts. Treat it as private diagnostic data. Nothing uploads it. `BURNZOMBIES_HOME` selects a separate state directory for tests; do not point it at shared or untrusted storage.

The catalog has a 4 MiB compressed checkpoint ceiling, 4,096 process records with eight samples each, 500 receipts/30 days, and 256 ownership leases with at most 512 identities each. Expired, fully exited leases are pruned. A corrupt or oversized catalog pauses monitoring/cleanup with an error; it is not silently deleted. Quit the app and move the state directory aside to preserve it before starting fresh. Permission files must never be imported from someone else.

To uninstall: disable **Start at login** if enabled, quit BurnZombies, remove its MCP entry from your agent client, and move its app bundle to Trash. Optionally move its Application Support directory to Trash. No root helper, launch daemon, browser extension, or system policy is installed. A wrapper you started belongs to that running command; cancel it normally before removing its executable. Quit does not stop your workloads.

## Development

`BurnCore` owns the catalog, deterministic decisions, and action journal. `CBurn` contains the small macOS process adapter. `BurnApp` hosts SwiftUI in an AppKit status item/popover. `BurnCLI` records explicit ownership. `BurnProof` runs the test suite. Dependencies are platform frameworks only.

For a safe visual preview with synthetic data:

```sh
dist/BurnZombies.app/Contents/MacOS/BurnZombiesApp --demo --show-window
```

Demo mode cannot signal any process or write production state. [Contributions](../CONTRIBUTING.md) and [private security reports](../SECURITY.md) are welcome. MIT licensed.
