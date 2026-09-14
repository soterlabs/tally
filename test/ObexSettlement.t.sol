// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { console2 } from "forge-std/Test.sol";
import { ForkBase } from "./Backtest.t.sol";
import { MockVat, MockToken, MockJoin, MockAllocatorVault, MockBuffer } from "./Tally.t.sol";
import { Tally } from "../src/Tally.sol";
import { Till } from "../src/Till.sol";

interface ObexTokenLike {
    function balanceOf(address) external view returns (uint256);
}

interface ObexVatLike {
    function ilks(bytes32) external view returns (uint256, uint256, uint256, uint256, uint256);
}

/// Real historical Maple/sUSDS indices and ALM holdings; persistent simulated
/// Vat, USDS, allocator and join. Tally and Till execute their production code.
/// This is an economic simulation, not verification of deployed allocator roles.
contract ObexSettlementForkTest is ForkBase {
    bytes32 constant ILK = "ALLOCATOR-OBEX-A";
    address constant ALM = 0xb6dD7ae22C9922AFEe0642f9Ac13e58633f715A2;
    address constant SUB = 0x8be042581f581E3620e29F213EA8b94afA1C8071;
    address constant SYRUP = 0x80ac24aA929eaF5013f6436cdA2a7ba190f5Cc0b;
    uint256 constant WAD = 1e18;
    uint256 constant RAY = 1e27;

    MockVat vat;
    MockToken usds;
    MockJoin join;
    MockAllocatorVault vault;
    MockBuffer buffer;
    Tally tally;
    Till till;

    uint256 initialDebt;
    uint256 initialSub;
    uint256 initialShares;
    uint256 initialUsdc;
    uint256 historicalDebt;
    uint256 historicalSub;

    struct Totals {
        uint256 fee;
        uint256 agent;
        uint256 gain;
        uint256 drew;
        uint256 paid;
        uint256 kept;
        uint256 legacyDebt;
        uint256 legacySend;
    }
    Totals totals;
    bool classifyLegacy;

    function setUp() public {
        rpc = vm.envString("ETH_RPC");
        _fork(0);
        (uint256 art, uint256 rate,, uint256 line,) = ObexVatLike(VAT).ilks(ILK);
        assertEq(rate, RAY, "simulation requires unit allocator rate");
        initialDebt = historicalDebt = art;
        initialSub = historicalSub = ObexTokenLike(USDS).balanceOf(SUB);
        initialShares = ObexTokenLike(SYRUP).balanceOf(ALM);
        initialUsdc = ObexTokenLike(USDC).balanceOf(ALM);
        assertEq(ObexTokenLike(USDS).balanceOf(ALM), 0);
        assertEq(ObexTokenLike(SUSDS).balanceOf(SUB), 0);

        vat = new MockVat();
        vat.set(ILK, art, rate);
        vat.setLine(ILK, line);
        usds = new MockToken(18);
        usds.mint(SUB, initialSub);
        join = new MockJoin(address(usds));
        buffer = new MockBuffer();
        vault = new MockAllocatorVault(address(vat), address(join), ILK, address(buffer));
        tally = new Tally(ILK, address(vat), address(usds), SUSDS);
        till = new Till(address(tally), VOW, address(join), address(usds));
        vault.rely(address(till));
        buffer.approve(address(usds), address(till), type(uint256).max);
        till.file("vault", address(vault));
        till.file("buffer", address(buffer));
        tally.file("alm", ALM);
        tally.file("sub", SUB);
        tally.file("till", address(till));
        tally.file("pad", 0.002e27);
        tally.file("tip", 0.002e27);
        tally.file("pay", 1);
        _raw(tally, address(usds), tally.MTM());
        _raw(tally, USDC, tally.MTM());
        _v4626(tally, SYRUP, tally.MTM());

        vm.makePersistent(address(vat));
        vm.makePersistent(address(usds));
        vm.makePersistent(address(join));
        vm.makePersistent(address(buffer));
        vm.makePersistent(address(vault));
        vm.makePersistent(address(tally));
        vm.makePersistent(address(till));
    }

    function test_obex_daily_settlement_legacy() public {
        _runSettlement("legacy", true, false, 0);
        assertEq(totals.legacyDebt, 2_535_968e18);
        assertEq(totals.legacySend, 916_736e18);
        _fullyPaid();
    }

    function test_obex_daily_settlement_noted() public {
        classifyLegacy = true;
        _runSettlement("noted", true, false, 0);
        assertEq(totals.legacyDebt, 2_535_968e18);
        assertEq(tally.notes("MSC-2026-07"), 1);
        _fullyPaid();
    }

    function test_obex_daily_settlement_refresh() public {
        // Post-payment refresh is now automatic. An additional same-block
        // drip must be idempotent and produce identical daily balances.
        _runSettlement("refresh", true, true, 0);
        _fullyPaid();
    }

    function test_obex_daily_settlement_ceiling() public {
        // Isolate a closed ceiling and exhausted float. No legacy event in this
        // synthetic stress scenario; the real August 17 spell bypasses frob's
        // ceiling check, which this allocator mock deliberately does not model.
        vat.setLine(ILK, (initialDebt + WAD) * RAY);
        _runSettlement("ceiling", false, true, 20_000e18);
        assertEq(totals.drew, 0);
        assertEq(totals.paid, 20_000e18);
        assertEq(usds.balanceOf(address(till)), 0);
        assertGt(tally.owe(), 0);
        assertGt(tally.sde(), 0);
    }

    function _fullyPaid() internal view {
        assertLt(tally.owe(), WAD, "only sub-USDS payout rounding may remain");
        assertGe(tally.sde(), 0);
        assertLt(uint256(tally.sde()), WAD, "only sub-USDS draw rounding may remain");
        assertEq(usds.balanceOf(address(till)), 0, "no float needed for this profitable month");
    }

    function _legacy(uint256 day, bool include) internal {
        (uint256 art, uint256 rate,,,) = ObexVatLike(VAT).ilks(ILK);
        assertEq(rate, RAY);
        uint256 sub = ObexTokenLike(USDS).balanceOf(SUB);
        if (art != historicalDebt || sub != historicalSub) {
            assertEq(day, 17, "unclassified historical flow");
            assertEq(art - historicalDebt, 2_535_968e18);
            assertEq(sub - historicalSub, 916_736e18);
            if (include) {
                // July's obligation is still due during August. Add it once,
                // separately from the daily settlement of August's earnings.
                if (classifyLegacy) tally.drip();
                vat.frob(ILK, art - historicalDebt);
                usds.mint(SUB, sub - historicalSub);
                if (classifyLegacy) tally.note("MSC-2026-07");
                totals.legacyDebt += art - historicalDebt;
                totals.legacySend += sub - historicalSub;
            }
        }
        historicalDebt = art;
        historicalSub = sub;
    }

    function _runSettlement(string memory name, bool legacy, bool refresh, uint256 float) internal {
        usds.mint(address(till), float);
        console2.log("OBEX_SIM", name);
        console2.log("initial_debt", initialDebt);
        console2.log("initial_sub", initialSub);
        console2.log("initial_float", float);
        for (uint256 day = 1; day <= 31; day++) {
            _fork(day);
            // Fail rather than silently treating an unmodeled investment flow
            // or SubProxy sUSDS position as part of this counterfactual.
            assertEq(ObexTokenLike(SYRUP).balanceOf(ALM), initialShares);
            assertEq(ObexTokenLike(USDC).balanceOf(ALM), initialUsdc);
            assertEq(ObexTokenLike(USDS).balanceOf(ALM), 0);
            assertEq(ObexTokenLike(SUSDS).balanceOf(SUB), 0);
            // The legacy hook can accrue before its debt change; measure the
            // incoming carry before that accrual, not after it.
            uint256 carry = tally.owe();
            _legacy(day, legacy);
            tally.drip();
            tally.poke();
            totals.fee += tally.tab();
            totals.agent += tally.owe() - carry;
            assertGe(tally.gain(), 0);
            totals.gain += uint256(tally.gain());
            uint256 debt = tally.debt();
            uint256 sub = usds.balanceOf(SUB);
            uint256 bank = join.credited(VOW);
            tally.settle();
            totals.drew += tally.debt() - debt;
            totals.paid += usds.balanceOf(SUB) - sub;
            totals.kept += (join.credited(VOW) - bank) / RAY;
            if (refresh) tally.drip();

            assertEq(tally.sin(), 0, "Obex has positive daily supply PnL");
            assertEq(tally.gap(), classifyLegacy ? int256(0) : -int256(totals.legacyDebt), "own draws must not become equity losses");
            assertEq(tally.debt(), initialDebt + totals.legacyDebt + totals.drew);
            assertEq(usds.balanceOf(SUB), initialSub + totals.legacySend + totals.paid);
            assertEq(float + totals.drew, totals.paid + totals.kept + usds.balanceOf(address(till)));
            assertEq(totals.gain, totals.drew + uint256(tally.sde()), "draws plus carry conserve revenue");
            assertEq(totals.gain + totals.agent - totals.fee, totals.paid + tally.owe(), "paid plus owed conserve PnL");
            assertEq(usds.balanceOf(address(buffer)), 0);
            _snapshot(day);
        }
        assertApproxEqAbs(totals.gain, 1_631_729.312219144086e18, 0.01e18);
        console2.log("OBEX_SIM_END", name);
    }

    function _snapshot(uint256 day) internal view {
        console2.log("day", day);
        console2.log("block", block.number);
        console2.log("debt", tally.debt());
        console2.log("sub", usds.balanceOf(SUB));
        console2.log("float", usds.balanceOf(address(till)));
        console2.log("gain", totals.gain);
        console2.log("fee", totals.fee);
        console2.log("agent", totals.agent);
        console2.log("drew", totals.drew);
        console2.log("paid", totals.paid);
        console2.log("kept", totals.kept);
        console2.log("owe", tally.owe());
        console2.log("sde", tally.sde());
        console2.log("sin", tally.sin());
        console2.log("gap", tally.gap());
        console2.log("legacy_debt", totals.legacyDebt);
        console2.log("legacy_send", totals.legacySend);
    }
}
