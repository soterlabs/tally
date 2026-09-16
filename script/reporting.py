"""Shared report output and frozen MSC-input verification (standard library)."""
import csv
import hashlib
import io
import json
from pathlib import Path
import os
import tempfile

BASELINE = Path(__file__).resolve().parents[1] / 'test/fixtures/msc'


def verify_baseline(root):
    """Verify packaged inputs; a caller-supplied MSC checkout is explicitly unpinned."""
    if root.resolve() != BASELINE.resolve():
        return
    manifest = json.loads((root / 'manifest.json').read_text())
    for name, expected in manifest['files'].items():
        actual = hashlib.sha256((root / name).read_bytes()).hexdigest()
        if actual != expected:
            raise ValueError(f'MSC fixture checksum mismatch: {name}')


class Outputs:
    """Buffer all artifacts until validation completes; replace each file atomically.

    Publication across several files is not a filesystem transaction. A process
    crash during commit can leave a mixed set; rerun the command to repair it.
    """
    def __init__(self, root):
        self.root = root
        self.pending = {}

    def text(self, name, content):
        self.pending[name] = content

    def csv(self, name, rows):
        handle = io.StringIO(newline='')
        writer = csv.DictWriter(handle, fieldnames=rows[0].keys(), lineterminator='\n')
        writer.writeheader()
        writer.writerows(rows)
        self.text(name, handle.getvalue())

    def commit(self):
        self.root.mkdir(parents=True, exist_ok=True)
        for name, content in self.pending.items():
            path = self.root / name
            temporary = None
            try:
                with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=self.root,
                                                 delete=False) as handle:
                    temporary = Path(handle.name)
                    handle.write(content)
                os.replace(temporary, path)
            finally:
                if temporary is not None:
                    temporary.unlink(missing_ok=True)
