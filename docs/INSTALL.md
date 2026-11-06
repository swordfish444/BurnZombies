# Install once. Watch the whole Mac.

```sh
curl -fsSL https://raw.githubusercontent.com/swordfish444/BurnZombies/main/install.sh | bash
```

macOS 14+, Apple Silicon or Intel. The installer checks the download's checksum and signature, puts **BurnZombies.app** in `~/Applications` and starts it in the menu bar: look for the skull. No account, no API key, no sudo, no package manager and no restart.

BZ keeps running with no chat open, and a new install starts at login, so it comes back after you restart your Mac. macOS shows a notice when BZ adds itself to your login items. To stop that, switch off **Start at login** in Settings; updates keep your choice. Updating from v0.13.0 or earlier keeps the switch as it was; if it's off, turn it on in Settings. To remove BZ, see [Uninstall](#uninstall).

## Updates and About

Open **Settings → About BurnZombies** to see the installed version and build. **Check for Updates**
checks the latest published stable GitHub release. If one is newer, choose **Update and Restart**.
BZ downloads and verifies it, finishes work already in progress, and restarts into Settings. Your
rules, Keep decisions, recovery files, selected harness/model and start-at-login choice stay in place.
Updates use the same release signing certificate, preserving the app's Full Disk Access identity.

Checking or downloading never starts a hunt or cleanup. You can cancel a download before the restart
handoff. BZ never installs an older version, runs a downloaded installer script, or changes Gatekeeper.
An update that cannot be verified leaves the installed app alone. If the new app cannot start, BZ
restores and restarts the previous version. Replacement uses an atomic directory swap on the same
volume, so an interruption never leaves a missing app path; rollback copies are preserved if automatic
recovery cannot complete. Updates need write access to the app's folder, as with `~/Applications`.

Update checks and downloads contact GitHub only after you press a button. No app catalog, project
evidence, model credentials or telemetry is sent with them. There is no automatic polling or silent
installation. Versions before 0.16.0 do not have this button: run the install command above once to
upgrade, then use Settings for later releases.

## With or without Claude Code or Codex

**With Claude Code or Codex installed and signed in,** BZ uses it to judge new things, through your existing login. If you have both, it picks Claude Code. Reinstalling keeps the one you have.

**Without either,** AI judging is off. BZ still cleans with its own rules and your answers. To add AI later, install and sign in to Claude Code or Codex, then run:

```sh
~/Applications/BurnZombies.app/Contents/MacOS/burnzombies setup
```

Only Claude Code and Codex run AI sweeps. BZ reuses your login without copying or changing it, and never switches to another tool or account on its own. It adds nothing to your chats: no hooks, no reminders, no always-on tools and no edits to your Claude Code or Codex settings. Each AI sweep gets its own private connection to BZ.

## Installer options

Options pass through the pipe:

```sh
curl -fsSL https://raw.githubusercontent.com/swordfish444/BurnZombies/main/install.sh | bash -s -- --look-only
```

| Option | What it does |
| --- | --- |
| `--look-only` | Look first. BZ finds, sizes and asks as usual but burns nothing until you choose **Start burning** in the menu, or switch off **Settings → Autopilot → Look only**. Works with every `--mcp` choice, `none` included. |
| `--observe-only` | AI judging off. It isn't a dry run: BZ still burns what its starter rules and your answers cover. Turn AI on later with `burnzombies setup --with-ai`. |
| `--no-open` | Installs without starting the app. |
| `--mcp claude` or `--mcp codex` | Uses that tool for AI judging. The default, `auto`, picks Claude Code, then Codex. |
| `--mcp none` | Skips AI setup. |

To install somewhere other than `~/Applications`, set `BURNZOMBIES_INSTALL_DIR`: `curl … | BURNZOMBIES_INSTALL_DIR=/path/to/folder bash`.

From v0.13.0, releases are signed with BurnZombies' own certificate (not an Apple Developer ID) and are not notarized. The installer never disables Gatekeeper, removes quarantine flags or bypasses permissions. If your Mac's policy blocks the app, [build from source](../CONTRIBUTING.md).

## The first minutes

