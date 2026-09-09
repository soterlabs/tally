# DSC — Daily Settlement Cycle (on-chain)

On-chain, daily version of the Monthly Settlement Cycle (MSC) that
`../settlement-cycle` runs off-chain today. Written in Sky/Maker house style.
Status: **design draft with a compiling, tested reference implementation.**

Decisions taken so far (2026-09-07) are marked **[D]**; open items are in §5.

## 1. What the MSC does today, and what DSC does instead

Each month, per prime (forum post MSC #12, August 2026):

```
sky  = sky_revenue                                   Sky share
dv   = agent_rate + distribution_rewards + ...       demand side
sv   = prime_agent_revenue − (sky_revenue − sde)     prime supply share
mint = sky + max(sv, 0)     "Mint X USDS debt in ALLOCATOR-*-A and transfer to surplus buffer"
send = dv + sv              "Send Y USDS from surplus buffer to the SubProxy"
```

DSC runs the same identity once a day, on-chain, with the inputs read from
chain where they can be and pushed by governance or the hybrid process where
they cannot.

| MSC term | Off-chain source today | DSC |
|---|---|---|
| `cum_debt` | `Vat.ilks(ilk).Art × rate` at EoD block | `debt(ilk)`, same read **[D]** |
| Base Rate | `SSR_apr(n=12) + spread`, spread from config | `dchi + pad × dt/365d`, where `dchi` is the growth of the sUSDS share price over the interval **[D]** |
| subsidy | SOFR ramp on first $1B | `cut` (rate) and `line` (cap), filed by governance **[D]** |
| utilized deductions | idle USDS, PSM3 legs, lending-idle | **not on-chain**: most idle sits on other chains; deducted in the hybrid layer **[D]** |
| `value_som/eom`, `period_inflow` | balance × unit price at pin blocks, Transfer-event flows | `poke`: index PnL `pie × Δchi`, flows fall out |
| ERC-7540 escrow | `balanceOf + pendingRedeem + claimableRedeem` | `Erc7540Pip`, same, plus queued deposits at par |
| redemption fees | none modelled (BUIDL $15k flat, heuristic) | per-gem `fee` haircut filed by governance **[D]** |
| Aave / SparkLend rebasing | closed form over month boundaries | `ATokenPip`: `scaledBalanceOf × normalizedIncome` **[D]** |
| SDE (fixed / capped) | `sky_direct_exposures.yaml`, daily value-weighted share | gem `tag = SDE`, optional `cap`, share resolved per poke |
| sUSDS spread reimbursement | `value × spread/365` per day, reduces sky revenue | gem `tag = SAV`, `rebate` |
| agent rate | SubProxy USDS × (SSR+20bps), sUSDS × 20bps, cost-basis principal | `drip`: same rates, sUSDS at current `convertToAssets` **[D]** |
| distribution rewards | external xlsx | `gift(ilk, wad)` by an authorised hybrid process |
| idle balances on L2s | deducted from utilized | relayed gems tagged `IDL`, Base Rate rebated on-chain; or `gift` **[D: hybrid]** |
| mint | `vat.grab` + `vat.suck` in a spell | `AllocatorVault.draw(mint)`, pulled from the AllocatorBuffer by allowance, capped by ceiling headroom **[D]** |
| send | USDS transfer from surplus buffer | paid out of the mint, shortfall from `Tally`'s own USDS; net `mint − send` joined to the Vow |
| whole USDS | `round()` per prime | floor to whole USDS, fractions carried **[D]** |
| negative Sky share | not addressed | carried forward in `sde` **[D]** |

Facts from the off-chain pipeline that shaped the design:

- The BR charge is not accrued on-chain today; allocator ilks are capitalised
  monthly by `grab`. `Tally.drip` is the missing Jug.
- BR is a nominal APR (Rule 1, 2026-09-01). Accrual is linear between
  settles; compounding happens only through capitalisation, which DSC does
  daily. Hence the APY→APR conversion at `n = 365`. On-chain the cleanest
  form is the sUSDS share price itself: its growth between two drips is the
  SSR compounded per second over exactly that interval, every SP-BEAM change
  included. Over one day that equals the `n = 365` slice; over a longer gap
  it is what Sky actually paid on sUSDS, which is what Rule 1's neutrality
  argument wants.
- The 0.66 bps/yr settlement-lag residual the PRD attributes to monthly
  cadence (`PRD.md:1332`) disappears by construction.
- Grove's E9 phantom loss (−$22.5M, escrowed JTRSY shares) is why the 7540
  adapter counts in-flight shares. The Spark MSC#11 restatement (+$667K
  aToken yield) is why the aToken adapter uses the index directly.

