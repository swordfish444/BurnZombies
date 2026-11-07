#!/usr/bin/env python3
"""Stock-bash installer control flow with a signed, inert sacrificial app.

This proves argument forwarding, launch dispatch, and rollback. It does not
replace the separate real release archive or installed observer acceptance.
"""
import hashlib
import json
import os
import platform
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
from installer_signing_fixture import keychains, production_pin, signing_fixture

repo = Path(__file__).resolve().parents[1]
production_pin(repo / "install.sh")
with tempfile.TemporaryDirectory(prefix="bz-install-control-") as temporary, \
        signing_fixture(Path(temporary) / "signing") as signer:
    root = Path(temporary)
    before_failure = keychains()
    try:
        signer.sign(root / "missing.app")
        raise AssertionError("Missing app unexpectedly signed")
    except FileNotFoundError:
        pass
    assert keychains() == before_failure, "Signing failure must restore the search list"
    app = root / "package/BurnZombies.app"
    macos = app / "Contents/MacOS"
    macos.mkdir(parents=True)
    with (app / "Contents/Info.plist").open("wb") as file:
        plistlib.dump({"CFBundleIdentifier": "io.burnzombies.app", "CFBundleExecutable": "BurnZombiesApp",
                      "CFBundlePackageType": "APPL", "CFBundleVersion": "30"}, file)
    main = macos / "BurnZombiesApp"
    main_source = root / "main.c"
    main_source.write_text("int main(void) { return 0; }\n")
    subprocess.run(["cc", "-arch", "arm64", "-arch", "x86_64", str(main_source), "-o", str(main)], check=True)
    cli = macos / "burnzombies"
    controller = root / "controller.py"
    controller.write_text('''import json,os,sys
with open(os.environ['BZ_CONTROL_LOG'],'a') as log:
    log.write(json.dumps(sys.argv[1:])+'\\n')
if sys.argv[1]=='setup' and os.environ.get('BZ_CONTROL_FAIL')=='setup': sys.exit(66)
if sys.argv[1]=='autopilot' and os.environ.get('BZ_CONTROL_FAIL')=='autopilot': sys.exit(69)
if sys.argv[1]=='start-observer' and os.environ.get('BZ_CONTROL_FAIL')=='start':
    from pathlib import Path
    if not (Path(os.environ['BURNZOMBIES_INSTALL_DIR'])/'BurnZombies.app/previous-marker').exists(): sys.exit(67)
''')
    bridge = root / "bridge.c"
    bridge.write_text('#include <unistd.h>\nint main(int argc, char **argv) {\n'
        + f'char *args[argc+2]; args[0]={json.dumps(sys.executable)}; args[1]={json.dumps(str(controller))};\n'
        + 'for(int i=1;i<argc;i++) args[i+1]=argv[i]; args[argc+1]=0;\n'
        + 'execv(args[0],args); return 127; }\n')
    subprocess.run(["cc", str(bridge), "-o", str(cli)], check=True)
    signer.sign(app)
    installer = signer.installer(repo / "install.sh", root / "install.sh")
    remote = root / "remote"
    remote.mkdir()
    asset = remote / "BurnZombies-macOS-universal.tar.gz"
    with tarfile.open(asset, "w:gz") as archive:
        archive.add(app, arcname="BurnZombies.app")
    (remote / "SHA256SUMS").write_text(hashlib.sha256(asset.read_bytes()).hexdigest() + "  " + asset.name + "\n")
    stubs = root / "bin"
    stubs.mkdir()
    curl = stubs / "curl"
    curl.write_text(f"#!{sys.executable}\n" + '''import os,shutil,sys
from pathlib import Path
args=sys.argv[1:]
url=next(v for v in args if v.startswith('https://'))
assert url.startswith('https://github.com/swordfish444/BurnZombies/releases/download/v0.17.0/')
shutil.copyfile(Path(os.environ['BZ_CONTROL_REMOTE'])/url.rsplit('/',1)[1],args[args.index('-o')+1])
''')
    curl.chmod(0o755)
    mover = stubs / "mv"
    mover.write_text(f"#!{sys.executable}\n" + '''import os,sys
from pathlib import Path
if os.environ.get('BZ_CONTROL_FAIL')=='move':
    destination=Path(sys.argv[2]); destination.mkdir()
    (destination/'partial-backup').write_text('incomplete cross-volume copy')
    sys.exit(68)
os.execv('/bin/mv',['/bin/mv']+sys.argv[1:])
''')
    mover.chmod(0o755)
    observe, look = ["--observe-only"], ["--look-only"]
    for client, flags, upgrade, failure in [
        ("codex", [], False, None), ("codex", observe, False, None),
        ("claude", [], False, None), ("claude", observe, False, None),
        ("auto", [], True, None), ("codex", [], True, "setup"),
        ("codex", observe, True, "start"),
        ("codex", [], False, "setup"),
        ("auto", [], True, "move"),
        ("codex", look, False, None), ("claude", observe + look, True, None),
        ("none", look, False, None), ("none", look, True, "autopilot"),
    ]:
        case = root / f"case-{client}-{'-'.join(flags)}-{upgrade}-{failure}"
        case.mkdir()
        destination = case / "Applications"
        installed = destination / app.name
        if upgrade:
            shutil.copytree(app, installed)
            (installed / "previous-marker").write_text("Exact previous bundle\n")
        def hashes():
            return {str(p.relative_to(installed)): hashlib.sha256(p.read_bytes()).hexdigest()
                    for p in installed.rglob('*') if p.is_file()}
        before = hashes() if upgrade else {}
        private_tmp = case / "tmp"
        private_tmp.mkdir()
        log = case / "calls.jsonl"
        env = dict(os.environ, PATH=str(stubs) + os.pathsep + os.environ["PATH"],
                   BURNZOMBIES_INSTALL_DIR=str(destination), BZ_CONTROL_REMOTE=str(remote),
                   BZ_CONTROL_LOG=str(log), BZ_CONTROL_FAIL=failure or "", TMPDIR=str(private_tmp))
        result = subprocess.run(["/bin/bash", str(installer), "--mcp", client] + flags,
                                env=env, capture_output=True, text=True, timeout=30)
        assert (result.returncode == 0) == (failure is None), result.stdout + result.stderr
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        if failure == "move":
            assert calls == [["stop-observer", str(installed)], ["start-observer"]], calls
            assert hashes() == before and not (installed/'previous.app').exists()
            assert list(private_tmp.glob('burnzombies-install.*/previous.app/partial-backup'))
            assert 'preserved both locations without merging' in result.stderr
            continue
        if client == "none":
            # No AI setup, so look-only goes straight to Autopilot.
            assert not any(call[0] == "setup" for call in calls), calls
            assert (["autopilot", "look-only"] in calls) == ("--look-only" in flags), calls
        else:
            assert ["setup", "--harness", client] + flags in calls, calls
        if "--look-only" in flags:
            # Burns are held first, before the new app is copied into place and before setup.
            assert calls[1 if upgrade else 0] == ["autopilot", "look-only"], calls
        if failure is None:
            # A look-only install never says it burns in minute one.
            burns = "burns what's clearly safe" in result.stdout
            assert burns != ("--look-only" in flags), result.stdout
        if failure is None or upgrade:
            assert calls[-1] == ["start-observer"], calls
        assert (installed / "previous-marker").exists() == bool(failure and upgrade), calls
        if upgrade:
            assert calls[0] == ["stop-observer", str(installed)], calls
        if failure and upgrade:
            assert "Previous app restored" in result.stderr
        if failure and not upgrade:
            assert not installed.exists()
    # Integrity alone accepts both ad-hoc code and a different publisher. Neither may run
    # before replacement, even when it has the expected bundle ID and a matching checksum.
    adhoc = root / "adhoc/BurnZombies.app"
    shutil.copytree(app, adhoc)
    for binary in (adhoc / "Contents/MacOS").iterdir():
        subprocess.run(["codesign", "--force", "--sign", "-", str(binary)], check=True, capture_output=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(adhoc)], check=True, capture_output=True)
    tampered = root / "tampered/BurnZombies.app"
    shutil.copytree(app, tampered)
    image = tampered / "Contents/MacOS/BurnZombiesApp"
    data = bytearray(image.read_bytes()); data[1024] ^= 1; image.write_bytes(data)

    # Each slice is valid independently; only the foreign slice has the wrong signer.
    native = platform.machine()
    other = "x86_64" if native == "arm64" else "arm64"
    thin_apps = []
    for arch in [native, other]:
        thin = root / ("thin-" + arch) / "BurnZombies.app"
        shutil.copytree(app, thin)
        executable = thin / "Contents/MacOS/BurnZombiesApp"
        output = executable.with_name("thin-main")
        subprocess.run(["lipo", str(executable), "-thin", arch, "-output", str(output)], check=True)
        output.replace(executable)
        if arch == native:
            signer.sign(thin)
        else:
            subprocess.run(["codesign", "--force", "--sign", "-", str(thin)], check=True, capture_output=True)
        thin_apps.append(thin)
    mixed = root / "mixed/BurnZombies.app"
    shutil.copytree(thin_apps[0], mixed)
    executable = mixed / "Contents/MacOS/BurnZombiesApp"
    subprocess.run(["lipo", "-create", *[str(p / "Contents/MacOS/BurnZombiesApp") for p in thin_apps],
                    "-output", str(executable)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(mixed)], check=True)

    for label, package, script in [("wrong-certificate", app, repo / "install.sh"),
                                    ("ad-hoc", adhoc, installer), ("tampered", tampered, installer),
                                    ("foreign-slice", mixed, installer)]:
        case = root / ("rejected-" + label); case.mkdir()
        destination = case / "Applications"; installed = destination / app.name
        shutil.copytree(app, installed)
        before = {str(p.relative_to(installed)): p.read_bytes() for p in installed.rglob('*') if p.is_file()}
        with tarfile.open(asset, "w:gz") as archive: archive.add(package, arcname=app.name)
        (remote / "SHA256SUMS").write_text(hashlib.sha256(asset.read_bytes()).hexdigest() + "  " + asset.name + "\n")
        log = case / "calls.jsonl"
        env = dict(os.environ, PATH=str(stubs) + os.pathsep + os.environ["PATH"],
                   BURNZOMBIES_INSTALL_DIR=str(destination), BZ_CONTROL_REMOTE=str(remote),
                   BZ_CONTROL_LOG=str(log), BZ_CONTROL_FAIL="", BURNZOMBIES_SIGNING_IDENTITY=signer.fingerprint)
        result = subprocess.run(["/bin/bash", str(script), "--mcp", "codex"],
                                env=env, capture_output=True, text=True, timeout=30)
        assert result.returncode != 0, label
        assert not log.exists(), (label, "Downloaded code ran before signer authentication")
        assert {str(p.relative_to(installed)): p.read_bytes() for p in installed.rglob('*') if p.is_file()} == before
    print("PASS pinned universal signer, wrong/ad-hoc/tampered/foreign-slice rejection before execution; stock bash setup, look-only, upgrade, launch and rollback")
