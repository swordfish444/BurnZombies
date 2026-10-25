#!/usr/bin/env python3
"""Exercise real archive/signature/install handling; stub only download and client config."""
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
assert url.startswith('https://github.com/swordfish444/BurnZombies/releases/download/v0.2.0/')
name=url.rsplit('/',1)[1]
assert name in ('SHA256SUMS','BurnZombies-macOS-universal.tar.gz')
shutil.copyfile(Path(os.environ['BZ_TEST_REMOTE'])/name, args[args.index('-o')+1])
''')
    client_stub = f"#!{sys.executable}\n" + '''import json,os,sys
from pathlib import Path
root=Path(os.environ['BZ_TEST_CONFIG'])
client=Path(sys.argv[0]).name
args=sys.argv[1:]
state=root/(client+'.json')
if args[:2]==['mcp','get']:
    if state.exists(): print(state.read_text()); sys.exit(0)
    sys.exit(1)
assert args[:2]==['mcp','add']
assert not state.exists(), 'existing configuration overwritten'
state.write_text(json.dumps(args))
'''
    for name in ("codex", "claude"): (stubs / name).write_text(client_stub)
    for path in stubs.iterdir(): path.chmod(0o755)
    config = root / "config"; config.mkdir()
    destination = root / "Applications with spaces"
    env = dict(os.environ, PATH=str(stubs) + os.pathsep + os.environ["PATH"],
               BZ_TEST_REMOTE=str(remote), BZ_TEST_CONFIG=str(config),
               BURNZOMBIES_INSTALL_DIR=str(destination))
    def install(client, success=True):
        result = subprocess.run(["/bin/bash", str(repo / "install.sh"), "--mcp", client, "--no-open"],
                                env=env, capture_output=True, text=True, timeout=60)
        assert (result.returncode == 0) == success, result.stdout + result.stderr
        return result
    install("codex")
    app = destination / "BurnZombies.app"
    binary = str(app / "Contents/MacOS/burnzombies-mcp")
    assert json.loads((config / "codex.json").read_text()) == ["mcp", "add", "burnzombies", "--", binary]
    install("claude")
    assert json.loads((config / "claude.json").read_text()) == ["mcp", "add", "--scope", "user", "--transport", "stdio", "burnzombies", "--", binary]
    existing = (config / "codex.json").read_bytes()
    install("auto")
    assert (config / "codex.json").read_bytes() == existing
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    original_binary = (app / "Contents/MacOS/BurnZombiesApp").read_bytes()
    with (remote / asset).open("ab") as file: file.write(b"bad download")
    assert "checksum failed" in install("none", success=False).stderr
    assert (app / "Contents/MacOS/BurnZombiesApp").read_bytes() == original_binary
    with tarfile.open(remote / asset, "w:gz") as file:
        info = tarfile.TarInfo("BurnZombies.app/../../escaped"); info.size = 4
        file.addfile(info, io.BytesIO(b"bad!"))
    checksum()
    assert "archive paths" in install("none", success=False).stderr
    assert not (root / "escaped").exists()
    print("PASS installer: both clients, spaces, repeat install, config preservation, signatures, corrupt download and path traversal refusal")
