# Tally

On-chain daily settlement for Sky prime agents. Replaces a monthly spreadsheet with one transaction a day.

| | |
|---|---|
| Repo | `soterlabs/tally` (private) |
| Commit | `7f88efa` |
| Tests | 54 unit, 3 mainnet-fork backtests |
| Status | reference implementation. Not audited, not deployed |

## Results first: August 2026, against the published settlement

Deployed on a fork at the July 31 pin block, stepped through every day of August at the pipeline's own end-of-day blocks. All figures USDS.

### Obex — one venue, no capital movements

| Line | Tally | Pipeline | Diff |
|---|---:|---:|---:|
| Prime revenue | 1,631,729.31 | 1,631,729.31 | **0.00** |
| Sky share | 1,247,071.87 | 1,248,716.85 | −1,644.98 |
| Agent rate | 75,136.44 | 75,327.60 | −191.16 |
| Position value, month end | 403,893,190.94 | 403,893,190.94 | **0.00** |

### Osero — rebasing SparkLend position, ten draws mid-month

| Line | Tally | Pipeline | Diff |
|---|---:|---:|---:|
| Prime revenue | 5,557.81 | 5,557.82 | **−0.01** |
| Base Rate on full debt | 11,333.36 | 11,348.31 | −14.95 |
| Idle rebate | 3,785.64 | 4,342.64 | −557.00 |
| Sky share, net | 7,547.71 | 7,005.67 | +542.04 |
| Agent rate | 31,098.68 | 31,140.91 | −42.23 |

This is the venue type whose off-chain yield formula caused a $667K restatement in an earlier cycle. The on-chain index reproduces it to the cent.

### Grove — two ilks, five chains, 27 venues

Only Ethereum venues with an adapter were marked. The gap is the measurement.

| Line | Tally | Pipeline | Diff |
|---|---:|---:|---:|
| Prime revenue, marked venues | 1,033,916.91 | 1,034,235.44 | **−318.53** |
| Prime revenue, all venues | 1,033,916.91 | 4,913,183.00 | −3,879,266.09 |
| Direct exposure, JTRSY | 2,507,334.74 | 2,507,613.29 | −278.55 |
| Direct exposure, BUIDL | 0.00 | 2,111,592.75 | −2,111,592.75 |
| Base Rate, net | 3,744,428.62 | 3,720,604.84 | +23,823.78 |
| Agent rate | 78,036.49 | 78,320.96 | −284.47 |

The missing revenue accounts for itself:

| Not marked | Revenue | Why |
|---|---:|---|
| Morpho vaults on Base | 1,047,130.65 | another chain |
| JAAA on Avalanche | 1,143,058.29 | another chain |
| GACLO-1, ACRDX on Plume | 356,305.72 | another chain; one has no feed anywhere |
| Agora, Galaxy cash sweeps | 1,332,452.89 | yield paid as cash, not a price move |
| **Total** | **3,878,947.55** | against a 3,879,266 gap |

Nothing in the residual is unexplained.

## What it settles

The same identity the Monthly Settlement Cycle publishes, once a day:

```
sky  = tab + sde − rebate     Sky's share: Base Rate, direct exposures, rebates
sv   = gain + rebate − tab    the prime's supply share
mint = sky + max(sv, 0)       drawn as new ilk debt
send = owe + max(sv, 0)       paid to the SubProxy
```

`settle()` is permissionless. A dss-cron job sends it on the keeper networks that already run Sky's maintenance.

## How it reads the chain

| Layer | Holds | Does |
|---|---|---|
| **Pips** | one adapter per venue | shares held, price per share |
| **Tally** | nothing | accrues the Base Rate, marks positions, routes gains by tag |
| **Till** | the USDS float, the allocator roles | draws within the ceiling, pays the SubProxy, banks Sky's net |

Three mechanisms worth knowing:

1. **Revenue is an index move, not a balance change.** Each position is a share count and a price per share. A deposit changes the count and books nothing, so the relayer moves funds freely without any of it reading as profit. Same mechanism as the Jug, applied to the asset side.
2. **An equity layer catches what the index cannot.** Yield arriving as new tokens looks like a deposit to a balance reader. So Tally also measures assets minus liabilities and publishes the difference between the two layers daily. For an Ethereum-only agent that number should be zero, which makes it a correctness check.
3. **Rates come from the sUSDS index.** Tally reads how much the share price grew since its last call, not the current rate. That figure carries every rate change inside the interval, compounded per second.

## Vocabulary

Written in the house style of Sky's core contracts.

| Word | Means here | Precedent |
|---|---|---|
| `ilk` | the agent's debt compartment, one contract per ilk | Vat |
| `gem` | one tracked position, priced by its pip | Vat, Join |
| `pie` / `chi` | shares held, price per share | Pot, sUSDS |
| `drip` | accrue the interest owed since last time | Jug |
| `poke` | re-mark a position at the current price | Spot |
| `tab` / `owe` | interest charged, demand side owed | Cat, Dog |
| `sin` | a loss carried against future gains | Vat, Vow |
| `pad` / `cut` / `line` | rate spread, subsidised rate, subsidy cap | Jug, Vat |
| `wad` / `ray` | 18 and 27 decimal fixed point | everywhere |

## Why the numbers differ

Four causes. Three are deliberate.

1. **Daily vs monthly compounding.** The monthly cycle converts the Savings Rate assuming monthly capitalisation; Tally capitalises daily and converts daily. Every interest figure sits at 0.9987 of the monthly one. Over a year both charge the same.
2. **Sampling at the interval's edges.** Balances are read at two points, not integrated. Tally takes the reading worse for the agent: larger debt, smaller credit. Accruing before drawing makes it exact; skipping that costs the agent, never Sky.
3. **Flows priced at the closing index.** A mid-day deposit misses part of that day's yield. One day at a daily cadence; thirty at a monthly one.
4. **Venues with no adapter.** The only real gap. A position on another chain contributes nothing until its values reach Ethereum.

## What it cannot do yet

1. **Positions on other chains.** 2.55M of Grove's 4.91M monthly revenue. First step is the operator relay, which already computes those balances daily.
2. **Yield delivered as tokens or cash.** Dividends and sweeps look like deposits. The equity layer recognises the money; deciding whose it is still needs a human input.
3. **Off-chain administrators.** A custodial loan facility and a private credit fund publish through an API with no on-chain feed. Permissioned entry point exists.
4. **Uniswap V4 and Savings V2.** Two venue types used by the largest agent. Readable on-chain, not yet written.
5. **Two open decisions.** How large the USDS float should be, and whether the relayer accrues before moving funds, which removes cause 2 entirely.

## Run it

```shell
forge test                                          # unit tests, against mocks
ETH_RPC=<archive rpc> forge test --match-contract Fork -vv   # the three backtests
```

Cold Grove backtest: about 17 minutes while the fork cache fills, seconds after.

Next: read `DESIGN.md` for the line-by-line mapping from the monthly process, the decisions log, and the open questions.
