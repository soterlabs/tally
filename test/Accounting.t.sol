// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { Test } from "forge-std/Test.sol";
import { Tally } from "../src/Tally.sol";
import { Till } from "../src/Till.sol";
import { RawPip } from "../src/pips/RawPip.sol";
import { Erc4626Pip } from "../src/pips/Erc4626Pip.sol";
import { RelayPip } from "../src/pips/RelayPip.sol";
import { MockToken, MockVault, MockSusds, MockVat, MockJoin, MockAllocatorVault, MockBuffer } from "./Tally.t.sol";

contract AccountingTest is Test {
    uint256 constant RAY = 1e27;
    bytes32 constant ILK = "ALLOCATOR-TEST-A";
    address constant ALM = address(0xA1);
    address constant SUB = address(0x51);
    MockToken usds;
    MockSusds susds;
    MockVat vat;
    MockJoin join;
    MockAllocatorVault vault;
    MockBuffer buffer;
    Tally tally;
    Till till;

    function setUp() public {
        vm.warp(1_757_000_000);
        usds = new MockToken(18);
        susds = new MockSusds(address(usds), 1000000001096988989836188434, 1e18);
        vat = new MockVat();
        vat.set(ILK, 0, RAY);
        join = new MockJoin(address(usds));
        buffer = new MockBuffer();
        vault = new MockAllocatorVault(address(vat), address(join), ILK, address(buffer));
        tally = new Tally(ILK, address(vat), address(usds), address(susds));
        till = new Till(address(tally), address(0xB0), address(join), address(usds));
        vault.rely(address(till));
        buffer.approve(address(usds), address(till), type(uint256).max);
        till.file("vault", address(vault)); till.file("buffer", address(buffer));
        tally.file("alm", ALM); tally.file("sub", SUB); tally.file("till", address(till));
        tally.file("pad", 0.002e27); tally.file("tip", 0.002e27); tally.file("pay", 1);
        tally.init(address(usds), address(new RawPip(address(usds))), tally.MTM());
    }

    function test_post_payment_balance_earns_next_interval() public {
        usds.mint(address(till), 1_000e18);
        tally.gift(1_000e18);
        tally.settle();
        assertEq(tally.usd(), usds.balanceOf(SUB));
        vm.warp(block.timestamp + 1 days);
        tally.drip();
        uint256 growth = susds.convertToAssets(1e18) - 1e18;
        assertApproxEqAbs(tally.owe(), 1_000 * growth + uint256(1_000e18) * 0.002e27 / 365 / RAY, 1_000);
    }

    function test_runtime_fits_deployment_limit() public view {
        assertLe(address(tally).code.length, 24_576);
        assertLe(address(till).code.length, 24_576);
    }

    function test_gas_budget_for_32_simple_positions() public {
        for (uint256 i=1;i<32;i++) {
            MockToken token=new MockToken(18);
            token.mint(ALM,100e18);
            tally.init(address(token),address(new RawPip(address(token))),tally.MTM());
        }
        vm.warp(block.timestamp+1 days);
        uint256 before=gasleft();
        tally.settle();
        assertLt(before-gasleft(),2_000_000);
    }

    function test_actual_draw_rounding_is_not_capital() public {
        vat.set(ILK, 1_000_000_000e18, 1.01e27);
        tally.drip();
        vm.warp(block.timestamp + 1 days);
        tally.settle();
        assertGt(tally.debt(), 1_010_000_000e18);
        assertEq(tally.art(), tally.debt());
        assertEq(tally.capital(), 0);
        tally.drip();
        assertEq(tally.capital(), 0);
    }

    function test_note_keeps_debt_chargeable_without_equity_loss() public {
        vm.warp(block.timestamp + 1 days);
        tally.drip();
        vat.frob(ILK, 2_535_968e18);
        usds.mint(SUB, 916_736e18);
        tally.note("MSC-2026-07");
        assertEq(tally.art(), 2_535_968e18);
        assertEq(tally.usd(), 916_736e18);
        assertEq(tally.capital(), 0);
        tally.settle();
        assertEq(tally.gap(), 0);
        vm.warp(block.timestamp + 1 days);
        tally.drip();
        assertGt(tally.tab(), 250e18);
        assertGt(tally.owe(), 90e18);
    }

    function test_note_requires_auth_freshness_delta_and_unique_reference() public {
        vm.prank(address(0xBAD));
        vm.expectRevert("Tally/not-authorized");
        tally.note("MSC");
        vm.warp(block.timestamp + 1);
        vm.expectRevert("Tally/rho-not-updated");
        tally.note("MSC");
        tally.drip();
        vm.expectRevert("Tally/no-settlement-debt");
        tally.note("MSC");
        vat.frob(ILK, 10e18);
        vm.expectRevert("Tally/bad-reference");
        tally.note(bytes32(0));
        tally.note("MSC");
        vat.frob(ILK, 20e18);
        vm.expectRevert("Tally/bad-reference");
        tally.note("MSC");
        tally.note("MSC-next");
        assertEq(tally.art(), 30e18);
        assertEq(tally.notes("MSC"), 1);
        tally.cage();
        vm.expectRevert("Tally/not-live");
        tally.note("closed");
    }

    function test_note_cannot_reclassify_debt_after_intervening_drip() public {
        vat.frob(ILK, 10e18);
        tally.drip();
        vm.expectRevert("Tally/no-settlement-debt");
        tally.note("MSC");
        assertEq(tally.capital(), 10e18);
    }

    function test_rebate_configuration_needs_drip_even_after_poke() public {
        vm.warp(block.timestamp + 1 days);
        tally.poke();
        uint8 idl = tally.IDL();
        vm.expectRevert("Tally/rho-not-updated"); tally.file(address(usds), "tag", idl);
        vm.expectRevert("Tally/rho-not-updated"); tally.file(address(usds), "cap", 1e18);
        vm.expectRevert("Tally/rho-not-updated"); tally.file(address(usds), "fee", 1);
        vm.expectRevert("Tally/rho-not-updated"); tally.file(address(usds), "who", SUB);
        vm.expectRevert("Tally/rho-not-updated"); tally.file(address(usds), "pip", address(0));
        vm.expectRevert("Tally/rho-not-updated"); tally.file("alm", SUB);
        tally.drip();
        tally.file(address(usds), "tag", idl);
        assertEq(tally.rebate(), 0);
    }

    function test_till_binding_rejects_wrong_books_and_currency() public {
        Tally other = new Tally(ILK, address(vat), address(usds), address(susds));
        Till wrong = new Till(address(other), address(0xB0), address(join), address(usds));
        vm.expectRevert("Tally/wrong-tally"); tally.file("till", address(wrong));
        MockToken currency = new MockToken(18);
        wrong = new Till(address(tally), address(0xB0), address(join), address(currency));
        vm.expectRevert("Tally/wrong-usds"); tally.file("till", address(wrong));
        tally.file("till", address(0));
        tally.file("till", address(till));
    }

    function test_sav_yield_offsets_ssr_borrowing_cost() public {
        vat.frob(ILK, 1_000e18);
        tally.drip();
        susds.mint(ALM, 1_000e18);
        tally.init(address(susds), address(new Erc4626Pip(address(susds))), tally.SAV());
        vm.warp(block.timestamp + 1 days);
        tally.drip(); tally.poke();
        assertGt(tally.gain(), 0);
        assertApproxEqAbs(tally.gain() + int256(tally.rebate()) - int256(tally.tab()), 0, 1_000);
        uint256 was = uint256(tally.gain());
        // Declared transfer at unchanged index changes shares, not revenue.
        susds.mint(ALM, 100e18);
        tally.poke();
        assertEq(uint256(tally.gain()), was);
    }

    function testFuzz_subsidy_on_net_utilized(uint96 debt_, uint96 idle_, uint96 cap_) public {
        uint256 debt = bound(uint256(debt_), 1e18, 1_000_000_000e18);
        uint256 idle = bound(uint256(idle_), 0, 2_000_000_000e18);
        uint256 cap = bound(uint256(cap_), 0, 1_000_000_000e18);
        vat.frob(ILK, debt); tally.drip();
        tally.file("cut", 0.03e27); tally.file("line", cap);
        RelayPip pip = new RelayPip();
        pip.poke(ALM, idle, RAY, 0);
        tally.init(address(pip), address(pip), tally.IDL());
        uint256 old = tally.chi();
        vm.warp(block.timestamp + 1 days);
        pip.poke(ALM, idle, RAY, 0);
        tally.drip();
        uint256 br = susds.convertToAssets(1e18) * RAY / old - RAY + (0.002e27 / uint256(365 days)) * 1 days;
        uint256 net = idle > debt ? 0 : debt - idle;
        uint256 lo = net < cap ? net : cap;
        uint256 expected = lo * ((0.03e27 / uint256(365 days)) * 1 days) / RAY + (net - lo) * br / RAY;
        assertEq(tally.tab() - tally.rebate(), expected);
    }

    function test_subsidy_deductions_cross_cap() public {
        // 120M gross, 40M idle, 100M subsidized: ALL 80M utilized pays cut.
        vat.frob(ILK, 120_000_000e18); tally.drip();
        tally.file("line", 100_000_000e18); tally.file("cut", 0.03e27);
        RelayPip pip = new RelayPip();
        pip.poke(ALM, 40_000_000e18, RAY, 0);
        tally.init(address(pip), address(pip), tally.IDL());
        vm.warp(block.timestamp + 1 days);
        pip.poke(ALM, 40_000_000e18, RAY, 0);
        tally.drip();
        assertApproxEqAbs(tally.tab() - tally.rebate(), uint256(80_000_000e18) * 3 / 100 / 365, 1e8);
    }

    function test_rebate_poke_cannot_replace_unaccrued_sample() public {
        RelayPip pip = new RelayPip();
        pip.poke(ALM, 1_000e18, RAY, 0);
        tally.init(address(pip), address(pip), tally.IDL());
        vat.frob(ILK, 10_000e18); tally.drip();
        vm.warp(block.timestamp + 1 days);
        pip.poke(ALM, 10_000e18, RAY, 0);
        vm.expectRevert("Tally/rho-not-updated"); tally.poke(address(pip));
        tally.drip();
        assertApproxEqAbs(tally.rebate(), tally.tab() / 10, 1);
        tally.poke(address(pip));
    }

    struct Ledger {
        int256 gain;
        uint256 fee;
        uint256 agent;
        uint256 drew;
        uint256 paid;
        uint256 legacy;
    }

    function testFuzz_conservation_across_settlements(uint256 seed) public {
        MockVault position = new MockVault(address(usds), 18, 1e18);
        tally.init(address(position), address(new Erc4626Pip(address(position))), tally.MTM());
        vat.frob(ILK, 1_000_000e18);
        usds.mint(ALM, 1_000_000e18);
        tally.drip(); tally.poke();
        usds.slash(ALM, 1_000_000e18);
        position.mint(ALM, 1_000_000e18);
        tally.poke();
        usds.mint(address(till), 1_000e18);
        Ledger memory l;
        for (uint256 i = 0; i < 12; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 carry = tally.owe();
            vm.warp(block.timestamp + 1 days);
            tally.drip();
            if (i == 5) {
                vat.frob(ILK, 1_000e18);
                tally.note("legacy-cycle");
                l.legacy += 1_000e18;
            }
            // Price losses/recoveries and changing debt headroom exercise sin,
            // sde and owe together, rather than only profitable settlements.
            position.setPps((950_000 + seed % 250_001) * 1e12);
            tally.poke();
            tally.gift((seed % 7) * 1e18);
            vat.setLine(ILK, i % 3 == 0 ? tally.debt() * RAY : type(uint256).max / 2);
            l.gain += tally.gain(); l.fee += tally.tab(); l.agent += tally.owe() - carry;
            uint256 before = tally.debt();
            uint256 sub = usds.balanceOf(SUB);
            tally.settle();
            l.drew += tally.debt() - before;
            l.paid += usds.balanceOf(SUB) - sub;
            assertEq(tally.debt(), 1_000_000e18 + l.legacy + l.drew);
            assertEq(1_000e18 + l.drew, l.paid + join.credited(address(0xB0)) / RAY + usds.balanceOf(address(till)));
            assertEq(l.gain, int256(l.drew) + tally.sde() - int256(tally.sin()));
            assertEq(l.gain + int256(l.agent) - int256(l.fee), int256(l.paid + tally.owe()) - int256(tally.sin()));
            assertEq(tally.gap(), 0);
            assertEq(tally.capital(), 0);
        }
    }
}
