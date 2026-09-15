// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;
import { Test } from "forge-std/Test.sol";
import { Tally } from "../src/Tally.sol";
import { CapitalPip, RawPip, UniV3Pip, Erc7540Pip } from "../src/Pips.sol";
import { MockToken, MockSusds, MockVat, MockAsyncVault } from "./Tally.t.sol";

contract ReviewBrokenPip {
    bool public broken;

    function breakRead() external {
        broken = true;
    }

    function peek(address) external view returns (uint256, uint256, uint256) {
        require(!broken, "feed-down");
        return (100e18, 1e27, 0);
    }
}

contract ReviewPool {
    address public token0;
    address public token1;

    constructor(
        address a,
        address b
    ) {
        token0 = a;
        token1 = b;
    }

    function fee() external pure returns (uint24) {
        return 100;
    }

    function slot0() external pure returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (uint160(2 ** 96), 0, 0, 0, 0, 0, true);
    }

    function feeGrowthGlobal0X128() external pure returns (uint256) {
        return 0;
    }

    function feeGrowthGlobal1X128() external pure returns (uint256) {
        return 0;
    }

    function ticks(
        int24
    ) external pure returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool) {
        return (0, 0, 0, 0, 0, 0, 0, false);
    }
}

contract ReviewNpm {
    address public a;
    address public b;
    uint128 public liquidity = 250012499687515624;
    uint128 public owed;
    uint256 public count = 1;
    int24 public lower = -1;
    int24 public upper = 1;

    function setRange(int24 lo, int24 hi) external {
        lower = lo;
        upper = hi;
    }

    function setCount(uint256 n) external {
        count = n;
    }

    constructor(
        address a_,
        address b_
    ) {
        a = a_;
        b = b_;
    }

    function setOwed(uint128 n) external {
        owed = n;
    }

    function setLiquidity(uint128 n) external {
        liquidity = n;
    }

    function doubleLiquidity() external {
        liquidity *= 2;
    }

    function balanceOf(address) external view returns (uint256) {
        return count;
    }

    function tokenOfOwnerByIndex(address, uint256) external pure returns (uint256) {
        return 0;
    }

    function positions(
        uint256
    )
        external
        view
        returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128)
    {
        return (0, address(0), a, b, 100, lower, upper, liquidity, 0, 0, owed, 0);
    }
}

