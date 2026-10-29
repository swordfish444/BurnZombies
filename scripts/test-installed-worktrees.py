#!/usr/bin/env python3
"""Exercise the installed observer, real native visibility and real recovery key.

Only freshly generated sacrificial repositories are adopted or removed. This
temporarily adds one discovery root, then removes it. No fixture access/consumer
injection, harness reconfiguration or macOS permission changes are performed.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--cli", type=Path, required=True)
args = parser.parse_args()
cli = args.cli.resolve()
assert cli.name == "burnzombies" and cli.parent.name == "MacOS"


def command(argv, timeout=180):
    result = subprocess.run(argv, text=True, capture_output=True, timeout=timeout)
    if result.returncode:
        raise AssertionError(f"Installed command failed: {result.stdout or result.stderr}")
    return result.stdout


access = json.loads(command([str(cli), "access-check"]))
assert access["state"] == "granted", access


def request(value, ok=True):
    result = subprocess.run([str(cli), "worktrees", "request"], input=json.dumps(value),
                            text=True, capture_output=True, timeout=300)
    body = json.loads(result.stdout)
    assert body["ok"] == ok, body.get("message", "Unexpected installed reply")
    return body.get("worktreeInventory", {})


def git(path, *words):
    return command(["/usr/bin/git", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
                    "-C", str(path), *words]).rstrip("\n")


with tempfile.TemporaryDirectory(prefix="bz-installed-worktrees-") as temporary:
    root = Path(temporary).resolve()
    repo = root / "repository"
    repo.mkdir()
    git(repo, "init", "--initial-branch=main")
    git(repo, "config", "user.name", "Installed acceptance fixture")
    git(repo, "config", "user.email", "fixture@example.invalid")
    (repo / "source").write_text("initial fixture\n")
    (repo / ".gitignore").write_text(".env\n")
    git(repo, "add", ".")
    git(repo, "commit", "-m", "synthetic installed fixture")
    paths = [root / "clean-fixture", root / "local-work-fixture"]
    for path in paths:
        git(repo, "worktree", "add", "--detach", str(path))
    request({"action": "add_root", "path": str(root)})
    try:
        request({"action": "scan"})

        def row_for(path):
            offset = 0
            for _ in range(1000):
                page = request({"action": "list", "offset": offset})
                for row in page["records"]:
                    if row["path"] == str(path) and not row["retired"]:
                        return row
                if page.get("nextOffset") is None:
                    break
                offset = page["nextOffset"]
            raise AssertionError("Installed observer did not inventory its sacrificial checkout")

        clean = row_for(paths[0])
        request({"action": "adopt", "id": clean["id"], "revision": clean["revision"]})
        request({"action": "confirm", "id": clean["id"], "revision": clean["revision"],
                 "evidence": "This generated acceptance checkout is complete; only deliberate test consumers may still exist."})
        consumers = [
            (["/bin/sleep", "60"], paths[0]),
            ([sys.executable, "-c", "import sys,time; f=open(sys.argv[1]); print('READY',flush=True); time.sleep(60)", str(paths[0] / "source")], root),
        ]
        for index, (argv, cwd) in enumerate(consumers):
            child = subprocess.Popen(argv, cwd=cwd, stdout=subprocess.PIPE, text=True)
            try:
                if index == 1:
                    assert child.stdout.readline().strip() == "READY"
                refused = request({"action": "preview", "id": clean["id"], "revision": clean["revision"]}, ok=False)
                assert (paths[0] / "source").read_text() == "initial fixture\n"
            finally:
                child.terminate()
                child.wait(timeout=5)
        print("PASS installed observer preserves active cwd and open-file consumers")

        operations = []
        for index, path in enumerate(paths):
            if index:
                (path / "source").write_text("staged fixture\n")
                git(path, "add", "source")
                (path / "source").write_text("unstaged fixture\n")
                (path / ".env").write_text("synthetic-noncredential-fixture\n")
                (path / "binary").write_bytes(bytes([0, 255, 32, 1]))
            observed = row_for(path)
            observed = request({"action": "inspect", "id": observed["id"]})["records"][0]
            if not observed["managed"]:
                request({"action": "adopt", "id": observed["id"], "revision": observed["revision"]})
            result = json.loads(command([str(cli), "worktrees", "archive-retire" if index else "retire",
                                        observed["id"], observed["revision"], "--evidence",
                                        "This synthetic installed acceptance task is complete and has no remaining consumer."], timeout=300))
            assert result["ok"], result.get("message")
            operation = result["worktreeInventory"]["operations"][0]
            assert operation["phase"] == "completed" and operation["originalPath"] == str(path)
            assert operation["worktreeID"] == observed["id"] and operation["repository"] == str(repo / ".git")
            assert not path.exists()
            operations.append(operation)
        # Independent restore must use the installed archive/key, not this repo.
        shutil.rmtree(repo)
        for index, operation in enumerate(operations):
            restored = root / f"restored-{index}"
            request({"action": "restore", "id": operation["id"], "path": str(restored)})
            git(restored, "fsck", "--strict", "--no-reflogs")
            assert (restored / "source").read_text() == ("unstaged fixture\n" if index else "initial fixture\n")
            if index:
                assert git(restored, "show", ":source") == "staged fixture"
                assert (restored / ".env").read_text() == "synthetic-noncredential-fixture\n"
                assert (restored / "binary").read_bytes() == bytes([0, 255, 32, 1])
            # Exact verified test IDs only; never select other recovery items.
            request({"action": "purge", "id": operation["id"], "evidence": "PURGE RECOVERY"})
        print("PASS installed clean/dirty retirement, real Keychain recovery, standalone restoration after original-repository loss, and exact test-archive purge")
    finally:
        request({"action": "remove_root", "path": str(root)})
print("PASS actual installed app/CLI/native guard journey; no simulated consumer or access boundary")
