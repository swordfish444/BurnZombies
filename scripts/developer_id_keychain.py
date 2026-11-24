"""Save and restore the dedicated BurnZombies Developer ID keychain in the maintainer vault."""
import argparse
import base64
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

TEAM = "7K3GR5QJRH"
IDENTITY = f"Developer ID Application: skylar graika ({TEAM})"
REQUIREMENT = (f'=anchor apple generic and certificate leaf[subject.OU] = "{TEAM}" '
               'and certificate leaf[field.1.2.840.113635.100.6.1.13] exists')
TITLE = "BurnZombies Developer ID Application signing identity"
NOTARY = "BurnZombies Apple Notarization API Key"
SERVICE = "BurnZombies Developer ID signing keychain"
KEYCHAIN = Path.home() / "Library/Keychains/BurnZombies-Developer-ID.keychain-db"
VAULT = os.environ.get("BURNZOMBIES_OP_VAULT", "skylar")


def run(*args, data=None):
    # Errors may contain process arguments. Report the operation without credentials.
    result = subprocess.run(args, input=data, capture_output=True)
    if result.returncode:
        raise SystemExit(f"{Path(args[0]).name} {args[1]} failed ({result.returncode}): "
                         + result.stderr.decode(errors="replace")[:400])
    return result.stdout


def op(*args, data=None):
    return run("op", *args, "--vault", VAULT, data=data)


def prove(keychain, password, temp):
    run("security", "unlock-keychain", "-p", password, keychain)
    identities = run("security", "find-identity", "-v", "-p", "codesigning", keychain).decode()
    if f'"{IDENTITY}"' not in identities or "1 valid identities found" not in identities:
        raise SystemExit("Expected exactly the BurnZombies Developer ID identity.")
    probe = temp / "probe"
    shutil.copyfile("/usr/bin/true", probe)
    run("codesign", "--force", "--sign", IDENTITY, "--keychain", keychain, "--timestamp=none", probe)
    run("codesign", "--verify", "--strict", "-R", REQUIREMENT, probe)


def unpack(document, destination):
    with destination.open("xb") as output:
        output.write(base64.b64decode(document["keychain"], validate=True))


def save(temp):
    # Only this isolated keychain may be backed up. Reject additional keys and password items.
    classes = sorted(line.split()[1] for line in run("security", "dump-keychain", KEYCHAIN)
                     .decode(errors="replace").splitlines() if line.startswith("class:"))
    if classes != ["0x00000010", "0x80001000", "0x80001000"]:
        raise SystemExit("Expected one private key and two certificates in the dedicated keychain.")
    password = run("security", "find-generic-password", "-s", SERVICE, "-w").decode().strip()
    prove(KEYCHAIN, password, temp)
    items = json.loads(op("document", "list", "--format", "json"))
    if not any(item["title"] == TITLE for item in items):
        document = json.dumps({"keychain": base64.b64encode(KEYCHAIN.read_bytes()).decode(),
                               "password": password}).encode()
        op("document", "create", "-", "--title", TITLE, "--file-name", "Developer-ID-keychain.json",
           "--tags", "BurnZombies,Apple", data=document)
    saved = json.loads(op("document", "get", TITLE))
    copy = temp / "restored.keychain-db"
    unpack(saved, copy)
    prove(copy, saved["password"], temp)
    original = run("security", "find-identity", "-v", "-p", "codesigning", KEYCHAIN)
    restored = run("security", "find-identity", "-v", "-p", "codesigning", copy)
    if original != restored:
        raise SystemExit("The saved identity differs from the installed identity.")
    print("Verified signing with the restored 1Password backup.")


def load(temp):
    document = json.loads(op("document", "get", TITLE))
    copy = temp / "restored.keychain-db"
    unpack(document, copy)
    prove(copy, document["password"], temp)
    if not KEYCHAIN.exists():
        unpack(document, KEYCHAIN)
        run("security", "add-generic-password", "-s", SERVICE, "-a", os.environ["USER"],
            "-w", document["password"])
    prove(KEYCHAIN, document["password"], temp)
    paths = shlex.split(run("security", "list-keychains", "-d", "user").decode())
    if str(KEYCHAIN) not in paths:
        run("security", "list-keychains", "-d", "user", "-s", *paths, str(KEYCHAIN))
    private_key = temp / "notary.p8"
    private_key.write_bytes(op("document", "get", NOTARY))
    key_id = op("item", "get", NOTARY, "--fields", "label=Apple Key ID").decode().strip()
    issuer = op("item", "get", NOTARY, "--fields", "label=Apple Issuer ID").decode().strip()
    run("xcrun", "notarytool", "store-credentials", "burnzombies-notary", "--key", private_key,
        "--key-id", key_id, "--issuer", issuer)
    print("Verified Developer ID signing and stored Apple's validated notarization profile.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("save", "load"))
    args = parser.parse_args()
    os.umask(0o077)
    if not os.environ.get("OP_SERVICE_ACCOUNT_TOKEN"):
        os.environ["OP_SERVICE_ACCOUNT_TOKEN"] = run("security", "find-generic-password", "-s",
            os.environ.get("BURNZOMBIES_OP_TOKEN_ITEM", "codex-1password-service-account-token"),
            "-w").decode().strip()
    with tempfile.TemporaryDirectory(prefix="burnzombies-signing-") as directory:
        (save if args.action == "save" else load)(Path(directory))
