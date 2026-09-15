// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { Test } from "forge-std/Test.sol";
import { Cash } from "../src/Cash.sol";
import { Tally } from "../src/Tally.sol";
import { RawPip, Erc4626Pip } from "../src/Pips.sol";
import { MockToken, MockSusds, MockVat, MockVault } from "./Tally.t.sol";

contract CashTest is Test {
    Tally tally;
    Cash cash;
    MockToken usds;
    MockVault vault;
    address constant ALM = address(0xA1);

    function setUp() public {
        vm.warp(1);
        usds = new MockToken(18);
        MockSusds susds = new MockSusds(address(usds), 1e27, 1e27);
        MockVat vat = new MockVat();
        vat.set("CASH-EXAMPLE", 0, 1e27);
        tally = new Tally("CASH-EXAMPLE", address(vat), address(usds), address(susds));
        tally.file("alm", ALM);
        tally.file("sub", address(0xB1));
        tally.init(address(usds), address(new RawPip(address(usds))), tally.MTM());
        vault = new MockVault(address(usds), 18, 1e18);
        vault.mint(ALM, 100e18);
        tally.init(address(vault), address(new Erc4626Pip(address(vault))), tally.MTM());
        cash = new Cash(address(tally));
        tally.rely(address(cash));
    }

    function test_cash_credit_preserves_nav_and_counts_once_after_reinvestment() public {
        usds.mint(ALM, 20e18); // observed payer receipt
        tally.poke();
        uint256 nav = tally.nav();
        cash.note(bytes32("receipt"), 7, 20e18);
        assertEq(tally.nav(), nav);
        assertEq(tally.gain(), 20e18);
        assertEq(tally.gap() + tally.flux() - tally.capital(), 0);
        assertEq(tally.owe(), 0); // not gift/demand income
        // Moving received cash into another registered position is capital.
        usds.slash(ALM, 20e18);
        vault.mint(ALM, 20e18);
        tally.poke();
        assertEq(tally.nav(), nav);
        assertEq(tally.gain(), 20e18);
        tally.settle();
        assertEq(tally.owe(), 20e18); // no Till: unpaid supply proceeds carry
        assertEq(tally.gap(), 0);
        vm.expectRevert("Cash/already-noted");
        cash.note(bytes32("receipt"), 7, 21e18); // changing amount cannot bypass reference
        assertEq(tally.owe(), 20e18);
    }

    function test_returned_principal_is_not_automatically_income() public {
        // Redemption returns capital from an already tracked claim to cash.
        vault.slash(ALM, 50e18);
        usds.mint(ALM, 50e18);
        tally.poke();
        assertEq(tally.nav(), 100e18);
        assertEq(tally.gain(), 0);
        assertEq(tally.flux(), 0);
        // Only a separately classified distribution receives a note.
        usds.mint(ALM, 7e18);
        tally.poke();
        cash.note(bytes32("distribution"), 3, 7e18);
        assertEq(tally.nav(), 107e18);
        assertEq(tally.gain(), 7e18);
        assertEq(tally.gap() + tally.flux() - tally.capital(), 0);
    }

    function test_cash_income_offsets_supply_loss_before_payment() public {
        vault.setPps(0.9e18);
        tally.settle();
        assertEq(tally.sin(), 10e18);
        usds.mint(ALM, 6e18);
        tally.poke();
        cash.note(bytes32("one"), 0, 6e18);
        tally.settle();
        assertEq(tally.sin(), 4e18);
        assertEq(tally.owe(), 0);
        usds.mint(ALM, 6e18);
        tally.poke();
        cash.note(bytes32("two"), 0, 6e18);
        tally.settle();
        assertEq(tally.sin(), 0);
        assertEq(tally.owe(), 2e18);
        assertEq(tally.gap(), 0);
    }

    function test_authorization_validation_and_failed_credit_retry() public {
        vm.prank(address(0xBAD));
        vm.expectRevert("Cash/not-authorized");
        cash.note(bytes32("receipt"), 1, 1e18);
        vm.expectRevert("Cash/zero-txid");
        cash.note(bytes32(0), 1, 1e18);
        vm.expectRevert("Cash/bad-amount");
        cash.note(bytes32("receipt"), 1, 0);
        vm.expectRevert("Cash/bad-amount");
        cash.note(bytes32("receipt"), 1, uint256(type(int256).max) + 1);
        tally.deny(address(cash));
        vm.expectRevert("Tally/not-authorized");
        cash.note(bytes32("receipt"), 1, 1e18);
        tally.rely(address(cash));
        cash.note(bytes32("receipt"), 1, 1e18); // failed call did not consume the key
        tally.cage();
        vm.expectRevert("Tally/not-live");
        cash.note(bytes32("receipt"), 2, 1e18);
    }
}