## 2. Architecture

```
                 ┌──────────────────────────────────────────────┐
  keeper (daily) │ Tally  (one instance per allocator ilk)       │
  ─ settle(ilk) ►│                                              │
                 │  drip   debt×(Δchi+pad·dt) → tab; rebates     │──► Vat.ilks(ilk)
                 │         SubProxy USDS/sUSDS × (Δchi+tip) → owe │──► sUSDS.convertToAssets, balances
                 │  poke   Σ pip.peek(who) → gain / sde / rebate │──► Pips ──► vaults, aTokens
                 │  settle sky, sv, mint, send (whole USDS)      │
                 │         vault.draw(min(mint, room)); transferFrom │──► AllocatorVault, AllocatorBuffer
                 │         usds.transfer(sub, send)              │
                 │         join(vow, mint − send)                │──► UsdsJoin
  governance     │  init / file / gift / rely / deny / cage      │
  ─────────────► └──────────────────────────────────────────────┘
                                   │ events: Drip, Poke, Settle
                                   ▼
                 settlement-cycle (hybrid: idle deductions, DR, off-chain venues)
```

**Deployment [D]:** Ethereum only for now (the ilks live there). One `Tally`
instance per allocator ilk, with `ilk` immutable and `alm`, `sub`, `vault`,
`buffer` filed by governance: Spark, Bloom, Grove (Diamond PAU), Obex, Prysm.
A prime with two ilks (Grove) deploys two instances sharing `sub` and sets
`pay = 1` on exactly one, so the agent rate on the shared SubProxy is paid
once. Keel and Skybase have no ilk and no ALM positions; an instance with no
gems and `debt = 0` still pays their agent rate through `drip` + `settle`.

### 2.1 Vocabulary

| Word | Meaning here | Precedent |
|---|---|---|
| `ilk` | the allocator ilk this instance settles (immutable) | Vat |
| `alm` | ALM Proxy, default holder of the gems | — |
| `sub` | SubProxy: paid at settle, earns the agent rate when `pay = 1` | — |
| `pay` | 1 if this ilk carries the prime's demand side (agent rate, gifts) | — |
| `gem` | a token position (USDS, sUSDC, JTRSY, spUSDS…) | Vat / Join |
| `pip` | pricing adapter for a gem, `peek(who) → (pie, chi, own)` | Spot / OSM |
| `who` | holder override for a gem (0 = `alm`) | — |
| `tag` | routing: `MTM`, `SDE`, `SAV`, `IDL`, `NIL` | — |
| `vault` / `buffer` | the prime's AllocatorVault / AllocatorBuffer | dss-allocator |
| `pie` / `chi` | per gem: shares held / price per 1e18 shares (ray) | Pot / sUSDS |
| `chi` (ilk) | sUSDS share price at last drip, the SSR index (wad) | Pot / sUSDS |
| `art` / `usd` / `sus` | ilk debt, SubProxy USDS, SubProxy sUSDS value at last drip | Vat `art` |
| `own` | assets owned outside the shares (7540 deposit queue) | — |
| `fee` | redemption haircut on vault value (wad) | — |
| `cap` | SDE: Sky's capped slice (wad), 0 = whole | — |
| `pad` | BR spread over SSR, annual nominal (ray) | — |
| `tip` | agent-rate spread over SSR, annual nominal (ray) | Clipper `tip` (a payment) |
| `cut` / `line` | subsidised BR (ray) / debt charged at `cut` (wad) | Vat `line` |
| `rho` | last drip / last poke timestamp | Jug / Pot |
| `tab` | BR charge accrued since last settle | Cat / Dog |
| `owe` | demand side owed to the prime since last settle | — |
| `gain` / `sde` / `rebate` | prime MTM / Sky-direct MTM / rebates (sUSDS spread, idle BR) | — |
| `sin` | negative prime share carried forward | Vat / Vow |
| `vow` | the surplus buffer | Vow |
| `drip` / `poke` / `settle` / `gift` | accrue / mark / execute / credit off-chain DV | Jug / Spot / — / — |
| `init` / `file` / `rely` / `deny` / `cage` / `live` | admin | everywhere |

