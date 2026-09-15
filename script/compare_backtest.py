#!/usr/bin/env python3
"""August 2026 Osero/Grove historical accrual examples (standard library only).

ETH_RPC=<archive RPC> python3 script/compare_backtest.py grove
python3 script/compare_backtest.py osero --log reports/osero-2026-08.log
No transactions are submitted to a live network.
"""
import argparse
import csv
from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP, getcontext
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
getcontext().prec = 60
D = Decimal
WAD = D(10) ** 18
FIELDS = ('block', 'timestamp', 'debt', 'nav', 'tab', 'rebate', 'owe', 'gain', 'sde', 'gap')
DIRECT = {'E1', 'E2', 'E3', 'E4', 'E5', 'E6', 'E7', 'E8', 'E11', 'E12', 'E13',
          'E15', 'E16', 'E17', 'E18', 'E24', 'E26', 'E30', 'E31', 'E32', 'E37', 'E40', 'E41'}
COVERAGE = {
    **{key: ('Ethereum marks', 'Local adapter; LP collect and capital-flow hooks still required') for key in DIRECT},
    'E9': ('Ethereum SDE marks', 'ERC-7540 claim valuation differs from headline NAV'),
    'E10': ('Ethereum SDE marks', 'CapitalPip with verified August capital-outflow declarations'),
    **{key: ('Remote position', 'Relay finalized remote shares/queues; preserve index versus capital')
       for key in ('E19', 'E20', 'E22', 'E23', 'E27')},
    'E21': ('Ethereum cash credited', 'Verified receipts attributed with Cash; Avalanche principal still absent'),
    **{key: ('Ethereum cash credited', 'Verified August receipts attributed via Cash.sort; future classification requires review') for key in ('E38', 'E42')},
    **{key: ('Display only', 'Excluded by Python accounting scope; not evidence of zero economic risk')
       for key in ('E14', 'E25', 'E33', 'E34', 'E35', 'E36')},
}


def money(value):
    return f"{D(value).quantize(D('.01'), rounding=ROUND_HALF_UP):,.2f}"


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def write_csv(path, rows):
    with path.open('w', newline='') as handle:
        writer = csv.DictWriter(handle, fieldnames=rows[0].keys(), lineterminator='\n')
        writer.writeheader()
        writer.writerows(rows)


