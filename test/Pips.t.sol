// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { Test } from "forge-std/Test.sol";
import { ChroniclePip, LendingIdlePip, CurveLegPip, CapitalPip } from "../src/Pips.sol";
import { MockToken, MockVault, MockAToken, MockPool } from "./Tally.t.sol";

contract MockChronicle {
    uint256 public price; mapping (address => bool) public tolled;
    constructor(uint256 p) { price = p; }
    function kiss(address who) external { tolled[who] = true; }
    function set(uint256 p) external { price = p; }
    function read() external view returns (uint256) { require(tolled[msg.sender], "Toll/not-tolled"); return price; }
}

contract MockCurve is MockToken {
    address[2] public coin; uint256[2] public bal;
    constructor(address c0, address c1) MockToken(18) { coin = [c0, c1]; }
    function set(uint256 b0, uint256 b1, uint256 supply) external { bal = [b0, b1]; totalSupply = supply; }
    uint256 public totalSupply;
    function coins(uint256 i) external view returns (address) { return coin[i]; }
    function balances(uint256 i) external view returns (uint256) { return bal[i]; }
}

contract MockATokenSupply is MockAToken {
    uint256 public totalSupply;
    constructor(address pool, address asset, uint8 dec) MockAToken(pool, asset, dec) {}
    function setSupply(uint256 s) external { totalSupply = s; }
}

contract PipsTest is Test {
    uint256 constant RAY = 1e27;
    address alm = address(0xA1);

    function test_chronicle_pip_needs_kiss() public {
        MockToken stac = new MockToken(6);
        MockChronicle oracle = new MockChronicle(1030.699938e18);
        ChroniclePip pip = new ChroniclePip(address(stac), address(oracle));
        stac.mint(alm, 100_000e6);
        vm.expectRevert("Toll/not-tolled");
        pip.peek(alm);
        oracle.kiss(address(pip));
        (uint256 pie, uint256 chi,) = pip.peek(alm);
        assertEq(pie, 100_000e18);
        assertEq(pie * chi / RAY, 103_069_993.8e18);
    }

    function test_lending_idle_pip_is_pro_rata_unborrowed() public {
        MockToken usds = new MockToken(18);
        MockPool pool = new MockPool();
        MockATokenSupply sp = new MockATokenSupply(address(pool), address(usds), 18);
        // Osero, Aug 1: 1.0005M of 752.35M supply; 286.10M USDS unborrowed in the pool.
        sp.mint(alm, 1_000_481.888993e18); sp.setSupply(752_353_352.361813e18);
        usds.mint(address(sp), 286_099_692.643701e18);
        LendingIdlePip pip = new LendingIdlePip(address(sp));
        (uint256 pie, uint256 chi,) = pip.peek(alm);
        assertEq(chi, RAY);
        assertApproxEqAbs(pie, 380_456e18, 5e18);   // pipeline: utilized 619,543.72 of 1,000,000
    }

    function test_curve_leg_pips() public {
        MockToken usdc = new MockToken(6); MockToken ausd = new MockToken(6);
        MockCurve pool = new MockCurve(address(usdc), address(ausd));
        pool.set(152_592_396, 149_134_767, 301.547852644914548578e18);   // Grove E11, Aug 31 (pool nearly drained)
        pool.mint(alm, 100e18);
        CurveLegPip p0 = new CurveLegPip(address(pool), address(pool), 0, address(0));
        CurveLegPip p1 = new CurveLegPip(address(pool), address(pool), 1, address(0));
        (uint256 pie0,,) = p0.peek(alm);
        (uint256 pie1,,) = p1.peek(alm);
        // 100 / 301.5479 of each reserve
        assertApproxEqAbs(pie0, 50.6031e18, 1e14);
        assertApproxEqAbs(pie1, 49.4565e18, 1e14);
    }

    function test_curve_yield_leg_prices_through_vault() public {
        MockToken usds = new MockToken(18);
        MockVault susds = new MockVault(address(usds), 18, 1.05e18);
        MockToken usdt = new MockToken(6);
        MockCurve pool = new MockCurve(address(susds), address(usdt));
        pool.set(1_000e18, 1_000e6, 2_000e18);
        pool.mint(alm, 1_000e18);
        CurveLegPip leg = new CurveLegPip(address(pool), address(pool), 0, address(susds));
        (uint256 pie, uint256 chi,) = leg.peek(alm);
        assertEq(pie, 500e18);
        assertEq(chi, 1.05e27);
    }

    function test_capital_pip_declared_flows_are_not_yield() public {
        MockToken buidl = new MockToken(6);
        CapitalPip pip = new CapitalPip(address(buidl));

        // Nothing declared, nothing held.
        (uint256 pie, uint256 chi, uint256 own) = pip.peek(alm);
        assertEq(pie, 0); assertEq(chi, RAY); assertEq(own, 0);

        // Deposit 700M, declared before the transfer: pie 700M at par.
        pip.deal(alm, 700_000_000e18);
        buidl.mint(alm, 700_000_000e6);
        (pie, chi,) = pip.peek(alm);
        assertEq(pie, 700_000_000e18); assertEq(chi, RAY);

        // Dividend of 2.1M arrives as new tokens: pie unchanged, chi up -> yield.
        buidl.mint(alm, 2_100_000e6);
        (pie, chi,) = pip.peek(alm);
        assertEq(pie, 700_000_000e18);
        assertEq(pie * chi / RAY, 702_100_000e18);

        // Redeem 75M, declared first: chi unchanged, no phantom PnL.
        uint256 before = chi;
        pip.deal(alm, -75_000_000e18);
        buidl.slash(alm, 75_000_000e6);
        (pie, chi,) = pip.peek(alm);
        assertApproxEqAbs(chi, before, 1e9);
        assertApproxEqAbs(pie * chi / RAY, 627_100_000e18, 1e6);

        // Deposit again at the higher index: still no PnL.
        pip.deal(alm, 100_000_000e18);
        buidl.mint(alm, 100_000_000e6);
        (, chi,) = pip.peek(alm);
        assertApproxEqAbs(chi, before, 1e9);

        // An undeclared arrival with nothing declared is yield-to-date at par.
        CapitalPip fresh = new CapitalPip(address(buidl));
        buidl.mint(address(0xB2), 5e6);
        (pie, chi, own) = fresh.peek(address(0xB2));
        assertEq(pie, 0); assertEq(own, 5e18);
    }

    function test_capital_pip_auth() public {
        CapitalPip pip = new CapitalPip(address(new MockToken(6)));
        vm.prank(address(0xDEAD));
        vm.expectRevert("CapitalPip/not-authorized");
        pip.deal(alm, 1);
    }
}
