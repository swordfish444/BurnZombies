#!/usr/bin/env python3
"""Verify a locally built MCPB archive and run protocol proof against its binary.

Requires the debug BurnProof fixture (swift build). No production cleanup occurs.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("archive", type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
with zipfile.ZipFile(args.archive) as archive:
    assert all(not Path(name).is_absolute() and ".." not in Path(name).parts
               for name in archive.namelist()), "Unsafe archive path"
    manifest = json.loads(archive.read("manifest.json"))
    assert manifest["server"]["type"] == "binary"
    entry = manifest["server"]["entry_point"]
    assert manifest["server"]["mcp_config"]["command"] == "${__dirname}/" + entry
    assert archive.getinfo(entry).external_attr >> 16 & 0o111, "Executable mode lost"
with tempfile.TemporaryDirectory(prefix="bz-mcpb-proof-") as temporary:
    target = Path(temporary)
    subprocess.run(["unzip", "-q", str(args.archive.resolve()), "-d", str(target)], check=True)
    app = target / "server/BurnZombies.app"
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    for name in ("BurnZombiesApp", "burnzombies", "burnzombies-mcp"):
        architectures = subprocess.check_output(["lipo", "-archs", str(app / "Contents/MacOS" / name)], text=True).split()
        assert {"arm64", "x86_64"}.issubset(architectures), f"Missing universal slice: {name}"
    subprocess.run([sys.executable, str(root / "scripts/test-mcp.py"),
                    "--server", str(target / entry)], check=True)
print("PASS MCPB paths, executable modes, universal binaries, app signature and protocol")
