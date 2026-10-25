#!/usr/bin/env python3
"""Capture aggregate GitHub launch metrics locally. Never uploads data."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import sys


def capture(repo, request):
    endpoints = {
        "repository": f"repos/{repo}",
        "releases": f"repos/{repo}/releases?per_page=100",
        "views": f"repos/{repo}/traffic/views",
        "clones": f"repos/{repo}/traffic/clones",
        "referrers": f"repos/{repo}/traffic/popular/referrers",
    }
    snapshot = {"repository": repo, "captured_at": datetime.now(timezone.utc).isoformat(),
                "metrics": {}, "errors": {},
                "notes": ["Traffic is a rolling 14-day window; do not sum overlapping snapshots.",
                          "Downloads include owner/testing requests; they do not prove activation.",
                          "Traffic may lag. Missing or denied endpoints are null, not zero.",
                          "Release downloads cover the latest 100 releases; API excludes fetches from clone totals."]}
    for name, endpoint in endpoints.items():
        try:
            value = request(endpoint)
            if name == "repository":
                value = {"stars": value["stargazers_count"], "forks": value["forks_count"],
                         "subscribers": value["subscribers_count"]}
            elif name == "releases":
                value = [{"tag": release["tag_name"], "assets": [
                    {"name": asset["name"], "downloads": asset["download_count"]}
                    for asset in release["assets"]]} for release in value if not release["draft"]]
            snapshot["metrics"][name] = value
        except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError) as error:
            snapshot["metrics"][name] = None
            # No raw HTTP bodies, credentials or gh diagnostics in the output.
            snapshot["errors"][name] = type(error).__name__
    return snapshot


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default="swordfish444/BurnZombies")
    parser.add_argument("--output", type=Path, required=True, help="Private JSON destination outside this checkout")
    args = parser.parse_args()
    output = args.output.expanduser().resolve()
    if output.is_relative_to(Path(__file__).resolve().parents[1]):
        parser.error("Store private traffic snapshots outside the public checkout.")

    def request(endpoint):
        response = subprocess.run(["gh", "api", endpoint], capture_output=True, text=True,
                                  check=True, timeout=30)
        return json.loads(response.stdout)

    snapshot = capture(args.repo, request)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("x") as stream:
        json.dump(snapshot, stream, indent=2)
        stream.write("\n")
    output.chmod(0o600)
    print(f"Saved {output}")
    if snapshot["errors"]:
        print("Unavailable endpoints: " + ", ".join(snapshot["errors"]), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
