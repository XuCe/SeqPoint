#!/usr/bin/env python3
"""Collect pinned native dependencies, including platform-specific modules."""
import json
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent
os.environ['GOTOOLCHAIN'] = next(line.split()[1] for line in
    (root / 'go.mod').read_text().splitlines() if line.startswith('toolchain '))

def go(*args):
    return subprocess.check_output(['go', *args], cwd=root, text=True)

def escape(value):
    return ''.join('!' + c.lower() if c.isupper() else c for c in value)

subprocess.run(['go', 'mod', 'download'], cwd=root, check=True)
required = sorted(item['Path'] for item in json.loads(go('mod', 'edit', '-json'))['Require'])
raw = go('list', '-m', '-json', *required)
decoder = json.JSONDecoder()
parts = [root.joinpath('NOTICE.md').read_text(), root.joinpath('LICENSE').read_text()]
while raw.strip():
    module, end = decoder.raw_decode(raw.lstrip())
    raw = raw.lstrip()[end:]
    directory = Path(module['Dir'])
    files = sorted(p for p in directory.iterdir() if p.is_file() and
        p.name.upper().startswith(('LICENSE', 'LICENCE', 'COPYING', 'NOTICE', 'COPYRIGHT')))
    if not files:
        raise RuntimeError('Missing license: ' + module['Path'])
    source = 'https://proxy.golang.org/' + escape(module['Path']) + '/@v/' + escape(module['Version']) + '.zip'
    parts.append('\nComponent: ' + module['Path'] + ' ' + module['Version'] + '\nSource: ' + source)
    parts.extend(p.name + '\n' + p.read_text() for p in files)
version = go('env', 'GOVERSION').strip()
go_root = Path(go('env', 'GOROOT').strip())
go_license = go_root / 'LICENSE'
if not go_license.exists():  # Homebrew keeps LICENSE next to libexec.
    go_license = go_root.parent / 'LICENSE'
parts += ['Go runtime: ' + version + '\nSource: https://go.dev/dl/' + version + '.src.tar.gz',
    go_license.read_text()]
output = root.parents[1] / 'apps/seqpoint_app/assets/licenses/syncthing.txt'
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text('\n\n'.join(parts) + '\n')
print(f'Wrote {len(required)} module notices and Go runtime license: {output}')
