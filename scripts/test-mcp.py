#!/usr/bin/env python3
"""Real stdio client against the shipped SDK server and a private native monitor."""
import argparse
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time
import statistics

repo = Path(__file__).resolve().parents[1]
binary = repo / ".build/debug"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--server", type=Path, default=binary / "burnzombies-mcp")
server_binary = parser.parse_args().server.resolve()
def line(process, timeout=10):
    if not select.select([process.stdout], [], [], timeout)[0]:
        raise AssertionError("MCP response timed out")
    value = process.stdout.readline()
    if not value:
        raise AssertionError("MCP process exited early")
    return value

with tempfile.TemporaryDirectory(prefix="bz-mcp-", dir="/tmp") as root:
    fixture = subprocess.Popen([str(binary / "BurnProof"), "--agent-fixture", root],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    server = None
    try:
        assert line(fixture).strip() == b"READY"
        env = dict(os.environ, BURNZOMBIES_HOME=root)
        server = subprocess.Popen([str(server_binary)], env=env,
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        sequence = 0
        def send(method, params=None, notification=False):
            global sequence
            sequence += 1
            payload = {"jsonrpc": "2.0", "method": method}
            if params is not None: payload["params"] = params
            if not notification: payload["id"] = sequence
            server.stdin.write(json.dumps(payload).encode() + b"\n"); server.stdin.flush()
            if notification: return
            result = json.loads(line(server))
            assert result["id"] == sequence, result
            return result
        initialized = send("initialize", {"protocolVersion": "2025-11-25", "capabilities": {"experimental": {"codex/auth-change": {}}},
                                         "clientInfo": {"name": "BurnZombies proof", "version": "1"}})
        assert initialized["result"]["serverInfo"]["name"] == "BurnZombies"
        send("notifications/initialized", notification=True)
        tools = send("tools/list")["result"]["tools"]
        assert {t["name"] for t in tools} == {"burnzombies_status", "burnzombies_inspect", "burnzombies_preview", "burnzombies_burn", "burnzombies_checkpoint", "burnzombies_work", "burnzombies_lifecycle", "burnzombies_workspace", "burnzombies_workspace_preview", "burnzombies_workspace_clean", "burnzombies_disk_decide", "burnzombies_disk_preview", "burnzombies_disk_clean"}
        burn = next(t for t in tools if t["name"] == "burnzombies_burn")
        assert burn["annotations"]["destructiveHint"] is True
        def call(name, args): return send("tools/call", {"name": name, "arguments": args})
        status = call("burnzombies_status", {})["result"]
        assert not status.get("isError")
        actual = json.loads(status["content"][0]["text"])
        assert actual["ok"] and actual["observedProcesses"] > 0 and actual["verifiedHelpers"] == 0
        checkpoint = call("burnzombies_checkpoint", {"client": "codex", "tool_name": "burnzombies_status"})["result"]
        assert not checkpoint.get("isError") and json.loads(checkpoint["content"][0]["text"]) == {}
        Path(root, "review-request").write_text("requested")
        checkpoint = json.loads(call("burnzombies_checkpoint", {"client": "claude", "tool_name": "Bash"})["result"]["content"][0]["text"])
        assert checkpoint["hookSpecificOutput"]["additionalContext"] and "decision" not in checkpoint
        assert "error" in call("burnzombies_checkpoint", {"client": "codex", "event": "Stop"})
        timings = []
        for _ in range(100):
            start = time.perf_counter()
            quiet = call("burnzombies_checkpoint", {"client": "codex", "tool_name": "Bash"})["result"]
            timings.append((time.perf_counter()-start)*1000)
            assert json.loads(quiet["content"][0]["text"]) == {}, 'unchanged checkpoint emitted context'
        print(f"PASS 100 quiet MCP checkpoints: median {statistics.median(timings):.2f} ms, p95 {sorted(timings)[94]:.2f} ms")

        inspection = call("burnzombies_inspect", {"pids": [server.pid]})["result"]
        inspected = json.loads(inspection["content"][0]["text"])
        assert len(inspected["processes"]) == 1 and inspected["processes"][0]["protectedReason"]
        assert "error" in call("burnzombies_inspect", {"pids": [True]})
        assert "error" in call("burnzombies_inspect", {"offset": -1})
        assert "error" in call("burnzombies_preview", {"finding_id": "11111111-1111-1111-1111-111111111111"})
        assert "error" in call("burnzombies_status", {"pid": 1})
        assert "error" in call("burnzombies_burn", {"preview_token": "fake"})
        denied = call("burnzombies_burn", {"preview_token": "11111111-1111-1111-1111-111111111111"})["result"]
        assert denied["isError"] is True
        worker = subprocess.Popen(["/bin/sleep", "120"])
        try:
            target = json.loads(call("burnzombies_inspect", {"pids": [worker.pid]})["result"]["content"][0]["text"])["processes"][0]
            registration = {"action": "register", "process_ids": [target["id"]], "label": "Protocol helper",
                "evidence": "This protocol proof owns and still needs the exact disposable worker.",
                "completion_condition": "Protocol assertions finish and no remaining consumer needs this worker."}
            registered = json.loads(call("burnzombies_lifecycle", registration)["result"]["content"][0]["text"])
            assert registered["ok"], registered
            token = registered["workToken"]
            claims = call("burnzombies_work", {})["result"]["content"][0]["text"]
            assert token not in claims and "tokenHash" not in claims
            assert "error" in call("burnzombies_lifecycle", dict(registration, action="release"))
            blocked = call("burnzombies_preview", {"process_ids": [target["id"]], "label": "still active",
                "rationale": "Even a plausible statement cannot override an active ownership claim."})["result"]
            assert blocked["isError"]
            released = call("burnzombies_lifecycle", {"action": "release", "work_token": token,
                "evidence": "Protocol assertions completed; this fixture has no remaining consumer."})["result"]
            assert not released.get("isError") and worker.poll() is None
            assert json.loads(call("burnzombies_status", {})["result"]["content"][0]["text"])["releasedWorkCount"] == 1
        finally:
            worker.terminate(); worker.wait(timeout=5)
        # Actual MCP -> private socket -> Git lifecycle. Production visibility rules stay enabled.
        repository = Path(root, "repository"); repository.mkdir()
        def git(*args):
            return subprocess.run(["git", "-C", str(repository), *args], check=True, capture_output=True, text=True)
        git("init", "--initial-branch=main"); git("config", "user.name", "Fixture"); git("config", "user.email", "fixture@example.invalid")
        Path(repository, "file.txt").write_text("saved fixture work\n")
        git("add", "."); git("commit", "-m", "fixture"); git("update-ref", "refs/remotes/origin/main", "HEAD")
        created = json.loads(call("burnzombies_workspace", {"action": "create", "repository": str(repository),
            "label": "MCP fixture workspace", "evidence": "This isolated protocol fixture needs a temporary Git worktree.",
            "completion_condition": "Protocol checks finish with all changes saved and no consumer remaining."})["result"]["content"][0]["text"])
        assert created["ok"], created
        workspace = created["workspaces"][0]; workspace_token = created["workToken"]
        preview_args = {"workspace_id": workspace["id"], "rationale": "Protocol checks are finished with all commits preserved and no fixture consumer remaining."}
        assert call("burnzombies_workspace_preview", preview_args)["result"]["isError"]
        released = call("burnzombies_workspace", {"action": "release", "work_token": workspace_token,
            "evidence": "All protocol checks completed; fixture commits are saved and no consumer uses this worktree."})["result"]
        assert not released.get("isError"), released
        workspace_preview = call("burnzombies_workspace_preview", preview_args)["result"]
        response = json.loads(workspace_preview["content"][0]["text"])
        if response["ok"]:
            cleaned = call("burnzombies_workspace_clean", {"preview_token": response["previewToken"]})["result"]
            assert not cleaned.get("isError"), cleaned
            result = json.loads(cleaned["content"][0]["text"])
            assert result["worktreesCleaned"] == 1 and not Path(workspace["path"]).exists()
            print("PASS production MCP worktree removal verified on this host")
        else:
            assert "visibility" in response["message"], response
            assert Path(workspace["path"]).is_dir()
            print("PASS production MCP worktree preserves checkout on incomplete host visibility; positive deletion covered by scoped fixture simulation")
        assert "error" in call("burnzombies_workspace", {"action": "release", "work_token": workspace_token,
            "evidence": "Completed fixture must reject extra mutation arguments.", "repository": str(repository)})
        assert send("prompts/list")["result"]["prompts"][0]["name"] == "tame_the_horde"
        assert send("prompts/get", {"name": "tame_the_horde"})["result"]["messages"]
        assert "error" in send("not/a/method")
        server.stdin.close()
        assert server.wait(timeout=10) == 0
        env['BURNZOMBIES_REVIEW_MODE'] = '1'
        env['BURNZOMBIES_REVIEW_IDS'] = '[]'
        server = subprocess.Popen([str(server_binary)], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        send("initialize", {"protocolVersion":"2025-11-25", "capabilities":{}, "clientInfo":{"name":"Bounded review proof","version":"1"}})
        send("notifications/initialized", notification=True)
        review_tools = {t['name'] for t in send('tools/list')['result']['tools']}
        assert 'burnzombies_lifecycle' not in review_tools and 'burnzombies_checkpoint' not in review_tools and 'burnzombies_workspace' not in review_tools and 'burnzombies_work' not in review_tools
        assert 'error' in call('burnzombies_lifecycle', registration)
        assert 'error' in call('burnzombies_workspace', {'action':'create'})
        for _ in range(8):
            response = call('burnzombies_status', {})['result']
            assert not response.get('isError')
            compact = json.loads(response['content'][0]['text'])
            assert compact['work'] == [] and compact['workspaces'] == [], 'Reviewer saw evidence outside selected batch'
            assert 'groups' not in compact and 'receipts' not in compact and 'worktreeReceipts' not in compact
        assert call('burnzombies_status', {})['result']['isError']
        server.stdin.close(); assert server.wait(timeout=10)==0
        print("PASS MCP lifecycle, protected working claims, redacted readback, strict arguments, reviewer capability restrictions and call budget")
    finally:
        if server and server.poll() is None:
            server.terminate(); server.wait(timeout=10)
        fixture.stdin.close()
        try: fixture.wait(timeout=10)
        except subprocess.TimeoutExpired:
            fixture.terminate(); fixture.wait(timeout=10)
            raise AssertionError("Native bridge did not stop cleanly")
