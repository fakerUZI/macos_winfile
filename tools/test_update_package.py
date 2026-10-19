#!/usr/bin/env python3
"""Verify a real release package and regression-test rejection of tampering (no private key)."""
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

from prepare_appcast import SPARKLE, verify_signatures

ROOT = pathlib.Path(__file__).resolve().parent.parent
INFO = plistlib.loads((ROOT / 'native/Info.plist').read_bytes())


class UpdatePackageTests(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory(prefix='winfile-signature-test-')
        self.addCleanup(self.workspace.cleanup)
        self.stage = pathlib.Path(self.workspace.name)
        self.archive = self.stage / 'update.zip'
        self.feed = self.stage / 'appcast.xml'
        shutil.copyfile(ROOT / 'dist' / f"WinFile-{INFO['CFBundleShortVersionString']}.zip", self.archive)
        shutil.copyfile(ROOT / 'dist/appcast.xml', self.feed)
        enclosure = ET.parse(self.feed).find('./channel/item/enclosure')
        self.signature = enclosure.get(f'{{{SPARKLE}}}edSignature')

    def verify(self):
        verify_signatures(self.archive, self.feed, self.signature, INFO['SUPublicEDKey'], self.stage)

    def test_signed_release(self):
        self.verify()

    def test_modified_archive(self):
        with self.archive.open('r+b') as archive:
            first = archive.read(1)
            archive.seek(0)
            archive.write(bytes([first[0] ^ 1]))
        with self.assertRaises(subprocess.CalledProcessError):
            self.verify()

    def test_modified_feed(self):
        original = self.feed.read_bytes()
        changed = original.replace(b'<channel>', b'<channeL>', 1)
        self.assertNotEqual(original, changed)
        self.feed.write_bytes(changed)
        with self.assertRaises(subprocess.CalledProcessError):
            self.verify()

    def test_false_payload_length(self):
        original = self.feed.read_bytes()
        self.feed.write_bytes(original.replace(b'\nlength: ', b'\nlength: 9', 1))
        with self.assertRaises(ValueError):
            self.verify()


if __name__ == '__main__':
    unittest.main()
