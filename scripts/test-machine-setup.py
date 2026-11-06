#!/usr/bin/env python3
"""Private machine setup and owned reviewer cancellation; never launches the app."""
import json, os, pathlib, signal, subprocess, tempfile, time, shutil, sqlite3
repo = pathlib.Path(__file__).resolve().parents[1]
cli = repo / '.build/debug/burnzombies'
with tempfile.TemporaryDirectory(prefix='bz-machine-setup-') as temporary:
    root = pathlib.Path(temporary)
    fake = root/'bin'; fake.mkdir()
    for name in ['codex', 'claude', 'agent', 'copilot', 'gemini']:
        path = fake/name; path.write_text('#!/usr/bin/python3\nimport json,sys\nprint(json.dumps({"argv":sys.argv[1:]}))\n'); path.chmod(0o700)
    shutil.copyfile(repo/'scripts/fixtures/mock-codex.py', fake/'codex'); (fake/'codex').chmod(0o700)
    env = dict(os.environ, PATH=str(fake)+':/usr/bin:/bin')
    for harness in ['codex', 'claude', 'cursor', 'copilot', 'gemini']:
        state = root/harness
        command = [str(cli), 'setup', '--harness', harness, '--root', str(state)]
        setup = subprocess.run(command, env=env, check=True, capture_output=True, text=True)
        assert len(setup.stdout.splitlines()) == 1, 'Setup should say one plain line: ' + setup.stdout
        assert not (state/"full-disk-access.json").exists(), "CLI setup must not grant access"
        config = json.loads((state/'machine-review.json').read_text())
        assert config['harness'] == harness and config['enabled']
        assert config['launcher'] == str(cli.resolve())
        assert config['executable'].startswith(str(fake))
        with sqlite3.connect(state/'intent.sqlite') as ledger:
            value = ledger.execute("select payload from documents where kind='setting' and id='legacy-authority'").fetchone()[0]
            assert json.loads(value) is False, 'Fresh setup granted legacy cleanup authority'
            assert ledger.execute("select count(*) from documents where kind in ('decision','operation','rule')").fetchone()[0] == 0
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
        config['huntIntervalHours'] = 8
        (state/'machine-review.json').write_text(json.dumps(config))
        subprocess.run(command, env=env, check=True, capture_output=True)
        retained = json.loads((state/'machine-review.json').read_text())
        assert retained['model'] == 'example-model' and retained.get('reasoningEffort') == config.get('reasoningEffort')
        assert retained['enabled'] is False, 'Reinstall re-enabled disabled reviews'
        assert retained['huntIntervalHours'] == 8, 'Reinstall reset the hunt schedule'
        retained['enabled'] = True
        (state/'machine-review.json').write_text(json.dumps(retained))
        prompt = root/'prompt.txt'; prompt.write_text('Only capture invocation arguments. No real model is invoked.')
        executed = subprocess.run([str(repo/'.build/debug/BurnProof'), '--review-model', str(state), harness, str(prompt)], env=env, capture_output=True, text=True)
        assert executed.returncode == 0, executed.stdout + executed.stderr
        events=[json.loads(line) for line in (state/'last-review.log').read_text().splitlines()]
        if harness == 'codex':
            assert events[0]['model']=='example-model' and events[0]['reasoning']=='high'
            usage=[e for e in events if e['type']=='bz.usage']
            assert len(usage)==1 and usage[0]['usage']['input_tokens']==100, 'Cumulative usage duplicated'
            argv=[]
        else:
            argv=events[0]['argv']
            assert argv[argv.index('--model')+1] == 'example-model'
        if harness == 'claude': assert argv[argv.index('--effort')+1] == 'high'
        if harness == 'copilot': assert argv[argv.index('--reasoning-effort')+1] == 'high'
        before = (state/'machine-review.json').read_bytes()
        rejected = subprocess.run(command+['--thinking','invalid'],env=env,capture_output=True)
        assert rejected.returncode != 0 and (state/'machine-review.json').read_bytes() == before
        subprocess.run(command+['--model','default','--thinking','default'],env=env,check=True,capture_output=True)
        reset = json.loads((state/'machine-review.json').read_text())
        assert reset.get('model') is None and reset.get('reasoningEffort') is None
        if harness in ['codex', 'claude']:
            subprocess.run(command+['--observe-only'],env=env,check=True,capture_output=True)
            assert json.loads((state/'machine-review.json').read_text())['enabled'] is False
            report = subprocess.run([str(cli),'doctor'],env=dict(env,BURNZOMBIES_HOME=str(state)),check=True,capture_output=True,text=True,timeout=15)
            doctor = json.loads(report.stdout)
            assert doctor['configuredHarness'] == harness and doctor['configuredExecutableAvailable']
            assert doctor['mcpServerAvailable'] and not doctor['cleanupRequested']
            assert not doctor['backgroundReviewsEnabled'] and not doctor['appResponding']
            # After installing with AI judging off, one command turns it back on; a reinstall never does.
            subprocess.run(command, env=env, check=True, capture_output=True)
            assert json.loads((state/'machine-review.json').read_text())['enabled'] is False
            subprocess.run(command+['--with-ai'], env=env, check=True, capture_output=True)
            assert json.loads((state/'machine-review.json').read_text())['enabled'] is True
    # Look-only belongs to Autopilot, not the AI: setup turns it on with or without AI judging, keeps
    # the AI choice as it was and says so in one more line; a reinstall without it leaves it on.
    for harness in ['claude', 'none']:
        state = root/f'look-only-{harness}'
        command = [str(cli), 'setup', '--harness', harness, '--root', str(state)]
        subprocess.run(command, env=env, check=True, capture_output=True)
        before = (state/'machine-review.json').read_bytes() if harness != 'none' else None
        looked = subprocess.run(command + ['--look-only'], env=env, check=True, capture_output=True, text=True)
        lines = looked.stdout.splitlines()
        assert len(lines) == 2 and lines[1].startswith('Look-only is on'), looked.stdout
        assert 'still burns' not in looked.stdout, 'Setup promised burns while look-only: ' + looked.stdout
        assert json.loads((state/'autopilot/sweep.json').read_text())['lookOnly'] is True
        if before is None:
            assert not (state/'machine-review.json').exists(), 'Look-only without AI set up AI'
        else:
            assert (state/'machine-review.json').read_bytes() == before, 'Look-only changed the AI choice'
        subprocess.run(command, env=env, check=True, capture_output=True)
        assert json.loads((state/'autopilot/sweep.json').read_text())['lookOnly'] is True, 'A reinstall started burning'
    # The installer's path when it skips AI setup (--mcp none): with no app running, straight to the state folder.
    state = root/'look-only-autopilot'
    looked = subprocess.run([str(cli), 'autopilot', 'look-only'], env=dict(env, BURNZOMBIES_HOME=str(state)),
                            check=True, capture_output=True, text=True, timeout=15)
    assert looked.stdout.startswith('Look-only is on'), looked.stdout
    assert json.loads((state/'autopilot/sweep.json').read_text())['lookOnly'] is True
    assert not (state/'machine-review.json').exists(), 'Look-only without AI set up AI'
    # Installer setup and app migration use the same exclusive migration lock.
    for iteration in range(50):
        state=root/f'concurrent-migration-{iteration}'
        command=[str(cli),'setup','--harness','codex','--observe-only','--root',str(state)]
        first=subprocess.Popen(command,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        second=subprocess.Popen(command,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        for child in (first,second):
            stdout,stderr=child.communicate(timeout=15)
            assert child.returncode==0, (stdout,stderr)
        receipt=json.loads((state/'intent-migration.json').read_text())
        with sqlite3.connect(state/'intent.sqlite') as ledger:
            identity=json.loads(ledger.execute("select payload from documents where kind='setting' and id='migration-identity'").fetchone()[0])
            assert receipt['phase']=='complete' and receipt['id']==identity
    print('PASS 50 concurrent two-process first migrations preserve one matching authority identity')
    # Verify the real Codex adapter sends one focused instruction block, not the full playbook twice.
    plan = root/'focused-plan.json'
    plan.write_text(json.dumps({'executable':str(fake/'codex'),'model':'example-model','effort':'low',
        'instructions':'Focused fixture instructions','prompt':'Review supplied evidence.',
        'overrides':['features.hooks=false','features.view_image=true']}))
    focused = subprocess.run([str(cli),'review-codex',str(plan)],
        env=dict(env,BZ_EXPECT_FOCUSED='1'),capture_output=True,text=True,timeout=15)
    assert focused.returncode==0, focused.stdout+focused.stderr
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
    # A Mac without Claude Code or Codex still gets BurnZombies: AI judging stays off and setup says
    # how to add it later. Asking for a missing one by name still fails, and nothing is written.
    empty = root/'no-harness-bin'; empty.mkdir()
    bare = dict(os.environ, PATH='/usr/bin:/bin', BURNZOMBIES_HARNESS_DIRS=str(empty))
    state = root/'no-harness'
    auto = subprocess.run([str(cli), 'setup', '--root', str(state)], env=bare, capture_output=True, text=True)
    assert auto.returncode == 0, auto.stdout + auto.stderr
    assert 'No Claude Code or Codex found' in auto.stdout and 'burnzombies setup' in auto.stdout, auto.stdout
    assert not (state/'machine-review.json').exists(), 'Setup without a harness wrote an AI configuration'
    named = subprocess.run([str(cli), 'setup', '--harness', 'codex', '--root', str(state)], env=bare, capture_output=True, text=True)
    assert named.returncode != 0 and not (state/'machine-review.json').exists()
    # Look-only needs no AI tool; a setup that fails turns nothing on.
    refused = subprocess.run([str(cli), 'setup', '--harness', 'codex', '--look-only', '--root', str(state)], env=bare, capture_output=True, text=True)
    assert refused.returncode != 0 and not (state/'autopilot/sweep.json').exists(), 'A failed setup turned look-only on'
    looked = subprocess.run([str(cli), 'setup', '--look-only', '--root', str(state)], env=bare, capture_output=True, text=True)
    assert looked.returncode == 0 and looked.stdout.splitlines()[-1].startswith('Look-only is on'), looked.stdout + looked.stderr
    assert 'still burns' not in looked.stdout, looked.stdout
    assert json.loads((state/'autopilot/sweep.json').read_text())['lookOnly'] is True
    assert not (state/'machine-review.json').exists()
print('PASS five-provider setup, model/effort subprocess arguments, reinstall persistence, defaults, private config, owned cancellation, setup without a harness and look-only')
