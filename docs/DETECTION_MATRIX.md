# Evidence and action matrix

The agent harness owns abandonment decisions. Resource use, age, executable name and parent PID 1 are evidence, not verdicts.

| Situation | Agent responsibility | Native behavior |
|---|---|---|
| Finished/cancelled disposable job | Establish exact ownership, no consumers, and which helpers remain | Fresh identity preview, then one SIGTERM attempt within authorization |
| Idle pool, browser or dev server | Determine whether a live task still needs it | Never automatically classified as abandoned |
| Unknown ownership | Leave running; identify missing evidence | No independent kill decision |
| True OS zombie | Investigate its parent and supported reap/teardown path | Child signaling refused; an exited child has no live workload to reclaim |
| Caller ancestry, system service or main app | Preserve | Protected by native guard |
| PID reuse, path/boot change, missing metrics or partial coverage | Reinspect; do not bypass refusal | Preview/action refused |
| Unreviewed children | Inspect the tree or use owner-native teardown | Parent action refused |
| Target remains after 15 seconds | Investigate owner | Partial receipt, no forced kill or credit |
| New matching child under same verified parent | Investigate possible restart behavior | No credit during the 120-second watch |
| Existing sibling or unrelated new job | Preserve active work | Not mistaken for recurrence |
| Exact targets exit and watch completes | Continue original task | Verified receipt contributes impact |
| Meaningful aggregate buildup/pressure change | One bounded review when authorized and convenient | Quiet checkpoint; no process selected by the signal |

There is no process-group or executable-name kill. No files, profiles, recordings, credentials or queues are inferred disposable. Periodic observation cannot prove that no brief process existed between samples or reliably attribute a replacement that was reparented. [Safety](SAFETY.md) · [Kernel zombie research](ZOMBIE_RESEARCH.md).
