# Adapter and integration contract

Tally owns accounting policy; Till owns cash movement and allocator permissions;
each pip owns one protocol-specific valuation. New protocols should normally add
a pip, not a new branch in Tally. Maker-style `wards`, `file`, `drip`, `poke` and
`cage` remain the administrative and operational vocabulary.

## ABI and units

Import `PipLike` or the abstract `Pip` from `src/pips/Pip.sol`.

```solidity
function peek(address who) external view
    returns (uint256 pie, uint256 chi, uint256 own);
```

| Field | Meaning | Scale |
|---|---|---|
| `pie` | Shares held, including eligible in-flight shares | wad, 1e18 |
| `chi` | USDS-equivalent assets per normalized share, before Tally's haircut | ray, 1e27 |
| `own` | Assets owned outside those shares, such as fixed redemption claims | wad, 1e18 |

`value = pie * chi / 1e27 + own`. Normalize both share and asset decimals;
normalization rounds down. `own` must never also be counted in `pie * chi`.
Zero holdings must return zero value. `who` is the requested holder, not the
caller. A pip may be shared by multiple gems/holders; it must not mix them.

Existing `RawPip`, ERC-4626 and aToken adapters assume a par USD underlying.
Decimal normalization is not a USD conversion. An ETH-denominated vault, for
example, needs an additional price conversion with an explicit oracle policy.
Raw stablecoin pricing does not recognize depegs. These are registration
assumptions, not properties proved by the ABI. Curve and UniV3 adapters also
have protocol/pair-specific assumptions documented in their source.

## Revenue and capital

Tally books `pie_old * (chi_new - chi_old) / 1e27`, subject to integer rounding.
A deposit or withdrawal at an unchanged price changes `pie`/`own`, not `chi`.
An appreciation changes `chi`, not the share quantity. Book the move before
changing the share count to avoid assigning an interval's yield to a new balance.

Token/cash distributions are not automatically distinguishable from deposits.
Use `CapitalPip` with authorized, atomic capital declarations, or relay an
explicit share/index decomposition and reconcile the equity gap. These introduce
trust in the declaring writer. `own` changes enter the gap rather than the
index-PnL bucket. UniV3 fee collections, liquidity/range changes and reinvestment
require a pre-operation mark and post-operation `Tally.sync(gem, reference)`.
UniV3Pip contains only live assets; collected cash is marked separately. It
rejects mixed-decimal pools and holders with more than 32 NFTs.

Mixed depositor/allocator funding must be attributed before registration. Only
the in-scope assets/yield belong in the pip. The ABI does not represent negative
net asset value or a separate liability book; a position that needs these is
not faithfully represented by blindly registering its gross token balance.

