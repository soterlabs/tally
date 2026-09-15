# Tally

An on-chain accounting and settlement reference implementation for Sky prime
agents, explored alongside the existing **MSC process**. Suitable for engineering
discussion; not independently audited or deployed to a live network.

Start with the concise [discussion brief](docs/TALLY_DISCUSSION.md), then the
[current design](DESIGN.md), [adapter guide](docs/ADAPTERS.md) and
[release review disposition](docs/RELEASE-REVIEW.md).

- **Tally:** one set of books per allocator ilk; on-chain SSR accrual, index PnL,
  utilization deductions, loss carry, referenced flow and recovery hooks.
- **Till:** allocator draw, prime payment and surplus join; keeps the USDS float.
- **Pips:** modular valuation adapters; protocol assumptions and lifecycle hooks
  remain specific to each venue. `src/Pips.sol` retains aggregate imports.
- **Cash:** approved receipt attribution to supply income, with per-deployment
  transaction/log deduplication. Classification remains trusted.
- **TallyJob:** keeper scheduling with failed-entry isolation.

## Reproduce a clean checkout

Install Foundry **v1.8.1** using the [official installation instructions](https://getfoundry.sh/introduction/installation/),
then select the pinned version with `foundryup --install v1.8.1`.
Python 3.12+ and Git are also required; scripts use only the standard library.

```sh
git clone --recurse-submodules https://github.com/soterlabs/tally.git
cd tally
git submodule update --init --recursive
forge --version
forge build --sizes
forge test --no-match-contract Fork -vv
python3 script/check_repo.py
python3 -m unittest discover -s test -p 'test_*.py' -v
python3 -O -m unittest discover -s test -p 'test_*.py' -v
```

Solidity **0.8.34**, optimizer **200 runs**, and **Cancun** EVM target are pinned
in `foundry.toml`; forge-std is pinned by the submodule and lock file. Optimization
is deliberate: the expanded accounting/recovery core needs deployment-size
headroom. CI builds and tests this exact profile, including runtime-size checks.
Maker-style layout and naming are retained. The formatting gate checks spaces,
LF, final newlines and trailing whitespace; stock `forge fmt` is not the release
gate. Avoid unrelated layout changes when contributing.

The PR check is named **Review gate**. Maintainers should require it in branch
protection. The separate manual archive workflow needs an `archive-forks`
environment, reviewed access, and its `ETH_RPC` secret. These are repository
settings, not configured by committing workflow YAML.

## August 2026 comparisons

No RPC or MSC checkout is required to rebuild the committed reports:

```sh
python3 script/compare_obex.py --log reports/obex-2026-08.log
python3 script/simulate_obex.py --log reports/obex-settlement-2026-08.log
python3 script/compare_backtest.py osero --log reports/osero-2026-08.log
python3 script/compare_backtest.py grove --log reports/grove-2026-08.log
```

The [frozen MSC inputs](test/fixtures/msc/README.md) contain baseline reports,
checksums and source provenance. `--pipeline /path/to/msc` explicitly selects an
external MSC checkout; `--output /tmp/reports` preserves committed artifacts.
All acceptance checks run before publication. Each output file is replaced
atomically; the collection of files is not a filesystem transaction.

For new chain observations, securely set `ETH_RPC` to an Ethereum archive endpoint
and omit `--log`, or run `forge test --match-contract Fork -vv` locally. Never
commit the endpoint or publish unredacted provider diagnostics.

| Example | What is exercised |
|---|---|
| [Obex accrual](reports/obex-2026-08.md) | Historical balances and prices, on-chain SSR, MSC reconciliation |
| [Obex settlement](reports/obex-settlement-2026-08.md) | Daily payments and debt feedback with simulated settlement infrastructure |
| [Osero](reports/osero-2026-08.md) | Historical Ethereum accrual |
| [Grove](reports/grove-2026-08.md) | Ethereum accrual, BUIDL capital declarations, verified cash attribution; explicit remote shortfall |

`test/Permissions.t.sol` rehearses draw-only allocator authorization, buffer
allowance, real USDS payments and surplus joins on a historical fork using
impersonated authorities. It is not a deployed governance spell. Adapter
lifecycle and failure regressions are in `test/Lifecycle.t.sol`; conservation
fuzzing is in `test/Accounting.t.sol`.

Grove's [cross-chain proposal](docs/GROVE-CROSS-CHAIN.md) explains why Ethereum
price feeds alone cannot cover remote ownership. `RelayPip` is a trusted-message
prototype, not a bridge verifier. The historical LP replay lacks transaction-level
collection hooks; synthetic lifecycle tests exercise the required integration.

To reverify the committed receipt fixtures, use `script/collect_buidl.py` and
`script/collect_grove_cash.py` with an Alchemy-compatible archive endpoint. These
collectors verify transfers and balances, but their payer/venue classification
still requires human accounting review.

## Sharing and contributions

Share an exact commit or the review PR, not an unspecified moving branch.
Changes should include focused accounting regressions and update the authoritative
design when semantics change. Source is AGPL-3.0-or-later; see [LICENSE](LICENSE).
Read [SECURITY.md](SECURITY.md) for reporting and deployment boundaries.
