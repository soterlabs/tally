// SPDX-License-Identifier: AGPL-3.0-or-later

/// Till.sol -- cash register for a Tally: draws, pays, and banks the day

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

// dss-allocator: `draw` mints new ilk debt as USDS into the AllocatorBuffer;
// the buffer itself only exposes `approve`, so we pull with `transferFrom`.
interface VaultLike {
    function draw(uint256 wad) external;
}

interface JoinLike {
    function join(address usr, uint256 wad) external;
}

interface GemLike {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

/**
 * @title  Till
 * @notice The part of the Daily Settlement Cycle that touches money. One per
 *         `Tally`. `Tally` keeps the books and decides the day's figures;
 *         `Till` executes them:
 *
 *           draw   new ilk debt through the prime's AllocatorVault, pulled
 *                  from the AllocatorBuffer by allowance
 *           pay    the SubProxy, from the fresh draw first, then from the
 *                  USDS float governance keeps here
 *           keep   Sky's net (draw − send), joined to the surplus buffer
 *
 *         `Till` holds the prime-scoped allocator roles and the float.
 *         `Tally` holds nothing and moves nothing. Only `Tally` may call
 *         `pay`; governance may `quit` anything out at any time.
 */
contract Till {

    // --- Auth ---
    mapping (address => uint256) public wards;
    function rely(address usr) external auth { wards[usr] = 1; emit Rely(usr); }
    function deny(address usr) external auth { wards[usr] = 0; emit Deny(usr); }
    modifier auth {
        require(wards[msg.sender] == 1, "Till/not-authorized");
        _;
    }

    // --- Data ---
    address  public immutable vow;    // surplus buffer
    JoinLike public immutable join;   // UsdsJoin
    GemLike  public immutable usds;

    address public vault;    // AllocatorVault: draws the mint as ilk debt
    address public buffer;   // AllocatorBuffer: where the vault delivers USDS

    // --- Events ---
    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event File(bytes32 indexed what, address data);
    event Pay(uint256 drew, uint256 send, uint256 paid, uint256 kept);
    event Quit(address indexed gem, address indexed dst, uint256 wad);

    constructor(address vow_, address join_, address usds_) {
        vow  = vow_;
        join = JoinLike(join_);
        usds = GemLike(usds_);
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
        // The join burns from us when we credit the surplus buffer.
        usds.approve(join_, type(uint256).max);
    }

    // --- Administration ---
    function file(bytes32 what, address data) external auth {
        if      (what == "vault")  vault  = data;
        else if (what == "buffer") buffer = data;
        else revert("Till/file-unrecognized-param");
        emit File(what, data);
    }

    /// @notice Move tokens out (the USDS float, a mistaken transfer).
    function quit(address gem, address dst, uint256 wad) external auth {
        require(GemLike(gem).transfer(dst, wad), "Till/transfer-failed");
        emit Quit(gem, dst, wad);
    }

    // --- Settlement ---

    /// @notice Execute a day: draw `drew` of new ilk debt, pay `send` to
    ///         `to`, bank the rest. Returns what was actually paid and kept.
    function pay(uint256 drew, uint256 send, address to) external auth returns (uint256 paid, uint256 kept) {
        if (drew > 0) {
            require(vault != address(0) && buffer != address(0), "Till/vault-not-set");
            VaultLike(vault).draw(drew);
            require(usds.transferFrom(buffer, address(this), drew), "Till/transfer-failed");
        }
        // From the fresh draw first, then from the float; the rest is owed.
        paid = usds.balanceOf(address(this));
        if (paid > send) paid = send;
        if (paid > 0) require(usds.transfer(to, paid), "Till/transfer-failed");
        // Sky's net goes to the surplus buffer.
        kept = drew > send ? drew - send : 0;
        if (kept > 0) join.join(vow, kept);
        emit Pay(drew, send, paid, kept);
    }
}
