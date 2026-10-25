#!/usr/bin/env python3
"""Private machine setup and owned reviewer cancellation; never launches the app."""
import json, os, pathlib, signal, subprocess, tempfile, time
repo = pathlib.Path(__file__).resolve().parents[1]
cli = repo / '.build/debug/burnzombies'
with tempfile.TemporaryDirectory(prefix='bz-machine-setup-') as temporary:
    root = pathlib.Path(temporary)
    fake = root/'bin'; fake.mkdir()
    for name in ['codex', 'claude', 'agent', 'copilot', 'gemini']:
        path = fake/name; path.write_text('#!/bin/sh\nexit 0\n'); path.chmod(0o700)
    env = dict(os.environ, PATH=str(fake)+':/usr/bin:/bin')
    for harness in ['codex', 'claude', 'cursor', 'copilot', 'gemini']:
        state = root/harness
        command = [str(cli), 'setup', '--harness', harness, '--root', str(state)]
        subprocess.run(command, env=env, check=True, capture_output=True)
        config = json.loads((state/'machine-review.json').read_text())
        assert config['harness'] == harness and config['enabled']
        assert config['launcher'] == str(cli.resolve())
        assert config['executable'].startswith(str(fake))
        before = (state/'machine-review.json').read_bytes()
        subprocess.run(command, env=env, check=True, capture_output=True)
        assert (state/'machine-review.json').read_bytes() == before
        subprocess.run([str(cli), 'setup', '--harness', 'auto', '--root', str(state)], env=env, check=True, capture_output=True)
        assert json.loads((state/'machine-review.json').read_text())['harness'] == harness
        assert not any((state/x).exists() for x in ['.codex', '.claude', '.cursor', '.gemini', '.copilot'])
    # One reviewer group is cancelled without touching a sibling active job.
    script = root/'worker'; pidfile = root/'pids'
    script.write_text('#!/bin/sh\ntrap "" TERM\nsleep 60 &\necho "$$ $!" > "$1"\nwait\n')
    script.chmod(0o700)
    active = subprocess.Popen(['/bin/sleep', '60'])
    review = subprocess.Popen([str(cli), 'review-worker', '--', str(script), str(pidfile)])
    try:
        deadline = time.monotonic()+10
        while not pidfile.exists() and time.monotonic()<deadline: time.sleep(.05)
        assert pidfile.exists()
        owned = [int(x) for x in pidfile.read_text().split()]
        review.terminate(); assert review.wait(timeout=6) == 124
        assert active.poll() is None, 'Reviewer cancellation affected unrelated active work'
        for pid in owned:
            ps = subprocess.run(['ps','-p',str(pid),'-o','stat='],capture_output=True,text=True)
            assert ps.returncode != 0 or 'Z' in ps.stdout, 'Owned reviewer child remains running'
    finally:
        if review.poll() is None: review.terminate(); review.wait(timeout=6)
        active.terminate(); active.wait(timeout=5)
print('PASS private setup for five providers, provider pinning, no chat config/hooks, and owned process-group cancellation')
