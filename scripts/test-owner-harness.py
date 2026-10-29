#!/usr/bin/env python3
"""One opt-in real harness review against private Gradle owners, using production instructions.
No live settings/hooks/UI, no expected-answer prompt, no retry or account/provider fallback.
"""
import argparse, hashlib, json, os, pathlib, select, shutil, socket, subprocess, tempfile, time

repo = pathlib.Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--client', choices=['codex', 'claude'], required=True)
p.add_argument('--distribution', required=True, type=pathlib.Path)
p.add_argument('--java', required=True, type=pathlib.Path)
p.add_argument('--output', required=True, type=pathlib.Path)
p.add_argument('--preflight-only', action='store_true')
args = p.parse_args()
args.output.mkdir(parents=True, exist_ok=True); args.output.chmod(0o700)
binary = repo/'.build/debug'
distribution, java = args.distribution.resolve(), args.java.resolve()
assert distribution.name == 'gradle-8.14.6' and (distribution/'lib/gradle-daemon-main-8.14.6.jar').is_file()
for name in ['BurnProof', 'burnzombies', 'burnzombies-mcp']: assert (binary/name).is_file(), 'Build products first'
installed = pathlib.Path.home()/'Library/Application Support/BurnZombies/machine-review.json'
live = json.loads(installed.read_text())
client = live.get('executable') if args.client == 'codex' and live.get('harness') == 'codex' else shutil.which(args.client)
assert client and pathlib.Path(client).is_file(), 'Installed harness missing; no fallback'
config = {'harness': args.client, 'executable': client, 'launcher': str((binary/'burnzombies').resolve()),
          'server': str((binary/'burnzombies-mcp').resolve()), 'enabled': True}
if args.client == 'codex':
    assert live.get('harness') == 'codex', 'Do not infer a different model/account selection'
    for key in ['model', 'reasoningEffort']:
        if live.get(key) is not None: config[key] = live[key]
report = {'client': args.client, 'passed': False, 'modelInvocations': 0, 'requestedModel': config.get('model'),
          'requestedEffort': config.get('reasoningEffort'), 'productionOwnerLane': True, 'checks': [],
          'reviewInstructionsSHA256': hashlib.sha256((repo/'Sources/BurnCore/ReviewBatch.swift').read_bytes()).hexdigest()}
