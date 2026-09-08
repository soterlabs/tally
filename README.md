# tally — Daily Settlement Cycle

On-chain, daily counterpart of the Monthly Settlement Cycle (`../settlement-cycle`).

- `DESIGN.md` — MSC ↔ DSC mapping, architecture, vocabulary, rates, settlement, hybrid boundary, open items.
- `src/Tally.sol` — one instance per allocator ilk, `alm` / `sub` / `vault` / `buffer`
  filed by governance. `drip` accrues the Base Rate off the sUSDS share-price index
  plus a spread, the agent rate, and the sUSDS-spread / idle rebates; `poke`
  marks positions through pricing adapters with index-based PnL routed by tag;
  `settle` executes the MSC identity in whole USDS: draws the Sky share as new
  ilk debt through the AllocatorVault within the debt ceiling, pays the prime
  share to the SubProxy, and joins Sky's net to the surplus buffer. No Vat
  privileges.
- `src/TallyJob.sol` — dss-cron job: settles each instance once per UTC day, skipping any whose settle would revert.
- `src/Pips.sol` — adapters: raw stablecoin, ERC-4626, ERC-7540, Aave/SparkLend aToken, relayed.
- `test/Tally.t.sol`, `test/TallyJob.t.sol` — 33 tests against mocks.
- `test/Backtest.t.sol` — mainnet fork backtests: Obex, Osero and Grove, August 2026, versus `settlement-cycle` (see `DESIGN.md` §5).

```shell
forge build
forge test                                                   # unit tests, mocks
ETH_RPC=<archive rpc> forge test --match-contract Fork -vv       # August 2026 backtests against the MSC
```
