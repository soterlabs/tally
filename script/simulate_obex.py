#!/usr/bin/env python3
"""Run Obex's August daily-settlement simulation and write its report.

ETH_RPC=<archive RPC> python3 script/simulate_obex.py
python3 script/simulate_obex.py --log reports/obex-settlement-2026-08.log
"""

import argparse
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
    output = args.output
    if args.log:
        log = args.log.read_text()
    else:
        if not os.environ.get('ETH_RPC'):
            parser.error('Set ETH_RPC to an archive mainnet RPC endpoint.')
        run = subprocess.run(
            ['forge', 'test', '--match-contract', '^ObexSettlementForkTest$', '-vv'],
            cwd=ROOT, text=True, capture_output=True,
        )
        if run.returncode:
            raise RuntimeError('Settlement simulation failed; inspect the RPC connection and run forge locally.')
        log = (run.stdout + run.stderr).replace(os.environ['ETH_RPC'], '<ETH_RPC>')
    if '[FAIL' in log:
        raise ValueError('Failing simulation log')
    names = ('legacy', 'refresh', 'noted', 'ceiling')
    for name in names:
        if f'[PASS] test_obex_daily_settlement_{name}()' not in log:
            raise ValueError(f'Missing passing {name} simulation')
    outputs.text('obex-settlement-2026-08.log', log)

    scenarios = {}
    active = None
    for line in log.splitlines():
        line = line.strip()
        if line.startswith('OBEX_SIM '):
            active = line.split()[1]
            if active in scenarios:
                raise ValueError('Duplicate scenario')
            scenarios[active] = {'days': []}
        elif line.startswith('OBEX_SIM_END '):
            if not (active == line.split()[1]):
                raise ValueError('simulate_obex.py: active == line.split()[1]')
            active = None
        elif active:
            match = re.fullmatch(r'([a-z_]+) (-?\d+)', line)
            if match:
                key, value = match.groups()
                scenario = scenarios[active]
                if key == 'day':
                    scenario['days'].append({'day': int(value)})
                elif scenario['days']:
                    if key in scenario['days'][-1]:
                        raise ValueError(f'Duplicate simulation field: {key}')
                    scenario['days'][-1][key] = int(value)
                else:
                    if key in scenario:
                        raise ValueError(f'Duplicate simulation header: {key}')
                    scenario[key] = int(value)
    if not (set(scenarios) == set(names)):
        raise ValueError('simulate_obex.py: set(scenarios) == set(names)')
    if not (active is None):
        raise ValueError('simulate_obex.py: active is None')
    for name, scenario in scenarios.items():
        if not ([row['day'] for row in scenario['days']] == list(range(1, 32))):
            raise ValueError("simulate_obex.py: [row['day'] for row in scenario['days']] == list(range(1, 32))")
        for row in scenario['days']:
            if not (row['debt'] == scenario['initial_debt'] + row['legacy_debt'] + row['drew']):
                raise ValueError("simulate_obex.py: row['debt'] == scenario['initial_debt'] + row['legacy_debt'] + row['drew']")
            if not (row['sub'] == scenario['initial_sub'] + row['legacy_send'] + row['paid']):
                raise ValueError("simulate_obex.py: row['sub'] == scenario['initial_sub'] + row['legacy_send'] + row['paid']")
            if not (scenario['initial_float'] + row['drew'] == row['paid'] + row['kept'] + row['float']):
                raise ValueError("simulate_obex.py: scenario['initial_float'] + row['drew'] == row['paid'] + row['kept'] + row['float']")
            if not (row['gain'] == row['drew'] + row['sde']):
                raise ValueError("simulate_obex.py: row['gain'] == row['drew'] + row['sde']")
            if not (row['gain'] + row['agent'] - row['fee'] == row['paid'] + row['owe']):
                raise ValueError("simulate_obex.py: row['gain'] + row['agent'] - row['fee'] == row['paid'] + row['owe']")
            if not (row['sin'] == 0):
                raise ValueError("simulate_obex.py: row['sin'] == 0")
            if not (row['gap'] == (0 if name == 'noted' else -row['legacy_debt'])):
                raise ValueError("simulate_obex.py: row['gap'] == (0 if name == 'noted' else -row['legacy_debt'])")

    csv_rows = []
    for name in names:
        for row in scenarios[name]['days']:
            csv_rows.append({
                'scenario': name, 'date': f'2026-08-{row["day"]:02d}',
                **{key: value if key in ('day', 'block') else str(D(value) / WAD) for key, value in row.items()},
            })
    outputs.csv('obex-settlement-2026-08-daily.csv', csv_rows)

    final = {name: {key: D(value) / WAD for key, value in scenarios[name]['days'][-1].items()} for name in names}
    source = args.pipeline / 'settlements/obex/2026-08/provenance.json'
    raw = source.read_bytes()
    pipeline = json.loads(raw)['results']
    comparisons = [
        ('Investment revenue', 'gain', D(pipeline['prime_agent_revenue'])),
        ('Borrowing costs', 'fee', D(pipeline['sky_revenue'])),
        ('Agent-rate income', 'agent', D(pipeline['agent_rate'])),
        ('Net PnL, paid plus owed', 'pnl', D(pipeline['monthly_pnl'])),
    ]
    for values in final.values():
        values['pnl'] = values['paid'] + values['owe']
    if not (final['refresh']['fee'] == final['legacy']['fee']):
        raise ValueError("simulate_obex.py: final['refresh']['fee'] == final['legacy']['fee']")
    if not (final['refresh'] == final['legacy']):
        raise ValueError('extra drip must be idempotent')
    table = '\n'.join(
        f'| {label} | {money(published)} | {money(final["legacy"][key])} | {money(final["noted"][key])} |'
        for label, key, published in comparisons
    )
    cash_table = '\n'.join(
        f'| {label} | {money(final["legacy"][key])} | {money(final["noted"][key])} | {money(final["ceiling"][key])} |'
        for label, key in [
            ('August debt drawn', 'drew'), ('August paid to SubProxy', 'paid'),
            ('August joined to Vow', 'kept'), ('Closing debt', 'debt'),
            ('Closing SubProxy USDS', 'sub'), ('Unpaid claim / payout rounding', 'owe'),
            ('Undrawn amount / draw rounding', 'sde'), ('Closing float', 'float'),
            ('Unassigned equity gap', 'gap'),
        ]
    )
    exhausted = next(row['day'] for row in scenarios['ceiling']['days'] if row['float'] == 0)
    text = f'''# Obex — August 2026 daily settlement simulation

Production `Tally` and `Till` execute 31 daily settlements using the historical
July 31–August 31 mainnet forks from the accrual backtest. Maple holdings and
prices, the sUSDS index, and timestamps are read on-chain. Simulated Vat, USDS,
AllocatorVault, AllocatorBuffer and join contracts persist the changing debt,
payments and surplus credits across forks. This tests economic behavior and
cash conservation; it is not an integration test of the deployed allocator's
permissions, collateral checks, USDS implementation, or global debt ceiling.
The simulated ilk ceiling is initialized from July 31; other ilks are not modeled.

## Scenarios

- **Current:** updated `settle()` with automatic post-payment sampling, zero initial float. Start at the
  actual July 31 debt and SubProxy balance. Preserve the August 17 settlement
  of **July's** earnings: +2,535,968 debt and +916,736 SubProxy USDS, once.
  August's daily Tally draws/payments are additional, earned in August.
- **Refresh:** same inputs with an additional `drip()` after settlement.
  All final balances equal Current exactly, validating refresh idempotence.
- **Noted:** the monthly integration brackets its debt increase and payment
  with `drip(); ...; note("MSC-2026-07")`. The legacy event is modeled at
  August 17's end-of-day timestamp, not its actual intraday execution time.
  This demonstrates the hook, not intraday parity: it charges pre-event debt
  for the preceding interval, unlike Current's larger-endpoint sampling.
  Both scenarios keep the July obligation and charge it in later intervals.
- **Ceiling stress:** no draw headroom, 20,000 USDS initial float, no legacy
  July settlement injected. This is a synthetic liquidity test, not a second
  historical August comparison. The float is exhausted on August {exhausted:02d};
  subsequent unpaid amounts remain in `owe` and undrawn amounts in `sde`.

The tests assert unchanged ALM shares and idle balances throughout the month,
zero historical SubProxy sUSDS, and exactly one historical debt/payment change.
They fail if those assumptions cease to hold.

## Results (USDS)

| Accrual metric | Python monthly report | Current daily settlement | With monthly settlement hook |
|---|---:|---:|---:|
{table}

The current daily-settlement net PnL differs from the Python report by
{money(final['legacy']['pnl'] - D(pipeline['monthly_pnl']))} USDS.
The monthly-hook scenario changes net PnL by
{money(final['noted']['pnl'] - final['legacy']['pnl'])} USDS because it brackets
legacy debt at the modeled day-17 boundary. The unrelated extra-refresh
scenario is exactly equal to Current.

These figures differ from the accrual-only replay in
[ObexForkTest](../test/Backtest.t.sol), because
daily draws and payments now remain in the next day's balances. No hypothetical
new investments or discretionary withdrawals are modeled. All funded scenarios
pay every whole-USDS claim and need no starting float for this profitable month;
that is not a general float-sizing result.

| Cash and closing balances | Current | Monthly hook | Ceiling stress |
|---|---:|---:|---:|
{cash_table}

Cash totals in this table cover Tally's August settlement only. The legacy July
payment is included separately in closing debt/SubProxy balances. Seeded opening
balances and that legacy payment are external to the simulated August cash ledger.
Rounding amounts are shown to cents here but preserved at full precision in CSV.

## Reconciliation and validation

Every day, exact integer assertions check:

```text
closing debt = initial debt + legacy debt + August draws
closing SubProxy = initial SubProxy + legacy send + August payments
initial float + draws = payments + Vow credits + closing float
August investment gain = draws + undrawn carry
August gain + agent income - borrowing costs = payments + unpaid carry
```

All four tests pass. None of the funded scenarios has a supply loss; the existing
unit suite covers negative-supply carries, including multi-cycle fuzz tests.
Current retains the legacy equity gap at -2,535,968 USDS under `route = NIL`;
Noted eliminates it without removing the legacy debt from the interest base.
Tally's own daily draws are excluded in every scenario.

Source: committed Python August `provenance.json`, SHA-256
`{hashlib.sha256(raw).hexdigest()}`. Python was not regenerated.
See [daily balances](obex-settlement-2026-08-daily.csv),
[test output](obex-settlement-2026-08.log), and
[simulation source](../test/ObexSettlement.t.sol).

Reproduce: `ETH_RPC=<archive RPC> python3 script/simulate_obex.py`.
'''
    outputs.text('obex-settlement-2026-08.md', text)
    outputs.commit()
    print(table)
    print('\n' + cash_table)
    print(f'\nReport: {output / "obex-settlement-2026-08.md"}')


if __name__ == '__main__':
    main()
