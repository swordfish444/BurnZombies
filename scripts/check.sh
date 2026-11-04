#!/bin/bash
# Checks that need no compiler, done in seconds on any machine. GitHub runs these on every pull
# request; scripts/test.sh runs them before the build and the quick proofs.
set -euo pipefail
cd "$(dirname "$0")/.."
for script in install.sh scripts/*.sh; do bash -n "$script"; done
PYTHONPYCACHEPREFIX="$(mktemp -d)" python3 -m py_compile scripts/*.py
python3 - <<'PY'
import json, pathlib, re, sys

def read(path):
    return pathlib.Path(path).read_text()

def pin(path, pattern):
    match = re.search(pattern, read(path), re.M)
    if not match:
        sys.exit(f"FAIL: no version found in {path}")
    return match.group(1)

problems = []
# A release bumps all four together; install.sh downloads the release it names.
versions = {
    "Sources/BurnCore/BuildIdentity.swift": pin("Sources/BurnCore/BuildIdentity.swift", r'version = "([^"]+)"'),
    "install.sh": pin("install.sh", r'^version="([^"]+)"'),
    "scripts/build-app.sh": pin("scripts/build-app.sh", r"CFBundleShortVersionString</key><string>([^<]+)<"),
    "packaging/mcpb/manifest.json": json.loads(read("packaging/mcpb/manifest.json"))["version"],
}
if len(set(versions.values())) != 1:
    problems.append("versions differ: " + ", ".join(f"{k} {v}" for k, v in versions.items()))
builds = {
    "Sources/BurnCore/BuildIdentity.swift": pin("Sources/BurnCore/BuildIdentity.swift", r'build = "([^"]+)"'),
    "scripts/build-app.sh": pin("scripts/build-app.sh", r"CFBundleVersion</key><string>([^<]+)<"),
}
if len(set(builds.values())) != 1:
    problems.append("build numbers differ: " + ", ".join(f"{k} {v}" for k, v in builds.items()))
# Every relative link and image in the docs points at a file that exists.
for doc in ["README.md", "CONTRIBUTING.md", "SECURITY.md", *sorted(map(str, pathlib.Path("docs").glob("*.md")))]:
    for groups in re.findall(r'\]\(([^)\s]+)\)|src="([^"]+)"|srcset="([^"]+)"', read(doc)):
        target = next(g for g in groups if g)
        if re.match(r"(https?:|mailto:|#)", target):
            continue
        if not (pathlib.Path(doc).parent / target.split("#")[0]).exists():
            problems.append(f"broken link in {doc}: {target}")
for problem in problems:
    print("FAIL: " + problem)
if problems:
    sys.exit(1)
print("PASS scripts parse, versions agree, doc links resolve")
PY
