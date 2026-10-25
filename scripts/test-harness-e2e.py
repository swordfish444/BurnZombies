#!/usr/bin/env python3
"""Opt-in real-model proof using the user's existing CLI login and isolated disposable workers.
Never run in CI: --client is required. Normal harness permissions remain in force.
"""
import argparse, json, os, pathlib, re, select, shutil, signal, socket, subprocess, tempfile, time, tomllib
repo = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--client', choices=['claude', 'codex'], required=True)
parser.add_argument('--server', type=pathlib.Path, default=repo/'.build/debug/burnzombies-mcp')
parser.add_argument('--output', type=pathlib.Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True); args.output.chmod(0o700)
node = shutil.which('node')
assert node, 'This proof needs Node to create realistic disposable fixtures.'
with tempfile.TemporaryDirectory(prefix='bz-e2e-', dir='/tmp') as tmp:
    root = pathlib.Path(tmp)
    monitor = subprocess.Popen([str(repo/'.build/debug/BurnProof'), '--agent-fixture', str(root)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    workers = []
    try:
        assert select.select([monitor.stdout], [], [], 10)[0] and monitor.stdout.readline().strip() == b'READY'
        for index in range(3):
            project = root / ('project-' + str(index)); project.mkdir()
            worker = subprocess.Popen([node, '-e', 'const b=Buffer.alloc(8*1024*1024,7);setInterval(()=>b[0]++,1000);setTimeout(()=>process.exit(0),600000)'], cwd=project, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            workers.append(worker)
        # All three look like live idle Node workers; the agent must use lifecycle ownership evidence.
        manifest = [
            {'pid': workers[0].pid, 'job': 'fixture-build-a', 'owner_job_state': 'completed', 'disposable': True, 'consumers': []},
            {'pid': workers[1].pid, 'job': 'fixture-build-b', 'owner_job_state': 'cancelled', 'disposable': True, 'consumers': []},
            {'pid': workers[2].pid, 'job': 'fixture-live-session', 'owner_job_state': 'running', 'disposable': False, 'consumers': ['active user task']},
        ]
        (args.output/'fixture-manifest.json').write_text(json.dumps(manifest, indent=2))
        prompt = '''BurnZombies computer-wide acceptance test. These workers belong to three separate project directories and were created before this background review. There is no active user chat or lifecycle hook. Inspect workingDirectory to corroborate their different origins. You have authorization to clean only abandoned disposable helpers in this test-owned manifest. Read it as lifecycle evidence and choose the targets yourself. Call BurnZombies inspect for the listed PIDs, preview the targets supported by the evidence with your rationale, and burn that preview. Preserve the live job. Do not use shell kill, touch any other process, modify files, spawn agents or wait for receipt verification. Report pending versus verified accurately. All entries are real test-owned Node processes created just now; the completed/cancelled job state is established by the test controller, not inferred from age or parent. Manifest:\n''' + json.dumps(manifest)
        env = dict(os.environ, BURNZOMBIES_HOME=str(root))
        # Exercise the production computer-wide dispatcher with no foreground chat or hook.
        config = {'harness': args.client, 'executable': shutil.which(args.client),
                  'launcher': str((repo/'.build/debug/burnzombies').resolve()),
                  'server': str(args.server.resolve()), 'enabled': True}
        (root/'machine-review.json').write_text(json.dumps(config))
        (root/'review-prompt.txt').write_text(prompt)
        command = [str(repo/'.build/debug/BurnProof'), '--review-model', str(root), args.client, str(root/'review-prompt.txt')]
        with (args.output/'client-output.jsonl').open('w') as out, (args.output/'client-stderr.txt').open('w') as err:
            result=subprocess.run(command,cwd=root,env=env,stdout=out,stderr=err,timeout=200)
        if (root/'last-review.log').exists(): shutil.copy2(root/'last-review.log', args.output/'review.log')
        assert result.returncode == 0, 'Harness failed; inspect private client output.'
        def status():
            with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as client:
                client.settimeout(8);client.connect(str(root/'agent.sock'))
                client.sendall(b'{"operation":"status"}\n')
                data=b''
                while not data.endswith(b'\n'): data += client.recv(262144)
                return json.loads(data)
        report=status()
        assert report['receipts'], 'Model did not execute a cleanup through MCP.'
        assert workers[0].wait(timeout=5) == -signal.SIGTERM
        assert workers[1].wait(timeout=5) == -signal.SIGTERM
        assert workers[2].poll() is None, 'Live control was stopped!'
        deadline=time.monotonic()+145
        while time.monotonic()<deadline and report['verifiedHelpers']!=2:
            time.sleep(15)
            report=status()
            assert workers[2].poll() is None
        assert report['verifiedHelpers']==2, report
        (args.output/'receipt.json').write_text(json.dumps(report,indent=2))
        print('PASS',args.client,': background reviewer selected 2 abandoned Node workers across projects, preserved live Node job, used MCP graceful stops, verified receipts; no reboot')
    finally:
        for worker in workers:
            if worker.poll() is None: worker.terminate()
            try: worker.wait(timeout=5)
            except subprocess.TimeoutExpired: raise AssertionError('Fixture did not exit; no force kill')
        monitor.stdin.close()
        try: monitor.wait(timeout=5)
        except subprocess.TimeoutExpired:
            monitor.terminate();monitor.wait(timeout=5)
