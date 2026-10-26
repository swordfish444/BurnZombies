#!/usr/bin/env python3
"""Opt-in working-agent -> durable evidence -> independent production-reviewer proof.
Uses existing login, default model/effort, isolated workers and no UI. Stops on account/permission failure.
"""
import argparse, json, os, pathlib, select, shutil, signal, socket, subprocess, tempfile, time
repo=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--client',choices=['codex','claude'],required=True)
p.add_argument('--output',type=pathlib.Path,required=True)
a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True);a.output.chmod(0o700)
bin=repo/'.build/debug'
with tempfile.TemporaryDirectory(prefix='bz-owner-',dir='/tmp') as temporary:
    root=pathlib.Path(temporary); state=root/'state'; state.mkdir(); project=root/'project';project.mkdir()
    subprocess.run(['git','init','-q',str(project)],check=True)
    subprocess.run([str(bin/'burnzombies'),'install-skill','--home',str(project),'--skill-file',str(repo/'skills/burnzombies/SKILL.md')],check=True,capture_output=True,env=dict(os.environ,BURNZOMBIES_HOME=str(state)))
    monitor=subprocess.Popen([str(bin/'BurnProof'),'--agent-fixture',str(state)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    workers=[]
    def rpc(request):
        with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as s:
            s.settimeout(10);s.connect(str(state/'agent.sock'));s.sendall(json.dumps(request).encode()+b'\n');data=b''
            while not data.endswith(b'\n'):data+=s.recv(262144)
            return json.loads(data)
    try:
        assert select.select([monitor.stdout],[],[],10)[0] and monitor.stdout.readline().strip()==b'READY'
        script=project/'fixture_worker.js'
        script.write_text("""const fs=require('fs'),path=require('path');
const root=process.argv[2];
setInterval(()=>{const input=path.join(root,'request.json'),output=path.join(root,'result.json');
if(fs.existsSync(input)&&!fs.existsSync(output)){const values=JSON.parse(fs.readFileSync(input)).values;
fs.writeFileSync(output,JSON.stringify({sum:values.reduce((a,b)=>a+b,0),processed:values.length,status:'completed'}));}},100);
setTimeout(()=>process.exit(0),900000);
""")
        for name in ['report-worker','future-preview','uncertain-control']:
            directory=project/name;directory.mkdir()
            worker=subprocess.Popen([shutil.which('node'),str(script),str(directory)],cwd=directory,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            workers.append(worker)
        manifest={name:proc.pid for name,proc in zip(['report-worker','future-preview','uncertain-control'],workers)}
        (project/'helpers.json').write_text(json.dumps(manifest))
        (state/'allowed-processes.json').write_text(json.dumps(list(manifest.values())))
        prompt=f'''Complete this isolated local task in {project}. The two helpers report-worker and future-preview in helpers.json are test-owned disposable helpers assigned to your task; the uncertain-control belongs to an unrelated test task and must remain untouched. The report-worker accepts a request.json containing {{"values":[17,25,100]}} in its directory and writes result.json. Use it to calculate and verify the report, then save report.txt with the result. Its job ends once the report is saved and checked. Keep future-preview alive and retained for a requested follow-up preview after this turn; it has no job to run yet. Do not stop any process yourself: a separate reviewer will handle leftovers after you exit. Do not open UI, invoke other agents, modify outside this project, change accounts/configuration, or wait for cleanup. Use normal permissions. No shell kills. Return a concise task result.'''
        env=dict(os.environ,BURNZOMBIES_HOME=str(state))
        client=shutil.which(a.client);assert client
        if a.client=='codex':
            command=[client,'exec','--ephemeral','--skip-git-repo-check','--ignore-user-config','--approve-for-me','--json','-C',str(project),'-c','features.hooks=false','-c','mcp_servers.burnzombies.command='+json.dumps(str((bin/'burnzombies-mcp').resolve())),'-c','mcp_servers.burnzombies.env.BURNZOMBIES_HOME='+json.dumps(str(state)),prompt]
        else:
            command=[client,'-p',prompt,'--output-format','json','--no-session-persistence','--strict-mcp-config','--mcp-config',json.dumps({'mcpServers':{'burnzombies':{'command':str((bin/'burnzombies-mcp').resolve()),'env':{'BURNZOMBIES_HOME':str(state)}}}}),'--settings','{"disableAllHooks":true}','--permission-prompts','none','--tools','Read,Write,Edit,Bash,Glob,Grep,Skill','--allowedTools',f'mcp__burnzombies__*,Read,Write,Edit,Glob,Grep,Skill,Bash({bin}/burnzombies:*),Bash(python3:*),Bash(cat:*)']
        with (a.output/'owner.jsonl').open('w') as out,(a.output/'owner.stderr').open('w') as err:
            owner=subprocess.Popen(command,cwd=project,env=env,stdout=out,stderr=err,start_new_session=True)
            try:code=owner.wait(timeout=180)
            finally:
                if owner.poll() is None:
                    os.killpg(owner.pid,signal.SIGTERM);owner.wait(timeout=10)
            assert code==0,'Working harness failed; do not switch accounts/providers or retry quota errors.'
        result=json.loads((project/'report-worker/result.json').read_text())
        assert result['sum']==142 and (project/'report.txt').exists(),'Working agent did not finish actual task'
        work=rpc({'operation':'work'})['work']
        # Controller reads actual agent records; it never registers or marks completed work.
        report=[w for w in work if workers[0].pid in w['livePIDs']]
        active=[w for w in work if workers[1].pid in w['livePIDs']]
        assert report and all(w['state']=='released' for w in report),'Owner did not release finished work'
        assert active and all(w['state']=='active' for w in active),'Owner failed to retain future use'
        assert not any(workers[2].pid in w['livePIDs'] for w in work),'Owner claimed unrelated work'
        assert all(w.poll() is None for w in workers),'Evidence capture stopped a process'
        (a.output/'owner-evidence.json').write_text(json.dumps(work,indent=2))
        # Restart only the private test observer; proof must survive memory/context loss.
        monitor.stdin.close();monitor.wait(timeout=10)
        monitor=subprocess.Popen([str(bin/'BurnProof'),'--agent-fixture',str(state)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        assert select.select([monitor.stdout],[],[],10)[0] and monitor.stdout.readline().strip()==b'READY'
        config={'harness':a.client,'executable':client,'launcher':str((bin/'burnzombies').resolve()),'server':str((bin/'burnzombies-mcp').resolve()),'enabled':True}
        (state/'machine-review.json').write_text(json.dumps(config))
        with (a.output/'review-result.txt').open('w') as out:
            review=subprocess.run([str(bin/'BurnProof'),'--review-model',str(state),a.client,'--production'],cwd=project,env=env,stdout=out,stderr=subprocess.STDOUT,timeout=200)
        if (state/'last-review.log').exists():shutil.copy2(state/'last-review.log',a.output/'review.jsonl')
        assert review.returncode==0,'Production review failed; inspect log without retrying account errors'
        assert workers[0].wait(timeout=5)==-signal.SIGTERM,'Released helper was not gracefully stopped'
        assert all(w.poll() is None for w in workers[1:]),'Active or uncertain control was stopped'
        deadline=time.monotonic()+145
        status=rpc({'operation':'status'})
        while time.monotonic()<deadline and status['verifiedHelpers']!=1:
            time.sleep(15);status=rpc({'operation':'inspect','pids':list(manifest.values())})
            assert all(w.poll() is None for w in workers[1:])
        assert status['verifiedHelpers']==1,status
        assert len(status['receipts'])==1
        (a.output/'receipt.json').write_text(json.dumps(status,indent=2))
        print('PASS',a.client,': real job completion recorded by owner; active/uncertain preserved; observer restart; independent production review; one verified graceful cleanup')
    finally:
        for worker in workers:
            if worker.poll() is None:worker.terminate()
            worker.wait(timeout=5)
        if monitor.poll() is None:
            monitor.stdin.close();monitor.wait(timeout=10)