BZ takes its first look right away and keeps looking every minute for its first half hour, then every 15 minutes (change that with **Settings → Autopilot → Sweep every**). Within about a minute the panel shows how much it found, like **Found 4.2 GB of leftovers**, and **BZ has N quick questions** when there's something to decide. Safe starter rules burn from the first minute. With Claude Code or Codex, the first AI sweep starts about 10 minutes after install. [What BZ burns on its own →](AUTOPILOT.md)

Installed with `--look-only`, nothing burns: not the starter rules, not your yes answers, not the AI. The panel says **Look-only · nothing burns** and shows how much BZ would burn, like **I'd burn 5.6 GB**; **Findings** shows what and why. Answers still become rules. When you're ready, choose **Start burning** on the panel and BZ starts burning what waited right away. To go back to looking, switch **Look only** on in **Settings → Autopilot**.

## Optional Full Disk Access

Without Full Disk Access, BZ skips the places macOS guards with its privacy controls: Desktop, Documents, Downloads, iCloud Drive and other cloud drives (`~/Library/Mobile Documents`, `~/Library/CloudStorage`), Mail, Messages, Photos, other apps' data (`~/Library/Containers`, `~/Library/Group Containers`), and removable and network drives. It decides from the path alone and never reads inside them, so macOS never asks you for access to a folder. A skipped place is reported, never counted as empty: Autopilot's coverage note, the Worktrees window and the storage map say which places were skipped. A copy in one of those places stays listed as **not checked** and keeps its saved details until access returns; a copy whose project lives there is skipped.

With Full Disk Access, those places are covered too: Autopilot, the Worktrees window, the storage map and the junk-folder inventory all reach them. AI sweeps run either way. Agent requests that inspect or stop programs through the [MCP tools](MCP.md) still need it.

To turn it on:

1. Click **Allow Full Disk Access** in the small menu-bar banner. It opens **System Settings → Privacy & Security → Full Disk Access**. The same link is always under **Settings cog → Full Disk Access**.
2. Add and enable **BurnZombies.app**. If it isn't listed, use **Copy app path** in BurnZombies Settings, then **+**, **Command–Shift–G**, and paste the path into the macOS chooser.
3. Return to BurnZombies; it checks access once by itself. If macOS asks, choose **Quit & Reopen**; the check runs after the relaunch. **Check access** stays in Settings if you need it. No restart needed.

The banner's **×** hides the reminder and remembers your choice; it never grants permission or widens what BZ covers. Verified access removes the banner and turns the Settings section into a muted **Complete** row with a green checkmark and a **Manage access** link. If access is lost later, the reminder comes back. Opening the permission pane never marks setup complete by itself, and BZ never opens System Settings, Finder or an onboarding window on its own. An agent can install BZ, but macOS requires a person to grant this permission.

BZ checks access without reading messages or mail: it opens a protected folder and closes it again without listing what's inside. macOS has no supported way to report Full Disk Access directly, so missing or unclear evidence counts as no access. Only the running app's own check counts; access that a shell or agent has is not proof that BZ has it.

Check from an agent without opening a window:

```sh
~/Applications/BurnZombies.app/Contents/MacOS/burnzombies access-status
```

**After an update:** macOS ties the permission to the app's signer, and every release from v0.13.0 on is signed with the same certificate, so Full Disk Access carries over. Coming from an earlier release, which was ad-hoc signed, macOS sees a new app once: in **System Settings → Privacy & Security → Full Disk Access**, remove BurnZombies with **−**, add it again and switch it on. BZ keeps working in the meantime; only the protected places wait.

**Keep access across your own builds:** run `scripts/ensure-signing-identity.sh` once. It creates a local "BurnZombies Local Signing" certificate in your login keychain, trusted for code signing only, and macOS asks for your password once. From then on `scripts/build-app.sh` signs every build with it, so you allow Full Disk Access one last time. Set `BURNZOMBIES_SIGNING_IDENTITY` to use a certificate you already have.

If the switch is on but access still fails, remove the old BurnZombies entry, add the installed app again and enable it, then reopen BZ and check again.

