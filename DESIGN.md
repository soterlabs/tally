# Tally accounting design

This is the authoritative description of the current reference implementation.
The MSC process remains the comparison baseline. Tally has not been independently
audited or deployed to a live network. See [the discussion brief](docs/TALLY_DISCUSSION.md)
for the proposed pilot and decisions still needed from Sky teams.

## Components and authority

One **Tally** holds the books for one allocator ilk. **Till** holds its USDS float
and executes draws, prime payments and surplus joins. Till accepts payment
instructions only from its immutable Tally; Tally and Till need no Vat wards.
Till needs an ilk-scoped allocator draw capability and a buffer USDS allowance.
Its administrative wards can configure or rescue funds, so they remain trusted.

**Pips** implement `peek(holder) -> (pie, chi, own)`: normalized shares in wad,
share price in ray, and separately owned fixed claims in wad. New venues normally
add an adapter, with no protocol branch in Tally. This interface is a valuation
contract, not proof of ownership, freshness, economic classification or completeness.

**Cash** references approved Ethereum receipts and classifies supply income.
**TallyJob** proposes one settlement per UTC day through the keeper network.
Permissionless `settle` itself has no daily limit. A failing due-read or settlement
is skipped by the job; monitoring must detect books that are no longer advancing.

A prime with several ilks uses several Tallies, with exactly one paying the
shared SubProxy's demand income. Positions and deductions must be assigned to
their actual funding ilk without duplication. Grove's replay groups Ethereum
positions for comparison; it is not a verified production funding-ilk map.

## Recognition and equity

For each gem:

```text
value = pie * chi / RAY + own
index PnL = old pie * new chi / RAY - old pie * old chi / RAY
flow = new value - old value - index PnL
unresolved equity = gap + flux - capital
```

`capital` tracks observed debt changes, excluding Tally's own settlement draws
and explicitly referenced external settlement debt. `flux` aggregates asset flows.
At settlement, their difference enters `gap`. Default `route = NIL` carries that
gap for review. Enabling automatic routing requires a complete, reconciled
perimeter; missing remote assets or monthly debt attribution can otherwise become
false investment losses.

| Tag | Income | Borrowing treatment | NAV |
|---|---|---|---|
| MTM | Prime gain/loss | Ordinary utilization | Included |
| SDE | Sky yield up to configured cap; remainder to prime | Sky slice reduces utilization | Included |
| SAV | Prime savings-token yield | Spread rebated | Included |
| IDL | No index income; memorandum slice | Reduces utilization | Excluded |
| NIL | No income or equity classification | No deduction | Included |

`sort(signedAmount, MTM/SDE)` moves an amount from gap into the chosen income
bucket. It is a trusted classification, not a transfer or proof of earnings.
`gift(amount)` credits demand income and is not interchangeable with `sort`:
supply losses do not offset demand claims. Cash wraps prime-side sort with
transaction/log deduplication per Cash deployment. One authoritative attribution
ledger must prevent duplicate recognition through other wrappers, index marks,
direct sort, or automatic routing; corrections use a signed sort with evidence.

## Rates, timing and flow hooks

`drip` reads the actual on-chain sUSDS index. It prices interval SSR growth plus
a nominal annual spread divided by 365 days. The debt sample is the higher
endpoint; demand and rebate balances use the lower endpoint. Subsidized debt
is charged at `cut` up to `line`; the remaining debt receives the full base rate.
IDL and SDE deductions reduce net utilized debt across that same subsidy curve.
SAV additionally rebates the spread. Applied rebates cannot exceed accrued `tab`.

This prices the observed SSR index, but does not integrate changing balances.
An intraday borrow-and-repay can disappear between observations. Integrations
must atomically `drip; poke`, move capital, then `drip; poke`. Configuration
changes require fresh samples so old intervals are not repriced retrospectively.
Different permissionless call cadences also partition SSR growth differently;
timing economics must be agreed before enabling payments.

Some operations change an adapter's index without investment performance.
For an LP collect, liquidity/range change or reinvestment, use:

```text
drip(); poke();
perform the LP operation and its cash transfers
sync(lpGem, uniqueReference);
drip(); poke();
```

`sync` refreshes the LP mark and records its entire value delta as flow, preserving
previously marked income. Received cash is marked separately, so internal transfers
cancel in aggregate flux. It requires authorization, current timestamp samples and
a nonzero one-use reference. Those guards cannot prove that the operator actually
marked before the operation or that no profit was hidden; the integration must
execute the sequence atomically. Ordinary price changes must use `poke`, not sync.
UniV3Pip returns only live LP assets and fees; the former collected-fee accumulator
has been removed. It supports equal-decimal stablecoin pairs at par and at most
32 holder NFTs; unsolicited NFTs can still impair availability. Range changes and
full exits require the same flow checkpoint.

