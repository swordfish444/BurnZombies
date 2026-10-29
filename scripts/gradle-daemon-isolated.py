#!/usr/bin/env python3
"""Owned Gradle fixtures only. No user registry lookup or blanket stop command.

Usage: python3 scripts/gradle-daemon-isolated.py --distribution /path/gradle-8.14.6 --java /path/bin/java
Creates two private Gradle homes; refuses to operate outside those homes.
"""
import argparse, json, os, pathlib, subprocess, tempfile, time, uuid

parser = argparse.ArgumentParser()
parser.add_argument('--distribution', required=True, type=pathlib.Path)
parser.add_argument('--java', required=True, type=pathlib.Path)
parser.add_argument('--evidence', type=pathlib.Path)
parser.add_argument('--proof-binary', type=pathlib.Path)
parser.add_argument('--swift-only', action='store_true')
options = parser.parse_args()
repo = pathlib.Path(__file__).resolve().parents[1]
distribution, java = options.distribution.resolve(), options.java.resolve()
assert distribution.name == 'gradle-8.14.6'
assert (distribution/'lib/gradle-daemon-main-8.14.6.jar').is_file()
helper = repo/'Sources/BurnCore/Resources/BZGradleDaemon.java'
env = {'PATH': '/usr/bin:/bin', 'HOME': str(pathlib.Path.home()), 'JAVA_HOME': str(java.parent.parent),
       'LANG': 'en_US.UTF-8', 'TMPDIR': tempfile.gettempdir()}
