#!/usr/bin/env python3
"""Package a verified universal app with the official, pinned MCPB toolchain."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / "dist/BurnZombies.app")
    parser.add_argument("--output", type=Path, default=ROOT / "dist/release")
    args = parser.parse_args()
    app = args.app.resolve()
    output = args.output.resolve()
    manifest = json.loads((ROOT / "packaging/mcpb/manifest.json").read_text())
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info["CFBundleShortVersionString"] != manifest["version"]:
        parser.error("App and MCPB versions differ; update the manifest before packaging.")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    for name in ("BurnZombiesApp", "burnzombies", "burnzombies-mcp"):
        architectures = subprocess.check_output(["lipo", "-archs", str(app / "Contents/MacOS" / name)], text=True).split()
        assert {"arm64", "x86_64"}.issubset(architectures), f"Missing universal slice: {name}"
    output.mkdir(parents=True, exist_ok=True)
    artifact = output / "BurnZombies-macOS-universal.mcpb"
    if artifact.exists():
        parser.error(f"Refusing to replace {artifact}; choose a new output directory.")
    with tempfile.TemporaryDirectory(prefix="burnzombies-mcpb-") as stage_path:
        stage = Path(stage_path)
        (stage / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        shutil.copytree(app, stage / "server/BurnZombies.app", symlinks=True)
        shutil.copy2(ROOT / "Sources/BurnApp/Resources/EmberSkull.png", stage / "icon.png")
        shutil.copy2(ROOT / "LICENSE", stage / "LICENSE")
        shutil.copy2(ROOT / "docs/MCP.md", stage / "README.md")
        command = ["npx", "--yes", "@anthropic-ai/mcpb@2.1.2"]
        subprocess.run(command + ["validate", str(stage / "manifest.json")], check=True)
        subprocess.run(command + ["pack", str(stage), str(artifact)], check=True)
    digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
    (output / "MCPB-SHA256SUMS").write_text(f"{digest}  {artifact.name}\n")
    metadata = {
        "$schema": "https://static.modelcontextprotocol.io/schemas/2025-12-11/server.schema.json",
        "name": "io.github.swordfish444/burnzombies",
        "title": "BurnZombies",
        "description": "Harness-led cleanup of abandoned agent helpers on macOS.",
        "version": manifest["version"],
        "repository": {"url": "https://github.com/swordfish444/BurnZombies", "source": "github"},
        "packages": [{
            "registryType": "mcpb",
            "identifier": f"https://github.com/swordfish444/BurnZombies/releases/download/v{manifest['version']}/{artifact.name}",
            "fileSha256": digest,
            "transport": {"type": "stdio"},
        }],
    }
    (output / "server.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Built {artifact}; registry metadata prepared, not submitted.")


if __name__ == "__main__":
    main()
