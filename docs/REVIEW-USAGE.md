# Review usage repair — v0.7.1

Cause: the old observer launched a model on startup, every hour, on ordinary memory/process growth, and as often as every minute for release requests. Unchanged evidence could be reviewed repeatedly. A general coding-agent context and lifecycle-skill reads multiplied input on each MCP turn. Only the latest review log survived, hiding total usage.

The 24-hour trial captured 25 distinct completed review logs with 5,133,398 input tokens (4,173,056 cached) and 17,749 output tokens. This is a lower bound from retained evidence, not account-credit or billing telemetry. Eighteen captured no-op reviews had a median of 226,328 input tokens.

The repair gates model dispatch on new released lifecycle evidence, coalesces releases for two minutes, uses a 30-minute minimum interval, persists reviewed revisions, and limits starts to eight per rolling day. A 200,000 recorded-input-token threshold, including cached input, blocks further starts; the final run can exceed that threshold. Unavailable usage remains unknown and consumes an attempt. This is not a provider-enforced hard token or credit ceiling.

Codex loads a focused cleanup policy with optional apps, plugins, memories, host skills and unrelated tools disabled for the invocation. Authentication, selected model/thinking and managed security controls stay with Codex. Native identity, consumer, worktree and preview safeguards are unchanged. The working-task lifecycle skill uses the CLI by default; global MCP integration remains opt-in. No chat hooks are installed.

A first stricter read-only/never-approval candidate refused the fixture burn. That invocation configuration was rejected and the existing supervised automatic approval-review path restored. No broad sandbox or permission bypass was introduced.

Measured isolated Codex Low runs:
- Empty queue: 20,193 input / 9,856 cached / 68 output tokens, one status call, no cleanup. Automatic empty queues now dispatch zero model calls; this explicit test measured context overhead.
- Completed test report: 70,744 input / 62,464 cached / 398 output tokens, status → inspect → preview → burn; retained and unrelated controls stayed alive. The native observer subsequently verified the exact exit and 120-second same-parent replacement watch.

These are observed token counts, not a claim of an equivalent percentage reduction in charged credits. Approval-review overhead may not be included in the CLI turn usage. No account or provider switch was used.
