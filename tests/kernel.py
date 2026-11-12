#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-2-Clause
# Copyright (c) 2026 The Blueberry Pie OS Authors
"""Usage: kernel.py BUNDLE OUTPUT [CONSOLE]"""
import hashlib
import json
from pathlib import Path
import re
import struct
import sys
import uuid

bundle, out = Path(sys.argv[1]), Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
b = bundle.read_bytes()
assert b[:8] == b'PIEBUNDL'
version, count = struct.unpack_from('<II', b, 8)
assert version == 2 and count < 100
result = {}
for index in range(count):
    name, offset, size = struct.unpack_from('<16sQQ', b, 16 + 32 * index)
    name = name.split(b'\0')[0].decode()
    assert '/' not in name and name not in ('.', '..')
    assert offset + size <= len(b)
    data = b[offset:offset + size]
    (out / name).write_bytes(data)
    item = {'sha256': hashlib.sha256(data).hexdigest(), 'offset': offset, 'size': size}
    if name.startswith('kernel.'):
        assert data[:4] == b'\xcf\xfa\xed\xfe'
        ncmds = struct.unpack_from('<I', data, 16)[0]
        pos = 32
        for _ in range(ncmds):
            cmd, length = struct.unpack_from('<II', data, pos)
            assert length >= 8 and pos + length <= len(data)
            if cmd == 0x1b:
                item['uuid'] = str(uuid.UUID(bytes=data[pos + 8:pos + 24])).upper()
            pos += length
        match = re.search(rb'Darwin Kernel Version [^\0\n]+', data)
        assert match is not None and 'uuid' in item
        item['uname'] = match.group().decode()
    result[name] = item
(out / 'identity.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
if len(sys.argv) > 3:
    console = Path(sys.argv[3]).read_text(errors='replace')
    match = re.search(r'pieboot: kernel (bcm\d+)', console)
    assert match, 'no pieboot kernel selection in console'
    selected = result['kernel.' + match[1]]
    assert selected['uname'] in console, 'console version differs'
    if 'Kernel UUID:' in console:
        assert 'Kernel UUID: ' + selected['uuid'] in console
    print('Console selection and version match bundle member kernel.' + match[1])
