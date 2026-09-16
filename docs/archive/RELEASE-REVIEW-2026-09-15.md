> Historical findings at b1c8c6b. See [the current disposition](../RELEASE-REVIEW.md).
> Temporary diagnostics have since been replaced by corrected lifecycle regressions.

# Tally external-review readiness

Reviewed 2026-09-15 at `b1c8c6b` on `examples/osero-grove-backtests`, including
the local discussion brief. This is an engineering review, not an independent
security audit. It covers first-party contracts, adapters, tests, scripts,
reports, documentation, build/dependency configuration and CI availability.
The vendored forge-std implementation was not independently audited.

## Recommendation

Fix the three reproduced contract issues below before presenting this snapshot
as a polished reference implementation. It can be shared for an explicitly
experimental design discussion if those issues are disclosed, but the current
passing tests are insufficient evidence of integration readiness. This review
supersedes the earlier, more optimistic readiness assessment.

The separation between accounting (Tally), money movement (Till), pricing pips
and referenced cash attribution is useful. Maker-style authorization and naming
are appropriate here. The primary concerns are accounting lifecycle correctness,
recovery paths and release discipline, rather than a need for more abstraction.

## Confirmed contract findings

### R1 — High: CapitalPip full exit reverses earned yield

Location: `src/pips/CapitalPip.sol:55–78`, interacting with
`src/Tally.sol:528–543`.

When declared shares reach zero, CapitalPip resets `chi` to RAY. Tally still
calculates the next index move using the previous share count and index.
A fully bracketed exit consequently books a loss unrelated to investment
performance.

Reproduced with 100 units of opening capital, 10 of dividend income, a mark,
then a declared withdrawal of all 110 units. `gain` falls from 10 to zero.
The position's lifetime revenue should remain 10. Under SDE tagging the same
calculation affects Sky's income; if prior income was already settled, the
false loss enters a later accounting period.

The August BUIDL replay only exercises partial exits, so its passing result
does not cover this case.

**Required fix:** define index continuity and flow attribution across empty
positions, full exits and re-entry. Add integrated Tally/CapitalPip regressions
for profit and loss, including a zero-value position receiving new capital.
Do not merely suppress all marks with a zero current balance: final realized
PnL and claim transitions still need accounting.

### R2 — High: UniV3 collected-fee accounting corrupts NAV and subsequent flows

Location: `src/pips/UniV3Pip.sol:229–235` and its `deal` accumulator.

The pip adds cumulative collected fees to current position value. Once those
fees are received in a separately tracked cash balance, they are represented
twice. The same cumulative amount also changes the index when liquidity changes,
so adding capital can reverse previously recognized fees.

Two reproductions:

- Collect 100 units of fees and register the received cash: total NAV increases
  by another 100 although value merely moved from the NFT to cash.
- After recording 100 units of collected fees, double liquidity at unchanged
  market conditions: Tally books a false 50-unit loss.

The cross-chain document already warns about the NAV problem, but the current
adapter implementation still has it. The Grove replay does not declare its
historical LP collections, so it does not validate the collection path.

**Required fix:** separate live asset valuation from realized-income/withdrawal
attribution. Test collect, reinvest, change liquidity/range and full exit against
an independent asset-and-cash ledger. Include mixed-decimal pool assumptions;
`Q96` represents equal raw token units, not universal dollar parity.

### R3 — High: permanently failing adapters cannot be replaced normally

Location: `src/Tally.sol:319–346`, `poke` and the position list.

Changing a pip or tag requires a current gem mark. If the old adapter starts
reverting after the previous mark, that mark cannot be refreshed. Replacement
therefore reverts on freshness, while marking and settlement revert on the
broken adapter. Tagging NIL does not provide an escape: it has the same guard,
and NIL positions are still read by `poke` and NAV. There is no removal or
emergency position-recovery path.

Reproduced using an initially valid MTM adapter that later rejects reads:
`poke`, replacement, retagging and settlement all fail. SDE/IDL failures can
also prevent the preceding `drip`. A stale RelayPip can recover when its writer
publishes again; a permanently broken external dependency cannot rely on that.

**Required fix:** design an authorized quarantine/replacement or migration
procedure that preserves prior marks and outstanding claims, explicitly records
unresolved valuation, and avoids silently repricing the missed interval.
Simply deleting freshness checks would introduce a different accounting risk.

## Release and integration findings

### R4 — Medium: there is no automated release gate

No `.github/workflows` or other CI configuration is present; PR #2 has no
reported checks. Solidity is pinned to 0.8.34 and forge-std to an exact revision,
which is a good start, but the Foundry version/build profile and required checks
are not established as a reproducible release process.

Before sharing a release candidate, add PR checks for the local suite, build
size, agreed formatting and Python/report validation. Run archive-fork tests
separately with documented RPC access. Add secret scanning and a clearly named
required check. `forge fmt --check` currently fails; configure formatting to
preserve the chosen Maker style rather than applying a large cosmetic rewrite.

### R5 — Medium: DESIGN.md contains contradictory integration guidance

Concrete examples:

- Lines 30 and 39 describe idle deductions as off-chain or compensable through
  `gift`; current IDL/SDE rebates are on-chain and `gift` has different demand
  versus supply-loss semantics. These are not interchangeable integrations.
- Line 41 describes shortfalls coming from Tally's own USDS, although Till
  holds the float. Other examples use obsolete function signatures.
