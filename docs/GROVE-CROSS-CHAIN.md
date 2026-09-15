# Grove: one Ethereum settlement book, several sources of evidence

**Ethereum can host Grove's consolidated accounting and settlement. Ethereum
reads alone cannot establish every remote holding, pending transfer, or
off-chain claim.** The current replay covers an Ethereum subset. Full coverage
needs authenticated remote observations and explicit capital/cash attribution;
the remote integrations are not implemented by this example. Ethereum cash
attribution for E21/E38/E42 is now implemented through Cash and verified
August receipt fixtures.

This assessment uses the frozen MSC August 2026 reports and venue configuration
packaged in `test/fixtures/msc`; it is not a current deployment inventory.
The [backtest report](../reports/grove-2026-08.md) records source hashes and
baseline discrepancies. The [coverage CSV](../reports/grove-2026-08-coverage.csv)
classifies every revenue venue and display-only holding in that snapshot.

## What Ethereum can cover

| Grove allocations | Available evidence | Remaining work |
|---|---|---|
| Ethereum Aave, Morpho, Maple, STAC, JAAA, JTRSY, Curve, Uniswap, raw balances | Local balances, vault indices, oracle prices and claims | Existing pips cover the basic reads. Integrate movement/fee hooks, oracle permissions/freshness and claim valuation. |
| E10 BUIDL | Local token balance, including dividend mints | The updated replay uses CapitalPip with opening capital and verified August outflow declarations. Live subscriptions/redemptions still need atomic hooks; mint classification remains an explicit policy. |
| E19/E23 Base Morpho; E27 Base idle | Remote shares, balances and vault index | Relay authenticated remote state. An Ethereum bridge escrow balance does not establish Grove's current vault shares or yield. |
| E20 Avalanche JAAA | Ethereum NAV feed; Avalanche holder balance | Keep the NAV local if appropriate; relay ownership and pending claims. A local price alone is insufficient. |
| E22 Plume ACRDX | Ethereum price feed; remote shares and redemptions | Relay the remote position and distinguish actual redemption proceeds from indicative NAV. The pipeline config explicitly uses a separate redemption-pricing convention. |
| E21 Avalanche GACLO | Remote principal; USDC distributions arriving on Ethereum | August income receipts are credited through Cash. Remote principal and future principal/yield classification remain separate requirements. |
| E38 Agora and E42 Galaxy Warehouse | Ethereum cash receipts; external attribution and, for E42, an off-chain facility claim | Cash now credits the verified August receipts once under the pipeline attribution policy. The off-chain claim, future receipt classification and income-period policy still require external evidence. |
| E25/E33–E35 Monad and E36 relay principal | Remote/relay information | Python treats these as display-only in this snapshot. Preserve that scope explicitly; do not silently include their values in paying PnL or treat exclusion as proof they are riskless. |

Some source-config comments predate the current entries (for example the
cross-chain rollout heading). This inventory follows the actual configured
venues and report rows. Ethereum ERC-7540 adapters do not automatically cover
the same token's holder balances on another chain.

## Proposed integration

Keep one Tally/Till per Ethereum allocator ilk. Assign each remote exposure to
its funding ilk, and accrue Grove's shared SubProxy agent rate only once. A
remote-chain observer produces position marks; it does not create a second
copy of the same Sky debt or a second settlement liability. The current fork
fixture aggregates both books and registers the observed Ethereum positions
on BLOOM, including additional holders. It does not validate which ilk funded
each position; live per-ilk settlement requires that mapping to be reconciled.

1. Use the same normalized `pie`, `chi`, `own` convention locally and remotely.
   `pie` is capital shares, `chi` is the USDS-valued index, and `own` is an
   additional non-overlapping claim. Relaying NAV as the index of one permanent
   share would turn new deposits into profit. Fees, impairments and currency
   assumptions must match the asset's accounting policy.
2. Put an authenticated receiver in front of RelayPip. Bind the source chain,
   asset/vault, holder, funding ilk, source block/hash, source timestamp and
   sequence number. Reject wrong-domain, duplicate, out-of-order, future and
   over-age observations. Define source finality and a correction procedure.
   A configured trusted publisher is a possible initial trust model; it must
   not be described as a verified bridge proof.
3. Publish coherent batches across local cash, remote positions and in-transit
   claims. Each transfer reference has one recognized location at each step:
   source cash, recoverable transit claim, destination cash/shares. Replace
   the prior representation when the next one becomes authoritative. Inbound
   transfers follow the reverse path. Bridge fees or impaired claims need an
   explicit loss treatment rather than disappearing as unexplained capital.
4. Synchronize observation cutoffs before settlement. Remote block time and
   Ethereum receipt time differ. `drip()` uses Ethereum time, and RelayPip
   currently stamps receipt time only; it cannot retroactively accrue an old
   remote snapshot at its original time. Source-age checks and an explicit
   late-data/correction policy are required. Do not settle live local balances
   against yesterday's remote ownership and assume the equity gap is PnL.
