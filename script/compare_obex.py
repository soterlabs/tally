#!/usr/bin/env python3
"""Compare the historical Obex fork replay to the committed MSC report.

ETH_RPC=<archive RPC> python3 script/compare_obex.py
Or reuse a run: python3 script/compare_obex.py --log reports/obex-2026-08.log
Uses only the Python standard library; never sends transactions to mainnet.
"""

import argparse
from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP, getcontext
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
from reporting import BASELINE, Outputs, verify_baseline

getcontext().prec = 60
D = Decimal
WAD = D(10) ** 18
ROOT = Path(__file__).resolve().parents[1]


def money(value):
    return f"{D(value).quantize(D('.01'), rounding=ROUND_HALF_UP):,.2f}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--log', type=Path)
    parser.add_argument('--pipeline', type=Path, default=BASELINE)
    parser.add_argument('--output', type=Path, default=ROOT / 'reports')
    args = parser.parse_args()
    verify_baseline(args.pipeline)
    outputs = Outputs(args.output)
    source = args.pipeline / 'settlements/obex/2026-08/provenance.json'
    raw = source.read_bytes()
    report = json.loads(raw)
    output = args.output
    if args.log:
        log = args.log.read_text()
    else:
        if not os.environ.get('ETH_RPC'):
            parser.error('Set ETH_RPC to an archive mainnet RPC endpoint.')
        run = subprocess.run(
            ['forge', 'test', '--match-contract', '^ObexForkTest$', '-vv'],
            cwd=ROOT, text=True, capture_output=True,
        )
        log = (run.stdout + run.stderr).replace(os.environ['ETH_RPC'], '<ETH_RPC>')
        if run.returncode:
            # Do not persist provider errors, which can contain credentials.
            raise RuntimeError('Obex fork test failed; inspect the RPC connection and run forge locally.')
        outputs.text('obex-2026-08.log', log)

    if '[PASS] test_obex_august_2026()' not in log or '[FAIL' in log:
        raise ValueError('Expected a passing Obex fork test.')
    observations = []
    for line in log.splitlines():
        match = re.fullmatch(r'\s*(OBEX_DAY|block|timestamp|debt|sub_usds|sub_susds_value|ssr_index|nav|syrup_value|alm_usds|alm_usdc|tab|gain|owe|rebate|sde|gap) (-?\d+)(?:\s+.*)?', line)
        if not match:
            continue
        key, value = match.groups()
        if key == 'OBEX_DAY':
            observations.append({'day': int(value)})
        elif observations:
            if key in observations[-1]:
                raise ValueError(f'Duplicate observation field: {key}')
            observations[-1][key] = int(value)
    if [row['day'] for row in observations] != list(range(32)):
        raise ValueError('Expected July 31 baseline and 31 daily observations.')
    first, last = observations[0], observations[-1]
    if not (first['block'] == report['pin_blocks_som']['ethereum']):
        raise ValueError("compare_obex.py: first['block'] == report['pin_blocks_som']['ethereum']")
    if not (last['block'] == report['pin_blocks_eom']['ethereum']):
        raise ValueError("compare_obex.py: last['block'] == report['pin_blocks_eom']['ethereum']")
    if not (all(row['sub_susds_value'] == 0 for row in observations)):
        raise ValueError('Decomposition assumes USDS-only SubProxy')
    daily = report['sky_revenue_daily']
    if not (len(daily) == 31):
        raise ValueError('compare_obex.py: len(daily) == 31')
    results = {key: D(value) for key, value in report['results'].items() if key != 'gar_basis'}
    venue = report['venue_breakdown'][0]
    if not (D(venue['period_inflow']) == 0):
        raise ValueError("compare_obex.py: D(venue['period_inflow']) == 0")

    # Counterfactuals hold daily endpoint balances fixed while changing one
    # convention at a time: monthly -> daily rate, then conservative balance
    # sampling, then actual block-to-block elapsed seconds/index rounding.
    sky_daily_rate = D(0)
    agent_monthly_rate = D(0)
    agent_daily_rate = D(0)
    agent_sampled = D(0)
    rows = []
    for previous, current, published in zip(observations, observations[1:], daily):
        date = datetime.fromtimestamp(current['timestamp'], timezone.utc).date().isoformat()
        if not (date == published['date']):
            raise ValueError("compare_obex.py: date == published['date']")
        if not (D(current['debt']) / WAD == D(published['cum_debt'])):
            raise ValueError("compare_obex.py: D(current['debt']) / WAD == D(published['cum_debt'])")
        # Obex has no idle/SDE deductions, subsidy, or savings-token rebates.
        if not (D(published['utilized']) == D(published['cum_debt'])):
            raise ValueError("compare_obex.py: D(published['utilized']) == D(published['cum_debt'])")
        if not (published['sub_apr'] is None):
            raise ValueError("compare_obex.py: published['sub_apr'] is None")
        if not (current['rebate'] == current['sde'] == 0):
            raise ValueError("compare_obex.py: current['rebate'] == current['sde'] == 0")
        apy = D(str(published['ssr_apy']))
        factor = (1 + apy) ** (D(1) / 365) - 1 + D('.002') / 365
        sky_daily_rate += D(current['debt']) / WAD * factor
        agent_monthly_rate += D(current['sub_usds']) / WAD * D(str(published['base_apr'])) / 365
        agent_daily_rate += D(current['sub_usds']) / WAD * factor
        agent_sampled += D(min(previous['sub_usds'], current['sub_usds'])) / WAD * factor
        row = {'date': date, 'block': current['block'], 'elapsed_seconds': current['timestamp'] - previous['timestamp']}
        for key in ('debt', 'sub_usds', 'nav', 'syrup_value', 'alm_usds', 'alm_usdc', 'tab', 'gain', 'owe', 'gap'):
            row[key] = str(D(current[key]) / WAD)
        for key in ('tab', 'gain', 'owe'):
            row['daily_' + key] = str(D(current[key] - previous[key]) / WAD)
        row['pipeline_daily_sky'] = published['daily_sky_rev']
        rows.append(row)
    if not (abs(agent_monthly_rate - results['agent_rate']) < D('.01')):
        raise ValueError('Agent baseline does not reproduce report')
    outputs.csv('obex-2026-08-daily.csv', rows)

    gain, sky, agent = (D(last[key]) / WAD for key in ('gain', 'tab', 'owe'))
    comparisons = [
        ('Opening Maple position value', D(first['syrup_value']) / WAD, D(venue['value_som'])),
        ('Closing Maple position value', D(last['syrup_value']) / WAD, D(venue['value_eom'])),
        ('Investment revenue', gain, results['prime_agent_revenue']),
        ('Sky share / cost of funds', sky, results['sky_revenue']),
        ('Prime supply-side PnL', gain - sky, results['prime_agent_revenue'] - results['sky_revenue']),
        ('Agent rate / demand side', agent, results['agent_rate']),
        ('Prime total net PnL', gain - sky + agent, results['monthly_pnl']),
    ]
    for label, tally, pipeline in comparisons[:3]:
        if not (abs(tally - pipeline) < D('.01')):
            raise ValueError(f'{label} differs from current report')
    if not (last['gap'] == -(last['debt'] - first['debt'])):
        raise ValueError('Unexpected equity-gap attribution')
    table = '\n'.join(f'| {label} | {money(tally)} | {money(pipeline)} | {money(tally - pipeline)} |' for label, tally, pipeline in comparisons)
    changes = '\n'.join(
        f'- {row["date"]}: debt {money(row["debt"])} USDS; SubProxy {money(row["sub_usds"])} USDS.'
        for previous, current, row in zip(observations, observations[1:], rows)
        if current['debt'] != previous['debt'] or current['sub_usds'] != previous['sub_usds']
    )
    text = f'''# Obex — August 2026 historical accrual comparison

Tally was deployed on a local mainnet fork at block {first['block']} (July 31),
then its books and adapters were persisted across 31 historical end-of-day
forks through block {last['block']} (August 31). Each day calls `drip()` and
`poke()`. Positions: ALM USDS, USDC, and Maple syrupUSDC. Base and agent
spreads: 20 bps; no subsidy, SDE, or rebates. Default gap route: NIL.

Baseline: the committed Python [August report](../test/fixtures/msc/settlements/obex/2026-08/summary.md)
and its full-precision `provenance.json`, generated {report['generated_at_utc']}.
Provenance SHA-256: `{hashlib.sha256(raw).hexdigest()}`.
The Python pipeline was not regenerated.

All amounts below are USDS; difference is Tally minus Python.

| Metric | Tally | Python report | Difference |
|---|---:|---:|---:|
{table}

## Difference attribution

- Sky share: changing the monthly nominal SSR conversion to a daily conversion,
  holding published daily debt fixed, explains {money(sky_daily_rate - results['sky_revenue'])} USDS.
  Actual block timestamps and index precision account for the remaining
  {money(sky - sky_daily_rate)} USDS.
- Agent rate: daily conversion explains {money(agent_daily_rate - agent_monthly_rate)} USDS;
  using the smaller endpoint SubProxy balance explains
  {money(agent_sampled - agent_daily_rate)} USDS; actual timestamps/index precision
  explain {money(agent - agent_sampled)} USDS. Reconstructing the monthly-rate
  calculation from the observed end-of-day SubProxy balances agrees with the
  published agent rate within one cent.
- Investment revenue has no capital flows in the Python venue report. The
  index-based valuation reproduces its opening/closing position and gain.
  Tally also tracks {D(first['alm_usdc']) / WAD} USDC and
  {D(first['alm_usds']) / WAD} USDS of ALM cash at the opening block, outside
  the report's Maple venue row. The daily CSV includes this cash in total NAV.

Observed changes in debt or SubProxy balances:

{changes}

## Scope and equity gap

This is an accrual replay against the actual historical balance path, not a
counterfactual replacement of August's transactions. `settle()` and Till
payments are not executed; no simulated daily payments or debt capitalization
are fed into the next day. The historical August MSC transaction remains in
the debt and SubProxy readings. Prime total net PnL is `gain - tab + owe`,
before whole-USDS settlement rounding.

The closing unassigned equity gap is {money(D(last['gap']) / WAD)} USDS.
An historical settlement debt increase that did not enter the ALM appears in
`capital` but not position flows; unlike Tally's own draw, it is not automatically
excluded. With default `route = NIL`, this gap is reported but does not change
the PnL above. It must be reconciled before enabling automatic gap routing.

Validation: `ObexForkTest.test_obex_august_2026` passed. The comparison additionally
checks report pin blocks, all 31 dates and debt readings, and the reconstructed
agent-rate baseline. See [daily observations](obex-2026-08-daily.csv) and
[raw fork test output](obex-2026-08.log).

Reproduce from this repo with `ETH_RPC=<archive RPC> python3 script/compare_obex.py`.
'''
    outputs.text('obex-2026-08.md', text)
    outputs.commit()
    print(table)
    print(f'\nReport: {output / "obex-2026-08.md"}')


if __name__ == '__main__':
    main()
