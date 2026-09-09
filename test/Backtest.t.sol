// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { Test, console2 } from "forge-std/Test.sol";
import { Tally } from "../src/Tally.sol";
import { RawPip, Erc4626Pip, Erc7540Pip, ATokenPip, ChroniclePip, LendingIdlePip } from "../src/Pips.sol";

interface KissLike { function kiss(address) external; }

/// August 2026 backtests on a mainnet fork against settlements/<prime>/2026-08
/// in settlement-cycle. Deploy at the July 31 end-of-day block (the pipeline's
/// pin_blocks_som), then walk the end-of-day block of every day of August
/// calling drip and poke.
///
///   ETH_RPC=<archive mainnet rpc> forge test --match-contract Fork -vv
abstract contract ForkBase is Test {
    address constant VAT       = 0x35D1b3F3D7966A1DFe207aa4514C12a259A0492B;
    address constant VOW       = 0xA950524441892A31ebddF91d3cEEFa04Bf454466;
    address constant USDS_JOIN = 0x3C0f895007CA717Aa01c8693e59DF1e8C3777FEB;
    address constant USDS      = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address constant SUSDS     = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address constant USDC      = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant DAI       = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    // Last block at or before 23:59:59 UTC, 2026-07-31 .. 2026-08-31.
    uint256[32] BLOCKS = [
        uint256(25656292), 25663469, 25670641, 25677819, 25684999, 25692172, 25699361, 25706531,
        25713689, 25720867, 25728039, 25735200, 25742366, 25749550, 25756720, 25763887,
        25771073, 25778250, 25785424, 25792601, 25799779, 25806958, 25814126, 25821305,
        25828483, 25835657, 25842829, 25850009, 25857181, 25864358, 25871535, 25878704
    ];

    // n = 12 (monthly capitalisation, pipeline) vs n = 365 (daily, Tally):
    // 3.664456% vs 3.659626% with the 20 bps spread.
    uint256 constant N_RATIO = 0.998682e18;

    string rpc;

    function _fork(uint256 d) internal { vm.createSelectFork(rpc, BLOCKS[d]); _afterFork(); }
    // Per-fork fixtures that live in non-persistent contracts (e.g. an oracle whitelist).
    function _afterFork() internal virtual {}

    function _new(bytes32 ilk, address alm, address sub, uint256 pay) internal returns (Tally t) {
        t = new Tally(ilk, VAT, VOW, USDS_JOIN, USDS, SUSDS);
        t.file("alm", alm);
        t.file("sub", sub);
        t.file("pad", 0.002e27);
        t.file("tip", 0.002e27);
        t.file("pay", pay);
        vm.makePersistent(address(t));
    }

    function _raw(Tally t, address gem, uint8 tag) internal { _raw(t, gem, gem, tag, address(0)); }
    // `key` is the gem id in Tally (a token may appear once per holder), `gem` the token read.
    function _raw(Tally t, address key, address gem, uint8 tag, address who) internal {
        RawPip p = new RawPip(gem); vm.makePersistent(address(p));
        t.init(key, address(p), tag);
        if (who != address(0)) { t.poke(key); t.file(key, "who", who); }
    }
    function _v4626(Tally t, address vault, uint8 tag) internal {
        Erc4626Pip p = new Erc4626Pip(vault); vm.makePersistent(address(p));
        t.init(vault, address(p), tag);
    }
    function _v7540(Tally t, address share, address vault, uint8 tag) internal {
        Erc7540Pip p = new Erc7540Pip(vault); vm.makePersistent(address(p));
        t.init(share, address(p), tag);
    }
    function _atoken(Tally t, address aToken, uint8 tag) internal {
        ATokenPip p = new ATokenPip(aToken); vm.makePersistent(address(p));
        t.init(aToken, address(p), tag);
    }
    // The holder's share of unborrowed underlying in the pool, as an IDL gem next to the aToken.
    function _idle(Tally t, address aToken) internal {
        LendingIdlePip p = new LendingIdlePip(aToken); vm.makePersistent(address(p));
        t.init(address(uint160(aToken) + 1), address(p), t.IDL());
    }
    function _chronicle(Tally t, address gem, address oracle, uint8 tag) internal returns (ChroniclePip p) {
        p = new ChroniclePip(gem, oracle); vm.makePersistent(address(p));
        t.init(gem, address(p), tag);
    }

    function _run(Tally[] memory ts, string memory name) internal {
        uint256 som;
        for (uint256 i = 0; i < ts.length; i++) som += ts[i].nav();
        console2.log("%s  SoM nav %s  debt %s", name, som / 1e18, _debt(ts) / 1e18);
        for (uint256 d = 1; d < 32; d++) {
            _fork(d);
            for (uint256 i = 0; i < ts.length; i++) { ts[i].drip(); ts[i].poke(); }
        }
        uint256 eom;
        for (uint256 i = 0; i < ts.length; i++) eom += ts[i].nav();
        console2.log("%s  EoM nav %s  debt %s", name, eom / 1e18, _debt(ts) / 1e18);
    }

    function _debt(Tally[] memory ts) internal view returns (uint256 d) {
        for (uint256 i = 0; i < ts.length; i++) d += ts[i].debt();
    }

    function _report(Tally[] memory ts, uint256 pSky, uint256 pPrime, uint256 pSde, uint256 pAgent)
        internal view returns (uint256 tab, int256 gain, int256 sde, uint256 owe, uint256 rebate)
    {
        for (uint256 i = 0; i < ts.length; i++) {
            tab += ts[i].tab(); gain += ts[i].gain(); sde += ts[i].sde(); owe += ts[i].owe(); rebate += ts[i].rebate();
        }
        console2.log("                  Tally (daily)      pipeline (monthly)");
        console2.log("sky share (BR)  %s      %s", tab / 1e16, pSky / 1e16);
        console2.log("prime revenue   %s      %s", uint256(gain) / 1e16, pPrime / 1e16);
        console2.log("sde revenue     %s      %s", uint256(sde) / 1e16, pSde / 1e16);
        console2.log("agent rate      %s      %s", owe / 1e16, pAgent / 1e16);
        console2.log("rebates         %s", rebate / 1e16);
        console2.log("net BR (tab-rb) %s", (tab - (rebate < tab ? rebate : tab)) / 1e16);
        console2.log("(cents)");
    }
}

