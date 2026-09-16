# Tally architecture

Tally keeps accounting and settlement books for one Sky allocator ilk. This is
an unaudited reference implementation. Amounts are **wad** (`1e18`), prices/rates
are **ray** (`1e27`), and timestamps are seconds.

## Contracts

| Component | Responsibility |
|---|---|
| [Tally](src/Tally.sol) | Accrue charges, mark positions, classify equity changes and calculate settlement. Holds no operating funds. |
| [Till](src/Till.sol) | Hold the USDS float, draw through an AllocatorVault, pay the SubProxy and join Sky's net to the surplus buffer. |
| [Pips](src/pips/) | Read protocol-specific positions through a common valuation interface. [Pips.sol](src/Pips.sol) retains aggregate imports. |
| [Cash](src/Cash.sol) | Attribute approved receipts to prime supply income using transaction/log references. |
| [TallyJob](src/TallyJob.sol) | Schedule settlements once per UTC day and skip failing entries. |

Tally points to the position holder (`alm`), payment recipient (`sub`) and Till.
For several ilks sharing a SubProxy, exactly one Tally enables demand accrual
with `pay = 1`. Each exposure and utilization deduction must belong to the
correct ilk and appear only once.

## Position marks and the books

Each gem is a position key with a pip, optional holder override, tag, price
haircut, SDE cap and last mark. The key need not be the token address.
[PipLike](src/pips/Pip.sol) exposes:

```solidity
function peek(address who) external view
    returns (uint256 pie, uint256 chi, uint256 own);
```

`pie` is normalized floating shares, `chi` their asset price, and `own` separately
owned fixed claims. Claims must not also appear in the share value. Haircuts
apply to `chi`, not `own`. Pips must revert on unavailable data.

```text
value = pie * chi / RAY + own
index PnL = old pie * new chi / RAY - old pie * old chi / RAY
flow = new value - old value - index PnL
unresolved equity = gap + flux - capital
```

`flux` accumulates asset flows; `capital` accumulates observed investment debt
changes. Settlement moves their difference into `gap`. Default `route = NIL`
carries the gap for classification; automatic routing needs a complete book.

| Tag | Index PnL | Borrowing treatment |
|---|---|---|
| MTM | Prime `gain` | Ordinary utilization |
| SDE | Sky `sde` up to the cap; remainder to prime | Sky's slice reduces utilization |
| SAV | Prime `gain` | Savings-token spread rebated |
| IDL | None; memo slice excluded from NAV and flux | Reduces utilization |
| NIL | None; included in NAV, excluded from flux | No deduction |

`sort(signedAmount, MTM/SDE)` moves gap into an income bucket. `gift(amount)` adds
demand income to `owe`. Supply losses offset future supply gains, not demand
income. Cash uses sort, never adds an asset, and deduplicates receipts only within
its deployment. Classification and prevention of recognition through another
path remain the authorized writer's responsibility.

## Execution and integration hooks

**`drip()`** accrues on-chain sUSDS index growth plus a configured annual nominal
spread divided by 365 days. It uses the higher debt endpoint and lower demand/
rebate balance endpoints. Subsidized principal receives `cut` up to `line`;
IDL/SDE deductions reduce utilized debt across that same charge curve. SAV rebates
the spread. Applied rebates cannot exceed accrued charges (`tab`).

**`poke(gem)`** books index PnL and residual flow, then stores the new mark.
`poke()` marks all gems. Rebate-bearing positions require a fresh drip. Register
with `init`; use `file` for parameters. Changing valuation parameters or holders
requires fresh accrual and marks, then reseeds without booking the configuration
change as income.

Capital movements must execute atomically:

```text
drip(); poke();
perform draw / repayment / deposit / withdrawal
drip(); poke();
```

Endpoint sampling misses intraday round trips without these hooks. For LP
collection, reinvestment or liquidity/range changes, insert authorized
`sync(lpGem, uniqueReference)` immediately after the operation, before the final
marks. Sync treats the entire LP value delta as flow; separately marked cash
balances cancel internal transfers. Ordinary performance uses poke. Timestamp
and reference guards do not prove correct sequencing or economic purpose.

[CapitalPip](src/pips/CapitalPip.sol) additionally requires `deal(holder, signedAmount)`
before capital transfers. Undeclared arrivals can become yield. Full exits retain
the index. After a zero-index total loss, mark the loss and replace the pip with
a fresh share series at the normal configuration boundary before recapitalizing.

For an external settlement debt increase that does not fund investments, atomically
call `drip`, execute the increase, then `note(uniqueReference)` without an intervening
drip/settle. Note excludes that delta from capital attribution while keeping it
interest-bearing; it does not prevent duplicate economic payments.

## Settlement and permissions

`settle()` calls drip and poke, reconciles the gap, then calculates, before
rounding and payment constraints:

```text
sky = tab + sde - capped rebate
prime supply = gain + capped rebate - tab - prior supply loss
mint = sky + max(prime supply, 0)
send = demand owed + max(prime supply, 0)
```

Draws respect ilk/global debt headroom. Till pays from available USDS, including
its float, and joins Sky's net. Unpaid claims remain in `owe`, supply losses in
`sin`, and Sky/fractional carries in the books. Debt and payee samples refresh
after payment. Permissionless settlement has no daily restriction; only the job
sets a daily cadence. Call frequency also partitions interest-growth intervals.

Maker-style `wards`, `rely` and `deny` control configuration, attribution and
recovery. Only Till's immutable Tally can call `pay`. Till needs an ilk-scoped
draw capability and buffer allowance; neither contract needs Vat wards. Wards
remain trusted: they can configure accounting or rescue funds.

## Recovery and adapter boundaries

`halt(gem)` freezes its last valid mark/timestamp without a dependency read,
forces NIL routing, suppresses that gem's rebates and blocks all settlement.
NAV includes frozen values: consumers must check `stops` and `stopped(gem)`.
`mend(gem, replacementPip, reference)` closes accrual conservatively and leaves
the replacement value difference in unresolved gap. Missing yield/rebates require
review; they are not reconstructed automatically. `cage` permanently disables
settlement. See [lifecycle regressions](test/Lifecycle.t.sol).

New venues normally add a pip and protocol-specific tests, not branches in Tally.
Test normalization, holder isolation, price gains/losses, flows, full exits, queue
transitions and unavailable data. [Conformance](test/PipConformance.t.sol),
[conservation](test/Accounting.t.sol) and [allocator permissions](test/Permissions.t.sol)
tests provide starting points, not universal venue certification.

Par-valued adapters do not model depegs. UniV3Pip supports equal-decimal stablecoin
pairs and at most 32 holder NFTs; unsolicited NFTs can still block reads.
RelayPip checks receipt age, not source age, finality, ownership or bridge state.
Chronicle read permission is not a freshness policy. These assumptions need
explicit integration controls and independent review before payments.