CapitalPip requires initial capital and each subsequent capital transfer to be
declared with `deal` before tokens move. Full exits retain the last index, preserving
earned profit or loss across re-entry. A total loss produces a zero index and rejects
new declarations: mark the loss, replace with a fresh CapitalPip at the normal
fresh configuration boundary, then declare new capital. This starts a new share
series without reviving written-off shares. Undeclared receipts with no declared
shares appear as `own`; they require explicit income attribution.

## Settlement and monthly coexistence

Ignoring whole-USDS rounding and carries for readability:

```text
sky = tab + sde - capped rebate
prime supply = gain + capped rebate - tab - prior supply loss
mint = sky + max(prime supply, 0)
send = demand owed + max(prime supply, 0)
```

Draws are limited by ilk and global debt headroom. Till pays from available cash,
including its float, and joins Sky's net to the surplus buffer. Unpaid prime
claims remain in `owe`; negative supply income remains in `sin` against future
supply income. Unfunded Sky claims and fractional amounts carry in the books.
Post-payment debt and SubProxy samples are refreshed in the same transaction.
The [Obex simulation](reports/obex-settlement-2026-08.md) checks the multi-day
cash/debt feedback and conservation identities.

For an external monthly capitalization, atomically `drip`, execute the settlement
debt increase without ALM investment funding, then `note(reference)`. This excludes
the observed increase from investment capital, while retaining the debt for future
interest. It does not net or cancel monthly payments: the MSC process must subtract
obligations already settled by Tally. References prevent replay of a hook, not
payment under a different reference.

Prime investment revenue is already net of SDE income but before borrowing costs.
Prime supply revenue subtracts net borrowing costs; Sky supply revenue includes
those costs **plus** SDE income. Do not subtract total Sky revenue again from the
prime-only investment figure. Generated reports identify saved MSC summary versus
provenance discrepancies rather than silently mixing versions.

## Dependency failure and recovery

A ward can `halt(gem)` without calling its pip. This freezes the last mark, forces
NIL routing and blocks **all settlement** while any gem is halted. NAV can still
be read but includes explicitly stale values; consumers must check `stops` and
`stopped(gem)`. Quarantined gems earn no rebates during accrual, including the
unobserved interval preceding halt. Other positions and gross interest continue.

`mend(gem, replacementPip, reference)` closes accrual under that conservative
policy, reads the replacement, and seeds its mark. For assets in the equity book,
the entire replacement value difference enters unresolved `gap`, not index income.
It preserves previous earnings, claims and flows. The last successful repair
unblocks settlement; governance reviews the missing interval and uses signed sort
for approved income/loss corrections. Missing rebates are not automatically restored.
Multiple broken pips can be halted independently; a failed repair rolls back.

Recovery trusts governance valuation and classification. It does not establish
that the replacement is correct or that all missing history has been recovered.
Normal `file` freshness guards remain in force. `cage` is irreversible; it stops
settlement and administration, while Till rescue remains available. A halt is the
recoverable dependency response, not a replacement for a system shutdown.

## Evidence and remaining boundaries

Current numerical results live in generated [Obex](reports/obex-2026-08.md),
[Osero](reports/osero-2026-08.md), and [Grove](reports/grove-2026-08.md) reports.
Their packaged MSC baselines include hashes, source revision and a minimal venue
chain map. Saved-log regeneration is offline; new observations require archive RPC.
A report's closeness to its baseline does not prove either accounting policy.

Tests cover settlement conservation, supply-loss carry, adapter lifecycle flows,
async claim transitions, cash attribution, failed feeds and keeper isolation.
The permissions fork rehearses actual allocator draw, buffer allowance, pay and
surplus join using impersonated authorities on an isolated historical fork.
That is not approval of production permissions or a deployed integration.

Remote marks still need source finality, source age, domain/sequence protection
and bridge-transfer reconciliation. RelayPip only enforces local receipt age.
Chronicle access permission is not a freshness policy. Par pricing does not model
depegs; off-chain claims need approved valuations. Gas bounds, operational recovery,
cash classification and independent security review remain release-to-production
requirements. See [adapter integration requirements](docs/ADAPTERS.md) and the
[release review disposition](docs/RELEASE-REVIEW.md).
