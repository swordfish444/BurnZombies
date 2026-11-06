"""Disposable installer-test identity; never uses or replaces the release key."""
from contextlib import contextmanager
import hashlib
from pathlib import Path
import re
import secrets
import shlex
import subprocess

RELEASE_CERTIFICATE = "F6EE40DDEBB01F056DE8FC7910091F4FAC3D7B49"


def keychains():
    return shlex.split(subprocess.check_output(
        ["security", "list-keychains", "-d", "user"], text=True))


class SigningFixture:
    def __init__(self, root):
        self.root = Path(root)
        self.root.mkdir(mode=0o700)
        self.keychain = self.root / "fixture.keychain-db"
        self.password = secrets.token_hex(16)

    def run(self, *args):
        result = subprocess.run(args, capture_output=True)
        if result.returncode:
            error = result.stderr.decode(errors="replace").replace(self.password, "[redacted]")
            raise RuntimeError(f"{Path(args[0]).name} failed ({result.returncode}): {error}")
        return result

    def create(self):
        configuration = self.root / "openssl.cnf"
        configuration.write_text("""[req]
distinguished_name=dn
prompt=no
x509_extensions=v3
[dn]
CN=BurnZombies disposable installer fixture
[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
""")
        self.run("security", "create-keychain", "-p", self.password, str(self.keychain))
        self.run("security", "unlock-keychain", "-p", self.password, str(self.keychain))
        self.run("/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                 "-keyout", str(self.root / "key.pem"), "-out", str(self.root / "cert.pem"),
                 "-config", str(configuration))
        self.run("/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(self.root / "key.pem"),
                 "-in", str(self.root / "cert.pem"), "-out", str(self.root / "identity.p12"),
                 "-passout", "pass:" + self.password, "-name", "BurnZombies installer fixture",
                 "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1")
        self.run("security", "import", str(self.root / "identity.p12"), "-k", str(self.keychain),
                 "-P", self.password, "-T", "/usr/bin/codesign")
        self.run("security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
                 "-s", "-k", self.password, str(self.keychain))
        der = self.run("/usr/bin/openssl", "x509", "-in", str(self.root / "cert.pem"),
                       "-outform", "DER").stdout
        self.fingerprint = hashlib.sha1(der).hexdigest().upper()
        identities = self.run("security", "find-identity", "-p", "codesigning", str(self.keychain)).stdout
        assert self.fingerprint.encode() in identities, identities.decode(errors="replace")

    def sign(self, app):
        for binary in sorted((Path(app) / "Contents/MacOS").iterdir()):
            if binary.is_file():
                self.run("codesign", "--force", "--sign", self.fingerprint,
                         "--keychain", str(self.keychain), "--timestamp=none", str(binary))
        self.run("codesign", "--force", "--sign", self.fingerprint,
                 "--keychain", str(self.keychain), "--timestamp=none", str(app))

    def installer(self, source, destination):
        """Change one literal anchor in a private test copy; production has no override."""
        text = Path(source).read_text()
        pin = f'release_certificate="{RELEASE_CERTIFICATE}"'
        assert text.count(pin) == 1, "Production trust anchor changed; review the fixture"
        destination = Path(destination)
        destination.write_text(text.replace(pin, f'release_certificate="{self.fingerprint}"'))
        return destination


@contextmanager
def signing_fixture(root):
    before = keychains()
    default = subprocess.check_output(["security", "default-keychain", "-d", "user"])
    fixture = SigningFixture(root)
    try:
        fixture.create()
        yield fixture
    finally:
        if fixture.keychain.exists():
            subprocess.run(["security", "delete-keychain", str(fixture.keychain)],
                           check=True, capture_output=True)
        # Delete only the owned keychain. Never replace a possibly changed global search list.
        assert keychains() == before, "Fixture changed the keychain search list"
        assert subprocess.check_output(["security", "default-keychain", "-d", "user"]) == default


def production_pin(source):
    values = re.findall(r'^release_certificate="([0-9A-F]{40})"$', Path(source).read_text(), re.M)
    assert values == [RELEASE_CERTIFICATE], "Installer must keep one fixed release trust anchor"
