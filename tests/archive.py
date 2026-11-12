#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
"""Usage: archive.py OUTPUT KEYRING VERSION [ARCHIVE_URL]"""
import hashlib
import lzma
from pathlib import Path
import subprocess
import sys
import urllib.request

out, key, version = Path(sys.argv[1]), Path(sys.argv[2]).resolve(), sys.argv[3]
out.mkdir(parents=True, exist_ok=True)
base = (sys.argv[4] if len(sys.argv) > 4 else 'https://blueberrypieos.com/apt/').rstrip('/') + '/'

def get(path):
    req = urllib.request.Request(base + path, headers={'User-Agent': 'PIE-tests'})
    with urllib.request.urlopen(req, timeout=120) as response:
        return response.read()

def fields(text):
    result = {}
    name = None
    for line in text.splitlines():
        if line.startswith((' ', '\t')) and name:
            result[name] += '\n' + line
        elif ':' in line:
            name, value = line.split(':', 1)
            result[name] = value.strip()
    return result

signed = out / 'InRelease'
signed.write_bytes(get('dists/blueberry-pie-os/InRelease'))
with (out / 'signature.txt').open('w') as log:
    subprocess.run(['gpgv', '--status-fd=1', '--keyring', str(key), '--output',
                    str(out / 'Release'), str(signed)], stdout=log, stderr=log, check=True)
release = fields((out / 'Release').read_text())
assert 'blueberry-pie-os' in (release.get('Suite'), release.get('Codename')), 'Release is for another suite'
hashes = {p: (h, int(s)) for h, s, p in
          (line.split() for line in release['SHA256'].splitlines() if line.strip())}
selected = []
for component in release['Components'].split():
    path = component + '/binary-darwin-arm64/Packages.xz'
    expected, size = hashes[path]
    if release.get('Acquire-By-Hash') == 'yes':
        data = get('dists/blueberry-pie-os/' + path.rsplit('/', 1)[0] + '/by-hash/SHA256/' + expected)
    else:
        data = get('dists/blueberry-pie-os/' + path)
    assert len(data) == size and hashlib.sha256(data).hexdigest() == expected, path
    (out / (component + '-Packages.xz')).write_bytes(data)
    text = lzma.decompress(data).decode()
    (out / (component + '-Packages')).write_text(text)
    for block in text.strip().split('\n\n'):
        item = fields(block)
        if item.get('Package') == 'blueberry-pie-os-kernel' and item.get('Version') == version:
            selected.append(item)
assert len(selected) == 1, 'kernel version missing or ambiguous'
item = selected[0]
(out / 'kernel-stanza.txt').write_text('\n'.join(k + ': ' + v for k, v in item.items()) + '\n')
filename = item['Filename']
assert not filename.startswith('/') and '..' not in filename.split('/')
deb = get(filename)
actual = hashlib.sha256(deb).hexdigest()
assert actual == item['SHA256'] and len(deb) == int(item['Size']), 'deb hash or size'
(out / 'kernel.deb').write_bytes(deb)
print('Verified signed indexes and kernel deb:', filename, actual)
subprocess.run(['dpkg-deb', '-x', str(out / 'kernel.deb'), str(out / 'extracted')], check=True)
