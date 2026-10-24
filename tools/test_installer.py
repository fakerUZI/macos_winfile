#!/usr/bin/env python3
"""Exercise the installer with a local signed release; no network or user apps touched."""
from pathlib import Path
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ARCHIVE = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / 'dist/WinFile.zip').resolve()
if sys.platform != 'darwin':
    raise SystemExit('Installer integration tests require macOS.')
assert ARCHIVE.is_file(), 'Build dist/WinFile.zip first.'
with tempfile.TemporaryDirectory(prefix='winfile-installer-test-') as temporary:
    base = Path(temporary)
    fixtures = base / 'fixtures'
    fixtures.mkdir()
    shutil.copy2(ARCHIVE, fixtures / 'WinFile.zip')
    digest = hashlib.sha256(ARCHIVE.read_bytes()).hexdigest()
    checksum = fixtures / 'WinFile.zip.sha256'
    checksum.write_text(digest + '  WinFile.zip\n')
    commands = base / 'bin'
    commands.mkdir()
    scripts = {
        'curl': '#!/bin/bash\nset -eu\nurl=""; output=""\nwhile [ "$#" -gt 0 ]; do\n case "$1" in https://*) url="$1"; shift;; -o) output="$2"; shift 2;; *) shift;; esac\ndone\ncp "$FIXTURES/${url##*/}" "$output"\n',
        'pgrep': '#!/bin/bash\nexit "${SIMULATE_RUNNING:-1}"\n',
    }
    for name, body in scripts.items():
        path = commands / name
        path.write_text(body)
        path.chmod(0o755)
    env = dict(os.environ, PATH=str(commands) + ':' + os.environ['PATH'], FIXTURES=str(fixtures))
    def run(directory, success=True, **changes):
        result = subprocess.run(['/bin/bash', str(ROOT / 'install.sh'), '--dir', str(directory), '--no-open'],
                                env=dict(env, **changes), capture_output=True, text=True)
        assert (result.returncode == 0) == success, result.stdout + result.stderr
        assert not list(directory.glob('.WinFile-install.*')), 'Staging was left behind'
        return result
    target = base / 'fresh install'
    run(target)
    installed = target / 'LeafFiles.app'
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(installed)], check=True)
    print('PASS: verified first install, including a directory with spaces')
    (installed / 'previous-version.txt').write_text('keep this backup')
    run(target)
    backups = list((target / '.WinFile-backups').glob('*.app'))
    assert len(backups) == 1 and (backups[0] / 'previous-version.txt').read_text() == 'keep this backup'
    print('PASS: update preserves the complete previous app')
    sentinel = installed / 'untouched.txt'
    sentinel.write_text('old app')
    checksum.write_text('0' * 64 + '  WinFile.zip\n')
    run(target, success=False)
    assert sentinel.read_text() == 'old app'
    print('PASS: checksum mismatch leaves the installed app untouched')
    checksum.write_text(digest + '  WinFile.zip\n')
    run(target, success=False, SIMULATE_RUNNING='0')
    assert sentinel.read_text() == 'old app'
    print('PASS: a running app prevents replacement')
    # Corrupt only the newly moved app to exercise failure after replacement.
    move_wrapper = commands / 'mv'
    move_wrapper.write_text('#!/bin/bash\nset -e\n/bin/mv "$@"\ncase "$1" in */.WinFile-install.*/LeafFiles.app) printf invalid > "$2/Contents/MacOS/WinFile";; esac\n')
    move_wrapper.chmod(0o755)
    before = (installed / 'Contents/MacOS/WinFile').read_bytes()
    run(target, success=False)
    assert sentinel.read_text() == 'old app'
    assert (installed / 'Contents/MacOS/WinFile').read_bytes() == before
    move_wrapper.unlink()
    print('PASS: post-install verification failure rolls back the previous app')
    # An invalid signed bundle must fail before moving the old app.
    original = (fixtures / 'WinFile.zip').read_bytes()
    bad = base / 'bad';bad.mkdir()
    subprocess.run(['/usr/bin/ditto', '-x', '-k', str(ARCHIVE), str(bad)], check=True)
    bundle = next(bad.glob('*.app'))
    (bundle / 'Contents/MacOS/WinFile').write_bytes(b'invalid executable')
    subprocess.run(['/usr/bin/ditto', '-c', '-k', '--keepParent', str(bundle), str(fixtures / 'WinFile.zip')], check=True)
    checksum.write_text(hashlib.sha256((fixtures / 'WinFile.zip').read_bytes()).hexdigest() + '  WinFile.zip\n')
    run(target, success=False)
    assert sentinel.read_text() == 'old app'
    print('PASS: invalid code signature leaves the installed app untouched')
    (fixtures / 'WinFile.zip').write_bytes(original)
    checksum.write_text(hashlib.sha256(original).hexdigest() + '  WinFile.zip\n')
    # Migrate a legacy installation, including rollback after the new move.
    migration = base / 'legacy migration'; migration.mkdir()
    legacy = migration / 'WinFile.app'
    shutil.copytree(installed, legacy)
    legacy_sentinel = legacy / 'legacy-marker.txt'; legacy_sentinel.write_text('legacy data')
    move_wrapper.write_text('#!/bin/bash\nset -e\n/bin/mv "$@"\ncase "$1" in */.WinFile-install.*/LeafFiles.app) printf invalid > "$2/Contents/MacOS/WinFile";; esac\n')
    move_wrapper.chmod(0o755)
    run(migration, success=False)
    assert legacy_sentinel.read_text() == 'legacy data' and not (migration / 'LeafFiles.app').exists()
    move_wrapper.unlink()
    print('PASS: failed legacy migration restores the original WinFile.app path')
    run(migration)
    assert (migration / 'LeafFiles.app').is_dir() and not legacy.exists()
    assert any((p / 'legacy-marker.txt').is_file() for p in (migration / '.WinFile-backups').glob('*.app'))
    print('PASS: successful legacy migration installs only LeafFiles.app and backs up WinFile.app')
    # Both historical names may already exist. Back up both, leaving one live app.
    shutil.copytree(migration / 'LeafFiles.app', legacy)
    run(migration)
    assert not legacy.exists() and (migration / 'LeafFiles.app').is_dir()
    print('PASS: coexisting old and new names are consolidated')
    # A legacy symlink must not be followed or removed.
    legacy.symlink_to(migration / 'LeafFiles.app', target_is_directory=True)
    run(migration, success=False)
    assert legacy.is_symlink()
    legacy.unlink()
    print('PASS: legacy symbolic link is rejected without replacement')
    # Failure during replacement restores both preexisting directories.
    shutil.copytree(migration / 'LeafFiles.app', legacy)
    (legacy / 'both-old.txt').write_text('old')
    (migration / 'LeafFiles.app/both-new.txt').write_text('new')
    move_wrapper.write_text('#!/bin/bash\nset -e\n/bin/mv "$@"\ncase "$1" in */.WinFile-install.*/LeafFiles.app) printf invalid > "$2/Contents/MacOS/WinFile";; esac\n')
    move_wrapper.chmod(0o755)
    run(migration, success=False)
    assert (legacy / 'both-old.txt').read_text() == 'old'
    assert (migration / 'LeafFiles.app/both-new.txt').read_text() == 'new'
    move_wrapper.unlink()
    print('PASS: failed consolidation restores both original application directories')
print('11 installer integration scenarios passed.')
