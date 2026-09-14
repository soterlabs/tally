# Grove: one Ethereum settlement book, several sources of evidence

**Ethereum can host Grove's consolidated accounting and settlement. Ethereum
reads alone cannot establish every remote holding, pending transfer, or
off-chain claim.** The current replay covers an Ethereum subset. Full coverage
needs authenticated remote observations and explicit capital/cash attribution;
those integrations are not implemented by this example.

This assessment uses the local `settlement-cycle/config/grove.yaml` and August
2026 reports, not an independently verified inventory of today's deployments.
The [backtest report](../reports/grove-2026-08.md) records source hashes and
baseline discrepancies. The [coverage CSV](../reports/grove-2026-08-coverage.csv)
classifies every revenue venue and display-only holding in that snapshot.

## What Ethereum can cover

| Grove allocations | Available evidence | Remaining work |
|---|---|---|
| Ethereum Aave, Morpho, Maple, STAC, JAAA, JTRSY, Curve, Uniswap, raw balances | Local balances, vault indices, oracle prices and claims | Existing pips cover the basic reads. Integrate movement/fee hooks, oracle permissions/freshness and claim valuation. |
| E10 BUIDL | Local token balance, including dividend mints | RawPip reads balance but cannot distinguish dividends from subscriptions. CapitalPip can model declared capital and residual yield if every capital movement is bracketed. Historical event reconstruction is still needed. |
| E19/E23 Base Morpho; E27 Base idle | Remote shares, balances and vault index | Relay authenticated remote state. An Ethereum bridge escrow balance does not establish Grove's current vault shares or yield. |
| E20 Avalanche JAAA | Ethereum NAV feed; Avalanche holder balance | Keep the NAV local if appropriate; relay ownership and pending claims. A local price alone is insufficient. |
| E22 Plume ACRDX | Ethereum price feed; remote shares and redemptions | Relay the remote position and distinguish actual redemption proceeds from indicative NAV. The pipeline config explicitly uses a separate redemption-pricing convention. |
| E21 Avalanche GACLO | Remote principal; USDC distributions arriving on Ethereum | Relay principal and classify receipts into principal, yield and fees. Do not book a repayment as revenue. |
| E38 Agora and E42 Galaxy Warehouse | Ethereum cash receipts; external attribution and, for E42, an off-chain facility claim | Receipt evidence does not prove the economic claim or income period. Add an authorized, referenced classifier and a valuation policy for the external claim. |
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

CapitalPip and UniV3Pip have useful declaration hooks, but they are not generic
cash-event classifiers. CapitalPip requires explicit initial capital and every
subsequent capital movement; an undeclared inflow may be treated as yield, and
a zero-share `own` balance does not automatically enter Tally's index PnL.
UniV3Pip's collected-fee accumulator preserves revenue attribution, but is not
live capital: if received cash is also marked, the cumulative collect credit
must be reconciled to avoid inflating NAV. A dedicated receipt/realized-PnL
ledger should keep revenue credits separate from spendable assets, with event
references and reversals. This example does not change those contracts or
claim that calling a hook alone closes all of Grove's gaps.

Distribution rewards and Chronicle points remain separately attributed demand
income. `gift` can credit approved amounts, but currently has no reference-based
deduplication; a production wrapper must prevent duplicate claims. Supply-side
cash income must not be passed through `gift` merely to make totals agree,
since that bypasses supply loss carry and changes payment semantics.

## What full coverage would require next

A full historical Grove example should reconstruct Ethereum BUIDL capital and
LP fee events, classify E21/E38/E42 receipts, then replay Base, Avalanche and
Plume from their pinned blocks with matched transfer references. Add remote
queues, loss/recovery cases and cross-ilk reconciliation before simulating
Till payments. Reconcile the source report versions first: the current summary
and provenance disagree on E12 and E22, so there is no single unambiguous
published target for those rows.

The present examples establish local accrual behavior and enumerate what is
missing. They do not support a claim that Grove is already fully covered by
Ethereum-only reads, or that the remaining difference is all cross-chain PnL.
