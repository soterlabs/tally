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
| Base Rate | `SSR_apr(n=12) + spread`, spread from config | `duty(ilk) = ssrps() + pad/365d`, `ssrps` from `sUSDS.ssr()` at `n = 365` **[D]** |
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
| mint | `vat.grab` + `vat.suck` in a spell | `AllocatorVault.draw(mint)` → `AllocatorBuffer.withdraw` **[D]** |
| send | USDS transfer from surplus buffer | paid out of the mint, shortfall from `Tally`'s own USDS; net `mint − send` joined to the Vow |
| whole USDS | `round()` per prime | floor to whole USDS, fractions carried **[D]** |
| negative Sky share | not addressed | carried forward in `sde` **[D]** |

Facts from the off-chain pipeline that shaped the design:

- The BR charge is not accrued on-chain today; allocator ilks are capitalised
  monthly by `grab`. `Tally.drip` is the missing Jug.
- BR is a nominal APR (Rule 1, 2026-09-01). Accrual is linear between
  settles; compounding happens only through capitalisation, which DSC does
  daily. Hence the APY→APR conversion at `n = 365`, and hence `ssrps()`:
  `rpow(ssr, 86400) − RAY` is exactly one day's slice of the SSR APY.
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
                 │  drip   debt×duty×dt → tab                    │──► Vat.ilks(ilk)
                 │         SubProxy USDS/sUSDS × (SSR+tip) → owe │──► sUSDS.ssr(), balances
                 │  poke   Σ pip.peek(who) → gain / sde / rebate │──► Pips ──► vaults, aTokens
                 │  settle sky, sv, mint, send (whole USDS)      │
                 │         vault.draw(mint); buffer.withdraw     │──► AllocatorVault, AllocatorBuffer
                 │         usds.transfer(sub, send)              │
                 │         join(vow, mint − send)                │──► UsdsJoin
  governance     │  init / file / gift / rely / deny / cage      │
  ─────────────► └──────────────────────────────────────────────┘
                                   │ events: Drip, Poke, Settle
                                   ▼
                 settlement-cycle (hybrid: idle deductions, DR, off-chain venues)
```

**Deployment [D]:** Ethereum only for now (the ilks live there). One `Tally`
instance per allocator ilk: Spark, Bloom, Grove (Diamond PAU), Obex, Prysm.
Keel and Skybase have no ilk and no ALM positions; a `Tally` with no gems and
`debt = 0` still pays their agent rate through `drip` + `settle`.

### 2.1 Vocabulary

| Word | Meaning here | Precedent |
|---|---|---|
| `ilk` | an allocator ilk, i.e. a prime's debt compartment | Vat |
| `alm` | ALM Proxy, default holder of the gems | — |
| `sub` | SubProxy: paid at settle, earns the agent rate | — |
| `gem` | a token position (USDS, sUSDC, JTRSY, spUSDS…) | Vat / Join |
| `pip` | pricing adapter for a gem, `peek(who) → (pie, chi, own)` | Spot / OSM |
| `who` | holder override for a gem (0 = `alm`) | — |
| `tag` | routing: `MTM`, `SDE`, `SAV`, `IDL`, `NIL` | — |
| `vault` / `buffer` | the prime's AllocatorVault / AllocatorBuffer | dss-allocator |
| `pie` / `chi` | shares held / price per 1e18 shares (ray) | Pot / sUSDS |
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
ssrps     = (rpow(sUSDS.ssr(), 86400) − RAY) / 86400      SSR, per-second nominal at daily compounding
duty      = ssrps + pad / 365d                             Base Rate
agentRate = usds_sub × (ssrps + tip/365d) × dt + susds_sub_value × tip/365d × dt
fee       = min(debt, line) × cut/365d × dt + max(debt − line, 0) × duty × dt     (or debt × duty × dt if no subsidy)
```

`file(ilk, "pad"|"tip"|"cut"|"line")` requires `rho == now`: drip in the same
block so a rate change never applies retroactively. `duty` itself follows
SP-BEAM changes to `ssr` with no governance action.

