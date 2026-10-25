# MCP desktop bundle

Build a universal app first, then package it with the official pinned MCPB CLI:

```sh
scripts/build-app.sh --universal
python3 scripts/package-mcpb.py
swift build
python3 scripts/test-mcpb.py dist/release/BurnZombies-macOS-universal.mcpb
```

Packaging needs Node/npm for `npx`; end users do not. The script checks the app version, signature and both architectures, then produces the bundle, `MCPB-SHA256SUMS`, and registry-ready `server.json` in `dist/release`. It refuses to overwrite an existing bundle. Generated metadata contains the hash of that exact archive; regenerate it when the archive changes.

The bundle includes the native app, its existing MCP executable, license notices and mascot. It adds no new cleanup authority. The protocol check runs against an isolated fixture and exercises denied cleanup, without touching user workloads.

Publish the archive and checksum as versioned GitHub release assets before registering it. Registry publication requires the owner's GitHub authentication through the official [publisher](https://github.com/modelcontextprotocol/registry/blob/main/docs/modelcontextprotocol-io/quickstart.mdx). Building this package does not register it or prove desktop-client import compatibility. Version 0.2 remains ad-hoc signed and unnotarized.