evidence = {'version': '8.14.6', 'ownedFixtureOnly': True, 'checks': []}
children = []
with tempfile.TemporaryDirectory(prefix='bz-gradle-proof-') as temp:
    root = pathlib.Path(temp).resolve()
    native_source = root/'identity.c'
    native_source.write_text('''#include "CBurn.h"
#include "GradleIdentity.h"
#include <stdio.h>
#include <stdlib.h>
int main(int argc,char **argv){if(argc!=2)return 2;bz_process p;bz_gradle_identity g;
if(bz_read(atoi(argv[1]),&p)!=1)return 3;
printf("%llu\\n%llu\\n%s\\n",p.start_sec,p.start_usec,p.path);
if(bz_gradle_launch(p.pid,&g)!=1)return 4;
printf("%s\\n%s\\n%s\\n",g.home,g.distribution,g.version);return 0;}
''')
    native = root/'identity'
    subprocess.run(['/usr/bin/clang', '-I', str(repo/'Sources/CBurn/include'), str(native_source),
        str(repo/'Sources/CBurn/CBurn.c'), str(repo/'Sources/CBurn/GradleIdentity.c'), '-o', str(native)], check=True)
    def identity(pid):
        value = subprocess.run([str(native), str(pid)], capture_output=True, text=True, timeout=5)
        assert value.returncode == 0, ('native source evidence', value.returncode, value.stderr)
        lines = value.stdout.splitlines()
        assert pathlib.Path(lines[3]).is_relative_to(root), 'Refuse non-fixture home'
        assert pathlib.Path(lines[4]).resolve() == distribution
        return int(lines[0])*1000 + int(lines[1])//1000, lines[2]
    def owner(home, pid, action='inspect', uid='', busy_millis=None):
        assert home.is_relative_to(root)
        millis, executable = identity(pid)
        if action == 'stop-when-idle' and busy_millis is None:
            busy_millis = owner(home, pid).get('lastBusyMillis', -1)
        result = subprocess.run([str(java), '-Xmx128m', '-XX:ActiveProcessorCount=1', '--class-path', str(distribution/'lib/*'),
            str(helper), action, str(home), str(pid), str(millis), executable, uid, str(busy_millis or '')], env=env, capture_output=True, text=True, timeout=25)
        try: reply = json.loads(result.stdout)
        except Exception: raise AssertionError(('adapter response', result.returncode, result.stdout, result.stderr))
        return reply
    def make(name, busy=False):
        home, project = root/name/'home', root/name/'project'
        home.mkdir(parents=True); project.mkdir(parents=True)
        (project/'settings.gradle').write_text("rootProject.name = 'bz-owned-fixture'\n")
        (project/'gradle.properties').write_text('org.gradle.jvmargs=-Xmx96m -XX:ActiveProcessorCount=1\norg.gradle.daemon.idletimeout=60000\n')
        (project/'build.gradle').write_text('''tasks.register('fixture') {
 doLast {
  file('started').text = 'owned fixture started'
  if (project.hasProperty('hold')) {
   long deadline = System.currentTimeMillis() + 90000
   while (!file('release').exists() && System.currentTimeMillis() < deadline) { Thread.sleep(100) }
   if (!file('release').exists()) throw new GradleException('fixture hold deadline')
  }
  file('completed').text = 'owned fixture completed'
 }
}
''')
        args = [str(distribution/'bin/gradle'), '--gradle-user-home', str(home), '--project-dir', str(project), '--offline', '--console=plain', 'fixture']
        if busy: args += ['-Phold']
        output = open(root/(name+'.log'), 'w')
        process = subprocess.Popen(args, env=env, stdout=output, stderr=subprocess.STDOUT)
        children.append((process, output, project))
        deadline = time.time()+45
        while not (project/'started').exists() and time.time()<deadline and process.poll() is None: time.sleep(.1)
        assert (project/'started').exists(), 'Fixture startup failed: '+(root/(name+'.log')).read_text()[-2000:]
        logs = list((home/'daemon/8.14.6').glob('daemon-*.out.log'))
        assert len(logs) == 1
        pid = int(logs[0].name.split('-')[1].split('.')[0])
        if not busy: assert process.wait(timeout=20) == 0
        return home, project, pid
    fixtures = []
    try:
        if not options.swift_only:
            idle_home, idle_project, idle_pid = make('idle')
            fixtures.append((idle_home, idle_project, idle_pid))
            idle = owner(idle_home, idle_pid)
            assert idle.get('ok') and idle.get('state') == 'IDLE', idle
            evidence['checks'].append('exact owned daemon source and authenticated IDLE status')
            wrong = owner(idle_home, idle_pid, 'stop-when-idle', str(uuid.uuid4()))
            assert not wrong['ok'] and owner(idle_home, idle_pid)['ok']
            evidence['checks'].append('wrong daemon UID refused; target remains alive')
            busy_home, busy_project, busy_pid = make('busy', True)
            fixtures.append((busy_home, busy_project, busy_pid))
            busy = owner(busy_home, busy_pid)
            assert busy.get('ok') and busy.get('state') == 'BUSY', busy
            refusal = owner(busy_home, busy_pid, 'stop-when-idle', busy['uid'])
            assert not refusal['ok'] and not (busy_project/'completed').exists()
            evidence['checks'].append('active build refused without cancellation')
            stopped = owner(idle_home, idle_pid, 'stop-when-idle', idle['uid'])
            assert stopped.get('ok') and stopped.get('accepted'), stopped
            deadline = time.time()+20
            while time.time()<deadline:
                try: os.kill(idle_pid, 0)
                except ProcessLookupError: break
                time.sleep(.1)
            else: raise AssertionError('Exact idle daemon did not exit')
            assert owner(busy_home, busy_pid)['state'] == 'BUSY'
            (busy_project/'release').touch()
            assert children[-1][0].wait(timeout=25) == 0 and (busy_project/'completed').exists()
            evidence['checks'].append('idle target exited while unrelated same-version active build survived and completed')
            final = owner(busy_home, busy_pid)
            assert final['state'] == 'IDLE'
            assert owner(busy_home, busy_pid, 'stop-when-idle', final['uid'])['ok']
            # Insert only a fixture barrier immediately before the production owner's
            # gracefulStop call. This deterministically exercises idle -> busy AFTER
            # all checks; the real Gradle state machine must preserve the raced build.
            race_home, race_project, race_pid = make('race')
            fixtures.append((race_home, race_project, race_pid))
            race = owner(race_home, race_pid)
            ready, proceed = root/'race-ready', root/'race-proceed'
            fixture_helper = root/'BZGradleDaemon.java'
            source = helper.read_text()
            needle = 'services.get(DaemonStopClient.class).gracefulStop(Collections.singletonList(daemon));'
            assert source.count(needle) == 1
            barrier = ('Files.writeString(Path.of('+json.dumps(str(ready))+'), "ready"); '
                'long limit = System.currentTimeMillis()+45000; '
                'while(!Files.exists(Path.of('+json.dumps(str(proceed))+')) && System.currentTimeMillis()<limit) Thread.sleep(20); '
                'require(Files.exists(Path.of('+json.dumps(str(proceed))+'))); ')
            fixture_helper.write_text(source.replace(needle, barrier+needle))
            millis, executable = identity(race_pid)
            stop = subprocess.Popen([str(java), '-Xmx128m', '-XX:ActiveProcessorCount=1', '--class-path', str(distribution/'lib/*'),
                str(fixture_helper), 'stop-when-idle', str(race_home), str(race_pid), str(millis), executable,
                race['uid'], str(race['lastBusyMillis'])], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            deadline = time.time()+30
            while not ready.exists() and time.time()<deadline and stop.poll() is None: time.sleep(.05)
            assert ready.exists(), stop.communicate(timeout=1)
            (race_project/'started').unlink(); (race_project/'completed').unlink()
            output = open(root/'race-active.log', 'w')
            build = subprocess.Popen([str(distribution/'bin/gradle'), '--gradle-user-home', str(race_home),
                '--project-dir', str(race_project), '--offline', '--console=plain', 'fixture', '-Phold'],
                env=env, stdout=output, stderr=subprocess.STDOUT)
            children.append((build, output, race_project))
            deadline = time.time()+30
            while not (race_project/'started').exists() and time.time()<deadline and build.poll() is None: time.sleep(.05)
            assert (race_project/'started').exists() and owner(race_home, race_pid)['state'] == 'BUSY'
            proceed.touch()
            response, errors = stop.communicate(timeout=15)
            assert stop.returncode == 0 and json.loads(response).get('accepted'), (response, errors)
            assert build.poll() is None and not (race_project/'completed').exists()
            (race_project/'release').touch()
            assert build.wait(timeout=20) == 0 and (race_project/'completed').exists()
            deadline = time.time()+20
            while time.time()<deadline:
                try: os.kill(race_pid, 0)
                except ProcessLookupError: break
                time.sleep(.1)
            else: raise AssertionError('Raced daemon did not exit after successful build completion')
            evidence['checks'].append('deterministic idle-to-busy race: owner deferred exit, active build completed successfully, then exact daemon exited')
        if options.proof_binary:
            swift_home, swift_project, swift_pid = make('swift')
            fixtures.append((swift_home, swift_project, swift_pid))
            saved = root/'swift-preview.json'
            def swift_action(action):
                result = subprocess.run([str(options.proof_binary.resolve()), '--gradle-fixture', action,
                    str(swift_pid), str(swift_home), str(saved)], env=env, capture_output=True, text=True, timeout=45)
                assert result.returncode == 0, (action, result.stdout, result.stderr)
                return json.loads(result.stdout)
            assert swift_action('inspect')['eligible']
            assert swift_action('wrong-uid')['refused']
            assert swift_action('expired')['refused']
            assert swift_action('changed')['refused']
            assert swift_action('denied')['refused']
            for name in ('started', 'completed', 'release'): (swift_project/name).unlink(missing_ok=True)
            held_output = open(root/'swift-active.log', 'w')
            held = subprocess.Popen([str(distribution/'bin/gradle'), '--gradle-user-home', str(swift_home),
                '--project-dir', str(swift_project), '--offline', '--console=plain', 'fixture', '-Phold'],
                env=env, stdout=held_output, stderr=subprocess.STDOUT)
            children.append((held, held_output, swift_project))
            deadline = time.time()+30
            while not (swift_project/'started').exists() and time.time()<deadline and held.poll() is None: time.sleep(.1)
            assert (swift_project/'started').exists() and owner(swift_home, swift_pid).get('state') == 'BUSY'
            assert swift_action('advanced')['refused']
            assert held.poll() is None and not (swift_project/'completed').exists(), 'Cached IDLE evidence interrupted an active build'
            evidence['checks'].append('production Swift actuator refuses cached IDLE evidence after owner becomes BUSY; held build survives')
            (swift_project/'release').touch()
            assert held.wait(timeout=30) == 0 and (swift_project/'completed').exists()
            assert swift_action('advanced')['refused']
            assert swift_action('inspect')['eligible']
            assert swift_action('stop')['requested']
            deadline = time.time()+20
            while time.time()<deadline:
                try: os.kill(swift_pid, 0)
                except ProcessLookupError: break
                time.sleep(.1)
            else: raise AssertionError('Swift adapter target did not exit')
            evidence['checks'].append('production Swift API: wrong UID, expired preview, changed configuration, revoked policy and newer work refused; refreshed exact idle daemon exited')
    finally:
        # Only fixtures created above are released; their idle timeout bounds leftovers.
        for process, output, project in children:
            (project/'release').touch()
            try: process.wait(timeout=25)
            except subprocess.TimeoutExpired: process.terminate(); process.wait(timeout=5)
            output.close()
        for home, project, pid in fixtures:
            try:
                reply = owner(home, pid)
                if reply.get('state') == 'IDLE': owner(home, pid, 'stop-when-idle', reply['uid'])
            except Exception: pass
evidence['passed'] = True
if options.evidence: options.evidence.write_text(json.dumps(evidence, indent=2)+'\n')
print(json.dumps(evidence, indent=2))
