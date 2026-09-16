#!/usr/bin/env python3
"""Bounded credential scan and Maker-style source hygiene; never print matches."""
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PATTERNS = [
    rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
    rb'gh[pousr]_[A-Za-z0-9]{30,}',
    rb'github_pat_[A-Za-z0-9_]{60,}',
    rb'https?://[^\s"\'<>]*(?:alchemy\.com/v2/|infura\.io/v3/)[A-Za-z0-9_-]{16,}',
    rb'(?im)^(?:export\s+)?(?:ETH_RPC|PRIVATE_KEY|API_KEY|SECRET_KEY)\s*=\s*["\']?(?:https?://|0x[0-9a-fA-F]{64})',
]


def main():
    names = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others',
                                     '--exclude-standard'], cwd=ROOT).decode().split('\0')
    errors = []
    for name in filter(None, names):
        path = ROOT / name
        if name.startswith('lib/') or not path.is_file():
            continue
        raw = path.read_bytes()
        if Path(name).name == '.env' or Path(name).name.startswith('.env.'):
            errors.append(f'{name}: environment file must not be published')
        if any(re.search(pattern, raw) for pattern in PATTERNS):
            errors.append(f'{name}: credential pattern detected (value suppressed)')
        if path.suffix in ('.sol', '.py', '.yml', '.toml'):
            if not raw.endswith(b'\n') or b'\r' in raw or b'\t' in raw:
                errors.append(f'{name}: use spaces and LF with a final newline')
            if any(line.rstrip(b' ') != line for line in raw.splitlines()):
                errors.append(f'{name}: trailing whitespace')
    # Scan reachable first-party history, including deleted files, without
    # printing blob contents or matches. This is a pattern gate, not an audit.
    objects = subprocess.check_output(['git', 'rev-list', '--objects', '--all'], cwd=ROOT).decode().splitlines()
    count = 0
    for entry in objects:
        oid, _, name = entry.partition(' ')
        if not name or name.startswith('lib/'):
            continue
        kind = subprocess.check_output(['git', 'cat-file', '-t', oid], cwd=ROOT).strip()
        if kind != b'blob':
            continue
        raw = subprocess.check_output(['git', 'cat-file', 'blob', oid], cwd=ROOT)
        count += 1
        if any(re.search(pattern, raw) for pattern in PATTERNS):
            errors.append(f'history {oid[:12]} ({name}): credential pattern detected (value suppressed)')
    if errors:
        raise SystemExit('\n'.join(errors))
    print(f'Source hygiene and credential patterns passed; {count} historical blobs scanned.')


if __name__ == '__main__':
    main()
