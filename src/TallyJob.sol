// SPDX-License-Identifier: AGPL-3.0-or-later

/// TallyJob.sol -- dss-cron job that settles Tally instances once per UTC day

// Copyright (C) 2026 Soter Labs
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity ^0.8.21;

// dss-cron
interface IJob {
    function work(bytes32 network, bytes calldata args) external;
    function workable(bytes32 network) external returns (bool canWork, bytes memory args);
}

interface SequencerLike {
    function isMaster(bytes32 network) external view returns (bool);
}

interface TallyLike {
    function live() external view returns (uint256);
    function zzz() external view returns (uint256);
    function settle() external;
}

/**
 * @title  TallyJob
 * @notice Keeper-network job for the Daily Settlement Cycle.
 *
 *         Holds the list of `Tally` instances (one per allocator ilk). An
 *         instance is due once the UTC day has rolled over since its last
 *         settle. `workable` finds the first due instance whose `settle`
 *         succeeds in simulation (a stale relay mark or a missing role makes
 *         it revert, and that instance is skipped rather than burning keeper
 *         gas); `work` settles it. One instance per call, as dss-cron jobs
 *         do; the keeper loops until nothing is workable.
 */
contract TallyJob is IJob {

    // --- Auth ---
    mapping (address => uint256) public wards;
    function rely(address usr) external auth { wards[usr] = 1; emit Rely(usr); }
    function deny(address usr) external auth { wards[usr] = 0; emit Deny(usr); }
    modifier auth {
        require(wards[msg.sender] == 1, "TallyJob/not-authorized");
        _;
    }

    // --- Data ---
    SequencerLike public immutable sequencer;

    address[]                    public list;
    mapping (address => uint256) public has;   // 1 if in the list

    // --- Events ---
    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event Add(address indexed tally);
    event Remove(address indexed tally);
    event Work(bytes32 indexed network, address indexed tally);

    // --- Errors ---
    error NotMaster(bytes32 network);
    error ShouldNotTrigger();

    constructor(address sequencer_) {
        sequencer = SequencerLike(sequencer_);
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    // --- Administration ---
    function add(address tally) external auth {
        require(has[tally] == 0, "TallyJob/already-added");
        require(tally.code.length > 0, "TallyJob/no-code");
        require(TallyLike(tally).live() <= 1, "TallyJob/bad-live");
        TallyLike(tally).zzz();
        has[tally] = 1;
        list.push(tally);
        emit Add(tally);
    }

    function remove(address tally) external auth {
        require(has[tally] == 1, "TallyJob/not-added");
        has[tally] = 0;
        for (uint256 k = 0; k < list.length; k++) {
            if (list[k] == tally) {
                list[k] = list[list.length - 1];
                list.pop();
                break;
            }
        }
        emit Remove(tally);
    }

    function count() external view returns (uint256) {
        return list.length;
    }

    // --- Job ---

    /// @notice An instance is due when a new UTC day has begun since it last settled.
    function due(address tally) public view returns (bool) {
        TallyLike t = TallyLike(tally);
        return t.live() == 1 && t.zzz() / 1 days < block.timestamp / 1 days;
    }

    function work(bytes32 network, bytes calldata args) external override {
        if (!sequencer.isMaster(network)) revert NotMaster(network);
        address tally = abi.decode(args, (address));
        if (has[tally] == 0 || !due(tally)) revert ShouldNotTrigger();
        TallyLike(tally).settle();
        emit Work(network, tally);
    }

    /// @dev Not a view on purpose: the keeper calls this with eth_call, so
    ///      the trial `settle` is free and its state is discarded. Only an
    ///      instance that would actually settle is reported as workable.
    function workable(bytes32 network) external override returns (bool, bytes memory) {
        if (!sequencer.isMaster(network)) return (false, bytes("Network is not master"));
        for (uint256 k = 0; k < list.length; k++) {
            address tally = list[k];
            try this.due(tally) returns (bool ready) {
                if (!ready) continue;
            } catch { continue; }
            try TallyLike(tally).settle() {
                return (true, abi.encode(tally));
            } catch {
                continue;
            }
        }
        return (false, bytes("No tally is due"));
    }
}