Full Disk Access lets BZ look; it never approves a burn, skips an ownership check or lifts other macOS limits. A place BZ couldn't fully check still blocks cleanup there. See [Apple's access controls](https://support.apple.com/en-ca/guide/security/secddd1d86a6/web) and [Apple's explanation of access verification](https://developer.apple.com/forums/thread/835851).

## Hunt now or choose a schedule

Click **Hunt Zombies** in the menu bar to start an AI sweep now; it needs Claude Code or Codex. **Hunting Zombies →** opens the live hunt: a side-scrolling scene and an activity log of what BZ found, burned and freed. Finding something isn't burning it; the celebration waits for a verified burn. Closing the window leaves the sweep running. One sweep runs at a time.

On its own, BZ starts an AI sweep when there's something new to judge, at most every 30 minutes, and rechecks every 4 hours. The first waits about 10 minutes after install, until the first look is complete. A sweep takes a few minutes and is capped at 15; one that runs out of time after judging some things counts as done, and the next picks up the rest. If a sweep fails, BZ waits 15, 30, 60, then 120 minutes before trying again (at least an hour after a login or usage-limit problem). It never stops for good, and your rules keep working meanwhile. Scheduled sweeps never open a window or take focus.

**Settings → Autopilot** turns Autopilot, AI included, off and on; holds every burn with **Look only**; sets how often BZ looks (**Sweep every**, 15 minutes by default); starts a sweep (**Sweep now**); and lists the starter rules and **What BZ has learned**.

## Model and cost

Claude Code uses Sonnet at **Medium** thinking by default; Codex uses its own default. BZ sets Claude Code's thinking level for each sweep, so an effort level in your own Claude Code settings (such as max) can't make every sweep think for minutes. To change it, open **Settings → Review intelligence**, choose a model and thinking level, then **Save**. The change applies to the next sweep; a running one finishes as it started. **Use defaults** goes back to these defaults.

On API pricing a sweep costs roughly $0.30–$1.20. On a Claude or ChatGPT subscription it uses plan usage instead. Looking around between sweeps uses no AI. **Settings → Usage & estimated cost** charts tokens and estimated cost by hour or day for 1, 7 or 30 days, for all models or one. Unknown prices and missing usage are marked unavailable, never guessed.

An agent can set the model without opening a window:

```sh
~/Applications/BurnZombies.app/Contents/MacOS/burnzombies setup --model MODEL_ID --thinking high
```

`--model default --thinking default` clears the choice. `--harness claude` or `--harness codex` switches tools; switching clears the old tool's model and thinking level unless you pass new ones. These settings live only in BZ's private configuration, and reinstalling keeps them.

## Check it's working

```sh
~/Applications/BurnZombies.app/Contents/MacOS/burnzombies doctor
```

`doctor` is read-only. It checks BZ's own setup, whether Claude Code or Codex is found, and whether the running app answers (`appResponding`, `runningAppMatchesCLI`). It never starts the AI or a burn, and finding a tool doesn't prove you're signed in. Test results and known limits are in [VALIDATION.md](VALIDATION.md).

## Uninstall

1. Switch off **Start at login** in Settings, then stop BZ:

   ```sh
   ~/Applications/BurnZombies.app/Contents/MacOS/burnzombies stop-observer ~/Applications/BurnZombies.app
   ```

2. Delete `~/Applications/BurnZombies.app`.
3. Delete `~/Library/Application Support/BurnZombies`.

Deleted the app first? If BurnZombies is still listed in **System Settings → General → Login Items**, remove it there.

Restore points stay in each repository until you delete them, and they are the only way back for copies BZ burned there. To delete them, run this inside the repository:

```sh
git for-each-ref --format='%(refname)' refs/burnzombies/ | xargs -n1 git update-ref -d
```

Default setup adds nothing to your chats, so there's nothing else to remove. If you once used the optional chat integration (`burnzombies install`), remove only BurnZombies' entries through your tool's own settings.

## Agent-led setup

Give Claude Code or Codex the [agent setup guide](https://raw.githubusercontent.com/swordfish444/BurnZombies/main/llms.txt). It installs BZ, checks the result with `doctor`, keeps your agent settings and never treats setup as permission to clean.

## How BZ knows a chat is still working

BZ reads the session records Claude Code and Codex keep on your Mac to learn which chats are still running, and in which folders. It reads small, bounded pieces and keeps no prompts, replies, commands or tool output. Your chats do no bookkeeping for BZ, and looking around makes no AI calls. A program or copy a running chat is working in is never touched.
