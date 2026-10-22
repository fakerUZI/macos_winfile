#!/usr/bin/env python3
"""Real MTP protocol regression; only touches a unique generated fixture directory."""
import argparse
import base64
import json
import os
import signal
from pathlib import Path
import subprocess
import tempfile
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--helper', required=True)
parser.add_argument('--filename', default="中文 ' 100% #? 😀.txt",
                    help='Generated sample filename; some MTP devices reject special characters.')
args = parser.parse_args()
if Path(args.filename).name != args.filename or args.filename in ('', '.', '..'):
    parser.error('--filename must be a single filename')
helper = str(Path(args.helper).resolve())
passed = 0

def request(op, **values):
    child = subprocess.run([helper], input=json.dumps(dict(op=op, **values)), text=True,
                           capture_output=True, timeout=90, env=dict(os.environ, PATH='/usr/bin:/bin'))
    records = [json.loads(line) for line in child.stdout.splitlines()]
    return records[-1]

def check(name, value):
    global passed
    if not value:
        raise AssertionError(name)
    passed += 1
    print('PASS', name, flush=True)

scan = request('scan')['result']['devices']
ready = [d for d in scan if d['state'] == 'device']
if not ready:
    raise SystemExit('No MTP-ready device; unlock phone and select File Transfer.')
device = ready[0]
base = dict(serial=device['serial'], transport=device['transportID'])
root = device['storages'][0]['path']
fixture = root + '/WinFile-MTP-QA-' + str(uuid.uuid4())
def call(op, path=fixture, **values):
    reply = request(op, path=path, **base, **values)
    if 'error' in reply:
        raise RuntimeError(op + ': ' + reply['error'])
    return reply['result']

def error(op, expected, path=fixture, **values):
    reply = request(op, path=path, **base, **values)
    check(op + ' rejects ' + expected, reply.get('error') == expected)

with tempfile.TemporaryDirectory(prefix='WinFile-MTP-QA-') as temporary:
    local = Path(temporary)
    call('mkdir')
    try:
        check('MTP ready with a restricted PATH and no ADB lookup', call('stat')['entry']['isDirectory'])
        check('storage root accepts trailing directory slash',
              call('stat', root + '/')['entry']['objectID'] == 0)
        check('storage root listing accepts trailing directory slash',
              any(e['path'] == fixture for e in call('list', root + '/')['entries']))
        check('nested directory accepts trailing and repeated separators',
              call('list', fixture.replace('/', '//') + '///')['entries'] == [])
        check('device root accepts repeated separators',
              any(e['path'] == root for e in call('list', '///')['entries']))
        error('stat', 'invalidPath', fixture + '/./')
        error('stat', 'invalidPath', fixture + '/../')
        error('delete', 'storageRoot', root + '/')
        for i in range(20):
            check('stable attachment and listing %d' % i,
                  call('list').get('entries') == [] and device['transportID'] in request('presence')['result']['transports'])
        filename = args.filename
        sample = local / filename
        payload = 'WinFile MTP 测试\n'.encode() + bytes(range(256)) * 32
        sample.write_bytes(payload)
        sent = call('push', local=str(sample))['entry']
        check('upload returns an MTP object identity', sent['objectID'] > 0 and sent['storageID'] > 0)
        entries = call('list')['entries']
        check('requested filename survives', any(e['name'] == filename and e['size'] == len(payload) for e in entries))
        stream = call('streamInfo', sent['path'])['entry']
        expected = {key: stream[key] for key in ['objectID', 'storageID', 'size', 'modified']}
        for offset, length in [(0, 17), (1027, 29), (len(payload)-7, 50), (len(payload), 1)]:
            part = call('read', sent['path'], offset=offset, length=length, **expected)
            check('partial read returns exact bytes at %d' % offset,
                  base64.b64decode(part['bytes']) == payload[offset:offset+length])
        error('read', 'range', sent['path'], offset=-1, length=10, **expected)
        error('read', 'range', sent['path'], offset=0, length=1024*1024+1, **expected)
        changed = dict(expected, objectID=expected['objectID']+1)
        error('read', 'fileChanged', sent['path'], offset=0, length=10, **changed)
        error('push', 'exists', local=str(sample))
        call('pull', sent['path'], local=str(local / 'back.bin'))
        check('download is byte-identical', (local / 'back.bin').read_bytes() == payload)
        error('rename', 'invalidName', sent['path'], name='../escape')
        error('stat', 'invalidPath', fixture + '/../escape')
        error('delete', 'storageRoot', root)
        call('rename', sent['path'], name='renamed.txt')
        check('renamed file remains accessible', call('stat', fixture + '/renamed.txt')['entry']['size'] == len(payload))
        call('touch', fixture + '/empty.txt')
        check('zero-byte file supported', call('stat', fixture + '/empty.txt')['entry']['size'] == 0)
        tree = local / 'Tree'
        (tree / 'Nested').mkdir(parents=True)
        (tree / 'Nested' / 'leaf.txt').write_text('nested test', encoding='utf-8')
        call('push', local=str(tree))
        call('rename', fixture + '/Tree', name='Renamed Tree')
        call('pull', fixture + '/Renamed Tree', local=str(local / 'tree-back'))
        check('recursive upload, folder rename and download', (local / 'tree-back/Nested/leaf.txt').read_text() == 'nested test')
        call('mkdir', fixture + '/Destination')
        moved = request('move', path=fixture + '/renamed.txt', target=fixture + '/Destination', **base)
        if moved.get('error') == 'unsupportedMove':
            check('unsupported move preserves source', call('stat', fixture + '/renamed.txt')['entry']['size'] == len(payload))
        else:
            check('device-supported move succeeds', 'result' in moved)
            check('moved content remains intact', call('stat', fixture + '/Destination/renamed.txt')['entry']['size'] == len(payload))
        (local / 'Link').symlink_to(sample)
        error('push', 'localRead', local=str(local / 'Link'))
        large = local / 'cancelled-upload.bin'
        with large.open('wb') as stream:
            stream.truncate(64 * 1024 * 1024)
        child = subprocess.Popen([helper], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True)
        child.stdin.write(json.dumps(dict(base, op='push', path=fixture, local=str(large))))
        child.stdin.close()
        child.stdin = None
        first = json.loads(child.stdout.readline())
        check('transfer progress is delivered before completion', 'progress' in first and first['progress'] < 1)
        child.send_signal(signal.SIGTERM)
        try:
            output, _ = child.communicate(timeout=8)
        except subprocess.TimeoutExpired:
            child.kill()
            child.communicate()
            raise RuntimeError('Device did not finish direct-helper upload cancellation within 8 seconds; child killed.')
        check('real upload cancellation completes', json.loads(output.splitlines()[-1]).get('error') == 'cancelled')
        check('cancelled upload removes its partial object', not any(e['name'] == large.name for e in call('list')['entries']))
        call('delete', fixture + '/empty.txt')
        error('stat', 'notFound', fixture + '/empty.txt')
    finally:
        # Cancellation can interrupt USB or leave a helper busy until killed.
        # Re-discover only this same serial for cleanup of our unique fixture.
        fresh = request('scan').get('result', {}).get('devices', [])
        attached = next((d for d in fresh if d['serial'] == device['serial'] and d['state'] == 'device'), None)
        if attached:
            base['transport'] = attached['transportID']
        call('delete')
    error('stat', 'notFound')
print('MTP helper regression:', passed, 'passed, 0 failed', flush=True)
