# Agent instructions

## Releases

Releases are packaged and signed on the maintainer's Mac, never in CI. Every release since v0.13.0 is signed with one self-signed certificate, "BurnZombies Local Signing" (SHA-256 `dbe8297fd599efa4bb942d0ebb5487e3bc27c15d7b71fadc8253da8ab1d697b9`). macOS ties Full Disk Access to it, so a release signed with any other key makes every user allow BurnZombies again.

The key lives in 1Password as "BurnZombies release signing identity", in the `skylar` vault. To release:

1. **Make sure this Mac has the key.** `security find-identity -p codesigning` should list "BurnZombies Local Signing" with SHA-1 `F6EE40DDEBB01F056DE8FC7910091F4FAC3D7B49`. If it doesn't, run `scripts/release-identity.sh load`. It reads the key with the 1Password service account behind the maintainer's 1Password MCP (keychain item `codex-1password-service-account-token`), so nobody has to approve it, and installs it in the login keychain. The certificate isn't marked trusted, and doesn't need to be. The first signature on a Mac may ask whether codesign may use the key; the maintainer chooses Always Allow once. Never run `scripts/ensure-signing-identity.sh` for this: it makes a new key, and the release check refuses builds signed with it.
2. **Build from a clean checkout of the release commit.** `caffeinate -i -m scripts/package-release.sh` builds the universal app and signs it. It stops unless the signature carries the release certificate. If macOS asks whether codesign may use the key, the maintainer chooses Always Allow.
3. **Upload a draft.** Run `gh release create vX.Y.Z --draft --title vX.Y.Z --notes-file <notes> dist/release/*`.
4. **Merge, then publish at once.**
   1. Merge the release PR with `--match-head-commit`.
   2. Check that the merge commit's tree equals the built commit's tree: compare `git rev-parse <sha>^{tree}` for both.
   3. Publish: `gh release edit vX.Y.Z --target <merge sha> --draft=false --latest`.

   `install.sh` on main downloads that exact release, so installs fail until it is published.

Between building and merging, merge nothing else into main: the tree check would fail.

Never export the key yourself. `scripts/release-identity.sh save` exports it from a Mac's keychain into 1Password; only the maintainer runs it.
