# External review readiness — disposition

The [initial review at b1c8c6b](archive/RELEASE-REVIEW-2026-09-15.md) reproduced
three contract defects and identified release-process gaps. This revision fixes
those defects and packages a reproducible engineering-review snapshot. It remains
a reference implementation, not an independently audited production release.

## Findings addressed

| Finding | Current disposition and evidence |
|---|---|
| R1: CapitalPip exits reversed income | Retains the last index across full exit and re-entry; rejects over-withdrawal and zero-index declarations. Tests cover earned yield, losses, re-entry and a fresh share series after total loss. |
| R2: LP collected fees inflated NAV/diluted income | Removes the collection accumulator. Authorized `Tally.sync` records operation deltas as flows after a pre-operation mark. Tests cover collection, reinvestment, liquidity/range changes, exit/re-entry and cash reconciliation. Mixed-decimal pools are explicitly rejected. |
| R3: failed adapters could not be replaced | `halt` freezes the last valid mark and its timestamp, blocks settlement and suppresses that gem's rebates. `mend` replaces the feed and leaves value differences in unresolved gap. Tests cover failed/retried repairs, multiple failed feeds and classification without invented PnL. |
| R4: no CI/reproducible build policy | PR workflow pins actions, Foundry 1.8.1, Solidity 0.8.34, optimizer 200 and Cancun. Checks local tests, deployment size, Maker-style whitespace hygiene, credential patterns and offline Python report acceptance. Separate manual workflow uses archive RPC. |
| R5: contradictory documentation | DESIGN.md is authoritative; old WRITEUP is archived. Current guides describe flow/recovery hooks and link generated numerical reports. The discussion brief is included under the requested `TALLY_DISCUSSION.md` name. |
| R6: reports needed a sibling MSC checkout | Packaged baseline files, minimal venue/chain configuration and hash manifest. All four comparisons regenerate offline. Explicit validation survives Python `-O`; invalid late-stage inputs leave existing reports untouched. Output files are individually replaced atomically. |
| R7: incomplete lifecycle/integration tests | Adds corrected regressions, async deposit/redemption/fixed-claim transitions, LP lifecycle cases, keeper due-read isolation and gas ceilings. A historical Grove allocator fork rehearses scoped draw access, buffer allowance, payment, surplus join and revocation. Venue-wide production integration remains open. |
| R8: incomplete release packaging | Adds license, security guidance, clean-checkout instructions, source-input provenance and the concise discussion document to the review branch. Review the exact PR commit; merging/default-branch promotion is separate. |

The Solidity architecture keeps Maker-style administration and separates books,
payments, valuation and attribution. New venues normally add a pip; they still
need protocol-specific tests and a documented economic/operational contract.

## Verification

Verification: **99 local Solidity tests**, **8 archive-fork tests** (including
permissions), and **4 Python test groups** in both normal and optimized modes.
Tally runtime is **15,963 bytes**, leaving **8,613 bytes** below EIP-170 under the
pinned optimized profile. All four report regenerations pass with unchanged
financial outputs. Source hygiene and the bounded history scan pass.

Forge's correctness lint remains advisory and emits warnings, including casts,
timestamp comparisons, loops and external-call ordering. Its output is not a
clean static-analysis certificate; trusted dependencies and numeric bounds still
need independent review. Naming and gas-style suggestions are excluded to retain
the Maker conventions. Commands and results are also recorded in the PR. The reproducible
local gates are:

```sh
forge build --sizes
forge test --no-match-contract Fork -vv
python3 script/check_repo.py
python3 -m unittest discover -s test -p 'test_*.py' -v
python3 -O -m unittest discover -s test -p 'test_*.py' -v
```

Archive checks run all three accrual examples, four Obex settlement scenarios
and the allocator permissions rehearsal. The latest report replays preserve the
August comparison results: Grove prime investment revenue is 2,589,306.08 USDS,
with a 2,323,876.93 shortfall to MSC provenance comprising 2,323,558.39 of remote
income and a 318.54 local residual. Borrowing costs remain 23,823.78 above MSC;
that difference is not resolved by the lifecycle fixes.

The gas tests enforce a 2M ceiling for settlement with 32 simple mock positions
and a 1M ceiling for the fork's small allocator settlement, excluding deployment.
These are representative regression budgets, not bounds for arbitrary adapters,
NFT counts, remote proofs or cold-access production portfolios.

The permissions test uses existing [allocator role APIs](https://github.com/sky-ecosystem/dss-allocator/blob/dev/src/AllocatorRoles.sol)
and impersonates the actual ilk administrator/buffer ward on a local fork.
It grants Till a draw capability, never a Vat or allocator-vault ward. The chosen
test role and authority impersonation are a rehearsal, not a deployment plan.

## Decisions and work still needed before payments

- **Independent review:** audit contracts and accounting policy, including the
  new trusted flow/recovery hooks. Timestamp and reference guards do not prove
  that integrations used the correct atomic operation sequence.
- **Accounting authority:** approve SSR/rate conversion, subsidy and utilization
  conventions, correction policy, valuation cutoffs, loss carry and early-payout
  risk. Net daily obligations against the MSC process to prevent duplicate payment.
- **Production venue integration:** reconstruct and bracket real LP operations;
  approve async vault fulfillment semantics and capital hooks. Grove's LP replay
  is still daily sampling, BUIDL outflows are staged at EoD, and cash classifications
  are trusted. Passing those examples does not prove full Grove coverage.
- **Remote positions:** implement source age/finality/domain/sequence checks,
  bridge and in-transit reconciliation, holder ownership and funding-ilk assignment.
  RelayPip checks receipt age only. Ethereum price feeds alone are insufficient.
- **Operational controls:** define quarantine/replacement review, missed-rebate
  corrections, float funding, keeper monitoring and shutdown. Halted NAV is stale;
  a repaired adapter does not prove the unresolved gap has been classified.
- **Attribution scope:** one authoritative receipt ledger must prevent recognition
  through multiple Cash deployments, sort, index marks or automatic gap routing.
  Cash's per-deployment deduplication does not solve that economic duplication.
- **Gas/availability:** UniV3 bounds enumeration at 32 NFTs, but unsolicited NFTs
  can still trigger rejection. A production integration should use controlled
  custody or an explicit position registry, with portfolio-specific gas budgets.
- **Repository settings:** require **Review gate** in branch protection and configure
  the reviewed `archive-forks` environment/secret. Workflow files alone do not
  change those settings. The credential scan is a bounded pattern check.

These are explicit rollout conditions, not claims of observed unauthorized theft.
The appropriate next step is an external design/code review and a shadow pilot
with the MSC process authoritative, followed by a separate payment decision.
