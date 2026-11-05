#!/usr/bin/env python3
"""Exercise real archive/signature/install handling; stub only download; never touch live harness settings."""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

repo = Path(__file__).resolve().parents[1]
archive = Path(sys.argv[1]).resolve()
asset = "BurnZombies-macOS-universal.tar.gz"
with tempfile.TemporaryDirectory(prefix="bz-install-") as temp:
    root = Path(temp); remote = root / "remote"; remote.mkdir()
    shutil.copy2(archive, remote / asset)
    def checksum():
        digest = hashlib.sha256((remote / asset).read_bytes()).hexdigest()
        (remote / "SHA256SUMS").write_text(f"{digest}  {asset}\n")
    checksum()
    stubs = root / "bin"; stubs.mkdir()
    (stubs / "curl").write_text(f"#!{sys.executable}\n" + '''import os,sys,shutil
from pathlib import Path
args=sys.argv[1:]
url=next(a for a in args if a.startswith('https://'))
assert url.startswith('https://github.com/swordfish444/BurnZombies/releases/download/v0.14.0/')
name=url.rsplit('/',1)[1]
assert name in ('SHA256SUMS','BurnZombies-macOS-universal.tar.gz')
shutil.copyfile(Path(os.environ['BZ_TEST_REMOTE'])/name, args[args.index('-o')+1])
''')
    for path in stubs.iterdir(): path.chmod(0o755)
    (stubs / "codex").write_text("#!/bin/sh\nexit 0\n")
    (stubs / "codex").chmod(0o755)
    config = root / "config"; config.mkdir()
    destination = root / "Applications with spaces"
    # Only the stubs count as installed tools, whatever this Mac has.
    empty = root / "no-harness-bin"; empty.mkdir()
    env = dict(os.environ, PATH=str(stubs) + os.pathsep + "/usr/bin:/bin", BURNZOMBIES_HARNESS_DIRS=str(empty),
               BZ_TEST_REMOTE=str(remote), BZ_TEST_CONFIG=str(config),
               BURNZOMBIES_HOME=str(root / "observer-state"), BURNZOMBIES_SKILL_HOME=str(root / "skill-home"),
               BURNZOMBIES_INSTALL_DIR=str(destination))
    def install(client, success=True, observe=False):
        result = subprocess.run(["/bin/bash", str(repo / "install.sh"), "--mcp", client, "--no-open"]
                                + (["--observe-only"] if observe else []),
                                env=env, capture_output=True, text=True, timeout=60)
        assert (result.returncode == 0) == success, result.stdout + result.stderr
        return result
    first = install("none")
    assert 'Full Disk Access' in first.stdout
    # A newcomer reads a few lines saying what happens next, not a manual.
    assert len(first.stdout.splitlines()) <= 7, first.stdout
    app = destination / "BurnZombies.app"
    install("none")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    original_binary = (app / "Contents/MacOS/BurnZombiesApp").read_bytes()
    install("auto")
    configured = json.loads((root / "observer-state/machine-review.json").read_text())
    assert not (root / 'observer-state/full-disk-access.json').exists(), 'Installer must never claim a user granted disk access'
    assert configured['harness'] == 'codex' and configured['enabled']
    assert configured['server'] == str(app / 'Contents/MacOS/burnzombies-mcp')
    assert not (root/'skill-home/.codex/config.toml').exists(), 'Default installer added global MCP overhead'
    assert not (root/'skill-home/.claude.json').exists(), 'Default installer changed harness configuration'
    assert not (root/'skill-home/.agents/skills/burnzombies/SKILL.md').exists(), 'Default installation must not add per-chat instructions'
    install("auto")
    assert json.loads((root / "observer-state/machine-review.json").read_text()) == configured
    install("codex", observe=True)
    assert json.loads((root / "observer-state/machine-review.json").read_text())['enabled'] is False
    # Look-only holds every burn from the first minute, with or without AI setup, in a few lines.
    for client in ["none", "codex"]:
        state = root / f"look-only-{client}"
        looking = subprocess.run(["/bin/bash", str(repo / "install.sh"), "--mcp", client, "--no-open", "--look-only"],
                                 env=dict(env, BURNZOMBIES_HOME=str(state)), capture_output=True, text=True, timeout=60)
        assert looking.returncode == 0, looking.stdout + looking.stderr
        assert "Look-only is on" in looking.stdout and len(looking.stdout.splitlines()) <= 7, looking.stdout
        assert json.loads((state / "autopilot/sweep.json").read_text())["lookOnly"] is True
        assert (state / "machine-review.json").exists() == (client == "codex")
    # Without Claude Code or Codex the default install still succeeds, with AI judging off.
    bare = dict(env, BURNZOMBIES_HOME=str(root / "bare-state"), BURNZOMBIES_INSTALL_DIR=str(root / "Bare Applications"))
    (stubs / "codex").unlink()
    plain = subprocess.run(["/bin/bash", str(repo / "install.sh"), "--no-open"], env=bare,
                           capture_output=True, text=True, timeout=60)
    assert plain.returncode == 0, plain.stdout + plain.stderr
    assert 'No Claude Code or Codex found' in plain.stdout, plain.stdout
    assert (root / "Bare Applications/BurnZombies.app/Contents/MacOS/burnzombies").exists()
    assert not (root / "bare-state/machine-review.json").exists()
    with (remote / asset).open("ab") as file: file.write(b"bad download")
    assert "checksum failed" in install("none", success=False).stderr
    assert (app / "Contents/MacOS/BurnZombiesApp").read_bytes() == original_binary
    with tarfile.open(remote / asset, "w:gz") as file:
        info = tarfile.TarInfo("BurnZombies.app/../../escaped"); info.size = 4
        file.addfile(info, io.BytesIO(b"bad!"))
    checksum()
    assert "archive paths" in install("none", success=False).stderr
    assert not (root / "escaped").exists()
    print("PASS installer: private default reviewer setup, look-only, spaces, repeat install, signatures, corrupt download and path traversal refusal")