Full CapitalPip exits retain the index rather than resetting earned income.
For a zero-index total loss, mark the loss first, replace the pip with a fresh
share series using the normal fresh `file` boundary, then declare new capital.
Do not seed new money into written-off shares. See [the design](../DESIGN.md#rates-timing-and-flow-hooks)
for the complete LP flow sequence and its authorized-caller trust assumption.

## Tags and registration

| Tag | Index PnL | Rate treatment |
|---|---|---|
| `MTM` | Prime `gain` | Full borrowing cost unless another eligible slice offsets it |
| `SAV` | Prime `gain` | Spread reimbursement for debt-funded Sky savings assets |
| `SDE` | Sky `sde` up to its configured slice; remainder to prime | Sky's slice excluded from net utilized debt |
| `IDL` | None; memorandum item, excluded from NAV | Idle slice excluded from net utilized debt |
| `NIL` | None; tracked in NAV, outside equity attribution | No rebate |

Do not register overlapping IDL/SDE deductions for the same capital. Tally
caps the aggregate deduction at debt, but cannot identify economic overlap.
The subsidy applies to **net utilized debt**. The IDL/SDE rebate is the difference
between the gross and net charge curves, not a single marginal rate times idle.
SAV's extra spread credit is separate; the total applied rebate never exceeds
`tab`. SubProxy sUSDS earns the spread on current asset value, not cost basis.

Deploy the pip, accrue and mark existing positions, then call
`init(gem, pip, tag)`. The gem address is a unique position key; it need not be
the actual token address. Use `file(gem, "who", holder)` for a holder override;
zero means the default ALM. `fee` is a wad haircut on `chi`, not on `own`.
`cap` is the wad SDE asset slice, with zero meaning the whole position.

Before changing a gem's fee/cap/tag/holder/pip: `drip()`, then `poke(gem)`, then
`file(...)`, all atomically. ALM changes require `drip()` and `poke()` on every
gem first. A SAV/IDL/SDE `poke` itself requires fresh `drip`, so a caller cannot
replace an unaccrued rebate sample. Initialization seeds a mark without booking
old yield; changing configuration reseeds under the new parameters.

## Capital movements and monthly spells

Every capital movement should execute this sequence atomically:

```text
drip(); poke();
perform draw / repayment / deposit / withdrawal
drip(); poke();
```

This records old balances for the preceding interval and new balances for the
next. Endpoint sampling without these hooks cannot detect an intraday loan
that is repaid before the next observation. A permissionless caller may advance
the clocks; it cannot reconstruct missing history. `settle()` refreshes its
own post-payment debt and SubProxy balances automatically.

For an **external monthly settlement**, an authorized integration instead uses:

```text
drip();
execute settlement debt increase and SubProxy payment (no ALM investment flow)
note(unique_reference);
```

`note` records the actual positive `debt() - art` and updates the samples,
excluding that delta only from ALM capital attribution. Interest still accrues
on the full new debt. No arbitrary amount is accepted. The reference is nonzero
and one-use per Tally. No intervening `drip`/`settle` is allowed. The timestamp
guard alone does not prove atomicity or economic purpose: the authorized spell
must enforce the sequence and attest that the debt really belongs to settlement.
It must not mix investment flows into that same bracket. If a monthly payment
does not increase debt, use a normal post-payment `drip()` instead of `note`. The hook cannot repair
already recognized gaps retroactively. An authorized ward has broad accounting
power through `file`/`sort` already; grant it deliberately.

The monthly process must net amounts already paid/capitalized by daily settlement.
Reference uniqueness prevents replaying a classification, not double-paying the
same economic obligation under different references. July's outstanding payment
can coexist with August's daily earnings; August's earnings must not be paid again
in full by September's monthly spell.

## Missing data and reconciliation

Revert on unavailable inputs rather than returning a plausible zero. Define
staleness per source. `RelayPip` enforces its configured `hop`; other adapters
depend on the underlying protocol/feed and do not add a universal timestamp
check. Chronicle read authorization is not by itself a freshness guarantee.

A stale mark makes settlement revert and the keeper skip that instance.
For a permanently broken pip, `halt(gem)` freezes the last mark without a read,
blocks settlement and stops that gem's rebates. `mend(gem, pip, reference)` closes
the conservative accrual interval and records the replacement value difference
in unresolved gap. It does not silently recognize missing yield. Governance
must review the difference and any missing rebate before approving corrections.
See [the recovery procedure](../DESIGN.md#dependency-failure-and-recovery).
Consumers of NAV must check `stops`: halted marks are stale, not live values. An
unfunded or unset Till can carry claims; a caged configured Till or failed draw
reverts the whole transaction. Monitor `zzz`, `owe`, `sde`, `sin`, `gap` and the
`Settle`, `Pay`, `Gap`, `Note` events to distinguish paid, carried and unclassified
amounts. Keep `route = NIL` until the tracked perimeter is complete and external
settlement debt is classified. Do not treat a bridge out of that perimeter as
an investment loss by default.

## Tests for a new adapter

Extend `PipConformance` in `test/PipConformance.t.sol` for normalization, zero
holdings, holder isolation and deposits at a constant index. Its fixtures assume
par initial pricing and 6-decimal fund increments; adapt the fixture deliberately.
It currently runs against raw, ERC-4626, ERC-7540, aToken and capital adapters.

Add protocol-specific tests for price appreciation/losses, partial/full redemption,
all queue states, non-18 decimals, fees, zero supply and stale/missing inputs.
Check direct value reconciliation and that capital movements book no index PnL
when bracketed. For relay/declaration adapters, test unauthorized and stale writes.
Add a pinned historical fork comparison for production venues; the shared tests
do not establish protocol-specific correctness or coverage by themselves.

Individual adapters can be imported from `src/pips/<Name>.sol`. Existing named
imports from `src/Pips.sol` remain supported. No delegatecall or proxy layer is
introduced by splitting the source files.

For separate Ethereum cash distributions, use the existing equity path rather
than adding a duplicate NAV position. [Cash](../src/Cash.sol) wraps `sort` with
transaction/log-reference deduplication; see the [Grove integration](GROVE-CROSS-CHAIN.md#cash-attribution-integration)
for its trust, scope and correction requirements. This preserves supply-loss
carry and keeps cash attribution separate from demand-side `gift` credits.