// ---------------------------------------------------------------------------
// Obex: one venue, Maple syrupUSDC, no flows in the month.
// ---------------------------------------------------------------------------
contract ObexForkTest is ForkBase {
    bytes32 constant ILK   = 0x414c4c4f4341544f522d4f4245582d4100000000000000000000000000000000; // ALLOCATOR-OBEX-A
    address constant ALM   = 0xb6dD7ae22C9922AFEe0642f9Ac13e58633f715A2;
    address constant SUB   = 0x8be042581f581E3620e29F213EA8b94afA1C8071;
    address constant SYRUP = 0x80ac24aA929eaF5013f6436cdA2a7ba190f5Cc0b;

    uint256 constant PIPE_SKY   = 1248716.853281968734508417e18;
    uint256 constant PIPE_PRIME = 1631729.31221914408600e18;
    uint256 constant PIPE_AGENT = 75327.597118087929616472e18;

    Tally t;

    function setUp() public {
        rpc = vm.envString("ETH_RPC");
        _fork(0);
        t = _new(ILK, ALM, SUB, 1);
        _raw(t, USDS, t.MTM());
        _raw(t, USDC, t.MTM());
        _v4626(t, SYRUP, t.MTM());
    }

    function test_obex_august_2026() public {
        Tally[] memory ts = new Tally[](1); ts[0] = t;
        _run(ts, "obex");
        (uint256 tab, int256 gain,, uint256 owe,) = _report(ts, PIPE_SKY, PIPE_PRIME, 0, PIPE_AGENT);

        // Prime revenue is pure index PnL with no flows: to the cent.
        assertApproxEqAbs(uint256(gain), PIPE_PRIME, 0.01e18);
        // Sky share: conversion frequency only.
        assertApproxEqRel(tab, PIPE_SKY * N_RATIO / 1e18, 0.0002e18);
        // Agent rate: conversion frequency plus one day of the sampling rule on
        // the MSC#11 payment that landed at the SubProxy on Aug 17 (~92 USDS).
        assertApproxEqRel(owe, PIPE_AGENT * N_RATIO / 1e18, 0.0015e18);
    }
}

