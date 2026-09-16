"""Offline acceptance tests: frozen MSC inputs, valid and corrupted fork logs."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'script'))
from compare_backtest import observations
from reporting import BASELINE, verify_baseline

COMMANDS = (
    ('compare_obex.py', (), 'obex-2026-08'),
    ('simulate_obex.py', (), 'obex-settlement-2026-08'),
    ('compare_backtest.py', ('osero',), 'osero-2026-08'),
    ('compare_backtest.py', ('grove',), 'grove-2026-08'),
)


class ReportsTest(unittest.TestCase):
    def run_report(self, script, args, log, out):
        env = dict(os.environ)
        env.pop('ETH_RPC', None)
        command = [sys.executable]
        if not __debug__:
            command.append('-O')
        return subprocess.run([*command, str(ROOT / 'script' / script), *args,
                               '--log', str(log), '--output', str(out)],
                              cwd=out, env=env, capture_output=True, text=True)

    def test_all_reports_reproduce_offline(self):
        verify_baseline(BASELINE)
        for script, args, stem in COMMANDS:
            with self.subTest(report=stem), tempfile.TemporaryDirectory() as directory:
                out = Path(directory)
                run = self.run_report(script, args, ROOT / 'reports' / f'{stem}.log', out)
                self.assertEqual(run.returncode, 0, run.stderr)
                for expected in (ROOT / 'reports').glob(f'{stem}*.csv'):
                    self.assertEqual((out / expected.name).read_bytes(), expected.read_bytes())
                self.assertIn('August', (out / f'{stem}.md').read_text())

    def test_invalid_late_receipt_check_leaves_outputs_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            target = out / 'grove-2026-08-daily.csv'
            target.write_text('previous accepted report\n')
            log = (ROOT / 'reports/grove-2026-08.log').read_text()
            # The receipt validation runs after daily rows have been built.
            bad = out / 'bad.log'
            bad.write_text(log.replace('cash_log_index 703', 'cash_log_index 704'))
            self.assertNotEqual(bad.read_text(), log)
            run = self.run_report('compare_backtest.py', ('grove',), bad, out)
            self.assertNotEqual(run.returncode, 0)
            self.assertEqual(target.read_text(), 'previous accepted report\n')
            self.assertFalse((out / 'grove-2026-08.md').exists())

    def test_rejects_bad_boundaries_for_every_report(self):
        for script, args, stem in COMMANDS:
            with self.subTest(report=stem), tempfile.TemporaryDirectory() as directory:
                out = Path(directory)
                log = (ROOT / 'reports' / f'{stem}.log').read_text()
                # Corrupt one economic observation even while PASS is present.
                import re
                matches = list(re.finditer(r'(?m)^(\s*debt )\d+', log))
                self.assertGreater(len(matches), 1)
                match = matches[1]
                corrupted = log[:match.start()] + match[1] + '1' + log[match.end():]
                bad = out / 'bad.log'; bad.write_text(corrupted)
                run = self.run_report(script, args, bad, out)
                self.assertNotEqual(run.returncode, 0)
                self.assertEqual(set(p.name for p in out.iterdir()), {'bad.log'})

    def test_snapshot_parser_rejects_missing_and_duplicate_fields(self):
        log = (ROOT / 'reports/osero-2026-08.log').read_text()
        rows = observations(log, 'osero')
        self.assertEqual(len(rows), 32)
        import re
        missing = re.sub(r'(?m)^\s*nav \d+[^\n]*\n', '', log, count=1)
        duplicate = re.sub(r'(?m)^(\s*nav \d+[^\n]*)$', r'\1\n\1', log, count=1)
        for bad in (missing, duplicate, log.replace('[PASS]', '[FAIL]')):
            with self.assertRaises(ValueError):
                observations(bad, 'osero')


if __name__ == '__main__':
    unittest.main()
