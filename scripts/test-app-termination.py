#!/usr/bin/env python3
"""Exercise async updater/Quit exits and external termination in real AppKit.

Each process is a demo-only fixture: no windows, observer, AI or live state.
The timeout catches MainActor deadlocks that external stop-observer tests miss.
"""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
binary = repo / ".build/debug/BurnZombiesApp"
failures = []
with tempfile.TemporaryDirectory(prefix="bz-termination-") as directory:
    for mode in ["update", "quit", "external"]:
        receipt = Path(directory) / mode
        try:
            result = subprocess.run(
                [str(binary), "--termination-proof", mode, str(receipt)],
                capture_output=True, text=True, timeout=10,
            )
            assert result.returncode == 0, result.stdout + result.stderr
            assert receipt.read_text() == "shutdown-complete-before-exit\n"
            print(f"PASS {mode}: graceful exit after shutdown, no visible windows", flush=True)
        except (subprocess.TimeoutExpired, AssertionError, OSError) as error:
            failures.append(mode)
            print(f"FAIL {mode}: {error}", flush=True)
if failures:
    raise SystemExit("Termination regressions: " + ", ".join(failures))
