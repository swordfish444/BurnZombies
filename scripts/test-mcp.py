#!/usr/bin/env python3
"""Real stdio client against the shipped SDK server and a private native monitor."""
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
binary = repo / ".build/debug"
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
        server = subprocess.Popen([str(binary / "burnzombies-mcp")], env=env,
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
        initialized = send("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                         "clientInfo": {"name": "BurnZombies proof", "version": "1"}})
        assert initialized["result"]["serverInfo"]["name"] == "BurnZombies"
        send("notifications/initialized", notification=True)
        tools = send("tools/list")["result"]["tools"]
        assert {t["name"] for t in tools} == {"burnzombies_status", "burnzombies_preview", "burnzombies_burn"}
        burn = next(t for t in tools if t["name"] == "burnzombies_burn")
        assert burn["annotations"]["destructiveHint"] is True
        def call(name, args): return send("tools/call", {"name": name, "arguments": args})
        status = call("burnzombies_status", {})["result"]
        assert not status.get("isError")
        actual = json.loads(status["content"][0]["text"])
        assert actual["ok"] and actual["observedProcesses"] > 0 and actual["verifiedHelpers"] == 0
        assert "error" in call("burnzombies_status", {"pid": 1})
        assert "error" in call("burnzombies_burn", {"preview_token": "fake"})
        denied = call("burnzombies_burn", {"preview_token": "11111111-1111-1111-1111-111111111111"})["result"]
        assert denied["isError"] is True
        assert send("prompts/list")["result"]["prompts"][0]["name"] == "tame_the_horde"
        assert send("prompts/get", {"name": "tame_the_horde"})["result"]["messages"]
        assert "error" in send("not/a/method")
        server.stdin.close()
        assert server.wait(timeout=10) == 0
        print("PASS MCP initialize, discovery, live status, strict arguments, denied cleanup, prompt and EOF shutdown")
    finally:
        if server and server.poll() is None:
            server.terminate(); server.wait(timeout=10)
        fixture.stdin.close()
        try: fixture.wait(timeout=10)
        except subprocess.TimeoutExpired:
            fixture.terminate(); fixture.wait(timeout=10)
            raise AssertionError("Native bridge did not stop cleanly")
