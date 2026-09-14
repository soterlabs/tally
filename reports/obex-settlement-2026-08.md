# Obex — August 2026 daily settlement simulation

Production `Tally` and `Till` execute 31 daily settlements using the historical
July 31–August 31 mainnet forks from the accrual backtest. Maple holdings and
prices, the sUSDS index, and timestamps are read on-chain. Simulated Vat, USDS,
AllocatorVault, AllocatorBuffer and join contracts persist the changing debt,
payments and surplus credits across forks. This tests economic behavior and
cash conservation; it is not an integration test of the deployed allocator's
permissions, collateral checks, USDS implementation, or global debt ceiling.
The simulated ilk ceiling is initialized from July 31; other ilks are not modeled.

## Scenarios

- **Current:** existing `settle()` behavior, zero initial float. Start at the
  actual July 31 debt and SubProxy balance. Preserve the August 17 settlement
  of **July's** earnings: +2,535,968 debt and +916,736 SubProxy USDS, once.
  August's daily Tally draws/payments are additional, earned in August.
- **Refresh:** same inputs, plus `drip()` immediately after each settlement,
  in the same transaction. This updates debt/SubProxy samples after Till pays.
  It demonstrates an integration improvement using existing public functions;
  production contracts were not modified.
- **Ceiling stress:** no draw headroom, 20,000 USDS initial float, no legacy
  July settlement injected. This is a synthetic liquidity test, not a second
  historical August comparison. The float is exhausted on August 02;
  subsequent unpaid amounts remain in `owe` and undrawn amounts in `sde`.

The tests assert unchanged ALM shares and idle balances throughout the month,
zero historical SubProxy sUSDS, and exactly one historical debt/payment change.
They fail if those assumptions cease to hold.

## Results (USDS)

| Accrual metric | Python monthly report | Current daily settlement | With post-payment refresh |
|---|---:|---:|---:|
| Investment revenue | 1,631,729.31 | 1,631,729.31 | 1,631,729.31 |
| Borrowing costs | 1,248,716.85 | 1,249,503.01 | 1,249,503.01 |
| Agent-rate income | 75,327.60 | 75,760.97 | 75,805.31 |
| Net PnL, paid plus owed | 458,340.06 | 457,987.27 | 458,031.61 |

The current daily-settlement net PnL differs from the Python report by
-352.79 USDS.
The refresh adds 44.34
USDS of agent-rate income. Its borrowing costs are unchanged: debt only grows
in this simulation, so the larger endpoint debt already includes each prior draw.
Paid balances then feed back into subsequent agent-rate accruals.

These figures differ from the [accrual-only replay](obex-2026-08.md), because
daily draws and payments now remain in the next day's balances. No hypothetical
new investments or discretionary withdrawals are modeled. Both normal scenarios
pay every whole-USDS claim and need no starting float for this profitable month;
that is not a general float-sizing result.

| Cash and closing balances | Current | Refresh | Ceiling stress |
|---|---:|---:|---:|
| August debt drawn | 1,631,729.00 | 1,631,729.00 | 0.00 |
| August paid to SubProxy | 457,987.00 | 458,031.00 | 20,000.00 |
| August joined to Vow | 1,173,742.00 | 1,173,698.00 | 0.00 |
| Closing debt | 404,163,469.00 | 404,163,469.00 | 399,995,772.00 |
| Closing SubProxy USDS | 25,134,509.00 | 25,134,553.00 | 23,779,786.00 |
| Unpaid claim / payout rounding | 0.27 | 0.61 | 442,380.75 |
| Undrawn amount / draw rounding | 0.31 | 0.31 | 1,631,729.31 |
| Closing float | 0.00 | 0.00 | 0.00 |
| Unassigned equity gap | -2,535,968.00 | -2,535,968.00 | 0.00 |

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

All three tests pass. Neither normal scenario has a supply loss; the existing
unit suite covers negative-supply carries. The legacy equity gap remains
-2,535,968 USDS with `route = NIL`. It is the July settlement's debt movement,
not an investment loss. Each Tally-owned daily draw is already excluded correctly.
The proposed authorized legacy-settlement hook would remove this gap without
removing the debt from the borrowing-cost base; that hook is not implemented here.

Source: committed Python August `provenance.json`, SHA-256
`e0684e29ae36278f36e79d02a5a4cf72ea3cc76de549bb3c0356573819b38fb8`. Python was not regenerated.
See [daily balances](obex-settlement-2026-08-daily.csv),
[test output](obex-settlement-2026-08.log), and
[simulation source](../test/ObexSettlement.t.sol).

Reproduce: `ETH_RPC=<archive RPC> python3 script/simulate_obex.py`.
