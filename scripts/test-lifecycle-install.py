#!/usr/bin/env python3
"""Portable skill discovery and conservative upgrades, with no live config access."""
import hashlib, pathlib, subprocess, tempfile
repo = pathlib.Path(__file__).resolve().parents[1]
cli = repo/'.build/debug/burnzombies'
with tempfile.TemporaryDirectory(prefix='bz-skill-') as tmp:
    home = pathlib.Path(tmp)
    configs = {'.codex/config.toml':b'[features]\nkeep=true\n', '.claude/settings.json':b'{"keep":true}\n'}
    for name, content in configs.items():
        p=home/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(content)
    command=[str(cli),'install-skill','--home',str(home),'--skill-file',str(repo/'skills/burnzombies/SKILL.md')]
    def install(ok=True):
        r=subprocess.run(command,capture_output=True,text=True)
        assert (r.returncode==0)==ok,r.stdout+r.stderr
    install(); install()
    shared=home/'.agents/skills/burnzombies/SKILL.md'
    claude=home/'.claude/skills/burnzombies/SKILL.md'
    assert shared.read_bytes()==claude.read_bytes()
    assert str(cli.resolve()) in shared.read_text()
    for name,content in configs.items(): assert (home/name).read_bytes()==content
    assert not list(home.rglob('hooks.json'))
    retire=[str(cli),'retire-skill','--home',str(home)]
    subprocess.run(retire,check=True,capture_output=True)
    assert not shared.exists() and not claude.exists()
    assert shared.with_name('retired-instructions.txt').exists()
    install()
    original=shared.read_bytes()
    claude.write_bytes(claude.read_bytes()+b'\nUser custom instruction\n')
    custom=claude.read_bytes(); install(False)
    result=subprocess.run(retire,capture_output=True)
    assert result.returncode != 0 and shared.read_bytes()==original and claude.read_bytes()==custom
    assert shared.read_bytes()==original and claude.read_bytes()==custom
    claude.unlink(); claude.symlink_to(shared); install(False)
    assert shared.read_bytes()==original
print('PASS portable five-harness skill paths, repeat install, custom edits/symlinks preserved, zero config/hook changes')
