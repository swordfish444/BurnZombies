#!/usr/bin/env python3
"""Native five-harness setup, preservation, idempotence, conflicts, lifecycle formats."""
import json, os, pathlib, subprocess, tempfile, time, tomllib
repo = pathlib.Path(__file__).resolve().parents[1]
cli = (repo / '.build/debug/burnzombies').resolve()
with tempfile.TemporaryDirectory(prefix='bz-harness-install-') as temp:
    home = pathlib.Path(temp)
    (home / '.codex').mkdir()
    original = 'model = "keep-user-model"\n[mcp_servers.other]\ncommand = "/keep/other"\n'
    (home / '.codex/config.toml').write_text(original)
    (home / '.claude').mkdir()
    settings = {'permissions': {'deny': ['Bash(rm *)']}, 'hooks': {'PostToolUse': [{'hooks': [{'type': 'command', 'command': 'echo keep'}]}]}}
    (home / '.claude/settings.json').write_text(json.dumps(settings))
    (home / '.claude.json').write_text(json.dumps({'userPreference': 'keep', 'mcpServers': {'other': {'command': 'keep'}}}))
    # Migrate the intrusive three-hook version without disturbing unrelated handlers.
    legacy = {event: [{'hooks':[{'type':'command','command':"'"+str(cli)+"' hook --client codex --event "+event,'timeout':5}]}] for event in ['SessionStart','PostToolUse','Stop']}
    (home/'.codex/hooks.json').write_text(json.dumps({'hooks':legacy}))
    command = [str(cli), 'install', '--harness', 'all', '--checkpoints', 'on', '--home', str(home), '--skill-file', str(repo/'skills/burnzombies/SKILL.md')]
    result = subprocess.run(command, capture_output=True, text=True, check=True)
    config = tomllib.loads((home/'.codex/config.toml').read_text())
    assert config['model'] == 'keep-user-model' and config['mcp_servers']['other']['command'] == '/keep/other'
    assert config['mcp_servers']['burnzombies']['command'] == str(cli.parent/'burnzombies-mcp')
    assert (home/'.codex/config.toml').read_text().startswith(original)
    for relative in ['.claude.json', '.cursor/mcp.json', '.copilot/mcp-config.json', '.gemini/settings.json']:
        assert json.loads((home/relative).read_text())['mcpServers']['burnzombies']['command'] == str(cli.parent/'burnzombies-mcp')
    for name in ['.agents', '.claude', '.cursor', '.copilot', '.gemini']:
        assert (home/name/'skills/burnzombies/SKILL.md').read_bytes() == (repo/'skills/burnzombies/SKILL.md').read_bytes()
    assert json.loads((home/'.claude/settings.json').read_text())['permissions'] == settings['permissions']
    assert json.loads((home/'.claude/settings.json').read_text())['hooks']['PostToolUse'][0] == settings['hooks']['PostToolUse'][0]
    for relative in ['.codex/hooks.json', '.claude/settings.json']:
        hooks = json.loads((home/relative).read_text())['hooks']
        assert 'SessionStart' not in hooks and 'Stop' not in hooks
        handlers = [h for group in hooks['PostToolUse'] for h in group['hooks'] if h.get('server') == 'burnzombies']
        assert len(handlers) == 1 and handlers[0]['type'] == 'mcp_tool' and handlers[0]['timeout'] == 1
    before = {p: p.read_bytes() for p in home.rglob('*') if p.is_file()}
    subprocess.run(command, check=True, capture_output=True)
    assert before == {p: p.read_bytes() for p in home.rglob('*') if p.is_file()}, 'repeat install changed files'
    # A conflict must be discovered before any other edits happen.
    conflict = home/'.gemini/settings.json'
    content = json.loads(conflict.read_text()); content['mcpServers']['burnzombies']['command'] = '/custom/preserve'
    conflict.write_text(json.dumps(content))
    before = {p: p.read_bytes() for p in home.rglob('*') if p.is_file()}
    assert subprocess.run(command, capture_output=True).returncode != 0
    assert before == {p: p.read_bytes() for p in home.rglob('*') if p.is_file()}
    # Hooks are bounded context transport. No model subprocess or process signaling.
    for client, event, key in [('codex','PostToolUse','hookSpecificOutput'), ('claude','PostToolUse','hookSpecificOutput'), ('cursor','postToolUse','additional_context'), ('copilot','postToolUse','additionalContext'), ('gemini','AfterTool','hookSpecificOutput')]:
        state = home/('state-'+client); state.mkdir()
        (state/'review-signal').write_text(json.dumps({'observedAt':time.time()-978307200,'processCount':10,'residentBytes':1024,'pressure':'Low'}))
        (state/'review-request').write_text('requested')
        env = dict(os.environ, BURNZOMBIES_HOME=str(state))
        invocation = [str(cli), 'hook', '--client', client, '--event', event]
        output = subprocess.run(invocation, input='{}', env=env, text=True, capture_output=True, check=True)
        assert key in json.loads(output.stdout)
        again = subprocess.run(invocation, input='{}', env=env, text=True, capture_output=True, check=True)
        assert json.loads(again.stdout) == {}
    # Turning checkpoints off removes only BZ callbacks; skill/tools remain usable.
    content['mcpServers']['burnzombies']['command'] = str(cli.parent/'burnzombies-mcp')
    conflict.write_text(json.dumps(content))
    subprocess.run([arg if i == 0 or command[i-1] != '--checkpoints' else 'off' for i, arg in enumerate(command)], check=True, capture_output=True)
    assert json.loads((home/'.codex/hooks.json').read_text())['hooks'] == {}
    assert json.loads((home/'.claude/settings.json').read_text())['hooks'] == settings['hooks']
print('PASS five harness configurations, preserved preferences/tools/hooks, idempotence, atomic conflict refusal, bounded lifecycle formats')
