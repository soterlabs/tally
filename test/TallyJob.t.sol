// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { Test } from "forge-std/Test.sol";
import { Tally } from "../src/Tally.sol";
import { Till } from "../src/Till.sol";
import { TallyJob } from "../src/TallyJob.sol";
import { RawPip, RelayPip } from "../src/Pips.sol";
import { MockToken, MockSusds, MockVat, MockJoin, MockAllocatorVault, MockBuffer } from "./Tally.t.sol";

contract MockSequencer {
    mapping (bytes32 => bool) public isMaster;
    function set(bytes32 network, bool master) external { isMaster[network] = master; }
}

contract TallyJobTest is Test {
    bytes32 constant NET  = "NTWK-A";
    bytes32 constant ILK1 = "ALLOCATOR-OBEX-A";
    bytes32 constant ILK2 = "ALLOCATOR-PRYSM-A";
    uint256 constant RAY  = 1e27;
    uint256 constant SSR  = 1000000001096988989836188434;

    address vow = address(0xB0);

    MockSequencer seq;
    MockVat vat; MockToken usds; MockSusds susds; MockJoin join;
    Tally t1; Tally t2;
    TallyJob job;

    function _tally(bytes32 ilk, address alm, address sub) internal returns (Tally t) {
        MockBuffer buffer = new MockBuffer();
        MockAllocatorVault vault = new MockAllocatorVault(address(vat), address(join), ilk, address(buffer));
        vat.set(ilk, 1_000_000e18, RAY);
        t = new Tally(ilk, address(vat), address(usds), address(susds));
        Till till = new Till(address(t), vow, address(join), address(usds));
        till.rely(address(t)); vault.rely(address(till));
        buffer.approve(address(usds), address(till), type(uint256).max);
        till.file("vault", address(vault)); till.file("buffer", address(buffer));
        t.file("alm", alm); t.file("sub", sub); t.file("till", address(till));
        t.file("pad", 0.002e27); t.file("tip", 0.002e27); t.file("pay", 1);
        usds.mint(alm, 1_000e18);
        t.init(address(usds), address(new RawPip(address(usds))), t.MTM());
    }

    // The keeper calls `workable` with eth_call, so the trial settle inside it
    // leaves no state behind. Emulate that here.
    function _workable() internal returns (bool ok, bytes memory args) {
        uint256 snap = vm.snapshotState();
        (ok, args) = job.workable(NET);
        vm.revertToState(snap);
    }

    function setUp() public {
        vm.warp(1_757_000_000);
        seq   = new MockSequencer();
        vat   = new MockVat();
        usds  = new MockToken(18);
        susds = new MockSusds(address(usds), SSR, 1.05e18);
        join  = new MockJoin(address(usds));
        t1 = _tally(ILK1, address(0xA1), address(0x51));
        t2 = _tally(ILK2, address(0xA2), address(0x52));
        job = new TallyJob(address(seq));
        job.add(address(t1));
        job.add(address(t2));
        seq.set(NET, true);
    }

    function test_not_master() public {
        seq.set(NET, false);
        (bool ok, bytes memory why) = _workable();
        assertFalse(ok);
        assertEq(string(why), "Network is not master");
        vm.expectRevert(abi.encodeWithSelector(TallyJob.NotMaster.selector, NET));
        job.work(NET, abi.encode(address(t1)));
    }

    function test_due_once_per_utc_day() public {
        // Never settled: due today.
        (bool ok, bytes memory args) = _workable();
        assertTrue(ok);
        assertEq(abi.decode(args, (address)), address(t1));
        job.work(NET, args);
        assertEq(t1.zzz(), block.timestamp);

        // t1 done for today, t2 still due.
        (ok, args) = _workable();
        assertTrue(ok);
        assertEq(abi.decode(args, (address)), address(t2));
        job.work(NET, args);

        (ok, args) = _workable();
        assertFalse(ok);
        assertEq(string(args), "No tally is due");
        vm.expectRevert(TallyJob.ShouldNotTrigger.selector);
        job.work(NET, abi.encode(address(t1)));

        // A relayer drip later today moves rho but not zzz: still not due.
        vm.warp(block.timestamp + 6 hours);
        t1.drip();
        assertFalse(job.due(address(t1)));

        // Next UTC day, one second in: due again, whatever the hour of the last settle.
        vm.warp((block.timestamp / 1 days + 1) * 1 days + 1);
        assertTrue(job.due(address(t1)));
        assertTrue(job.due(address(t2)));
    }

    function test_workable_skips_an_instance_whose_settle_would_revert() public {
        // t1 gets a relayed gem whose mark goes stale.
        RelayPip relay = new RelayPip();
        relay.poke(address(0xA1), 1e18, RAY, 0);
        t1.init(address(0xCAFE), address(relay), t1.IDL());
        vm.warp(block.timestamp + 2 days);

        (bool ok, bytes memory args) = _workable();
        assertTrue(ok);
        assertEq(abi.decode(args, (address)), address(t2));   // t1 skipped, not reported
        job.work(NET, args);

        (ok,) = _workable();
        assertFalse(ok);                                       // t1 still due but unworkable
        assertTrue(job.due(address(t1)));
        vm.expectRevert("RelayPip/stale");
        job.work(NET, abi.encode(address(t1)));

        // Operator re-marks: workable again.
        relay.poke(address(0xA1), 1e18, RAY, 0);
        (ok, args) = _workable();
        assertTrue(ok);
        assertEq(abi.decode(args, (address)), address(t1));
    }

    function test_caged_instance_is_not_due() public {
        t1.cage();
        assertFalse(job.due(address(t1)));
        (bool ok, bytes memory args) = _workable();
        assertTrue(ok);
        assertEq(abi.decode(args, (address)), address(t2));
    }

    function test_add_remove() public {
        job.remove(address(t1));
        assertEq(job.count(), 1);
        assertEq(job.has(address(t1)), 0);
        vm.expectRevert(TallyJob.ShouldNotTrigger.selector);
        job.work(NET, abi.encode(address(t1)));
        vm.expectRevert("TallyJob/not-added");
        job.remove(address(t1));
        job.add(address(t1));
        vm.expectRevert("TallyJob/already-added");
        job.add(address(t1));
        vm.prank(address(0xDEAD));
        vm.expectRevert("TallyJob/not-authorized");
        job.add(address(0x1));
    }
}