### 2.3 Positions

`poke(ilk, gem)` reads `(pie, chi, own)` from the gem's `pip`, applies the
`fee` haircut to `chi`, and books `dpnl = pie_old × (chi_new − chi_old)`:

| tag | routing |
|---|---|
| `MTM` | `gain += dpnl` |
| `SDE` | `share = cap == 0 ? 1 : min(1, cap / value)`; `sde += dpnl × share`; `gain += rest` |
| `SAV` | `rebate += value × pad/365d × dt`; `dpnl` ignored (SSR stays in the token) |
| `IDL` | `rebate += value × duty × dt`: the Base Rate charged on non-utilized balances is handed back. Exact while idle ≤ debt − line |
| `NIL` | nothing booked (Savings V2 position-only) |

Adapters shipped in `src/Pips.sol`:

| pip | `pie` | `chi` | `own` |
|---|---|---|---|
| `RawPip` | `balanceOf` | `RAY` | 0 |
| `Erc4626Pip` | `balanceOf` | `convertToAssets(1 share)` | 0 |
| `Erc7540Pip` | `balanceOf + pendingRedeem + claimableRedeem` | same | `pendingDeposit + claimableDeposit` |
| `ATokenPip` | `scaledBalanceOf` | `pool.getReserveNormalizedIncome(asset)` | 0 |
| `RelayPip` | pushed by an authorised writer | pushed | pushed |

`RelayPip` reverts on a mark older than `hop` (default one day, OSM-style), so a
stale relay stops `settle` for the whole ilk rather than settling on old data.

`RelayPip` is the extension point for positions that cannot be read on this
chain (L2 ALM Proxies, PSM3 baskets, custodial NAVs): a bridge receiver, an
oracle, or the hybrid process pokes it. Curve and Uniswap LP decomposition
would be further pips; nothing in `Tally` changes.

### 2.4 Settlement

`settle(ilk)` is permissionless. It drips, pokes every gem, then:

```
sky   = tab + sde − rebate
sv    = gain + rebate − tab − sin_prev
mint  = floor(sky + max(sv, 0))   fraction (or a negative total) carried in `sde`
send  = floor(owe + sv)           fraction carried in `owe`; a negative total in `sin`

vault.draw(mint)                  new ilk debt, USDS lands in the AllocatorBuffer
buffer.withdraw(usds, this, mint)
usds.transfer(sub, min(send, balance))     shortfall beyond the mint comes from
                                           USDS governance parked here; unpaid → owe
join(vow, mint − send)            Sky's net, credited to the surplus buffer
```

This nets the two MSC legs: instead of minting to the surplus buffer and
paying the SubProxy out of it, the prime's fresh debt pays the SubProxy
directly and only Sky's net crosses into the Vow. Economically identical,
and it needs no Vat privilege. When `send > mint` (Keel, Skybase, any prime
whose demand side exceeds its Sky share) Sky's part of the payment comes from
USDS that governance leaves in the contract, the on-chain equivalent of the
Demand-Side Buffer transfer in today's settlement transaction. If that runs
dry the balance is owed, not lost.

Because settlement executes in one transaction there is no `tab` to wipe;
the earlier `wipe` function is gone.

### 2.5 Permissions

`Tally` needs the prime-scoped roles the ALM controller already holds:
`AllocatorVault.draw` and `AllocatorBuffer.withdraw` for its own ilk. It
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
- `test/Tally.t.sol`: 20 tests against mocks of Vat, AllocatorVault,
  AllocatorBuffer, UsdsJoin, sUSDS, ERC-4626/7540 vaults and an aToken pool,
  covering rates, index PnL, haircuts, escrow, SDE caps, SAV and IDL rebates,
  subsidy, whole-USDS settlement with carries, the negative prime share, the
  hoard-funded demand side, gifts, permissionless settle, the
  allocator-only privilege boundary and relay staleness.

## 5. Decisions log

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

Open: contract name (`Tally` stands; `Till` is the short alternative); float
sizing and top-up cadence.
