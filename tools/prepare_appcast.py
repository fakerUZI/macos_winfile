#!/usr/bin/env python3
"""Package a verified WinFile build and sign its GitHub Release appcast."""
import argparse
import base64
import hashlib
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

REPOSITORY = "https://github.com/fakerUZI/macos_winfile"
ACCOUNT = "local.winfile.mac"
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def verify_signatures(archive, feed, signature, public_key, stage):
    verifier = stage / "verify_update"
    subprocess.run(["/usr/bin/swiftc", str(pathlib.Path(__file__).with_name("verify_update.swift")),
                    "-o", str(verifier)], check=True)
    def verify(path, ed_signature):
        if len(base64.b64decode(ed_signature, validate=True)) != 64:
            raise ValueError("Invalid Ed25519 signature")
        subprocess.run([str(verifier), public_key, str(path), ed_signature], check=True)
    verify(archive, signature)
    data = feed.read_bytes()
    signed, separator, trailer = data.rpartition(b"<!-- sparkle-signatures:\n")
    match = re.fullmatch(rb"edSignature: ([A-Za-z0-9+/=]+)\nlength: ([0-9]+)\n-->\s*", trailer)
    if not separator or not match or int(match[2]) != len(signed):
        raise ValueError("Malformed signed appcast")
    payload = stage / "appcast-payload.xml"
    payload.write_bytes(signed)
    verify(payload, match[1].decode("ascii"))


def prepare(app, sdk, destination, notes=None):
    app, sdk, destination = map(pathlib.Path, (app, sdk, destination))
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != ACCOUNT:
        raise ValueError("Release app must have the production bundle identifier")
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", version) or not re.fullmatch(r"[0-9]+", build):
        raise ValueError("Invalid release version/build")
    public_key = subprocess.check_output([str(sdk / "bin/generate_keys"), "--account", ACCOUNT, "-p"], text=True).strip()
    if public_key != info.get("SUPublicEDKey"):
        raise ValueError("The Keychain signing key does not match this app's public key; do not rotate it implicitly")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="winfile-appcast-") as work:
        stage = pathlib.Path(work)
        # Public download URLs remain stable, but the app inside the archive has the new name.
        release_app = stage / "LeafFiles.app"
        subprocess.run(["/usr/bin/ditto", "--noextattr", "--norsrc", str(app), str(release_app)], check=True)
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(release_app)], check=True)
        archive = stage / f"WinFile-{version}.zip"
        subprocess.run(["/usr/bin/ditto", "-c", "-k", "--keepParent", "--noextattr", "--norsrc", str(release_app), str(archive)], check=True)
        if notes:
            shutil.copyfile(notes, archive.with_suffix(pathlib.Path(notes).suffix))
        feed = stage / "appcast.xml"
        subprocess.run([str(sdk / "bin/generate_appcast"), "--account", ACCOUNT,
                        "--download-url-prefix", f"{REPOSITORY}/releases/download/v{version}/",
                        "--maximum-deltas", "0", "--maximum-versions", "1", "--embed-release-notes",
                        "-o", str(feed), str(stage)], check=True)
        enclosure = ET.parse(feed).find("./channel/item/enclosure")
        signature = enclosure.get(f"{{{SPARKLE}}}edSignature") if enclosure is not None else None
        if not signature or enclosure.get("url") != f"{REPOSITORY}/releases/download/v{version}/{archive.name}":
            raise ValueError("Appcast has no signed immutable release asset")
        if int(enclosure.get("length", "0")) != archive.stat().st_size:
            raise ValueError("Appcast archive length mismatch")
        verify_signatures(archive, feed, signature, public_key, stage)
        # Nothing in dist is replaced until the archive and feed are signed and verified.
        for name in [archive.name, "WinFile.zip"]:
            shutil.copyfile(archive, destination / name)
            (destination / f"{name}.sha256").write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + "  " + name + "\n")
        shutil.copyfile(feed, destination / feed.name)
    return version, build


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True)
    parser.add_argument("--sdk", required=True)
    parser.add_argument("--dist", required=True)
    parser.add_argument("--notes")
    args = parser.parse_args()
    version, build = prepare(args.app, args.sdk, args.dist, args.notes)
    print(f"Signed WinFile {version} ({build}): upload appcast.xml, WinFile-{version}.zip, WinFile.zip and both SHA-256 files")


if __name__ == "__main__":
    main()
