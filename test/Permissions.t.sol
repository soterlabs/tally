// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { ForkBase } from "./Backtest.t.sol";
import { Tally } from "../src/Tally.sol";
import { Till } from "../src/Till.sol";

interface LiveVault {
    function ilk() external view returns (bytes32);
    function buffer() external view returns (address);
    function wards(address) external view returns (uint256);
    function roles() external view returns (address);
}

interface LiveRoles {
    function ilkAdmins(bytes32) external view returns (address);
    function setRoleAction(bytes32, uint8, address, bytes4, bool) external;
    function setUserRole(bytes32, address, uint8, bool) external;
}

interface LiveBuffer {
    function wards(address) external view returns (uint256);
    function approve(address, address, uint256) external;
}

interface LiveVat {
    function wards(address) external view returns (uint256);
    function dai(address) external view returns (uint256);
}

interface LiveToken {
    function balanceOf(address) external view returns (uint256);
}

/// A permission rehearsal on existing allocator contracts, only on a local fork.
/// No storage edits, mocks, debt-ceiling changes or live-network transactions.
contract PermissionsForkTest is ForkBase {
    address constant VAULT = 0xf739a30c74927dc6cFA3B67E4933872a1FC5F4EB;

    function test_allocator_roles_draw_pay_join_and_revoke() public {
        rpc = vm.envString("ETH_RPC");
        _fork(0);
        LiveVault vault = LiveVault(VAULT);
        bytes32 ilk = vault.ilk();
        address buffer = vault.buffer();
        address sub = address(0xBEEF);
        Tally t = new Tally(ilk, VAT, USDS, SUSDS);
        Till till = new Till(address(t), VOW, USDS_JOIN, USDS);
        t.file("alm", address(0xA1));
        t.file("sub", sub);
        t.file("till", address(till));
        till.file("vault", VAULT);
        till.file("buffer", buffer);
        assertGe(t.room(), 150e18);
        // Model approved accrued income. No position valuation is asserted here.
        t.sort(100e18, t.MTM());
        t.sort(50e18, t.SDE());
        vm.expectRevert("AllocatorVault/not-authorized");
        t.settle();
        LiveRoles roles = LiveRoles(vault.roles());
        vm.startPrank(roles.ilkAdmins(ilk));
        roles.setRoleAction(ilk, 255, VAULT, bytes4(keccak256("draw(uint256)")), true);
        roles.setUserRole(ilk, address(till), 255, true);
        vm.stopPrank();
        // The vault permission alone must not grant access to its buffer.
        vm.expectRevert();
        t.settle();
        address admin = roles.ilkAdmins(ilk);
        assertEq(LiveBuffer(buffer).wards(admin), 1);
        vm.prank(admin);
        LiveBuffer(buffer).approve(USDS, address(till), type(uint256).max);
        uint256 debtBefore = t.debt();
        uint256 surplusBefore = LiveVat(VAT).dai(VOW);
        uint256 bufferBefore = LiveToken(USDS).balanceOf(buffer);
        uint256 gasBefore = gasleft();
        t.settle();
        assertLt(gasBefore - gasleft(), 1_000_000);
        assertApproxEqAbs(t.debt() - debtBefore, 150e18, 1);
        assertEq(LiveToken(USDS).balanceOf(sub), 100e18);
        assertEq(LiveVat(VAT).dai(VOW) - surplusBefore, 50e18 * 1e27);
        assertEq(LiveToken(USDS).balanceOf(buffer), bufferBefore);
        assertEq(LiveToken(USDS).balanceOf(address(till)), 0);
        assertEq(t.capital(), 0);
        assertEq(LiveVat(VAT).wards(address(t)), 0);
        assertEq(LiveVat(VAT).wards(address(till)), 0);
        assertEq(vault.wards(address(till)), 0); // draw capability, not a vault ward
        vm.prank(roles.ilkAdmins(ilk));
        roles.setUserRole(ilk, address(till), 255, false);
        t.sort(1e18, t.MTM());
        vm.expectRevert("AllocatorVault/not-authorized");
        t.settle();
    }
}
