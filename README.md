# tally — Daily Settlement Cycle

On-chain, daily counterpart of the Monthly Settlement Cycle (`../settlement-cycle`).
Reference implementation for design review; not audited or deployed.

- `DESIGN.md` — MSC ↔ DSC mapping, architecture, vocabulary, rates, settlement, hybrid boundary, open items.
- `src/Tally.sol` — one instance per allocator ilk, `alm` / `sub` / `vault` / `buffer`
  filed by governance. `drip` accrues the Base Rate off the sUSDS share-price index
  plus a spread, the agent rate, and the sUSDS-spread / idle rebates; `poke`
  marks positions through pricing adapters with index-based PnL routed by tag;
  `settle` executes the MSC identity in whole USDS: draws the Sky share as new
  ilk debt through the AllocatorVault within the debt ceiling, pays the prime
  share to the SubProxy, and joins Sky's net to the surplus buffer. No Vat
  privileges.
- `src/Cash.sol` — authorized, transaction/log-referenced cash attribution through
  Tally's supply-income equity path; duplicate credits are rejected per deployment.
- `src/Till.sol` — the cash register, one per Tally: holds the USDS float and the
  prime-scoped allocator roles; draws within the debt ceiling, pays the SubProxy and
  joins Sky's net to the surplus buffer. `pay` is callable only by its immutable
  `tally`. No Vat privileges anywhere.
- `src/TallyJob.sol` — dss-cron job: settles each instance once per UTC day, skipping any whose settle would revert.
- `src/pips/` — individual adapters (`src/Pips.sol` preserves aggregate imports): raw stablecoin, ERC-4626, ERC-7540, Aave/SparkLend aToken, Chronicle-priced,
  lending idle share, Curve leg, Uniswap V3 positions, declared-capital (BUIDL-style yield), relayed.
- `test/Tally.t.sol`, `test/Pips.t.sol`, `test/TallyJob.t.sol` — accounting and protocol tests against mocks.
- `test/Accounting.t.sol` — settlement hooks, SAV neutrality, subsidy boundaries, configuration guards, and multi-cycle conservation fuzzing.
- `test/PipConformance.t.sol` — shared adapter normalization, holder isolation and capital-flow checks.
- [Adapter contract and integration guide](docs/ADAPTERS.md) — how to add a pip, choose tags, and bracket capital or monthly settlement movements.
- `test/Backtest.t.sol` — mainnet fork backtests: Obex, Osero and Grove, August 2026, versus `settlement-cycle` (see `DESIGN.md` §5).

```shell
forge build
forge test --no-match-contract Fork                          # unit tests, mocks
ETH_RPC=<archive rpc> forge test --match-contract Fork -vv       # August 2026 backtests against the MSC
```

For Obex's August 2026 comparison against the local `../settlement-cycle`
report, including daily observations and a breakdown of the differences:

```shell
ETH_RPC=<archive rpc> python3 script/compare_obex.py
```

See [the Obex comparison](reports/obex-2026-08.md). This replays daily accruals
against historical balances; it does not execute daily settlement payments.

To simulate the feedback from daily draws and payments, run:

```shell
ETH_RPC=<archive rpc> python3 script/simulate_obex.py
```

The [settlement simulation](reports/obex-settlement-2026-08.md) executes Tally
and Till against historical market data with a persistent simulated cash/debt
system. It preserves July's legacy settlement and also tests idempotent post-payment
balance refreshes, the monthly settlement hook, and a closed debt ceiling with an exhausted float.

Osero and Grove have reproducible August accrual examples too:

```shell
ETH_RPC=<archive rpc> python3 script/compare_backtest.py osero
ETH_RPC=<archive rpc> python3 script/compare_backtest.py grove
```

See the [Osero comparison](reports/osero-2026-08.md),
[Grove comparison](reports/grove-2026-08.md), and
[Grove venue coverage and cross-chain proposal](docs/GROVE-CROSS-CHAIN.md).
These replay historical Ethereum accruals, not daily payments. Grove's report
explicitly separates its local subset from remote positions and cash income.
Both commands accept `--log reports/<prime>-2026-08.log` to regenerate reports
without RPC calls (the sibling pipeline checkout is still required).

`forge test --match-contract CrossChainExampleTest -vv` runs a synthetic
cash → transit claim → remote position → cash example using RelayPip,
including yield, loss and stale-data behavior.

Grove's BUIDL position uses CapitalPip, seeded with opening capital and August
outflows reconstructed in [the transfer fixture](test/fixtures/buidl-2026-08.json).
The updated report explains its dividend attribution and the Python pipeline's
1,001 USDS transfer-threshold difference. To reverify the fixture against logs
and historical balances, use `ETH_RPC=<alchemy-compatible rpc> python3 script/collect_buidl.py`.

Grove's E21/E38/E42 cash receipts are credited through Cash, without adding a
second asset or bypassing supply-loss carry. The [cash fixture](test/fixtures/grove-cash-2026-08.json)
and [receipt CSV](reports/grove-2026-08-cash.csv) record the four verified receipts.
Recollect with `ETH_RPC=<alchemy-compatible rpc> python3 script/collect_grove_cash.py`.
`forge test --match-contract CashTest -vv` checks authorization, deduplication,
reinvestment and supply-loss carry. Receipt classification remains a trusted
operator responsibility; Cash itself does not verify transaction log proofs.
