// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { Test, console2 } from "forge-std/Test.sol";
import { Tally } from "../src/Tally.sol";
import { RawPip, Erc4626Pip } from "../src/Pips.sol";

/// Backtest: deploy at the July 31, 2026 end-of-day block, then walk the
/// pipeline's end-of-day blocks for every day of August 2026 calling drip and
/// poke, and compare the books to settlements/obex/2026-08 in settlement-cycle.
///
///   ETH_RPC=<archive mainnet rpc> forge test --match-contract ObexFork -vv
contract ObexForkTest is Test {
    bytes32 constant ILK = 0x414c4c4f4341544f522d4f4245582d4100000000000000000000000000000000; // ALLOCATOR-OBEX-A

    address constant VAT       = 0x35D1b3F3D7966A1DFe207aa4514C12a259A0492B;
    address constant VOW       = 0xA950524441892A31ebddF91d3cEEFa04Bf454466;
    address constant USDS_JOIN = 0x3C0f895007CA717Aa01c8693e59DF1e8C3777FEB;
    address constant USDS      = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address constant SUSDS     = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address constant USDC      = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant SYRUP     = 0x80ac24aA929eaF5013f6436cdA2a7ba190f5Cc0b;

    address constant ALM = 0xb6dD7ae22C9922AFEe0642f9Ac13e58633f715A2;
    address constant SUB = 0x8be042581f581E3620e29F213EA8b94afA1C8071;

    // Last block at or before 23:59:59 UTC, 2026-07-31 .. 2026-08-31.
    // Endpoints equal the pipeline's pin_blocks_som / pin_blocks_eom.
    uint256[32] BLOCKS = [
        uint256(25656292), 25663469, 25670641, 25677819, 25684999, 25692172, 25699361, 25706531,
        25713689, 25720867, 25728039, 25735200, 25742366, 25749550, 25756720, 25763887,
        25771073, 25778250, 25785424, 25792601, 25799779, 25806958, 25814126, 25821305,
        25828483, 25835657, 25842829, 25850009, 25857181, 25864358, 25871535, 25878704
    ];

    // settlements/obex/2026-08/provenance.json
    uint256 constant PIPE_SKY   = 1248716.853281968734508417e18;
    uint256 constant PIPE_PRIME = 1631729.31221914408600e18;
    uint256 constant PIPE_AGENT = 75327.597118087929616472e18;
    uint256 constant PIPE_SOM   = 402261461.62722248595400e18;
    uint256 constant PIPE_EOM   = 403893190.9394416300400e18;

    string rpc;
    Tally tally;

    function setUp() public {
        rpc = vm.envString("ETH_RPC");
        vm.createSelectFork(rpc, BLOCKS[0]);

        tally = new Tally(ILK, VAT, VOW, USDS_JOIN, USDS, SUSDS);
        RawPip     usdsPip  = new RawPip(USDS);
        RawPip     usdcPip  = new RawPip(USDC);
        Erc4626Pip syrupPip = new Erc4626Pip(SYRUP);

        tally.file("alm", ALM);
        tally.file("sub", SUB);
        tally.file("pad", 0.002e27);   // BR = SSR + 20 bps
        tally.file("tip", 0.002e27);   // agent rate = SSR + 20 bps
        tally.file("pay", 1);
        tally.init(USDS,  address(usdsPip),  tally.MTM());
        tally.init(USDC,  address(usdcPip),  tally.MTM());
        tally.init(SYRUP, address(syrupPip), tally.MTM());

        vm.makePersistent(address(tally));
        vm.makePersistent(address(usdsPip));
        vm.makePersistent(address(usdcPip));
        vm.makePersistent(address(syrupPip));
    }

    function test_obex_august_2026() public {
        uint256 som = tally.nav();
        console2.log("SoM block %s  debt %s  nav %s", BLOCKS[0], tally.debt() / 1e18, som / 1e18);
        console2.log("SoM syrupUSDC value (pipeline value_som = 402,261,461.63): %s", tally.value(SYRUP) / 1e14);

        uint256 prevTab; uint256 prevOwe;
        for (uint256 d = 1; d < 32; d++) {
            vm.createSelectFork(rpc, BLOCKS[d]);
            tally.drip();
            tally.poke();
            (uint256 t, uint256 o, int256 g) = (tally.tab(), tally.owe(), tally.gain());
            console2.log("2026-08-%s  debt %s  sky/day %s", d, tally.debt() / 1e18, (t - prevTab) / 1e14);
            console2.log("            agent/day %s  gain (cum) %s", (o - prevOwe) / 1e14, uint256(g) / 1e14);
            prevTab = t; prevOwe = o;
        }

        (uint256 tab, uint256 owe, int256 gain) = (tally.tab(), tally.owe(), tally.gain());
        uint256 eom = tally.nav();
        console2.log("EoM syrupUSDC value (pipeline value_eom = 403,893,190.94): %s", tally.value(SYRUP) / 1e14);
        console2.log("");
        console2.log("                 Tally            pipeline");
        console2.log("sky share    %s   %s", tab / 1e14, PIPE_SKY / 1e14);
        console2.log("prime rev    %s   %s", uint256(gain) / 1e14, PIPE_PRIME / 1e14);
        console2.log("agent rate   %s   %s", owe / 1e14, PIPE_AGENT / 1e14);
        console2.log("nav SoM->EoM %s -> %s", som / 1e14, eom / 1e14);

        // Prime revenue is pure index PnL with no flows: must match to the cent.
        assertApproxEqAbs(uint256(gain), PIPE_PRIME, 0.01e18);
        // Sky share and agent rate differ only by the APY->APR conversion
        // frequency: the pipeline uses n = 12 (monthly capitalisation), Tally
        // n = 365 (daily). SSR_apr(12) = 3.464456%, SSR_apr(365) = 3.459626%.
        // With the 20 bps spread: 3.664456% vs 3.659626%, ratio 0.998682.
        assertApproxEqRel(tab, PIPE_SKY * 0.998682e18 / 1e18, 0.0002e18);
        // The agent rate carries one more difference: the MSC#11 payment
        // landed at the SubProxy on Aug 17. The pipeline credits the new
        // balance from that day (include-same-day); the sampling rule
        // credits it from the next drip, so Tally is one day of agent rate
        // on the increment (~92 USDS) lower. Result: 75,136.45 vs 75,327.60.
        assertApproxEqRel(owe, PIPE_AGENT * 0.998682e18 / 1e18, 0.0015e18);
        assertLt(owe, PIPE_AGENT * 0.998682e18 / 1e18);
    }
}
