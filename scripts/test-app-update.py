#!/usr/bin/env python3
"""Mac-only signed updater handoff/rollback proof. Uses the existing release identity;
inert apps plus an isolated observer with cleanup held and AI disabled. Never uses live state.
"""
import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid

CERTIFICATE = "F6EE40DDEBB01F056DE8FC7910091F4FAC3D7B49"
repo = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("app", type=Path, help="A current signed debug or release app containing the update helper")
parser.add_argument("--artifacts", type=Path, help="Retain private fixture files for diagnosing a failure")
parser.add_argument("--real-app-only", action="store_true")
options = parser.parse_args()
source_helper = options.app.resolve() / "Contents/MacOS/burnzombies"
proof = repo / ".build/debug/BurnProof"


def run(*arguments, **keywords):
    result = subprocess.run(arguments, capture_output=True, text=True, **keywords)
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout


run("codesign", "--verify", "--strict", "-R", f'=certificate leaf = H"{CERTIFICATE}"', str(source_helper))
# macOS UNIX-domain socket paths are limited to 104 bytes. Keep the private
# fixture root short, rather than using Python's long per-user temporary path.
if options.artifacts:
    options.artifacts.mkdir(mode=0o700)
with (contextlib.nullcontext(str(options.artifacts)) if options.artifacts else
      tempfile.TemporaryDirectory(prefix="bz-signed-updates-", dir="/tmp")) as temporary:
    root = Path(temporary).resolve()
    (root / "parent.c").write_text("#include <unistd.h>\nint main(void) { for (;;) pause(); }\n")
    (root / "cli.c").write_text(r'''#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifndef VERSION
#define VERSION "0.0.0"
#endif
#ifndef BUILD
#define BUILD "0"
#endif
int main(int argc, char **argv) {
    const char *root = getenv("BURNZOMBIES_HOME");
    if (!root || argc < 2) return 2;
    char path[4096]; snprintf(path, sizeof(path), "%s/calls", root);
    FILE *log = fopen(path, "a"); if (!log) return 3;
    fprintf(log, "%s:%s\n", argv[1], VERSION); fclose(log);
    if (!strcmp(argv[1], "doctor")) {
        const char *fail = getenv("BURNZOMBIES_UPDATER_FIXTURE_FAIL");
        int healthy = !fail || strcmp(fail, VERSION);
        printf("{\"appResponding\":%s,\"runningAppMatchesCLI\":true,"
               "\"runningAppVersion\":\"%s\",\"runningAppBuild\":\"%s\"}\n",
               healthy ? "true" : "false", VERSION, BUILD);
    }
    return 0;
}
''')

    def sign(app):
        for name in ["burnzombies", "burnzombies-mcp"]:
            executable = app / "Contents/MacOS" / name
            run("codesign", "--force", "--sign", CERTIFICATE, "--timestamp=none", str(executable))
        run("codesign", "--force", "--sign", CERTIFICATE, "--timestamp=none", str(app))

    def make_app(path, version, build):
        binaries = path / "Contents/MacOS"
        binaries.mkdir(parents=True)
        with (path / "Contents/Info.plist").open("wb") as output:
            plistlib.dump({"CFBundleIdentifier": "io.burnzombies.app", "CFBundleExecutable": "BurnZombiesApp",
                           "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version,
                           "CFBundleVersion": build, "LSMinimumSystemVersion": "14.0"}, output)
        run("cc", "-arch", "arm64", "-arch", "x86_64", str(root / "parent.c"), "-o", str(binaries / "BurnZombiesApp"))
        run("cc", "-arch", "arm64", "-arch", "x86_64", f'-DVERSION="{version}"', f'-DBUILD="{build}"',
            str(root / "cli.c"), "-o", str(binaries / "burnzombies"))
        shutil.copy2(binaries / "burnzombies", binaries / "burnzombies-mcp")
        sign(path)

    old = root / "old/BurnZombies.app"
    new = root / "new/BurnZombies.app"
    make_app(old, "1.0.0", "1")
    make_app(new, "2.0.0", "2")
    for mode in ([] if options.real_app_only else ["success", "health-failure", "bad-signature", "tamper-after-ready", "blocked-parent"]):
        case = root / mode
        apps = case / "Applications With Spaces"; apps.mkdir(parents=True)
        app = apps / "BurnZombies.app"; shutil.copytree(old, app)
        workspace = apps / (".BurnZombies-update-" + str(uuid.uuid4()).upper())
        workspace.mkdir(mode=0o700)
        payload = workspace / "unpacked/BurnZombies.app"; shutil.copytree(new, payload)
        helper = workspace / "update-helper"; shutil.copy2(source_helper, helper)
        state = case / "private-state"; state.mkdir(mode=0o700)
        settings = state / "owner-settings"; settings.write_text("keep forever; model unchanged")
        before = {str(p.relative_to(app)): hashlib.sha256(p.read_bytes()).hexdigest() for p in app.rglob("*") if p.is_file()}
        if mode == "bad-signature":
            run("codesign", "--force", "--sign", "-", str(payload))
        parent = subprocess.Popen([str(app / "Contents/MacOS/BurnZombiesApp")], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        worker = None
        try:
            run(str(proof), "--app-update-plan", str(app), str(workspace), str(parent.pid))
            environment = dict(os.environ, BURNZOMBIES_HOME=str(state))
            if mode == "health-failure": environment["BURNZOMBIES_UPDATER_FIXTURE_FAIL"] = "2.0.0"
            worker = subprocess.Popen([str(helper), "--finish-update", str(workspace / "update.json")],
                                      env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            deadline = time.monotonic() + 20
            while not (workspace / "ready").exists() and worker.poll() is None and time.monotonic() < deadline:
                time.sleep(0.05)
            current = {str(p.relative_to(app)): hashlib.sha256(p.read_bytes()).hexdigest() for p in app.rglob("*") if p.is_file()}
            assert current == before, (mode, "app changed before its process exited")
            if mode == "bad-signature":
                stdout, stderr = worker.communicate(timeout=5)
                assert worker.returncode != 0 and not (workspace / "ready").exists(), stdout + stderr
                assert not (state / "calls").exists(), "unauthenticated package executed"
                continue
            assert (workspace / "ready").exists(), worker.communicate(timeout=5)
            if mode == "blocked-parent":
                time.sleep(0.2)
                assert worker.poll() is None and parent.poll() is None
                assert plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleVersion"] == "1"
                continue
            if mode == "tamper-after-ready":
                binary = payload / "Contents/MacOS/BurnZombiesApp"
                data = bytearray(binary.read_bytes()); data[1024] ^= 1; binary.write_bytes(data)
            parent.terminate(); parent.wait(timeout=5)
            stdout, stderr = worker.communicate(timeout=60)
            success = mode == "success"
            assert (worker.returncode == 0) == success, stdout + stderr
            with (app / "Contents/Info.plist").open("rb") as source:
                installed = plistlib.load(source)
            assert installed["CFBundleShortVersionString"] == ("2.0.0" if success else "1.0.0"), mode
            assert settings.read_text() == "keep forever; model unchanged"
            result = json.loads((state / "app-update-result.json").read_text())
            assert result["state"] == ("updated" if success else "failed"), result
            calls = (state / "calls").read_text()
            if mode == "tamper-after-ready":
                assert ":2.0.0" not in calls, "package changed after preparation was executed"
            if not success:
                assert "start-observer:1.0.0" in calls, "previous app was not restarted"
            print("PASS signed update:", mode)
        finally:
            for owned in [worker, parent]:
                if owned and owned.poll() is None:
                    owned.terminate()
                    try: owned.wait(timeout=5)
                    except subprocess.TimeoutExpired: owned.kill(); owned.wait(timeout=5)
    if not options.real_app_only:
        print("PASS signed updater handoff: existing certificate, parent-exit barrier, health rollback, pre/post-handoff authentication and exact state preservation; inert apps only")

    # Exercise LaunchServices, the actual observer and its health response too, with an
    # isolated root, cleanup held and AI disabled. Custom roots never register a login item.
    case = root / "real-app"
    apps = case / "Applications"; apps.mkdir(parents=True)
    app = apps / "BurnZombies.app"; shutil.copytree(options.app.resolve(), app)
    metadata = app / "Contents/Info.plist"
    info = plistlib.loads(metadata.read_bytes()); info["CFBundleShortVersionString"] = "0.0.0"; info["CFBundleVersion"] = "1"
    metadata.write_bytes(plistlib.dumps(info))
    run("codesign", "--force", "--sign", CERTIFICATE, "--timestamp=none", str(app))
    workspace = apps / (".BurnZombies-update-" + str(uuid.uuid4()).upper()); workspace.mkdir(mode=0o700)
    shutil.copytree(options.app.resolve(), workspace / "unpacked/BurnZombies.app")
    helper = workspace / "update-helper"; shutil.copy2(source_helper, helper)
    state = case / "private-state"
    run(str(proof), "--app-update-state", str(state))
    environment = dict(os.environ, BURNZOMBIES_HOME=str(state))
    configuration = (state / "machine-review.json").read_bytes()
    parent = subprocess.Popen([str(app / "Contents/MacOS/BurnZombiesApp")], env=environment,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    worker = None
    try:
        cli = app / "Contents/MacOS/burnzombies"
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            status = subprocess.run([str(cli), "doctor"], env=environment, capture_output=True, text=True, timeout=10)
            if status.returncode == 0 and json.loads(status.stdout).get("appResponding"): break
            assert parent.poll() is None, "private observer exited before update"
            time.sleep(0.1)
        else: raise AssertionError("private observer did not become ready: " + status.stdout + status.stderr)
        run(str(proof), "--app-update-plan", str(app), str(workspace), str(parent.pid))
        worker = subprocess.Popen([str(helper), "--finish-update", str(workspace / "update.json")],
                                  env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        deadline = time.monotonic() + 20
        while not (workspace / "ready").exists() and worker.poll() is None and time.monotonic() < deadline:
            time.sleep(0.05)
        assert (workspace / "ready").exists(), worker.communicate(timeout=5)
        run(str(cli), "stop-observer", str(app), env=environment, timeout=40)
        parent.wait(timeout=10)
        stdout, stderr = worker.communicate(timeout=90)
        assert worker.returncode == 0, stdout + stderr + (state / "app-update-result.json").read_text()
        doctor = json.loads(run(str(cli), "doctor", env=environment, timeout=15))
        installed = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        assert doctor["appResponding"] and doctor["runningAppMatchesCLI"], doctor
        assert doctor["runningAppVersion"] == installed["CFBundleShortVersionString"]
        assert doctor["runningAppBuild"] == installed["CFBundleVersion"]
        sweep = json.loads((state / "autopilot/sweep.json").read_text())
        memory = json.loads((state / "autopilot/memory.json").read_text())
        assert not sweep["enabled"] and sweep["lookOnly"] is True
        assert "fixture-protected-resource" in memory["keptItems"]
        assert (state / "machine-review.json").read_bytes() == configuration
        assert json.loads((state / "app-update-result.json").read_text())["state"] == "updated"
        print("PASS real app update: graceful old-app exit, atomic replacement, LaunchServices restart, live matching observer health, AI off, look-only and Keep/model state preserved")
    finally:
        # Only this canonical fixture bundle is stopped. No other BZ instance is touched.
        cli = app / "Contents/MacOS/burnzombies"
        subprocess.run([str(cli), "stop-observer", str(app)], env=environment,
                       capture_output=True, text=True, timeout=40, check=True)
        for owned in [worker, parent]:
            if owned and owned.poll() is None:
                owned.terminate(); owned.wait(timeout=5)
