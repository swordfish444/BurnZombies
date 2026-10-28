#!/usr/bin/env python3
"""No-model, real MCP transport proof. Simulated GB; only tiny test-owned files."""
import hashlib
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time
import uuid

repo = Path(__file__).resolve().parents[1]
binary = repo / ".build/debug"

def line(p):
    assert select.select([p.stdout], [], [], 15)[0], "Fixture/transport timeout"
    value = p.stdout.readline()
    assert value, "Fixture/transport exited"
    return value

with tempfile.TemporaryDirectory(prefix="bz-discovery-mcp-") as directory:
    root = Path(directory).resolve()
    source = root / "unusual-tool-output"
    source.mkdir()
    (source / "manifest.json").write_text(json.dumps({"generatedBy": "fixture compiler", "producer_dirty": True,
        "credential": "NEVER_RETURN_THIS_VALUE"}))
    (source / "retention.md").write_text("Keep final accepted proof. Older compilation output can be recreated from preserved inputs.\n")
    now = time.time() - 978307200
    def node(path, size):
        return {"path": str(path), "scanRoot": str(source), "allocated": size, "unshared": size,
                "files": 1, "unknown": 0, "errors": 0, "hardlinks": 0, "dataless": 0,
                "complete": True, "childrenTruncated": False, "measured": now}
    nodes = [node(source, 15_000_000_000)]
    for i in range(3):
        child = source / f"revision-{i}" / "recreated-output"
        child.mkdir(parents=True)
        (child / "result.txt").write_text("test-owned output\n")
        nodes.append(node(child, 5_000_000_000))
    (root / "discovery-roots.json").write_text(json.dumps([str(source)]))
    (root / "disk-discovery.json").write_text(json.dumps({"nodes": nodes, "advice": {}, "queue": [],
        "lastCycle": now, "updated": now, "explored": [], "detail": "Isolated protocol fixture."}))
    expected = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in source.rglob("*") if p.is_file()}
    identity = "space:" + hashlib.sha256((str(source) + "|folder").encode()).hexdigest()
    fixture = subprocess.Popen([str(binary / "BurnProof"), "--agent-fixture", str(root)],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    server = None
    try:
        assert line(fixture).strip() == b"READY"
        attempt = str(uuid.uuid4()).upper()
        (root / 'review-progress.json').write_text(json.dumps({'attempt':attempt,'selected':[identity],'steps':[]}))
        env = dict(os.environ, BURNZOMBIES_HOME=str(root), BURNZOMBIES_REVIEW_MODE="1",
                   BURNZOMBIES_REVIEW_IDS=json.dumps([identity]), BURNZOMBIES_REVIEW_LANE='discovery',
                   BURNZOMBIES_REVIEW_ATTEMPT=attempt)
        server = subprocess.Popen([str(binary / "burnzombies-mcp")], env=env,
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        sequence = 0
        def send(method, params, notification=False):
            global sequence
            sequence += 1
            request = {"jsonrpc": "2.0", "method": method, "params": params}
            if not notification: request["id"] = sequence
            server.stdin.write(json.dumps(request).encode() + b"\n"); server.stdin.flush()
            if notification: return
            response = json.loads(line(server)); assert response["id"] == sequence
            return response
        send("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "storage-proof", "version": "1"}})
        send("notifications/initialized", {}, True)
        names = {t['name'] for t in send('tools/list', {})['result']['tools']}
        assert names == {'burnzombies_status','burnzombies_disk_inspect','burnzombies_disk_evidence',
                         'burnzombies_disk_explore','burnzombies_disk_recommend'}, names
        rejected = send('tools/call', {'name':'burnzombies_burn','arguments':{'preview_token':str(uuid.uuid4())}})
        assert 'error' in rejected, 'Unrelated mutation tools must be refused, not merely hidden'
        def call(name, arguments):
            result = send("tools/call", {"name": "burnzombies_" + name, "arguments": arguments})["result"]
            return result, json.loads(result["content"][0]["text"])
        result, status = call("status", {})
        assert not result.get("isError") and status["diskDiscovery"][0]["id"] == identity
        assert status["diskPolicy"]["mode"] == "recommend", "Discovery-only reviews must receive user policy"
        result, facts = call("disk_inspect", {"node_id": identity})
        assert not result.get("isError"), facts
        evidence = facts["diskInspection"]
        assert "fixture compiler" in json.dumps(evidence)
        assert "NEVER_RETURN_THIS_VALUE" not in json.dumps(evidence)
        assert "members" not in json.dumps(evidence)
        group = evidence["repeatedFolders"][0]
        assert group["folders"] == 3 and group["unshared"] == 15_000_000_000
        result, document = call("disk_evidence", {"node_id": identity, "relative_path": "retention.md"})
        assert not result.get("isError") and "Keep final accepted proof" in json.dumps(document)
        result, refusal = call("disk_evidence", {"node_id": identity, "relative_path": "../machine-review.json"})
        assert result.get("isError") and not refusal["ok"]
        result, refusal = call("disk_inspect", {"node_id": "space:unknown"})
        assert result.get("isError") and not refusal["ok"]
        result, saved = call("disk_recommend", {"node_id": group["id"], "disposition": "rebuildable",
            "title": "Review repeated compilation output", "summary": "The compiler produces these folders; preserve source and accepted evidence. Incomplete visibility still blocks removal.",
            "next_step": "Validate that consumers are finished before approving exact generated folders."})
        assert not result.get("isError"), saved
        stored = json.loads((root / "disk-discovery.json").read_text())
        assert stored["advice"][group["id"]]["disposition"] == "rebuildable"
        result, queued = call("disk_explore", {"node_id": identity})
        assert not result.get("isError") and "queued" in queued["message"]
        progress = json.loads((root / 'review-progress.json').read_text())
        assert progress['attempt'] == attempt
        assert any(s['tool']=='disk_explore' and s['id']==identity for s in progress['steps'])
        assert not any(s['id']=='space:unknown' for s in progress['steps']), 'Failed calls cannot acknowledge work'
        for path, digest in expected.items(): assert hashlib.sha256(Path(path).read_bytes()).hexdigest() == digest
        assert not (root / "review-usage.json").exists(), "Read-only protocol tests must not start a model"
        print("PASS production MCP discovery: grouped storage, producer/retention evidence, scope refusals, saved advice, queued native exploration; no deletion or model tokens")
    finally:
        if server:
            server.stdin.close()
            try: server.wait(timeout=10)
            except subprocess.TimeoutExpired: server.terminate(); server.wait(timeout=10)
        fixture.stdin.close()
        try: fixture.wait(timeout=10)
        except subprocess.TimeoutExpired: fixture.terminate(); fixture.wait(timeout=10)
