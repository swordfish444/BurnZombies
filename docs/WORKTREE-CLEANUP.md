# Finished work. Room for the next run.

BurnZombies shows **disk reclaimed** and **worktrees cleaned** beside helpers burned and memory released. These counters come from verified native cleanup receipts, not an agent's reported estimate. Old installations start these two counters at zero; previous process exits are not converted into disk savings.

## How a workspace becomes disposable

1. When an agent needs a throwaway task checkout, `burnzombies_workspace create` creates it from repository HEAD inside BurnZombies's private workspace directory. The agent records its purpose and observable completion condition and receives a private owner token.
2. The working agent finishes or cancels the task, preserves useful changes and outputs, finishes uploads and consumers, and releases its own token with observed completion evidence. A long-lived agent can release one finished workspace while continuing other work. No manual chat archive is necessary.
3. The independent background reviewer compares that evidence with the completion condition and contradictions. It can preview one released workspace and use the resulting short-lived token to request native removal.
4. Native checks run again immediately before removal. `git worktree remove` runs without force. The exact HEAD is retained in `refs/burnzombies/worktrees/<receipt-id>`; branches are never deleted. Counters update only after removal and the durable receipt are verified.

**An archived chat is a useful clue, not deletion authority.** Codex already manages its own worktree archive, snapshots and restoration. BurnZombies does not adopt existing worktrees, infer completion from age, or remove Codex-managed worktrees at default or custom locations. Automatic whole-worktree removal applies only to disposable workspaces created through its optional MCP/CLI interface. Version 0.8 also discovers generated output inside configured repositories; its separate [disk tuning controls](DISK-CLEANUP.md) require exact folder permission, independent review and fresh guards. Downloads, browser profiles, databases, arbitrary repositories and global caches remain outside automatic removal.

## What blocks removal

- An active/retained owner claim, missing release evidence, changed HEAD, changed directory identity, or reused preview.
- Tracked/staged changes, untracked **or ignored** files, including `.env` and generated output. The reviewer must not delete these to satisfy a guard.
- A worktree lock, unfinished merge/rebase/cherry-pick, sparse or assume-unchanged index entries, submodules, nested repositories, hardlinks, symlinks or special files.
- HEAD not reachable from an existing remote-tracking ref. No network fetch, push or credential use happens during cleanup. Remote reachability preserves work; it does not establish completion.
- A process using the checkout as cwd, executable location or open file path; incomplete same-user process/file-handle visibility also blocks cleanup.
- Unknown ownership, an inaccessible file tree, inspection limits, failed checkpoint or failed Git command.

Owner release is the primary evidence that future consumers are finished. Live checks are a second line of defense, not a proof that another process can never open a file: macOS/Git provide no transaction covering every future consumer and filesystem operation. Shared or uncertain workspaces must remain active. Tokens must not be handed to independent reviewers; retain before reuse. An interrupted/uncertain removal receives no credit and preserves its recovery ref.

On a Mac where protected services or a large descriptor table prevent complete inspection, unattended worktree removal stays blocked. BurnZombies does not request privacy permissions, ignore those failures, or claim a successful cleanup. Process cleanup continues under its existing guards.

## Disk accounting and recovery

Disk credit is the increase in filesystem free bytes observed around removal, capped by allocated regular-file blocks in the removed checkout. APFS clones/snapshots and concurrent disk activity affect attribution. A verified worktree can therefore count as cleaned with zero disk credit. The full calculation stays in the receipt details. CPU-time history remains available in details; it is no longer a headline metric.

To restore a cleaned checkout, use its repository and recovery ref from Burn Log:

```sh
git -C /path/to/repository worktree add --detach /new/restore/path refs/burnzombies/worktrees/RECEIPT_ID
```

Use the exact lowercase ref from the receipt. The saved ref keeps the commit reachable without relying on the remote. Ignored/uncommitted files never enter this recovery flow because they block removal.

## Evidence sources

- [Git worktree documentation](https://git-scm.com/docs/git-worktree): clean removal, locks and why pruning metadata is not disk cleanup.
- [Codex worktree lifecycle](https://learn.chatgpt.com/docs/environments/git-worktrees): managed worktrees, archive/restore and protected work.
- [Apple File System features](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/APFS_Guide/Features/Features.html): clones, snapshots and shared space.
