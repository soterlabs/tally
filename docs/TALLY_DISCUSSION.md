# Tally: on-chain accounting and settlement for Sky prime agents

**Discussion brief · September 2026 · Reference implementation, not audited or deployed**

## Purpose and proposed scope

The **MSC process** currently calculates monthly prime-agent results and supports
settlement. Tally explores whether part of that accounting and settlement can
run on Ethereum: observable books, explicit allocation of income between Sky
and primes, and more frequent settlement.

The practical proposal is hybrid. Contracts calculate what their inputs can
establish; authorized operators still supply classifications and evidence for
cash income, remote positions and off-chain claims. The initial objective should
be a parallel accounting pilot alongside the MSC process, with payments enabled
only after accounting conventions, permissions and operating procedures agree.

## How it works

- **Tally holds the books**, normally one instance per allocator ilk. It accrues
  borrowing costs using the on-chain sUSDS index plus a configured spread,
  applies subsidies and utilization deductions, and tracks prime and Sky income.
- **Pricing adapters (“pips”) read positions** through a common interface.
  Changes in shares represent capital movements; changes in the share-price
  index represent investment PnL. Adapters cover vaults, lending positions,
  liquidity pools, token balances, declared-capital positions and relayed marks.
- **An equity reconciliation tracks unexplained movements.** Flows between
  positions and debt-funded capital should reconcile. An unexplained balance
  is reported separately; it should not automatically become profit or loss
  while the accounting perimeter is incomplete.
- **Till moves settlement cash** through existing allocator permissions, within
  debt ceilings. It pays the prime and transfers Sky's proceeds to the surplus
  buffer. Unpaid amounts and rounding fractions carry forward. Supply losses
  offset future supply gains; demand income is tracked separately.
- **Lifecycle and recovery hooks keep changes explicit.** LP collections and
  liquidity changes use a pre-operation mark and referenced flow checkpoint;
  collected cash is not counted twice. A broken adapter can be quarantined,
  blocking settlement, then replaced with its valuation difference left in
  unresolved equity. Missing rebates are not silently reconstructed.
- **Authorized hooks handle exceptions.** CapitalPip distinguishes BUIDL
  dividends from declared capital movements. Cash attributes approved receipts
  to supply income with transaction/log-reference deduplication. A separate
  hook classifies monthly settlement debt that did not fund investments.

Accounting terminology matters: **prime investment revenue excludes income
allocated directly to Sky (SDE), but is before borrowing costs.** Prime
supply-side revenue subtracts net borrowing costs from that figure. Sky
supply-side revenue comprises those borrowing costs plus SDE income. Demand-side
income is separate; Sky's total must not be subtracted twice.

## What the examples establish

July 31 deployment on local forks followed by August 2026 observations gives
an initial feasibility check against the MSC process:

| Example | Evidence and limits |
|---|---|
| Obex | Investment revenue matches to the cent. A separate daily-payment simulation exercises cash/debt feedback, monthly capitalization and constrained liquidity using historical prices and simulated settlement infrastructure. |
| Osero | Investment revenue matches to the cent. Borrowing costs are about 542 USDS higher; rate conversion and balance sampling require reconciliation. |
| Grove | Ethereum adapters plus verified cash attribution recognize 2.589M USDS of prime investment revenue versus 4.913M in the MSC provenance. The remaining difference is 2.324M: remote-position revenue plus a 319 USDS local valuation residual. BUIDL dividend attribution is also implemented, with a documented 1,001 USDS classification difference. |

Osero/Grove are accrual replays, not daily-payment simulations. Grove's saved
summary and provenance differ on two venues; comparisons name and hash their
baseline. Passing tests demonstrate specified behavior, not complete coverage,
production approval or independent validation of the accounting policy. A
separate permissions fork rehearses allocator draw access, buffer allowance,
payments, surplus joins and revocation using impersonated authorities.

## Benefits and challenges

| Potential benefit | Challenge or tradeoff |
|---|---|
| Reproducible, inspectable books and explicit settlement rules | On-chain execution cannot establish the economic meaning of every transfer. Authorized inputs remain consequential. |
| Earlier visibility into PnL, debt and unresolved equity | Balance snapshots miss intraday round trips. Capital movements need correctly ordered accrual and marking hooks. |
| Modular adapters allow new venues without rewriting the core | Each adapter still needs a valuation policy, flow handling, oracle checks and tests; a common interface does not make venues economically interchangeable. |
| More frequent settlement reduces accumulated unpaid balances | Daily payments change debt and future interest. Later losses cannot automatically recover earlier payouts; liquidity, loss carry and timing differ from monthly netting. |
| Ethereum can consolidate a multi-chain book | Local price feeds do not prove remote ownership. Source finality, timestamps, replay protection, transfer matching and in-transit claims require additional infrastructure. |
| Explicit references improve cash-attribution auditability | Cash trusts its writer's classification. Its deduplication is per deployment, not global proof against recognition through another accounting path. |

Gas, contract-size limits, governance permissions and operational availability
also constrain deployment. Stale inputs or failed calls can prevent settlement;
operators need monitoring and rehearsed recovery procedures. Quarantined NAV
contains last-known values and must not be presented as a fresh valuation. Stablecoin-par valuation,
RWA redemption claims, LP fees and off-chain facility valuations require
explicit agreement rather than implicit adapter assumptions.

## Questions for Sky ecosystem teams

**Accounting and economics**

1. Which MSC conventions must match exactly: rate conversion, subsidies,
   utilization, valuation cutoffs, SDE allocation, rounding and loss treatment?
2. Should recognition, review and cash payment have different cadences? What
   exposure to early payouts and subsequent losses is acceptable?
3. Who approves cash-income classifications, impairments and corrections?
   How are report versions and receipts already recognized elsewhere reconciled?

**Technical and security**

4. Can allocator integrations enforce atomic hooks around capital movements,
   including redemptions, bridge transfers and legacy monthly settlements?
5. What evidence is sufficient for remote marks: trusted publishers, oracle
   networks or verified messages? Which source-age and finality rules apply?
6. How do we avoid duplicate assets across bridge escrow, transit claims and
   destination positions, and assign each exposure to the correct funding ilk?
7. What adapter review, invariants, gas limits and independent security work
   are required before enabling payments? Who owns upgrades and emergency powers?

**Operations and rollout**

8. Who operates keepers, maintains adapters and funds Till? Who may quarantine
   a feed, approve its replacement and reconcile missed yield or rebates?
9. How do daily payments net against the MSC process during coexistence,
   including monthly debt capitalization, shared payees and corrections?
10. What would qualify a pilot for expansion: agreed variance tolerances,
    resolved equity gaps, operational coverage and a tested rollback procedure?

A bounded first step is a shadow run for one prime with a small Ethereum venue
set. Keep the MSC process authoritative, reconcile each difference, then review
whether to enable limited payments before adding remote or off-chain exposures.

The repository now packages frozen MSC inputs, offline report validation, CI
workflows and lifecycle regressions. These make the proposal reviewable; they do
not replace an independent audit or an approved deployment and operating plan.

Further detail: [adapter requirements](ADAPTERS.md),
[Grove coverage and cross-chain design](GROVE-CROSS-CHAIN.md), and
[August Grove comparison](../reports/grove-2026-08.md).
