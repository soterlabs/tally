// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { Test } from "forge-std/Test.sol";
import { PipLike } from "../src/pips/Pip.sol";
import { RawPip } from "../src/pips/RawPip.sol";
import { Erc4626Pip } from "../src/pips/Erc4626Pip.sol";
import { Erc7540Pip } from "../src/pips/Erc7540Pip.sol";
import { ATokenPip } from "../src/pips/ATokenPip.sol";
import { CapitalPip } from "../src/pips/CapitalPip.sol";
import { MockToken, MockVault, MockAsyncVault, MockAToken, MockPool } from "./Tally.t.sol";

/// Reusable conformance checks for adapters with a par, empty initial fixture.
/// A new adapter supplies _fund in whole wad amounts (6-decimal resolution).
/// Protocol-specific price moves, queues, fees and freshness need separate tests.
abstract contract PipConformance is Test {
    address constant WHO = address(0xA1);
    PipLike pip;
    function _fund(address who, uint256 wad) internal virtual;

    function test_empty_holder_has_no_value() public view {
        (uint256 pie,, uint256 own) = pip.peek(WHO);
        assertEq(pie, 0); assertEq(own, 0);
    }

    function testFuzz_normalized_value(uint64 raw) public {
        uint256 wad = uint256(raw) * 1e12;
        _fund(WHO, wad);
        (uint256 pie, uint256 chi, uint256 own) = pip.peek(WHO);
        assertEq(pie * chi / 1e27 + own, wad);
        (pie,, own) = pip.peek(address(0xB1));
        assertEq(pie, 0); assertEq(own, 0);
    }

    function test_deposit_is_a_flow_not_an_index_gain() public {
        _fund(WHO, 100e18);
        (uint256 pie0, uint256 chi0, uint256 own0) = pip.peek(WHO);
        _fund(WHO, 50e18);
        (uint256 pie1, uint256 chi1, uint256 own1) = pip.peek(WHO);
        assertEq(chi1, chi0);
        assertEq((pie1 - pie0) * chi1 / 1e27 + own1 - own0, 50e18);
    }
}

contract RawPipConformanceTest is PipConformance {
    MockToken token;
    function setUp() public {
        token = new MockToken(6);
        pip = PipLike(address(new RawPip(address(token))));
    }
    function _fund(address who, uint256 wad) internal override { token.mint(who, wad / 1e12); }
}

contract Erc4626PipConformanceTest is PipConformance {
    MockVault vault;
    function setUp() public {
        MockToken token = new MockToken(6);
        vault = new MockVault(address(token), 6, 1e6);
        pip = PipLike(address(new Erc4626Pip(address(vault))));
    }
    function _fund(address who, uint256 wad) internal override { vault.mint(who, wad / 1e12); }
}

contract Erc7540PipConformanceTest is PipConformance {
    MockAsyncVault vault;
    function setUp() public {
        MockToken token = new MockToken(6);
        vault = new MockAsyncVault(address(token), 6, 1e6);
        pip = PipLike(address(new Erc7540Pip(address(vault))));
    }
    function _fund(address who, uint256 wad) internal override { vault.shareToken().mint(who, wad / 1e12); }
}

contract ATokenPipConformanceTest is PipConformance {
    MockAToken token;
    function setUp() public {
        MockPool pool = new MockPool(); pool.set(1e27);
        token = new MockAToken(address(pool), address(new MockToken(6)), 6);
        pip = PipLike(address(new ATokenPip(address(token))));
    }
    function _fund(address who, uint256 wad) internal override { token.mint(who, wad / 1e12); }
}

contract CapitalPipConformanceTest is PipConformance {
    MockToken token;
    function setUp() public {
        token = new MockToken(6);
        pip = PipLike(address(new CapitalPip(address(token))));
    }
    function _fund(address who, uint256 wad) internal override {
        CapitalPip(address(pip)).deal(who, int256(wad));
        token.mint(who, wad / 1e12);
    }
}