// ---------------------------------------------------------------------------
// Osero: SparkLend spUSDS (rebasing aToken) plus idle USDS, on the Diamond PAU
// ALM Proxy. A 13M draw and deposit mid-month. The pipeline deducts the
// prime's share of unborrowed USDS in the SparkLend pool ("lending idle")
// from utilized; Tally charges the full ilk debt.
// ---------------------------------------------------------------------------
contract OseroForkTest is ForkBase {
    bytes32 constant ILK    = 0x414c4c4f4341544f522d505259534d2d41000000000000000000000000000000; // ALLOCATOR-PRYSM-A
    address constant ALM    = 0x6d370e359e9cbd0Fd35Bb38fAF705D84238CB884;
    address constant SUB    = 0x24fdcd3bFA5C2553e05B2f9AD0365EBC296278D3;
    address constant SPUSDS = 0xC02aB1A5eaA8d1B114EF786D9bde108cD4364359;

    uint256 constant PIPE_SKY   = 7005.670168877913613751e18;
    uint256 constant PIPE_PRIME = 5557.81862043350430479200e18;
    uint256 constant PIPE_AGENT = 31140.910907017458158378e18;

    Tally t;

    function setUp() public {
        rpc = vm.envString("ETH_RPC");
        _fork(0);
        t = _new(ILK, ALM, SUB, 1);
        _atoken(t, SPUSDS, t.MTM());
        _idle(t, SPUSDS);              // prime's share of unborrowed USDS in SparkLend: not utilized
        _raw(t, USDS, t.MTM());
    }

    function test_osero_august_2026() public {
        Tally[] memory ts = new Tally[](1); ts[0] = t;
        _run(ts, "osero");
        (uint256 tab, int256 gain,, uint256 owe, uint256 rebate) = _report(ts, PIPE_SKY, PIPE_PRIME, 0, PIPE_AGENT);
        // Net Base Rate = full debt less the lending-idle rebate: the pipeline's
        // utilized. The residual is the sampling rule on the day of the 13M
        // draw: debt is charged at the new balance (max) while the idle share
        // is credited at the old one (min). A relayer that drips before drawing
        // removes it. Conservative for Sky by construction.
        assertApproxEqRel(tab - rebate, PIPE_SKY * N_RATIO / 1e18, 0.1e18);
        assertGe(tab - rebate, PIPE_SKY * N_RATIO / 1e18);

        // aToken yield through scaledBalance x liquidityIndex, daily: index PnL
        // with a 13M flow mid-month. Expect agreement within a day's yield on
        // the flow (13M x 4% / 365 = ~1,400 USDS) -- the flow-at-end-index
        // approximation.
        assertApproxEqRel(uint256(gain), PIPE_PRIME, 0.3e18);
        assertApproxEqRel(owe, PIPE_AGENT * N_RATIO / 1e18, 0.002e18);
        assertGt(tab, PIPE_SKY);   // gross, before the idle rebate
    }
}