def observations(log, prime):
    if f'[PASS] test_{prime}_august_2026()' not in log or '[FAIL' in log:
        raise ValueError('Expected a passing, single-prime fork log')
    rows = []
    for line in log.splitlines():
        match = re.fullmatch(r'\s*(BACKTEST_DAY|' + '|'.join(FIELDS) + r') (-?\d+)(?:\s+.*)?', line)
        if not match:
            continue
        key, value = match.groups()
        if key == 'BACKTEST_DAY':
            rows.append({'day': int(value)})
        elif rows:
            if key in rows[-1]:
                raise ValueError(f'Duplicate snapshot field: {key}')
            rows[-1][key] = int(value)
    if [r['day'] for r in rows] != list(range(32)):
        raise ValueError('Expected July 31 baseline and 31 daily snapshots')
    for row in rows:
        if set(row) != {'day', *FIELDS}:
            raise ValueError('Incomplete snapshot')
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('prime', choices=('osero', 'grove'))
    parser.add_argument('--log', type=Path)
    parser.add_argument('--pipeline', type=Path, default=ROOT.parent / 'settlement-cycle')
    args = parser.parse_args()
    prime = args.prime
    source = args.pipeline / 'settlements' / prime / '2026-08'
    raw = (source / 'provenance.json').read_bytes()
    summary_raw = (source / 'summary.md').read_bytes()
    report = json.loads(raw)
    if report['prime_id'] != prime or report['month'] != '2026-08':
        raise ValueError('Wrong pipeline baseline')
    out = ROOT / 'reports'
    out.mkdir(exist_ok=True)
    if args.log:
        log = args.log.read_text()
    else:
        if not os.environ.get('ETH_RPC'):
            parser.error('Set ETH_RPC to an archive Ethereum RPC endpoint')
        run = subprocess.run(['forge', 'test', '--match-contract', f'^{prime.title()}ForkTest$', '-vv'],
                             cwd=ROOT, capture_output=True, text=True)
        if run.returncode:
            raise RuntimeError('Fork replay failed; run forge locally to inspect the failure')
        log = (run.stdout + run.stderr).replace(os.environ['ETH_RPC'], '<ETH_RPC>')
    snaps = observations(log, prime)
    first, last = snaps[0], snaps[-1]
    assert first['block'] == report['pin_blocks_som']['ethereum']
    assert last['block'] == report['pin_blocks_eom']['ethereum']
    assert all(first[k] == 0 for k in ('tab', 'rebate', 'owe', 'gain', 'sde', 'gap'))
    daily = report['sky_revenue_daily']
    assert len(daily) == 31
    rows = []
    for prev, curr, baseline in zip(snaps, snaps[1:], daily):
        date = datetime.fromtimestamp(curr['timestamp'], timezone.utc).date().isoformat()
        assert date == baseline['date']
        assert curr['timestamp'] > prev['timestamp'] and curr['block'] > prev['block']
        debt_diff = D(curr['debt']) / WAD - D(baseline['cum_debt'])
        # Grove's Dune debt source rounds at six decimals.
        assert abs(debt_diff) < D('.01'), f'Debt mismatch on {date}'
        row = {'date': date, 'block': curr['block'], 'elapsed_seconds': curr['timestamp'] - prev['timestamp']}
        row.update({k: str(D(curr[k]) / WAD) for k in FIELDS if k not in ('block', 'timestamp')})
        for k in ('tab', 'rebate', 'owe', 'gain', 'sde'):
            row['daily_' + k] = str(D(curr[k] - prev[k]) / WAD)
        row['net_cost_of_funds'] = str(D(curr['tab'] - min(curr['tab'], curr['rebate'])) / WAD)
        row['pipeline_daily_cost_of_funds'] = baseline['daily_sky_rev']
        row['pipeline_utilized'] = baseline['utilized']
        for key in ('ssr_apy', 'sub_apr', 'sde_av', 'lending_idle'):
            row['pipeline_' + key] = baseline[key]
        row['pipeline_debt_difference'] = str(debt_diff)
        rows.append(row)
    write_csv(out / f'{prime}-2026-08-daily.csv', rows)
    (out / f'{prime}-2026-08.log').write_text(log)
    r = {k: D(v) for k, v in report['results'].items() if k != 'gar_basis'}
    t = {k: D(last[k]) / WAD for k in ('tab', 'rebate', 'gain', 'sde', 'owe', 'gap')}
    cost = t['tab'] - min(t['tab'], t['rebate'])
    pipeline_cost = r['sky_revenue'] - r['sde_revenue']
    assert abs(sum(D(d['daily_sky_rev']) for d in daily) - pipeline_cost) < D('.01')
    venues = report['venue_breakdown']
    assert abs(sum(D(v['revenue']) for v in venues) - r['prime_agent_revenue']) < D('.01')
    assert abs(sum(D(v['sd_revenue']) for v in venues) - r['sde_revenue']) < D('.01')
    extras = r['distribution_rewards'] + r['chronicle_points']
    pairs = [
        ('Prime investment revenue' + (' (Ethereum subset)' if prime == 'grove' else ''), t['gain'], r['prime_agent_revenue']),
        ('Net cost of funds: tab minus capped rebates', cost, pipeline_cost),
        ('SDE investment revenue (separate from prime revenue)', t['sde'], r['sde_revenue']),
        ('Total Sky share: cost of funds plus SDE yield', cost + t['sde'], r['sky_revenue']),
        ('Agent rate', t['owe'], r['agent_rate']),
        ('Distribution rewards + Chronicle points (not imported)', D(0), extras),
        ('Prime accrual: investment minus cost + agent (excludes rewards)',
         t['gain'] - cost + t['owe'], r['prime_agent_revenue'] - pipeline_cost + r['agent_rate']),
    ]
    table = '\n'.join(f'| {label} | {money(a)} | {money(b)} | {money(a-b)} |' for label, a, b in pairs)
    drift = []
    summary_venues = {}
    for line in summary_raw.decode().splitlines():
        if re.match(r'^\| [EO]\d+ \|', line):
            columns = [c.strip() for c in line.strip('|').split('|')]
            if len(columns) >= 11:
                summary_venues[columns[0]] = columns
    for venue in venues:
        columns = summary_venues.get(venue['venue_id'])
        if columns:
            for field, index in (('revenue', 7), ('sd_revenue', 8)):
                published = D(columns[index].replace('$', '').replace(',', ''))
                precise = D(venue[field])
                if abs(published - precise) > D('.011'):
                    drift.append(f'- {venue["venue_id"]} {field}: summary {money(published)}; provenance {money(precise)}.')
    scope = ''
    if prime == 'grove':
        config_raw = (args.pipeline / 'config/grove.yaml').read_bytes()
        chains = {}
        for block in re.split(r'(?m)^  - id: ', config_raw.decode())[1:]:
            key = block.splitlines()[0].strip()
            chain = re.search(r'(?m)^    chain: (\w+)', block)
            if chain:
                chains[key] = chain.group(1)
        coverage = []
        for venue in venues + report['display_only_breakdown']:
            key = venue['venue_id']
            group, requirement = COVERAGE[key]  # Fail on an unclassified new venue.
            coverage.append({'venue': key, 'chain': chains[key], 'label': venue['label'],
                             'coverage': group, 'requirement': requirement,
                             'pipeline_prime_revenue': venue.get('revenue', 'excluded'),
                             'pipeline_sde_revenue': venue.get('sd_revenue', 'excluded'),
                             'pipeline_value_som': venue['value_som'], 'pipeline_value_eom': venue['value_eom']})
        write_csv(out / 'grove-2026-08-coverage.csv', coverage)
        groups = {}
        for venue in venues:
            group = COVERAGE[venue['venue_id']][0]
            groups[group] = groups.get(group, D(0)) + D(venue['revenue'])
        partition = '\n'.join(f'| {key} | {money(value)} |' for key, value in groups.items())
        local = groups['Ethereum marks'] + groups['Ethereum cash credited']
        assert abs(t['gain'] - local) < D('500'), 'Local matched-scope revenue regression'
        cash_raw = (ROOT / 'test/fixtures/grove-cash-2026-08.json').read_bytes()
        cash_fixture = json.loads(cash_raw)
        cash_events = cash_fixture['events']
        assert cash_fixture['chain_id'] == 1
        assert cash_fixture['start_block'] == first['block'] and cash_fixture['end_block'] == last['block']
        assert len(cash_events) == len({(e['tx_hash'], e['log_index']) for e in cash_events}) == 4
        actual_receipts = re.findall(
            r'CASH_RECEIPT\s*\n\s*(0x[0-9a-f]{64})\s*\n\s*cash_log_index (\d+)[^\n]*\n\s*cash_amount (\d+)', log)
        assert [(tx, int(idx), int(wad)) for tx, idx, wad in actual_receipts] == [
            (e['tx_hash'], e['log_index'], e['amount_raw'] * 10**12) for e in cash_events]
        cash_total = sum(D(e['amount_raw']) / 10**e['decimals'] for e in cash_events)
        reported_cash = re.findall(r'^\s*CASH_INCOME (\d+)', log, re.M)
        assert len(reported_cash) == 1 and D(reported_cash[0]) / WAD == cash_total
        for venue_id in ('E21', 'E38', 'E42'):
            credited = sum(D(e['amount_raw']) / 10**e['decimals'] for e in cash_events if e['venue'] == venue_id)
            assert credited == D(next(v['revenue'] for v in venues if v['venue_id'] == venue_id))
        assert cash_total == groups['Ethereum cash credited']
        cash_rows = []
        for e in cash_events:
            day = next(day for day in range(1,32) if snaps[day-1]['block'] < e['block'] <= snaps[day]['block'])
            assert day == int(e['timestamp'][8:10])
            cash_rows.append({'date': e['timestamp'][:10], 'venue': e['venue'], 'block': e['block'],
                             'tx_hash': e['tx_hash'], 'log_index': e['log_index'],
                             'token': e['token'], 'amount_usds_at_par': str(D(e['amount_raw']) / 10**e['decimals'])})
        write_csv(out / 'grove-2026-08-cash.csv', cash_rows)
        cash_table = '\n'.join(f"| {row['date']} | {row['venue']} | {money(row['amount_usds_at_par'])} | [transaction](https://etherscan.io/tx/{row['tx_hash']}) |" for row in cash_rows)
        fixture_raw = (ROOT / 'test/fixtures/buidl-2026-08.json').read_bytes()
        fixture = json.loads(fixture_raw)
        events = fixture['events']
        assert fixture['start_block'] == first['block'] and fixture['end_block'] == last['block']
        assert fixture['decimals'] == 6
        minted = sum(e['amount_raw'] for e in events if e['kind'] == 'dividend_mint')
        outgoing = [e for e in events if e['kind'] == 'capital_outflow']
        assert fixture['closing_balance_raw'] - fixture['opening_balance_raw'] == minted - sum(e['amount_raw'] for e in outgoing)
        # Guard the EoD staging assumptions baked into GroveForkTest. No
        # dividend may follow a capital outflow within either affected day.
        for day, expected in ((24, 50_000_000), (31, 25_000_000)):
            day_events = [e for e in events if snaps[day-1]['block'] < e['block'] <= snaps[day]['block']]
            flows = [e for e in day_events if e['kind'] == 'capital_outflow']
            assert len(flows) == 2 and sum(e['amount_raw'] for e in flows) == expected * 10**6
            assert max(e['block'] for e in day_events if e['kind'] == 'dividend_mint') < min(e['block'] for e in flows)
        assert len(outgoing) == 4
        observed_yield = re.findall(r'^\s*BUIDL_YIELD (-?\d+)(?:\s+.*)?$', log, re.M)
        assert len(observed_yield) == 1, 'Requires updated CapitalPip replay'
        buidl_yield = D(observed_yield[0]) / WAD
        assert abs(buidl_yield - D(minted) / 10**6) < D('.01')
        buidl_pipeline = D(next(v['sd_revenue'] for v in venues if v['venue_id'] == 'E10'))
        buidl_flows = '\n'.join(f"| {e['block']} | {money(D(e['amount_raw']) / 10**6)} | [transaction](https://etherscan.io/tx/{e['tx_hash']}) |" for e in outgoing)
        scope = f'''
## Grove coverage

This run marks Ethereum holdings for BLOOM and GROVE, charges both ilks' debt,
and accrues the shared SubProxy agent rate once. It does not read other chains.
The following partitions the Python **prime** investment revenue (not Tally output):

| Source group | Python prime revenue |
|---|---:|
{partition}

The matched Ethereum subset is {money(local)} USDS versus Tally's
{money(t['gain'])}, a {money(t['gain'] - local)} USDS residual. Uniswap collected
fees are not declared in this baseline; its historical pricing assertion was
calibrated to the provenance's pre-correction LP figure. Agreement with that
snapshot does not validate the newer summary's LP accounting.
BUIDL now uses CapitalPip and routes its dividend yield to SDE. JTRSY uses
claimable redemption value, which can differ from the pipeline's share-NAV convention.

### Ethereum cash attribution

The replay now credits {money(cash_total)} USDS-equivalent of verified E21,
E38 and E42 receipts, including AUSD valued at par:

| Date | Venue | Income (USDS at par) | Evidence |
|---|---|---:|---|
{cash_table}

[Cash.sol](../src/Cash.sol) uses the existing authorized `sort(wad, MTM)` path.
Each reference includes chain ID, Tally, transaction hash and log index; the
same reference cannot be credited twice through this Cash deployment. Income
increases `gain` and decreases the unassigned `gap` by the same amount. It does
not create a position, mint cash, change NAV, or credit demand-side `owe`.
Supply-loss carry therefore applies normally. Receipt or reinvested asset
balances remain represented by their existing pips.

The writer supplies independently checked receipt evidence and classifies its
economic purpose. Cash does not verify logs on-chain. These four August
receipts follow the Python payer/venue attribution; returned principal,
transfers between own accounts and previously recognized yield must not be
submitted as new income. A known payer is not blanket authorization for all
future receipts. Use one authoritative Cash deployment per Tally; deduplication
does not extend across separate deployments or direct calls to `sort`.

Credits are applied after the corresponding day's marks in this accrual replay.
Tests check each credit leaves NAV and agent accrual unchanged, moves exactly
its amount from gap to gain, and matches the fixture transaction/log references.
Unit tests also cover reinvestment, duplicate rejection and supply-loss carry.
The collector verifies the successful receipts, tokens, payers, receiver,
amounts and log indices. Fixture SHA-256: `{digest(cash_raw)}`.
See [receipt data](grove-2026-08-cash.csv) and
[the fixture](../test/fixtures/grove-cash-2026-08.json).
Recollect with `ETH_RPC=<alchemy-compatible-rpc> python3 script/collect_grove_cash.py`.

The remaining prime-investment shortfall is
{money(r['prime_agent_revenue'] - t['gain'])} USDS:
{money(groups['Remote position'])} from remote-position revenue, plus
{money(local - t['gain'])} on the Ethereum positions already marked. E21's
cash income is now covered; its Avalanche principal is still not in local NAV.

### BUIDL update

| Metric | CapitalPip replay | Python provenance | Difference |
|---|---:|---:|---:|
| BUIDL dividend yield | {money(buidl_yield)} | {money(buidl_pipeline)} | {money(buidl_yield - buidl_pipeline)} |

The [verified transfer fixture](../test/fixtures/buidl-2026-08.json) contains
21 issuer mints and four outgoing transfers. Actual capital outflows total
75,000,000 USDS; the pipeline includes only 74,998,999 USDS because its
1M-USDS transfer threshold excludes the 1 and 1,000 USDS outgoing legs.
These small transfers go to the same recipient as their larger paired legs;
we classify all four as capital. This increases measured dividend revenue
by 1,001 USDS versus the provenance, rather than forcing agreement with its filter.
No capital subscriptions occur in this August fixture. Issuer-mint income
classification follows the baseline's policy for this observed set; a transfer
log by itself does not prove economic purpose for arbitrary future mints.

| Capital-outflow block | USDS | Evidence |
|---|---:|---|
{buidl_flows}

The collector uses Alchemy-compatible transfer discovery, verifies amounts
against block-local Transfer logs, and reconciles intermediate and boundary
balances. Fixture SHA-256: `{digest(fixture_raw)}`.
Recollect with `ETH_RPC=<alchemy-compatible-rpc> python3 script/collect_buidl.py`.

The fixture shows that dividends precede both paired outflows on August 24
and 31, with no intervening mints. To preserve the earlier daily borrowing-cost
comparison, the test first accrues against actual EoD balances, then stages
only the BUIDL pre-outflow balance with a test mock, marks yield, calls
`deal(-outflow)`, restores the real balance and marks the new capital shares.
This emulates capital attribution at the daily boundary; it is not execution
of historical transactions or proof of production hook permissions. A live
integration must mark and declare capital at the actual transfer time.

Before this update, BUIDL contributed zero index PnL. Total measured SDE yield
therefore increases by {money(buidl_yield)} USDS. Prime revenue is unchanged:
BUIDL's yield belongs entirely to Sky. The remaining SDE difference also
includes the roughly 279 USDS JTRSY claim-valuation difference.

The replay fixes the subsidy to 3.6613% on the first billion USDS of BLOOM debt.
The Python daily subsidy varies; its period-average subsidized rate is
{D(str(report['subsidy_summary']['sub_apr_avg'])) * 100:.6f}%. The cost residual
therefore includes subsidy configuration, daily versus monthly SSR conversion,
endpoint sampling on debt/SDE changes, and block timing. It is not solely an
SSR difference. No SOFR values are imported into Tally during this run.

See [all venue coverage](grove-2026-08-coverage.csv) and the
[Ethereum/cross-chain design](../docs/GROVE-CROSS-CHAIN.md).
Coverage config SHA-256: `{digest(config_raw)}`.
'''
    else:
        scope = '''
## Osero coverage

The example marks SparkLend spUSDS with ATokenPip and ALM USDS with RawPip.
LendingIdlePip supplies an IDL deduction for Osero's share of unborrowed pool
USDS; that deduction is not a second NAV asset. The 13M mid-month draw/deposit
makes endpoint sampling material: debt uses the higher endpoint, idle balances
the lower. Daily share/index marks also approximate intraday deposit timing.
The pipeline uses monthly SSR conversion; Tally uses the on-chain sUSDS index.
The table isolates investment revenue, net borrowing cost and agent accrual;
it does not claim a single rate-conversion explanation for all residuals.
'''
    execution_scope = (
        'or Till payments, no remote-chain replay, and no imported cash classifications.'
        if prime == 'osero' else
        'or Till payments and no remote-chain replay. Grove imports BUIDL capital\n'
        'classifications and E21/E38/E42 cash income from verified transfer fixtures.'
    )
    text = f'''# {prime.title()} — August 2026 historical accrual example

Deploy on a local Ethereum fork at block {first['block']} (July 31); preserve
Tally and its adapters through 31 end-of-day forks to block {last['block']}
(August 31). Each day calls `drip()` then `poke()`. Amounts are USDS at the
adapters' documented stablecoin-par convention; differences are Tally minus Python.

This is **historical accrual**, not a daily-payment counterfactual: no `settle`
{execution_scope}
Historical debt changes remain in the observations. Default gap routing is NIL.

| Metric | Tally | Python provenance | Difference |
|---|---:|---:|---:|
{table}

The unassigned closing equity gap is {money(t['gap'])} USDS. With NIL routing it
does not change the displayed PnL. For Grove, missing remote/off-chain assets,
cash classifications and internal transfers make it unsuitable for automatic
loss/profit routing. Neither example proves live allocator permissions or liquidity.
{scope}
## Baseline integrity

Baseline: `settlement-cycle/settlements/{prime}/2026-08/provenance.json`, generated
{report['generated_at_utc']}. The pipeline was not rerun or modified.
Provenance SHA-256: `{digest(raw)}`.
Summary SHA-256: `{digest(summary_raw)}`.

{chr(10).join(drift) if drift else 'No per-venue revenue discrepancies above one cent found between summary and provenance.'}

The stored `monthly_pnl` is {money(r['monthly_pnl'])} USDS. This report compares
prime economics using `prime_agent_revenue - (sky_revenue - sde_revenue) +
agent_rate`, then keeps the {money(extras)} USDS of additional demand rewards
separate. SDE revenue belongs to Sky and is already excluded from prime venue
revenue; subtracting total Sky revenue from that prime-only figure subtracts
SDE a second time. The provenance's `monthly_pnl` must not be used uncritically
as a like-for-like target. Grove's large incomplete-scope difference is not a
measured error in a complete Tally deployment.

## Reproduce

```sh
ETH_RPC=<archive-rpc> python3 script/compare_backtest.py {prime}
# Rebuild this report from the committed passing log:
python3 script/compare_backtest.py {prime} --log reports/{prime}-2026-08.log
```

Uses the standard library and the sibling pipeline checkout (`--pipeline` to
override). Validation checks the passing fork test, complete daily snapshots,
boundary blocks, all dates and debt readings, and pipeline revenue/cost sums.
See [daily data]({prime}-2026-08-daily.csv) and [fork output]({prime}-2026-08.log).
'''
    (out / f'{prime}-2026-08.md').write_text(text)
    print(table)
    print(f'Report: reports/{prime}-2026-08.md')


if __name__ == '__main__':
    main()
