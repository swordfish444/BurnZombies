# Security reporting

Use [GitHub private vulnerability reporting](https://github.com/swordfish444/BurnZombies/security/advisories/new) for unsafe targeting, identity/permission bypasses, state-file attacks or privacy leaks. Do not open a public issue containing sensitive evidence. If private reporting is unavailable, open a minimal issue requesting a private contact route without disclosing the vulnerability details or private data.

Include the affected commit/version, macOS version/architecture, expected protection, observed behavior and a synthetic reproducer if possible. Redact secrets, arguments, personal paths and session contents. Do not send your full catalog or crash report by default.

The current 0.1 line is the supported development line. This project does not yet provide a response-time SLA, signed downloadable release, or security audit certification. See the explicitly documented [safety limits](docs/SAFETY.md), including the residual PID-based signal race and the trust model for same-user lease files.