// ---------------------------------------------------------------------------
// Grove: two ilks (BLOOM carries the demand side), 5 chains, RWA tranches,
// Centrifuge 7540 vaults, Morpho vaults, LP positions, off-chain cash
// distributions, subsidy, SDE exclusion. Only the Ethereum venues with an
// adapter are marked here. Expect a large discrepancy.
// ---------------------------------------------------------------------------
contract GroveForkTest is ForkBase {
    bytes32 constant BLOOM = 0x414c4c4f4341544f522d424c4f4f4d2d41000000000000000000000000000000; // ALLOCATOR-BLOOM-A
    bytes32 constant GROVE = 0x414c4c4f4341544f522d47524f56452d41000000000000000000000000000000; // ALLOCATOR-GROVE-A
    address constant ALM     = 0x491EDFB0B8b608044e227225C715981a30F3A44E;
    address constant DIAMOND = 0x0DcD9298e163dFD3c0B5b00F0d9093C36e40A153;
    address constant SUB     = 0x1369f7b2b38c76B6478c0f0E66D94923421891Ba;
    address constant ALT     = 0x94B398ACb2fcE988871218221EA6a4a2b26CcCbC;   // alt holder
    address constant ESCROW  = 0x2Cd296095788A2741e72056D66B3Ae1fAeE23ea2;   // JTRSY Basin escrow

    address constant A_RLUSD_HOR = 0xE3190143Eb552456F88464662f0c0C4aC67A77eB;
    address constant A_USDC_HOR  = 0x68215B6533c47ff9f7125aC95adf00fE4a62f79e;
    address constant A_RLUSD     = 0xFa82580c16A31D0c1bC632A36F82e83EfEF3Eec0;
    address constant STEAK_USDC  = 0xBeefF08dF54897e7544aB01d0e86f013DA354111;
    address constant STEAK_HY    = 0xBEEf2B5FD3D94469b7782aeBe6364E6e6FB1B709;
    address constant STEAK_AUSD  = 0xBEEfF0d672ab7F5018dFB614c93981045D4aA98a;
    address constant STEAK_PYUSD = 0xd8A6511979D9C5D387c819E9F8ED9F3a5C6c5379;
    address constant SYRUP       = 0x80ac24aA929eaF5013f6436cdA2a7ba190f5Cc0b;
    address constant JAAA        = 0x5a0F93D040De44e78F251b03c43be9CF317Dcf64;
    address constant JAAA_VAULT  = 0x4880799eE5200fC58DA299e965df644fBf46780B;
    address constant JTRSY       = 0x8c213ee79581Ff4984583C6a801e5263418C4b86;
    address constant JTRSY_VAULT = 0xFE6920eB6C421f1179cA8c8d4170530CDBdfd77A;
    address constant BUIDL       = 0x6a9DA2D710BB9B700acde7Cb81F10F1fF8C89041;
    address constant RLUSD       = 0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD;
    address constant AUSD        = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
    address constant PYUSD       = 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8;
    address constant STAC        = 0x51C2d74017390CbBd30550179A16A1c28F7210fc;
    address constant STAC_ORACLE = 0x802CaCc19B9b3eb474C7DEf6f28c64AB67fb0753;   // Chronicle
    address constant CHRONICLE_AUTHED = 0x62a69d7832040Cd629Ee2f712b4C8639C0F905D7;
    ChroniclePip stacPip;

    uint256 constant PIPE_SKY   = 8339810.888358439873673301e18;
    uint256 constant PIPE_PRIME = 4913183.004893321502279642e18;
    uint256 constant PIPE_SDE   = 4619206.044032157837397506e18;
    uint256 constant PIPE_AGENT = 78320.958615627202319059e18;

    Tally bloom; Tally grove;

    // Chronicle feeds are toll-gated; the whitelist lives in the oracle, which
    // is re-read fresh on every fork, so re-kiss the pip each time.
    function _afterFork() internal override {
        if (address(stacPip) == address(0)) {
            // First fork: the pip does not exist yet; precompute its address.
            return;
        }
        vm.prank(CHRONICLE_AUTHED);
        KissLike(STAC_ORACLE).kiss(address(stacPip));
    }

    function setUp() public {
        rpc = vm.envString("ETH_RPC");
        _fork(0);
        bloom = _new(BLOOM, ALM, SUB, 1);
        grove = _new(GROVE, DIAMOND, SUB, 0);
        // Subsidy as the pipeline priced it for August: SOFR 3.66% ramping
        // toward BR over 24 months, T = 7 -> 3.6613% on the first $1B.
        bloom.file("cut", 0.036613e27);
        bloom.file("line", 1_000_000_000e18);

        // Ethereum venues with an on-chain adapter. Not marked: Curve / Uniswap
        // V3 LP, the EOA relay, cash distributions, and everything on Base,
        // Avalanche, Plume, Monad.
        _atoken(bloom, A_RLUSD_HOR, bloom.MTM());
        _atoken(bloom, A_USDC_HOR,  bloom.MTM());
        _atoken(bloom, A_RLUSD,     bloom.MTM());
        _v4626(bloom, STEAK_USDC,  bloom.MTM());
        _v4626(bloom, STEAK_HY,    bloom.MTM());
        _v4626(bloom, STEAK_AUSD,  bloom.MTM());
        _v4626(bloom, STEAK_PYUSD, bloom.MTM());
        _v4626(bloom, SYRUP,       bloom.MTM());
        stacPip = new ChroniclePip(STAC, STAC_ORACLE); vm.makePersistent(address(stacPip));
        _afterFork();   // kiss before the first read in init
        bloom.init(STAC, address(stacPip), bloom.MTM());
        _v7540(bloom, JAAA,  JAAA_VAULT,  bloom.MTM());
        _v7540(bloom, JTRSY, JTRSY_VAULT, bloom.SDE());
        _raw(bloom, BUIDL, bloom.SDE());          // const $1; its yield arrives as mints (flows)
        _raw(bloom, RLUSD, bloom.MTM());
        _raw(bloom, AUSD,  bloom.MTM());
        _raw(bloom, USDC,  bloom.MTM());
        _raw(bloom, DAI,   bloom.MTM());
        _raw(bloom, PYUSD, bloom.MTM());
        _raw(bloom, USDS,  bloom.MTM());
        _v4626(bloom, SUSDS, bloom.SAV());
        // Same tokens at other holders: distinct keys, holder override.
        _raw(bloom, address(uint160(AUSD) + 1), AUSD, bloom.MTM(), ALT);
        _raw(bloom, address(uint160(USDC) + 1), USDC, bloom.MTM(), ALT);
        _raw(bloom, address(uint160(USDS) + 1), USDS, bloom.MTM(), DIAMOND);
        _raw(bloom, address(uint160(USDS) + 2), USDS, bloom.MTM(), ESCROW);
    }

    // Pipeline per-venue revenue for the venues marked above (settlements/grove/2026-08).
    uint256 constant PIPE_MARKED   = 7322.92e18 + 36533.48e18 + 570646.76e18 + 469275.10e18;   // Steakhouse USDC, Steakhouse AUSD, JAAA, STAC
    uint256 constant PIPE_COF      = 3720604.844326282036275795e18;   // subsidy_summary.actual_cof: BR on utilized
    uint256 constant PIPE_E9       = 2507613.29e18;                              // JTRSY (SDE)

    function test_grove_august_2026() public {
        Tally[] memory ts = new Tally[](2); ts[0] = bloom; ts[1] = grove;
        _run(ts, "grove");
        (uint256 tab, int256 gain, int256 sde, uint256 owe, uint256 rebate) = _report(ts, PIPE_SKY, PIPE_PRIME, PIPE_SDE, PIPE_AGENT);

        // Prime revenue of the marked Ethereum venues: within $150 of the
        // pipeline's sum for the same four venues (E6 was fully redeemed
        // mid-month, E4 took a 3M deposit, STAC through Chronicle).
        assertApproxEqAbs(uint256(gain), PIPE_MARKED, 150e18);
        // Net Base Rate: full debt at cut/BR less the SDE slice's rebate ==
        // the pipeline's utilized (debt - sde_av) at the same tiers. The 0.6%
        // residual is the sampling rule on the day BUIDL was redeemed (75M)
        // and debt wiped (91M): debt charged at the higher reading, SDE slice
        // rebated at the lower. Conservative for Sky; a drip before the wipe
        // removes it.
        assertApproxEqRel(tab - rebate, PIPE_COF, 0.01e18);
        assertGe(tab - rebate, PIPE_COF);
        // JTRSY: the pipeline values escrowed shares at NAV, Tally values the
        // fulfilled part at its fixed claim (maxWithdraw): ~280 USDS apart.
        assertApproxEqAbs(uint256(sde), PIPE_E9, 400e18);
        // BUIDL's 2.11M is absent by construction: its yield arrives as
        // mints, which are flows to an index-based reader.
        // Sky share: full debt (2.79B) at cut/BR, vs the pipeline's utilized
        // (debt - 1.57B of SDE assets) at the same rates. Tally is higher.
        assertGt(tab, PIPE_SKY);
        assertApproxEqRel(owe, PIPE_AGENT * N_RATIO / 1e18, 0.005e18);
        console2.log("per-venue EoM values (cents):");
        for (uint256 k = 0; k < bloom.count(); k++) {
            address g = bloom.list(k);
            console2.log("  %s  %s", g, bloom.value(g) / 1e16);
        }
    }
}