/// Integrated accounting regressions from the external-release review.
contract LifecycleTest is Test {
    address constant ALM = address(0xA1);
    Tally t;
    MockToken token;

    function setUp() public {
        vm.warp(100);
        token = new MockToken(6);
        MockToken usds = new MockToken(18);
        MockSusds susds = new MockSusds(address(usds), 1e27, 1e27);
        MockVat vat = new MockVat();
        vat.set("TEST", 0, 1e27);
        t = new Tally("TEST", address(vat), address(usds), address(susds));
        t.file("alm", ALM);
        t.file("sub", address(0xB1));
    }

    function test_full_capital_exit_preserves_earned_yield() public {
        token.mint(ALM, 100e6);
        CapitalPip pip = new CapitalPip(address(token));
        pip.deal(ALM, 100e18);
        t.init(address(token), address(pip), t.MTM());
        token.mint(ALM, 10e6);
        t.poke();
        assertEq(t.gain(), 10e18);
        t.drip();
        t.poke();
        pip.deal(ALM, -110e18);
        token.slash(ALM, 110e6);
        t.drip();
        t.poke();
        assertEq(t.gain(), 10e18);
        pip.deal(ALM, 220e18);
        token.mint(ALM, 220e6);
        t.poke();
        assertApproxEqAbs(t.gain(), 10e18, 1);
        token.mint(ALM, 22e6);
        t.poke();
        assertApproxEqAbs(t.gain(), 32e18, 1);
    }

    function test_broken_pip_recovery_preserves_unresolved_value() public {
        ReviewBrokenPip bad = new ReviewBrokenPip();
        address key = address(0xC1);
        t.init(key, address(bad), t.SDE());
        vm.warp(block.timestamp + 1 days);
        bad.breakRead();
        vm.expectRevert("feed-down");
        t.drip();
        t.halt(key);
        t.poke();
        (,,,,, uint256 markedAt,,,) = t.gems(key);
        assertEq(markedAt, 100);
        assertEq(t.nav(), 100e18); // explicit frozen NAV
        vm.expectRevert("Tally/stopped");
        t.settle();
        token.mint(ALM, 80e6);
        t.mend(key, address(new RawPip(address(token))), "replace-feed");
        assertEq(t.stops(), 0);
        assertEq(t.nav(), 80e18);
        assertEq(t.gap(), -20e18);
        assertEq(t.sde(), 0);
        assertEq(t.gain(), 0);
        assertEq(t.rebate(), 0); // no invented rebate during outage
        t.sort(-20e18, t.SDE());
        assertEq(t.gap(), 0);
        assertEq(t.sde(), -20e18);
        t.poke();
        assertEq(t.sde(), -20e18);
    }

    function test_capital_loss_exit_and_zero_value_recapitalization() public {
        CapitalPip pip = new CapitalPip(address(token));
        pip.deal(ALM, 100e18);
        token.mint(ALM, 100e6);
        t.init(address(token), address(pip), t.SDE());
        token.slash(ALM, 20e6);
        t.poke();
        pip.deal(ALM, -80e18);
        token.slash(ALM, 80e6);
        t.poke();
        assertEq(t.sde(), -20e18);
        pip.deal(ALM, 80e18);
        token.mint(ALM, 80e6);
        t.poke();
        assertEq(t.sde(), -20e18);
        token.slash(ALM, 80e6);
        t.poke();
        assertEq(t.sde(), -100e18);
        vm.expectRevert("CapitalPip/zero-index");
        pip.deal(ALM, 50e18);
        // Wiped-out shares need a new share series. Mark the total loss first,
        // then replace at the existing fresh configuration boundary.
        CapitalPip fresh = new CapitalPip(address(token));
        t.file(address(token), "pip", address(fresh));
        fresh.deal(ALM, 50e18);
        token.mint(ALM, 50e6);
        t.poke();
        assertEq(t.sde(), -100e18);
        token.mint(ALM, 5e6);
        t.poke();
        assertEq(t.sde(), -95e18);
    }

    function _uni() internal returns (ReviewNpm npm, UniV3Pip pip) {
        MockToken other = new MockToken(6);
        ReviewPool pool = new ReviewPool(address(token), address(other));
        npm = new ReviewNpm(address(token), address(other));
        pip = new UniV3Pip(address(npm), address(pool));
        t.init(address(0xD1), address(pip), t.MTM());
        t.init(address(token), address(new RawPip(address(token))), t.MTM());
    }

    function test_collect_reinvest_and_full_exit_conserve_cash_and_pnl() public {
        (ReviewNpm npm,) = _uni();
        uint256 principal = t.nav();
        npm.setOwed(100e6);
        t.poke();
        uint256 earned = t.nav() - principal;
        int256 profit = t.gain();
        assertApproxEqAbs(profit, 100e18, 1e12);
        npm.setOwed(0);
        token.mint(ALM, 100e6);
        t.sync(address(0xD1), "collect");
        t.poke();
        assertApproxEqAbs(t.nav(), principal + earned, 1e12);
        assertEq(t.gain(), profit);
        assertApproxEqAbs(t.flux(), 0, 1e12);
        // Reinvest the collected cash at the same price.
        uint128 initial = npm.liquidity();
        npm.setLiquidity(initial + uint128(uint256(initial) * 100e18 / principal));
        token.slash(ALM, 100e6);
        t.sync(address(0xD1), "reinvest");
        t.poke();
        assertApproxEqAbs(t.nav(), principal + 100e18, 3e12);
        assertEq(t.gain(), profit);
        // More capital changes notional; it must not dilute past fees.
        npm.doubleLiquidity();
        t.sync(address(0xD1), "add-capital");
        t.poke();
        assertEq(t.gain(), profit);
        uint256 liveValue = t.nav();
        npm.setLiquidity(0);
        token.mint(ALM, liveValue / 1e12);
        t.sync(address(0xD1), "exit");
        t.poke();
        assertApproxEqAbs(t.nav(), liveValue, 1e12);
        assertEq(t.gain(), profit);
        npm.setLiquidity(initial);
        token.slash(ALM, principal / 1e12);
        t.sync(address(0xD1), "reenter");
        t.poke();
        assertEq(t.gain(), profit);
    }

    function test_lp_range_change_is_an_explicit_flow_boundary() public {
        (ReviewNpm npm,) = _uni();
        npm.setOwed(100e6);
        t.poke();
        int256 profit = t.gain();
        npm.setRange(-2, 2);
        t.sync(address(0xD1), "range");
        t.poke();
        assertEq(t.gain(), profit);
        npm.setOwed(110e6);
        t.poke();
        assertApproxEqAbs(t.gain() - profit, 10e18, 1e12);
        npm.setCount(33);
        vm.expectRevert("UniV3Pip/too-many-nfts");
        t.poke();
        t.halt(address(0xD1));
        vm.expectRevert("Tally/stopped");
        t.settle();
    }

    function test_sync_requires_fresh_authorized_unique_reference() public {
        _uni();
        vm.prank(address(0xBAD));
        vm.expectRevert("Tally/not-authorized");
        t.sync(address(0xD1), "x");
        vm.warp(block.timestamp + 1);
        t.drip();
        vm.expectRevert("Tally/rho-not-updated");
        t.sync(address(0xD1), "x");
        t.poke();
        t.sync(address(0xD1), "x");
        vm.expectRevert("Tally/bad-reference");
        t.sync(address(0xD1), "x");
    }

    function test_async_deposit_redeem_and_fixed_claim_lifecycle() public {
        MockAsyncVault vault = new MockAsyncVault(address(token), 6, 1e6);
        Erc7540Pip pip = new Erc7540Pip(address(vault));
        t.init(address(vault), address(pip), t.MTM());
        t.init(address(token), address(new RawPip(address(token))), t.MTM());
        token.mint(ALM, 100e6);
        t.poke();
        token.slash(ALM, 100e6);
        vault.setQueues(0, 100e6, 0, 0);
        t.poke();
        assertEq(t.nav(), 100e18);
        assertEq(t.gain(), 0);
        vault.setQueues(0, 0, 100e6, 0);
        t.poke();
        assertEq(t.nav(), 100e18);
        assertEq(t.gain(), 0);
        vault.setQueues(0, 0, 0, 0);
        vault.shareToken().mint(ALM, 100e6);
        t.poke();
        vault.setPps(1.1e6);
        t.poke();
        assertEq(t.gain(), 10e18);
        vault.shareToken().slash(ALM, 100e6);
        vault.setQueues(100e6, 0, 0, 0);
        t.poke();
        assertEq(t.nav(), 110e18);
        // Fulfillment fixes the claim at the observed price. Later price moves
        // cannot earn income on shares that are no longer floating.
        vault.setQueues(0, 0, 0, 110e6);
        t.poke();
        vault.setPps(0.9e6);
        t.poke();
        assertEq(t.nav(), 110e18);
        assertEq(t.gain(), 10e18);
        vault.setQueues(0, 0, 0, 0);
        token.mint(ALM, 110e6);
        t.poke();
        assertEq(t.nav(), 110e18);
        assertEq(t.gain(), 10e18);
        assertEq(t.flux(), 100e18); // only the original external funding
    }

    function test_mixed_decimal_lp_is_rejected() public {
        ReviewPool pool = new ReviewPool(address(token), address(new MockToken(18)));
        vm.expectRevert("UniV3Pip/mixed-decimals");
        new UniV3Pip(address(1), address(pool));
    }

    function test_recovery_auth_and_multiple_failed_dependencies() public {
        ReviewBrokenPip bad = new ReviewBrokenPip();
        t.init(address(1), address(bad), t.IDL());
        t.init(address(2), address(bad), t.SAV());
        vm.warp(block.timestamp + 1 days);
        bad.breakRead();
        vm.prank(address(0xBAD));
        vm.expectRevert("Tally/not-authorized");
        t.halt(address(1));
        t.halt(address(1));
        t.halt(address(2));
        vm.expectRevert("feed-down");
        t.mend(address(1), address(bad), "bad");
        assertEq(t.stops(), 2);
        assertEq(t.refs("bad"), 0);
        ReviewBrokenPip good = new ReviewBrokenPip();
        t.mend(address(1), address(good), "one");
        vm.expectRevert("Tally/stopped");
        t.settle();
        t.mend(address(2), address(good), "two");
        assertEq(t.stops(), 0);
        assertEq(t.gap(), 0);
    }
}