### 2.2 Rates

All annual rates are **nominal** and applied as `rate / 365 days` per second.

```
dchi      = sUSDS.convertToAssets(1e18) / chi_prev − 1     SSR over the interval, as sUSDS compounded it
br        = dchi + pad × dt / 365d                         Base Rate over the interval
fee       = max(debt_now, debt_prev) × br                  (subsidy: min(·, line) × cut × dt/365d + rest × br)
agentRate = min(usds_now, usds_prev) × (dchi + tip × dt/365d) + min(susds_now, susds_prev) × tip × dt/365d
rebates   = Σ SAV: min(val_now, val_prev) × pad × dt/365d ;  Σ IDL, SDE slice: min(val_now, val_prev) × marginal
```

`file("pad"|"tip"|"cut"|"line"|"pay")` requires a drip and a poke of every
gem in the same block, so no open interval is re-priced retroactively. The
SSR leg needs no governance action at all: the sUSDS index already carries
every SP-BEAM change, and a `drip` after a long gap prices each sub-period at
the rate that was in force.

**Sampling rule.** Balances are read at the two ends of an interval, not
integrated, and the Vat has no hook into `Tally`. So every accrual is taken on
the end that is worse for the prime: the larger of the two debt readings, the
smaller of the two SubProxy readings, and for `SAV` / `IDL` gems the smaller
of the two values. A prime that calls `drip` (or `poke`) in the same block
before it draws, wipes or moves funds is charged and credited exactly. One
that does not pays the interval at the higher debt. A same-block `drip`
accrues nothing but refreshes the samples, so drip-then-move works. The ALM
controller can be taught to call `drip` before `mintUSDS` / `burnUSDS`; until
then the rule makes mistiming cost the prime, never Sky.

### 2.3 Positions

`poke(ilk, gem)` reads `(pie, chi, own)` from the gem's `pip`, applies the
`fee` haircut to `chi`, and books `dpnl = pie_old × (chi_new − chi_old)`:

| tag | routing |
|---|---|
| `MTM` | `gain += dpnl` |
| `SDE` | `share = cap == 0 ? 1 : min(1, cap / prior value)`; `sde += dpnl × share`; `gain += rest`. The share is taken on the value the move was measured on, so a crash or a full redemption never routes more than Sky's slice. `drip` also rebates the Base Rate on Sky's slice: Sky takes its yield directly, so charging BR on it would bill twice (the MSC excludes `sde_av` from utilized) |
| `SAV` | no PnL (SSR stays in the token); `drip` rebates `min(value, prior value) × pad × dt/365d` |
| `IDL` | no PnL; `drip` rebates `min(value, prior value) × marginal`, where `marginal` is `cut` inside the subsidy cap and the full Base Rate above it. At settle the total rebate is bounded by `tab`: never more is handed back than was charged |
| `NIL` | nothing booked (Savings V2 position-only) |

Adapters shipped in `src/Pips.sol`:

| pip | `pie` | `chi` | `own` |
|---|---|---|---|
| `RawPip` | `balanceOf` | `RAY` | 0 |
| `Erc4626Pip` | `balanceOf` | `convertToAssets(1 share)` | 0 |
| `Erc7540Pip` | `share.balanceOf + pendingRedeem + maxMint` | same | `pendingDeposit + maxWithdraw` |
| `ATokenPip` | `scaledBalanceOf` | `pool.getReserveNormalizedIncome(asset)` | 0 |
| `ChroniclePip` | `balanceOf` | Chronicle `read()` (the pip must be `kiss`ed) | 0 |
| `LendingIdlePip` | `balanceOf / totalSupply × underlying.balanceOf(aToken)` | `RAY` | 0 |
| `CurveLegPip` | `lp.balanceOf / totalSupply × balances(i)` | `RAY`, or the leg's 4626 `convertToAssets` | 0 |
| `CapitalPip` | declared capital, as index shares | `balance / pie` | balance if nothing declared |
| `RelayPip` | pushed by an authorised writer | pushed | pushed |

