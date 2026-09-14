// SPDX-License-Identifier: AGPL-3.0-or-later

/// RelayPip.sol -- pricing adapter support for Tally

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

import { Pip } from "./Pip.sol";

/// Relayed position: values pushed by an authorised writer (the operator
/// today; a bridge receiver or an oracle adapter tomorrow) for positions
/// that cannot be read on this chain. A mark older than `hop` is stale and
/// `peek` reverts: a settlement that cannot read its inputs must stop, not
/// guess (OSM convention for `hop`).
contract RelayPip is Pip {
    mapping (address => uint256) public wards;
    function rely(address usr) external auth { wards[usr] = 1; emit Rely(usr); }
    function deny(address usr) external auth { wards[usr] = 0; emit Deny(usr); }
    modifier auth {
        require(wards[msg.sender] == 1, "RelayPip/not-authorized");
        _;
    }

    struct Mark { uint256 pie; uint256 chi; uint256 own; uint256 zzz; }
    mapping (address => Mark) public marks;

    uint256 public hop = 1 days;   // maximum age of a mark [seconds]

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event File(bytes32 indexed what, uint256 data);
    event Poke(address indexed who, uint256 pie, uint256 chi, uint256 own);

    constructor() {
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    function file(bytes32 what, uint256 data) external auth {
        if (what == "hop") hop = data;
        else revert("RelayPip/file-unrecognized-param");
        emit File(what, data);
    }

    function poke(address who, uint256 pie, uint256 chi, uint256 own) external auth {
        marks[who] = Mark(pie, chi, own, block.timestamp);
        emit Poke(who, pie, chi, own);
    }

    function peek(address who) external view override returns (uint256 pie, uint256 chi, uint256 own) {
        Mark storage m = marks[who];
        require(m.zzz != 0, "RelayPip/no-mark");
        require(block.timestamp - m.zzz <= hop, "RelayPip/stale");
        return (m.pie, m.chi, m.own);
    }
}
