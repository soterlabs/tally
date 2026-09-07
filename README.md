# tally — Daily Settlement Cycle

On-chain, daily counterpart of the Monthly Settlement Cycle (`../settlement-cycle`).

- `DESIGN.md` — MSC ↔ DSC mapping, architecture, vocabulary, rates, settlement, hybrid boundary, open items.
- `src/Tally.sol` — one instance per allocator ilk. `drip` accrues the Base Rate
  (derived from `sUSDS.ssr()` at daily compounding) and the agent rate; `poke`
  marks positions through pricing adapters with index-based PnL routed by tag;
  `settle` executes the MSC identity in whole USDS: draws the Sky share as new
  ilk debt through the AllocatorVault, pays the prime share to the SubProxy,
  and joins Sky's net to the surplus buffer. No Vat privileges.
- `src/Pips.sol` — adapters: raw stablecoin, ERC-4626, ERC-7540, Aave/SparkLend aToken, relayed.
- `test/Tally.t.sol` — 20 tests against mocks.

```shell
forge build
forge test
```