- The Grove results section still reports zero BUIDL yield and missing cash
  distributions, while the current replay recognizes both.
- Lines 512–523 overstate position exactness and attribute the entire interest
  residual to sampling. The current Grove report also identifies subsidy and
  rate-conversion differences.

Make one document authoritative for current behavior. Move old numerical
results and decisions into explicitly versioned historical material, and link
to generated current reports. WRITEUP.md is already labeled historical, but
its stronger claims should not be reused as current release messaging.

### R6 — Medium: external reviewers cannot reproduce the reports from this repo alone

`script/compare_backtest.py:81–87` and the other comparison scripts require the
sibling MSC checkout. Even saved-log mode fails without its provenance files;
Grove also needs its configuration and summary. Hashes identify inputs but do
not make those inputs available or pin an MSC commit.

All four report commands passed with the existing sibling checkout. A detached
checkout without that sibling failed with `FileNotFoundError` in saved-log mode.

Provide approved minimal baseline fixtures, or an explicit versioned setup and
access procedure. Keep baseline discrepancies visible. Automate report/parser
regressions, write output only after validation succeeds, and use explicit
validation errors for acceptance checks that must not disappear under Python
optimization (`assert` is currently used extensively).

### R7 — Medium: tests validate examples better than full integrations

There is meaningful coverage of settlement conservation, borrowing tiers,
authorization, cash deduplication and supply-loss carry. However:

- Shared pip conformance covers five adapters with empty/par initialization
  and six-decimal funding. It does not cover complete price/flow lifecycles.
- UniV3's unit coverage principally checks math, not collection/reinvestment
  with Tally; this allowed R2 to pass unnoticed.
- Obex settlement uses real prices but simulated Vat/USDS/allocator/join
  contracts. Osero/Grove do not execute payments through real allocator roles.
- BUIDL outflows are staged with test mocks at EoD; cash classifications use
  fixed verified receipt data. These demonstrate accounting under specified
  inputs, not production hook execution or automatic economic classification.

Add the reproduced cases as normal regressions with correct expected outcomes,
then an actual fork deployment/permissions smoke test and representative gas
budgets. Test adapter failure/recovery, full async queue transitions and
nontrivial NFT lifecycle changes before claiming generic venue support.

### R8 — Release packaging needs one named, complete snapshot

The latest work is in open PR #2, not the default branch. The discussion brief
was untracked when this review began, so cloning the repo would not include it.
Choose the exact commit/branch reviewers should inspect and include the brief.
Do not merge solely to make the default branch look current before addressing
R1–R3.

There is no root LICENSE text, SECURITY/contact document or clean-checkout setup
covering submodule initialization and the toolchain. Add these basic repository
artifacts; source SPDX headers are present. Distinguish unsupported integrations
from supported reference examples in the entry-point documentation.

## Additional boundaries to keep explicit

- Tally runtime is **24,133 bytes**, leaving **443 bytes** below the 24,576-byte
  limit in the current unoptimized build. Size regression checks must run in CI;
  new core features need a deliberate build/architecture decision.
- Cash and `sort` trust authorized classification. Receipt deduplication is per
  Cash deployment, and does not prevent recognition through another wrapper,
  direct sort, index mark or automatic gap routing. A correction process and
  authoritative attribution ledger are operational requirements.
- RelayPip checks receipt age, not source age/finality/domain/sequence. Chronicle
  read permission alone is not a freshness check. These limitations are
  documented and should remain prominent in any shared brief.
- Permissionless `settle` is not restricted to once per UTC day; only the keeper
  job imposes that cadence. Permissionless drip frequency also partitions the
  index-growth intervals. Specify and test the intended timing economics.
- UniV3 enumerates every NFT held at the NPM address before filtering by pool.
  Define exposure bounds and assess unsolicited-NFT/gas exhaustion behavior.
  The keeper's `due()` call is outside its settlement try/catch, so a malformed
  registered entry can also disrupt scanning; add registration validation.

These last items are design/operating boundaries, not claims of reproduced
unauthorized fund theft.

## Verification and reproducible diagnostics

At the reviewed commit:

| Check | Result |
|---|---|
| `forge test --no-match-contract Fork -vv` | 88 passed |
| `forge test --match-contract Fork -vv` with archive RPC | 7 passed |
| Four report regenerations with MSC checkout | Passed |
| Saved-log Grove report without MSC checkout | Failed as described in R6 |
| `forge fmt --check` | Failed; formatting policy/configuration needed |
| Historical credential-pattern scan | 139 first-party history blobs; no matches for configured credentials, provider-key URLs, GitHub tokens or private-key headers |
| Targeted contract diagnostics | Four reproduced undesirable behaviors covering R1–R3 |

The credential scan is bounded evidence, not a guarantee that every possible
secret or sensitive business datum has been identified. No production contracts
were changed by this review.

The review used temporary diagnostic tests outside the normal suite:

```sh
FOUNDRY_TEST=review forge test --match-contract ReleaseReviewTest -vv
```

They deliberately assert the **current bad behavior**, so a passing diagnostic
confirms the finding; it does not mean the issue is fixed. They are outside the
normal test directory. Turn them into corrected regression tests when fixing
the contracts.

Historical recommendation: fix R1–R3; add CI and authoritative documentation;
package reproducible inputs and the exact review snapshot; then invite external
review with the remaining trust and production-integration boundaries stated.