env = dict(os.environ); env.pop('BURNZOMBIES_HOME', None)
fixture_env = {'PATH': '/usr/bin:/bin', 'HOME': str(pathlib.Path.home()), 'JAVA_HOME': str(java.parent.parent), 'LANG': 'en_US.UTF-8'}
model_started = False
with tempfile.TemporaryDirectory(prefix='bz-owner-harness-', dir='/tmp') as temporary:
    root = pathlib.Path(temporary).resolve(); state = root/'state'; state.mkdir()
    (state/'machine-review.json').write_text(json.dumps(config)); (state/'machine-review.json').chmod(0o600)
    workers, fixtures, monitor = [], [], None
    def create(name, held):
        home, project = root/name/'home', root/name/'project'
        home.mkdir(parents=True); project.mkdir(parents=True)
        (project/'settings.gradle').write_text("rootProject.name='bz-owner-fixture'\n")
        (project/'gradle.properties').write_text('org.gradle.jvmargs=-Xmx96m -XX:ActiveProcessorCount=1\norg.gradle.daemon.idletimeout=600000\n')
        (project/'build.gradle').write_text('''tasks.register('fixture') { doLast {
 file('started').text='started'
 if(project.hasProperty('hold')) {
  long deadline=System.currentTimeMillis()+420000
  while(!file('release').exists() && System.currentTimeMillis()<deadline) Thread.sleep(100)
  if(!file('release').exists()) throw new GradleException('fixture hold expired')
 }
 file('completed').text='completed'
} }
''')
        output = open(root/(name+'.log'), 'w')
        command = [str(distribution/'bin/gradle'), '--gradle-user-home', str(home), '--project-dir', str(project),
                   '--offline', '--console=plain', 'fixture'] + (['-Phold'] if held else [])
        worker = subprocess.Popen(command, env=fixture_env, stdout=output, stderr=subprocess.STDOUT)
        workers.append((worker, output, project))
        deadline = time.monotonic()+45
        while not (project/'started').exists() and time.monotonic()<deadline and worker.poll() is None: time.sleep(.1)
        assert (project/'started').exists(), 'Owned fixture did not start'
        logs = list((home/'daemon/8.14.6').glob('daemon-*.out.log')); assert len(logs) == 1
        pid = int(logs[0].name.split('-')[1].split('.')[0])
        if not held: assert worker.wait(timeout=20) == 0
        fixtures.append((home, project, pid))
        return home, project, pid
    def rpc(request):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as channel:
            channel.settimeout(10); channel.connect(str(state/'agent.sock'))
            channel.sendall(json.dumps(request).encode()+b'\n'); data=b''
            while not data.endswith(b'\n'):
                chunk=channel.recv(262144)
                assert chunk and len(data)<1_048_576, 'Incomplete fixture reply'
                data += chunk
            return json.loads(data)
    def mcp_preflight(source):
        ids=json.loads((state/'owner-review-ids.json').read_text())
        lane_env=dict(env, BURNZOMBIES_HOME=str(state), BURNZOMBIES_REVIEW_MODE='1',
                      BURNZOMBIES_REVIEW_LANE='ownerProcess', BURNZOMBIES_REVIEW_IDS=json.dumps(ids))
        server=subprocess.Popen([str(binary/'burnzombies-mcp')],env=lane_env,stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        sequence=0
        def send(method,params=None,notification=False):
            nonlocal sequence
            sequence+=1; payload={'jsonrpc':'2.0','method':method,'params':params or {}}
            if not notification: payload['id']=sequence
            server.stdin.write(json.dumps(payload).encode()+b'\n');server.stdin.flush()
            if notification:return None
            assert select.select([server.stdout],[],[],15)[0], 'MCP preflight timeout'
            response=json.loads(server.stdout.readline());assert response.get('id')==sequence
            return response
        def call(name,arguments):
            reply=send('tools/call',{'name':name,'arguments':arguments})
            assert 'result' in reply, ('MCP preflight tool error',name)
            result=reply['result'];return result,json.loads(result['content'][0]['text'])
        try:
            send('initialize',{'protocolVersion':'2025-11-25','capabilities':{},'clientInfo':{'name':'owner-fixture-preflight','version':'1'}})
            send('notifications/initialized',notification=True)
            tools={t['name'] for t in send('tools/list')['result']['tools']}
            assert tools=={'burnzombies_status','burnzombies_owner_preview','burnzombies_owner_stop'}, tools
            result,status=call('burnzombies_status',{})
            assert not result.get('isError') and len(status.get('ownerProcesses',[]))==1, 'Owner status projection missing'
            selected=status['ownerProcesses'][0]
            assert selected.get('id') in ids and selected['evidence']['state']=='IDLE' and selected['evidence']['residentBytes']>0, 'Owner actionable ID/resource evidence missing'
            result,preview=call('burnzombies_owner_preview',{'owner_id':selected['id'],
                'rationale':'Native identity and authenticated producer state establish an idle exact owner; this read-only transport preview does not request retirement.'})
            assert not result.get('isError') and preview.get('previewToken'), 'Owner preview token was not projected'
            busy=next(v for v in source if v['state']=='BUSY'); i=busy['member']['identity']
            busy_id=f"owner-process:{i['boot']}:{i['pid']}:{i['seconds']}:{i['micros']}"
            result,refusal=call('burnzombies_owner_preview',{'owner_id':busy_id,
                'rationale':'Negative control: this exact owner is executing an active build and its preview must be refused without signaling.'})
            assert result.get('isError') and not refusal.get('previewToken'), 'Busy owner preview was not refused'
            report['checks'].append('actual scoped MCP: owner facts/actionable ID, idle preview token and busy preview refusal; no token consumed')
        finally:
            server.stdin.close()
            try:server.wait(timeout=10)
            except subprocess.TimeoutExpired:server.terminate();server.wait(timeout=5)
    try:
        idle_home, idle_project, idle_pid = create('idle-owner', False)
        busy_home, busy_project, busy_pid = create('active-owner', True)
        (state/'owned-pids.json').write_text(json.dumps([idle_pid, busy_pid]))
        monitor = subprocess.Popen([str(binary/'BurnProof'), '--owner-agent-fixture', str(state)],
            cwd=root, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert select.select([monitor.stdout], [], [], 25)[0], 'Private observer did not become ready'
        ready = monitor.stdout.readline().strip()
        assert ready == b'READY', ('Private observer setup failed', ready.decode(errors='replace')[:300])
        source = json.loads((state/'owner-fixture-evidence.json').read_text())
        assert len(source)==2 and {v['state'] for v in source} == {'IDLE','BUSY'}
        assert all(pathlib.Path(v['gradleHome']).is_relative_to(root) for v in source)
        report['fixtureIdentities']=[{'identity':v['member']['identity'],'state':v['state'],
            'daemonUID':v['daemonUID'],'residentBytes':v['residentBytes']} for v in source]
        report['checks'].append('real native owner identities plus authenticated IDLE/BUSY fixture evidence')
        mcp_preflight(source)
        if args.preflight_only:
            report['passed']=True
            print(json.dumps({'client':args.client,'preflightPassed':True,'modelInvocations':0}))
            raise SystemExit(0)
        report['modelInvocations']=1; model_started=True
        with (args.output/'review-driver.txt').open('w') as output:
            result = subprocess.run([str(binary/'BurnProof'), '--review-owner-model', str(state)], cwd=root,
                env=env, stdout=output, stderr=subprocess.STDOUT, timeout=200)
        if (state/'last-review.log').exists(): shutil.copy2(state/'last-review.log', args.output/'review.jsonl')
        if (state/'owner-review-usage.json').exists(): report['usage']=json.loads((state/'owner-review-usage.json').read_text())
        assert result.returncode == 0, 'Harness review failed; stop without retrying or switching account/provider'
        report['checks'].append('one harness review through production ownerProcess instructions and scoped MCP tools')
        status=rpc({'operation':'status'}); deadline=time.monotonic()+150
        while status.get('verifiedHelpers',0) != 1 and time.monotonic()<deadline:
            assert workers[1][0].poll() is None and not (busy_project/'completed').exists(), 'Active build was interrupted'
            if not status.get('receipts'): raise AssertionError('Harness did not request an owner retirement; do not manufacture a receipt')
            time.sleep(5); status=rpc({'operation':'status'})
        assert status.get('verifiedHelpers') == 1 and len(status.get('receipts',[])) == 1, 'Exact exit did not earn a verified receipt'
        assert status.get('memoryReleasedBytes',0)>0
        try: os.kill(idle_pid,0)
        except ProcessLookupError: pass
        else: raise AssertionError('Idle target still alive despite receipt')
        assert workers[1][0].poll() is None, 'Active same-version build was stopped'
        (busy_project/'release').touch()
        assert workers[1][0].wait(timeout=30)==0 and (busy_project/'completed').exists(), 'Active build did not complete successfully'
        report['checks'].append('one exact verified exit with positive resident-byte receipt; unrelated active build survived and completed')
        report['verifiedHelpers']=status['verifiedHelpers']; report['memoryReleasedBytes']=status['memoryReleasedBytes']
        report['receipts']=status['receipts']; report['passed']=True
    except Exception as error:
        report['failure']=str(error)[:600]
        if model_started and (state/'last-review.log').exists(): shutil.copy2(state/'last-review.log', args.output/'review.jsonl')
        raise
    finally:
        # Preserve private evidence even on model refusal; never retry the review.
        (args.output/'result.json').write_text(json.dumps(report,indent=2)+'\n')
        for worker, output, project in workers:
            (project/'release').touch()
            try: worker.wait(timeout=30)
            except subprocess.TimeoutExpired: worker.terminate(); worker.wait(timeout=10)
            output.close()
        if monitor and monitor.poll() is None:
            monitor.stdin.close(); monitor.wait(timeout=15)
        # Exact owner-native fixture teardown, independent of model acceptance.
        saved = state/'owner-fixture-evidence.json'
        if saved.exists():
            for value in json.loads(saved.read_text()):
                home=pathlib.Path(value['gradleHome']); assert home.is_relative_to(root)
                member=value['member']; identity=member['identity']; pid=identity['pid']
                millis=identity['seconds']*1000+identity['micros']//1000
                base=[member['executable'],'-Xmx128m','-XX:ActiveProcessorCount=1','--class-path',str(distribution/'lib/*'),
                    str(repo/'Sources/BurnCore/Resources/BZGradleDaemon.java')]
                def message(action, uid='', last=''):
                    r=subprocess.run(base+[action,str(home),str(pid),str(millis),member['executable'],uid,str(last)],
                        env=fixture_env,capture_output=True,text=True,timeout=12)
                    return json.loads(r.stdout) if r.stdout else {}
                try:
                    current=message('inspect')
                    if current.get('state')=='IDLE': message('stop-when-idle',current['uid'],current['lastBusyMillis'])
                except Exception: pass
        for path in args.output.iterdir():
            if path.is_file(): path.chmod(0o600)
print(json.dumps({k:report[k] for k in ['client','passed','modelInvocations','verifiedHelpers','memoryReleasedBytes','usage'] if k in report}))
