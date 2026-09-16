# Tally

An on-chain accounting and settlement reference implementation for Sky prime
agents. Start with [ARCHITECTURE.md](ARCHITECTURE.md) for the contracts, accounting
state, execution flow and integration requirements. Not independently audited
or deployed to a live network.

## Build and test

Use Foundry **v1.8.1** (`foundryup --install v1.8.1`) and Python **3.12+**.
Solidity 0.8.34, optimizer 200 and Cancun are pinned in `foundry.toml`;
forge-std is pinned by the submodule and lock file. Python uses the standard library.

```sh
git submodule update --init --recursive
forge build --sizes
forge test --no-match-contract Fork -vv
python3 script/check_repo.py
python3 -m unittest discover -s test -p 'test_*.py' -v
python3 -O -m unittest discover -s test -p 'test_*.py' -v
```

For archive-fork tests, set `ETH_RPC` securely and run
`forge test --match-contract Fork -vv`. The PR **Review gate** runs offline;
the manual archive workflow requires the reviewed `archive-forks` environment
and its RPC secret. Branch protection is configured separately. Maker-style
layout is retained; CI checks whitespace hygiene rather than stock `forge fmt`.

`reports/` holds replay logs and expected CSVs used by tests. Generated Markdown
reports are omitted from version control; rebuild them when needed, for example:

```sh
python3 script/compare_backtest.py grove --log reports/grove-2026-08.log
```

Other replay scripts expose `--help`. Frozen comparison inputs and their provenance
are described in [the fixture README](test/fixtures/msc/README.md). The broader
[discussion brief](docs/archive/TALLY_DISCUSSION.md) is archived for separate sharing.

[AGPL-3.0-or-later](LICENSE) · [Security reporting](SECURITY.md)
