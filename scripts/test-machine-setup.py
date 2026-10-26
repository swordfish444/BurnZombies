#!/usr/bin/env python3
"""Private machine setup and owned reviewer cancellation; never launches the app."""
import json, os, pathlib, signal, subprocess, tempfile, time
repo = pathlib.Path(__file__).resolve().parents[1]
cli = repo / '.build/debug/burnzombies'
with tempfile.TemporaryDirectory(prefix='bz-machine-setup-') as temporary:
    root = pathlib.Path(temporary)
    fake = root/'bin'; fake.mkdir()
    for name in ['codex', 'claude', 'agent', 'copilot', 'gemini']:
        path = fake/name; path.write_text('#!/usr/bin/python3\nimport json,sys\nprint(json.dumps({"argv":sys.argv[1:]}))\n'); path.chmod(0o700)
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
        selection = ['--model', 'example-model']
        if harness in ['codex', 'claude', 'copilot']: selection += ['--thinking', 'high']
        subprocess.run(command + selection, env=env, check=True, capture_output=True)
        config = json.loads((state/'machine-review.json').read_text())
        config['enabled'] = False
        (state/'machine-review.json').write_text(json.dumps(config))
        subprocess.run(command, env=env, check=True, capture_output=True)
        retained = json.loads((state/'machine-review.json').read_text())
        assert retained['model'] == 'example-model' and retained.get('reasoningEffort') == config.get('reasoningEffort')
        assert retained['enabled'] is False, 'Reinstall re-enabled disabled reviews'
        retained['enabled'] = True
        (state/'machine-review.json').write_text(json.dumps(retained))
        prompt = root/'prompt.txt'; prompt.write_text('Only capture invocation arguments. No real model is invoked.')
        executed = subprocess.run([str(repo/'.build/debug/BurnProof'), '--review-model', str(state), harness, str(prompt)], env=env, capture_output=True, text=True)
        assert executed.returncode == 0, executed.stdout + executed.stderr
        argv = json.loads((state/'last-review.log').read_text())['argv']
        assert argv[argv.index('--model')+1] == 'example-model'
        if harness == 'codex': assert 'model_reasoning_effort="high"' in argv
        if harness == 'claude': assert argv[argv.index('--effort')+1] == 'high'
        if harness == 'copilot': assert argv[argv.index('--reasoning-effort')+1] == 'high'
        before = (state/'machine-review.json').read_bytes()
        rejected = subprocess.run(command+['--thinking','invalid'],env=env,capture_output=True)
        assert rejected.returncode != 0 and (state/'machine-review.json').read_bytes() == before
        subprocess.run(command+['--model','default','--thinking','default'],env=env,check=True,capture_output=True)
        reset = json.loads((state/'machine-review.json').read_text())
        assert reset.get('model') is None and reset.get('reasoningEffort') is None
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
print('PASS five-provider setup, model/effort subprocess arguments, reinstall persistence, defaults, private config and owned cancellation')