`ChroniclePip` covers oracle-priced tranches (STAC; the JAAA / JTRSY fallback).
`LendingIdlePip`, tagged `IDL`, is the MSC's "lending idle" deduction: the
holder's share of underlying sitting unborrowed in a SparkLend / Aave pool.
`CurveLegPip` is one gem per pool leg, so a sUSDS leg can carry `SAV`.

`CapitalPip` is for yield that arrives as new tokens (BUIDL dividends) or as
cash at the holder (issuer sweeps). A balance reader cannot tell a dividend
from a deposit, so the party moving capital, the ALM controller or its
relayer, calls `deal(who, ±wad)` in the same block before the transfer.
Declared capital is kept as index shares at `chi = balance / pie`, so a
declared flow leaves the index unchanged and an undeclared arrival raises it.
This is the same discipline as `drip` before a draw; it is what replaces the
pipeline's Transfer-log counterparty classification on-chain.

`Erc7540Pip` follows ERC-7575: the vault has no ERC-20 surface, balances and
decimals come from `vault.share()`. Its four in-flight states are each priced
at the price they actually have: pending redeems float with the index, fulfilled
redeems are fixed assets (`maxWithdraw`), pending deposits are assets at par,
fulfilled deposits are shares already minted (`maxMint`).

`RelayPip` reverts on a mark older than `hop` (default one day, OSM-style), so a
stale relay stops `settle` for the whole ilk rather than settling on old data.

`RelayPip` is the extension point for positions that cannot be read on this
chain (L2 ALM Proxies, PSM3 baskets, custodial NAVs): a bridge receiver, an
oracle, or the hybrid process pokes it. Curve and Uniswap LP decomposition
would be further pips; nothing in `Tally` changes.

### 2.4 Settlement

`settle()` is permissionless. It drips, pokes every gem, then:

```
rebate = min(rebate, tab)          never hand back more than was charged
sky    = tab + sde − rebate
sv     = gain + rebate − tab − sin_prev
up     = max(sv, 0)
mint   = floor(sky + up)           fraction, a negative total, and anything the
                                   ceiling blocks carry in `sde`
send   = floor(owe + up)           fraction carries in `owe`
sin    = max(−sv, 0)               a supply loss waits for supply gains only

drew = min(mint, room)             room = ilk and global ceiling headroom, less 1 USDS
vault.draw(drew); usds.transferFrom(buffer, this, drew)
usds.transfer(sub, min(send, balance))     shortfall beyond the draw comes from
                                           USDS governance parks here; unpaid → owe
join(vow, drew − send)             Sky's net, credited to the surplus buffer
```

This nets the two MSC legs: the prime's fresh debt pays the SubProxy directly
and only Sky's net crosses into the Vow. When `send` exceeds the draw (Keel,
Skybase, any prime whose demand side exceeds its Sky share) Sky's part comes
from the pre-funded float, the on-chain form of the Demand-Side Buffer
transfer in today's settlement transaction. If the float runs dry the balance
is owed, not lost. `quit` lets governance move the float, or anything else,
out at any time, including after `cage`.

**Departure from the monthly identity.** The MSC nets a negative supply share
inside the send (`send = dv + sv`). Done daily that is path-dependent: a loss
day eats the agent rate, and the recovery day mints the prime new debt to pay
itself back. `Tally` instead carries the loss in `sin` and pays the demand
side regardless. Over any window the totals match a single monthly netting
only when the supply share ends positive; when it ends negative the prime
keeps its demand side and Sky keeps the loss on the books until supply gains
absorb it.

**Debt ceiling.** `room(ilk)` reads the ilk `line` and the global `Line`. The
draw is capped at whatever headroom exists and the remainder carries on the
Sky side, so a prime at its AutoLine cap still gets its demand side paid and
Sky's charge keeps accruing instead of the whole cycle reverting.

### 2.5 Permissions

`Tally` needs the prime-scoped roles the ALM controller already holds:
`AllocatorVault.draw` for its ilk and a USDS allowance from the
AllocatorBuffer (`buffer.approve(usds, tally, max)`; the audited buffer has
no `withdraw`, only `approve`). It
holds no Vat authority. Governance holds `Tally.wards` for `init`, `file`,
`gift`, `cage`, and tops up the USDS float for demand-side payments. The
hybrid process needs `gift` and `RelayPip.poke` only. `drip`, `poke`,
`settle` are open.

### 2.6 A moving `rate` on allocator ilks (not taken, for the record)