5. Reconcile capital and cash before enabling gap routing. Keep NIL while
   any remote/transit/external attribution is unresolved. Within one ilk,
   internal transfers should have zero aggregate capital flow. Cross-ilk moves
   need matched attribution in both books; the current `note(ref)` only
   classifies external settlement debt and is not a general transfer ledger.

The synthetic [CrossChainExampleTest](../test/CrossChainExample.t.sol) exercises
400 USDS leaving Ethereum, appearing as a transit claim, becoming remote vault
shares, earning 20 USDS, partially redeeming back to Ethereum, then losing
20 USDS on the remaining shares. At every step total NAV and PnL conserve and
the unexplained capital gap is zero. It also verifies stale marks stop
settlement atomically. This demonstrates the accounting representation under
a trusted, coherent writer; it does not validate actual Grove transfers,
source finality, message authentication or historical remote PnL.

```sh
forge test --match-contract CrossChainExampleTest -vv
```

## Current adapter limits

RelayPip already provides authorization, holder-specific marks and a receipt-age
limit. It has no source-chain identity, source timestamp, nonce, transfer ledger
or correction/finality mechanism. A fresh publication of old data passes its
receipt-age check. The receiver and operational protocol above are necessary
before using it as evidence for cross-chain settlement.

CapitalPip requires explicit initial capital and subsequent capital movements;
an undeclared inflow may be treated as yield, and a zero-share `own` balance
does not automatically enter Tally's index PnL. Full exits preserve its index;
zero-value recapitalization starts a fresh share series after marking the loss.

UniV3Pip now values only live positions and accrued/owed fees. It has no cumulative
collected-cash credit. Mark performance before each collection, liquidity/range
change or reinvestment, then use `Tally.sync` after the operation and mark the
received cash separately, atomically. This preserves earned fees without inflating
NAV or diluting prior income on new capital. The August historical replay still
samples LPs daily without reconstructing these operation hooks; its agreement
with the saved MSC provenance is not evidence of a complete LP integration.

Distribution rewards and Chronicle points remain separately attributed demand
income. `gift` can credit approved amounts, but currently has no reference-based
deduplication; a production wrapper must prevent duplicate claims. Supply-side
cash income must not be passed through `gift` merely to make totals agree,
since that bypasses supply loss carry and changes payment semantics.

## What full coverage would require next

BUIDL capital attribution is now reconstructed from 25 verified August
transfers; see the report for the 1,001 USDS threshold difference with Python.
E21/E38/E42 cash receipts are now verified and credited through Cash using
transaction/log references; they no longer contribute to the prime-revenue
coverage shortfall. To complete historical Grove coverage, reconstruct LP fee
events, then replay Base, Avalanche and
Plume from their pinned blocks with matched transfer references. Add remote
queues, loss/recovery cases and cross-ilk reconciliation before simulating
Till payments. Reconcile the source report versions first: the current summary
and provenance disagree on E12 and E22, so there is no single unambiguous
published target for those rows.

The present examples establish local accrual behavior and enumerate what is
missing. They do not support a claim that Grove is already fully covered by
Ethereum-only reads, or that the remaining difference is all cross-chain PnL.

## Cash attribution integration

`Cash` is an authorized wrapper around `Tally.sort(wad, MTM)`, with one credit
per chain/Tally/transaction/log reference **within that Cash deployment**.
Deploy one authoritative Cash per Tally, grant it a Tally ward, and restrict
its writer wards to the receipt-classification process. A replacement deployment
needs migration/reconciliation of consumed references; separate wrappers and
direct `sort` calls do not share the deduplication ledger.

The writer verifies receipt success/finality, token, receiver, payer, amount,
USDS conversion policy, economic purpose and previous recognition. `Cash` does
not verify an Ethereum log proof. Approved supply-income receipts are credited;
principal returns and internal transfers are left as capital, and previously
recognized yield must not be recognized again when paid in cash. The August
example uses USDC/AUSD at par and the Python E21/E38/E42 payer classifications.
That policy is explicit rather than a permanent rule that all payer transfers
are revenue. Attribute before automatic gap routing, or explicitly exclude
receipts already recognized by a previous route/mark/credit; reference
deduplication alone cannot detect recognition through another accounting path.

Mark the existing cash/position balances and call `Cash.note(txid, logidx, wad)`.
The note increases supply gain and subtracts the same amount from unassigned
equity. NAV, debt, float and demand-side accrual do not change. It remains valid
after cash is reinvested: the position movement is capital and must not be
credited again. Supply income first offsets any accumulated supply loss at
settlement; it does not bypass this through `gift`.

Cash currently supports positive attribution only. A mistaken classification
requires an authorized signed `Tally.sort` correction and an audit record;
the original receipt remains consumed. A correction after settlement affects
a subsequent cycle rather than reversing an executed payment. The authorized
operator remains responsible for matching credits, corrections and supporting
evidence. Neither Cash nor the fixture is a generic proof of off-chain income.
