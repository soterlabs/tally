#!/usr/bin/env python3
"""Run the local archive-fork permission rehearsal without logging RPC errors."""
import os
import subprocess
from pathlib import Path


def main():
    if not os.environ.get('ETH_RPC'):
        raise SystemExit('Set ETH_RPC to an archive endpoint')
    run = subprocess.run(['forge', 'test', '--match-contract', '^PermissionsForkTest$', '-vv'],
                         cwd=Path(__file__).resolve().parents[1], capture_output=True, text=True)
    if run.returncode:
        raise SystemExit('Permission rehearsal failed. Inspect with forge locally; provider diagnostics suppressed.')
    print('Allocator permissions fork passed: draw, buffer allowance, pay, join and revocation.')


if __name__ == '__main__':
    main()
