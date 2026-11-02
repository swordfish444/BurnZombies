#!/usr/bin/env python3
"""Real stdio MCP client against the autopilot-mode server and a private app endpoint."""
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time

repo = Path(__file__).resolve().parents[1]
binary = repo / ".build/debug"


def line(process, timeout=10):
    if not select.select([process.stdout], [], [], timeout)[0]:
        raise AssertionError("response timed out")
    value = process.stdout.readline()
    if not value:
        raise AssertionError("process exited early: " + process.stderr.read().decode()[-2000:])
    return value


with tempfile.TemporaryDirectory(prefix="bz-ap-", dir="/tmp") as root:
    fixture = subprocess.Popen([str(binary / "BurnProof"), "--autopilot-fixture", root],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    server = None
    try:
        assert line(fixture, 60).strip() == b"READY"
        env = dict(os.environ, BURNZOMBIES_HOME=root, BURNZOMBIES_AUTOPILOT="1")
        server = subprocess.Popen([str(binary / "burnzombies-mcp")], env=env, stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        sequence = 0

        def send(method, params=None, notification=False, timeout=10):
            global sequence
            sequence += 1
            payload = {"jsonrpc": "2.0", "method": method}
            if params is not None:
                payload["params"] = params
            if not notification:
                payload["id"] = sequence
            server.stdin.write(json.dumps(payload).encode() + b"\n")
            server.stdin.flush()
            if notification:
                return None
            result = json.loads(line(server, timeout))
            assert result["id"] == sequence, result
            return result

        def call(name, args, timeout=10):
            result = send("tools/call", {"name": name, "arguments": args}, timeout=timeout)["result"]
            return result.get("isError", False), json.loads(result["content"][0]["text"])

        hello = send("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                    "clientInfo": {"name": "autopilot proof", "version": "1"}})
        assert hello["result"]["serverInfo"]["name"] == "BurnZombies Autopilot", hello
        send("notifications/initialized", notification=True)
        tools = {t["name"]: t for t in send("tools/list")["result"]["tools"]}
        assert set(tools) == {"autopilot_catalog", "autopilot_inspect", "autopilot_decide",
                              "autopilot_burn", "autopilot_ask", "autopilot_report"}, tools.keys()
        assert tools["autopilot_burn"]["annotations"]["destructiveHint"] is True

        error, page = call("autopilot_catalog", {"status": "unsure"})
        assert not error and {i["id"] for i in page["items"]} == {"worktree:fixture-copy", "process:fixture-server"}, page
        assert "consequence" not in json.dumps(page["items"]), "catalog stays compact"
        error, detail = call("autopilot_inspect", {"id": "process:fixture-server"})
        assert not error and detail["commandLine"].startswith("node vite"), detail

        error, refused = call("autopilot_burn", {"ids": ["worktree:fixture-copy"]})
        assert refused[0]["outcome"] == "refused" and "autopilot_ask" in refused[0]["detail"], refused

        error, decided = call("autopilot_decide", {"judgments": [
            {"id": "worktree:fixture-copy", "verdict": "burn", "confidence": 0.93,
             "label": "Old atlas copy", "why": "Its work is on GitHub and nobody touched it in months."},
            {"id": "process:fixture-server", "verdict": "burn", "confidence": 0.97,
             "label": "Leftover dev server", "why": "Its chat ended a day ago."}]})
        assert not error and decided["authorized"] == "worktree:fixture-copy", decided

        started = time.monotonic()
        error, burned = call("autopilot_burn", {"ids": ["worktree:fixture-copy", "process:fixture-server"]}, timeout=40)
        took = time.monotonic() - started
        assert burned[0]["outcome"] == "burned" and took >= 7, (burned, took)
        assert burned[1]["outcome"] == "refused", "a listening server needs the owner"

        # BZ already asks one question about the server: a second one is refused, rewording it is not.
        error, overlap = call("autopilot_ask", {"kind": "process", "match": {"family": ["node"], "listening": ["yes"]},
                                                "question": "Can I burn leftover dev servers from chats that already finished?"})
        assert error and "already asking" in overlap.get("error", ""), overlap
        error, page = call("autopilot_catalog", {"status": "unsure"})
        native = next(q for q in page["openQuestions"] if q["kind"] == "process")
        error, question = call("autopilot_ask", {"kind": "process", "match": native["match"],
                                                 "question": "Can I burn leftover dev servers from chats that already finished?"})
        assert not error and question["count"] == 1 and question["source"] == "ai", question
        error, bad = call("autopilot_ask", {"kind": "process", "match": {"family": ["node"]}, "question": "no question mark"})
        assert error, "questions must be questions"
        error, done = call("autopilot_report", {"text": "Burned one old copy; asked about one dev server."})
        assert not error, done
        print("PASS autopilot MCP: six tools, compact catalog, inspect, refusal guidance, AI authority, "
              f"{took:.1f}s burn past the 5s socket deadline, listening-server refusal, one question per subject and report")
    finally:
        if server:
            server.terminate()
            server.wait(timeout=10)
        fixture.stdin.close()
        fixture.wait(timeout=30)