The alternative to `draw` was `vat.fold(ilk, vow, mint / Art)`, the Jug's
own path. Its merits: interest is capitalised the way every other ilk does
it, `Art × rate` reflects it instantly for every reader, no USDS moves for
the Sky leg, and the AllocatorVault already prices `draw`/`wipe` off the live
`rate` (Spark's ilk sits at ≈1.045 today, so nothing assumes 1.0). Its cost
is that `Tally` becomes a Vat ward, the highest privilege in the system, for
a keeper-triggered daily contract. Decision: `draw` via the allocator stack;
the frozen-rate convention is not load-bearing and could be revisited.

### 2.7 Operations: `TallyJob`

`src/TallyJob.sol` is a dss-cron job for Sky's keeper networks. It holds the
list of `Tally` instances and implements `IJob`:

- `due(tally)`: the instance is live and a new UTC day has begun since its
  last `settle` (`zzz`). `drip` moving `rho` does not count, so a relayer
  drip before a draw never suppresses the day's settle.
- `workable(network)`: false unless the network is the Sequencer's master;
  otherwise the first due instance whose `settle` succeeds in simulation.
  The trial `settle` runs inside the keeper's `eth_call`, so a stale relay
  mark or a missing allocator role makes that instance skipped rather than
  reported, and no keeper gas is burnt on a revert.
- `work(network, args)`: master check, decode the instance, `ShouldNotTrigger`
  unless it is listed and due, then `settle`. One instance per call; the
  keeper loops until nothing is workable.

Governance `rely`s on the job only to `add` / `remove` instances. `settle`
stays permissionless, so the job is a convenience, not a gate: anyone,
including the prime, can settle early or out of band.

## 3. What stays off-chain (hybrid boundary)

- Idle deductions from utilized (most sit on L2s) **[D]**: the on-chain BR
  charge is on full `Art × rate`. Two ways to hand the idle share back, both
  supported: (a) the hybrid process computes it and pays through `gift`;
  (b) the L2 balances are relayed into a `RelayPip` per leg and tagged `IDL`
  (idle USDS, PSM3 USDS leg), `SDE` (PSM3 USDC leg) or `SAV` (PSM3 sUSDS
  leg), and `poke` rebates on-chain. See §3.1.
- Anchorage (~$260M), Galaxy GACLO-1 ($50M): API-only or no NAV feed.
- Distribution Rewards: external, credited through `gift`.
- Subsidy reference rate (SOFR): governance files `cut`.
- Cats G/H (gas, governance tokens): unpriced by decision.

### 3.1 Getting L2 balances to mainnet

Three ways to fill a `RelayPip`, in increasing trust-minimisation:

1. **Operator relay.** The settlement-cycle pipeline already reads every L2
   balance daily; it signs and pokes `(pie, chi, own)`. Same trust as today's
   MSC, live in a week. Right first step.
2. **Messaging bridge.** A tiny reporter contract on each L2 reads the local
   ALM Proxy / PSM3 and forwards a message through LayerZero or CCTP-style
   messaging (the ALM controllers already use both, and `xchain-helpers`
   has forwarders and receivers for OP-stack, Arbitrum, AMB, LZ, CCTP).
   Canonical L2→L1 bridges are too slow for a daily cycle (7-day windows on
   OP-stack and Arbitrum), so this means a third-party messenger, or
   Chronicle publishing the L2 reads as an oracle, which is the Sky-native
   option.
3. **Storage proofs.** OP-stack chains and Arbitrum post state roots to L1
   roughly hourly; a `ProofPip` can verify the ALM's balance slot against
   them with no operator and no messenger. Not available for Avalanche.
   Highest assurance, most engineering.

In every case the receiving side is the same `RelayPip`, so the choice can be
made per chain and upgraded later without touching `Tally`.

## 4. Reference implementation

- `src/Tally.sol`: the contract above.
- `src/Pips.sol`: the five adapters.
- `test/Tally.t.sol`, `test/Pips.t.sol`, `test/TallyJob.t.sol`: 40 tests against mocks of Vat, AllocatorVault,
  AllocatorBuffer, UsdsJoin, sUSDS, ERC-4626/7540 vaults and an aToken pool,
  covering rates, index PnL, haircuts, escrow, SDE caps, SAV and IDL rebates,
  subsidy, whole-USDS settlement with carries, the negative prime share, the
  float-funded demand side, gifts, permissionless settle, the
  allocator-only privilege boundary, relay staleness, debt-ceiling carries,
  the sampling rule, the four ERC-7540 in-flight states, cap-on-prior-value
  SDE shares, gem re-basing, and `quit` after `cage`. The mocks match the real
  AllocatorBuffer (approve only) and the ERC-7575 share layout.

## 5. Backtests, August 2026

`test/Backtest.t.sol` deploys `Tally` on a mainnet fork at the July 31
end-of-day block (the pipeline's `pin_blocks_som`), makes it persistent, and
walks the end-of-day block of every day of August calling `drip` and `poke`.
Three primes, in increasing difficulty.

```
ETH_RPC=<archive mainnet rpc> forge test --match-contract Fork -vv
```

(Cold RPC cache: Obex 5 min, Osero 2 min, Grove 17 min. Warm: seconds.)

### Obex: one venue (Maple syrupUSDC), no flows

| | Tally (daily) | pipeline (monthly) | ratio |
|---|---:|---:|---:|
| prime revenue | 1,631,729.31 | 1,631,729.31 | exact, to the cent |
| Sky share | 1,247,071.87 | 1,248,716.85 | 0.998683 |
| agent rate | 75,136.44 | 75,327.60 | 0.997462 |

### Osero: SparkLend spUSDS (rebasing aToken), 13M deposit mid-month

Marked: spUSDS through `ATokenPip`, its unborrowed share through
`LendingIdlePip` tagged `IDL`, idle USDS.

| | Tally (daily) | pipeline (monthly) | ratio |
|---|---:|---:|---:|
| prime revenue | 5,557.81 | 5,557.82 | exact, to the cent |
| Sky share, gross Base Rate on full debt | 11,333.36 | 11,348.31 (`daily_sky_rev_gross`) | 0.998683 |
| lending-idle deduction | 3,785.64 | 4,342.64 (gross − net) | 0.872 |
| Sky share, net | 7,547.71 | 7,005.67 | 1.077 |
| agent rate | 31,098.68 | 31,140.91 | 0.998644 |

The pipeline deducts the prime's share of USDS sitting unborrowed in the
SparkLend pool from utilized (38% of the debt on day one). The gross charge
matches to the conversion factor. The deduction is 13% short because the
debt was drawn in steps (1M → 3M on Aug 17, 4M on Aug 18, … 14M) and on each
step day the sampling rule charges the new debt while crediting the old idle
share; the pipeline includes both from the same day. A relayer `drip` before
each draw removes it, and the error is one-sided in Sky's favour.

### Grove: two ilks, 5 chains, RWA tranches, LP, cash distributions, subsidy, SDE

Marked: Ethereum venues with an adapter (aTokens, Morpho vaults, syrupUSDC,
JAAA and JTRSY through the ERC-7540 adapter, STAC through `ChroniclePip`,
BUIDL at par, idle stables, sUSDS, alt-holder and escrow balances). Not
marked: Curve and Uniswap V3 LP, the EOA relay, AUSD incentive and Galaxy cash
distributions, and every venue on Base, Avalanche, Plume and Monad.

| | Tally (daily) | pipeline (monthly) | note |
|---|---:|---:|---|
| prime revenue, marked venues (E4, E6, E7, E8) | 1,083,873.97 | 1,083,778.26 | $96 apart: E6 fully redeemed mid-month, E4 took a 3M deposit |
| prime revenue, all venues | 1,083,873.97 | 4,913,183.00 | the other 3.8M is LP, cash distributions and four other chains |
| SDE revenue, JTRSY | 2,507,334.74 | 2,507,613.29 | $279: fulfilled redeems at their fixed claim vs at NAV |
| SDE revenue, BUIDL | 0 | 2,111,592.75 | yield arrives as mints; needs `CapitalPip` with declared flows |
| Base Rate, gross on full debt | 8,593,819.39 | | 1B at the subsidised rate, the rest at BR |
| SDE slice rebate | 4,849,390.77 | | Base Rate handed back on 1.57B of SDE assets |
| Base Rate, net | 3,744,428.62 | 3,720,604.84 | 0.6%: sampling rule on the BUIDL redemption / debt wipe day |
| agent rate | 78,036.49 | 78,320.96 | conversion factor plus the sampling rule on the Aug 17 payment |

### What the three runs establish

- **Position accounting is exact where the data is on-chain.** Every
  ERC-4626, ERC-7540, aToken and oracle-priced venue reproduces the pipeline
  to the cent or within a day's yield on a mid-month flow, across three primes
  and 25 venues. The aToken case is the one that produced the +$667K MSC#11
  restatement off-chain.
- **The Sky share now matches the pipeline's utilized base.** With the
  lending-idle gem and the SDE rebate, Osero's and Grove's net Base Rate land
  within 8% and 0.6% of the pipeline, and the whole residual is the sampling
  rule on days with large same-block moves. It is one-sided in Sky's favour
  and disappears when the relayer drips before it draws or wipes.
- **Yield delivered as new tokens** (BUIDL dividends, Galaxy and Agora cash
  sweeps) is the one class no balance reader can recognise: a dividend and a
  deposit look the same. `CapitalPip` recognises it once the party moving
  capital declares its flows; until the controller does that, it stays
  hybrid. This is the 2.1M BUIDL line.
- **Cross-chain** is Grove's largest remaining gap (2.55M of 4.91M prime
  revenue on Base, Avalanche and Plume) and is the operator-relay path
  already agreed. Curve and Uniswap positions have an adapter path
  (`CurveLegPip` is written; Uniswap V3/V4 needs the tick-math port) and
  are small.

## 6. Decisions log

2026-09-07: daily capitalisation; charge on full `Art × rate`; subsidy filed
by governance; `duty` from `sUSDS.ssr()`; adapter architecture; per-vault
haircut; 7540 deposit queues at par; `SAV` tag; holder override; five tags;
Ethereum only; one instance per ilk; settle through AllocatorVault + Buffer,
no Vat privileges; negative Sky share carried; sUSDS agent rate on current
value; whole-USDS floor with carries; **pre-funded USDS float** for Sky's
out-of-pocket demand-side payments (topped up by governance, unpaid amounts
carried in `owe`); **operator relay** for L2 balances now, via
`RelayPip.poke` from the settlement-cycle pipeline, with a messaging bridge
(LayerZero) and/or a Chronicle feed as the intended next step. Both future
sources plug into the same `RelayPip` by being `rely`'d on it; nothing in
`Tally` changes.

2026-09-07, code review: settle pulls from the buffer with `transferFrom`
(the real buffer has no `withdraw`); draws are capped by ceiling headroom and
the rest carried; accruals sample the balance worse for the prime; IDL rebate
at the marginal rate and bounded by `tab`; SDE share on prior value; every gem
re-file requires a same-block poke and re-seeds; rate re-files require every
gem poked; a supply loss never nets against the demand side; `quit` added;
ERC-7540 adapter reads the ERC-7575 share and prices claimable legs at their
fixed values; `cut == 0` no longer disables the subsidy (`line` is the switch).

2026-09-07, later: the SSR leg reads the sUSDS share price (index) instead
of the spot `ssr()`, so SP-BEAM changes inside an interval are priced
exactly and a long gap compounds as sUSDS does; one instance per ilk with
`ilk` immutable and `alm` / `sub` / `vault` / `buffer` filed; `pay` flag so
a prime with two ilks pays the agent rate once; rebates accrue in `drip` on
the drip interval. Obex backtest unchanged on the daily cadence.

2026-09-08: `TallyJob` (dss-cron `IJob`) settles each instance once per UTC
day; `zzz` records the last settle so relayer drips do not suppress it.
Backtests for Osero and Grove added alongside Obex (§5).

2026-09-09: four adapters after the backtests: `ChroniclePip` (STAC),
`LendingIdlePip` (the MSC's lending-idle deduction, tagged `IDL`),
`CurveLegPip` (one gem per pool leg), `CapitalPip` (declared capital flows
for BUIDL-style yield). `SDE` gems now rebate the Base Rate on Sky's slice,
matching the MSC's exclusion of `sde_av` from utilized. `IDL` gems are memo
items and are not added to NAV. Grove's marked Ethereum revenue rises to
1,083,874 vs 1,083,778, and both Osero's and Grove's net Base Rate now
reconcile to the pipeline's utilized base.

Open: contract name (`Tally` stands; `Till` is the short alternative); float
sizing and top-up cadence; teaching the ALM controller to `drip` before
`mintUSDS` / `burnUSDS`.
