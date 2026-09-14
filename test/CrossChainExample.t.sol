// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { Test } from "forge-std/Test.sol";
import { Tally } from "../src/Tally.sol";
import { RawPip, RelayPip } from "../src/Pips.sol";
import { MockToken, MockSusds, MockVat } from "./Tally.t.sol";

/// Synthetic accounting example, NOT historical Grove data or a bridge verifier.
/// A trusted writer supplies coherent remote and in-transit marks. A production
/// receiver must additionally authenticate source chain, block, age and sequence.
contract CrossChainExampleTest is Test {
    uint256 constant RAY = 1e27;
    address constant ALM = address(0xA1);
    address constant REMOTE = address(0xB1);
    address constant TRANSIT = address(0xC1);
    Tally tally;
    MockToken usds;
    RelayPip remote;
    RelayPip transit;

    function setUp() public {
        vm.warp(1);
        usds = new MockToken(18);
        MockSusds susds = new MockSusds(address(usds), RAY, RAY);
        MockVat vat = new MockVat();
        vat.set("GROVE-EXAMPLE", 1_000e18, RAY);
        usds.mint(ALM, 1_000e18);
        tally = new Tally("GROVE-EXAMPLE", address(vat), address(usds), address(susds));
        tally.file("alm", ALM);
        tally.init(address(usds), address(new RawPip(address(usds))), tally.MTM());
        remote = new RelayPip();
        transit = new RelayPip();
        remote.poke(ALM, 0, RAY, 0);
        transit.poke(ALM, 0, RAY, 0);
        tally.init(REMOTE, address(remote), tally.MTM());
        tally.init(TRANSIT, address(transit), tally.MTM());
    }

    function _check(uint256 nav, int256 pnl) internal {
        tally.drip();
        tally.poke();
        assertEq(tally.nav(), nav, "one economic asset, counted once");
        assertEq(tally.gain(), pnl, "capital transfers are not yield");
        assertEq(tally.flux() - tally.capital(), 0, "no unexplained equity movement");
    }

    function test_outbound_yield_return_and_loss() public {
        _check(1_000e18, 0);
        // Ethereum cash -> recoverable bridge claim. A coherent mark batch
        // includes the source debit; the destination must not be added yet.
        usds.slash(ALM, 400e18);
        transit.poke(ALM, 400e18, RAY, 0);
        _check(1_000e18, 0);
        // Finalized destination deposit replaces the in-transit claim.
        transit.poke(ALM, 0, RAY, 0);
        remote.poke(ALM, 400e18, RAY, 0);
        _check(1_000e18, 0);
        // Unchanged shares, higher index: actual remote yield.
        vm.warp(block.timestamp + 1 days);
        remote.poke(ALM, 400e18, 1.05e27, 0);
        transit.poke(ALM, 0, RAY, 0);
        _check(1_020e18, 20e18);
        // Redeem half, returning 210 USDS. Use the current index for shares
        // removed; the claim is principal plus already recognized yield.
        remote.poke(ALM, 200e18, 1.05e27, 0);
        transit.poke(ALM, 210e18, RAY, 0);
        _check(1_020e18, 20e18);
        usds.mint(ALM, 210e18);
        transit.poke(ALM, 0, RAY, 0);
        _check(1_020e18, 20e18);
        // Loss on the remaining remote shares must also reach the books.
        remote.poke(ALM, 200e18, 0.95e27, 0);
        _check(1_000e18, 0);
    }

    function test_stale_remote_mark_blocks_settlement() public {
        vm.warp(block.timestamp + 1 days + 1);
        // Even a zero-balance record must be refreshed: silence is not proof
        // that the destination still has no assets or liabilities.
        transit.poke(ALM, 0, RAY, 0);
        uint256 rho = tally.rho();
        vm.expectRevert("RelayPip/stale");
        tally.settle();
        assertEq(tally.rho(), rho, "failed settlement is atomic");
    }
}
