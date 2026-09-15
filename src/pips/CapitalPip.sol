// SPDX-License-Identifier: AGPL-3.0-or-later

/// CapitalPip.sol -- pricing adapter support for Tally

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

import { Pip, TokenLike } from "./Pip.sol";

/// Par token whose yield is DELIVERED AS NEW TOKENS (BUIDL dividends) or as
/// cash landing at the holder (issuer sweeps). A balance reader cannot tell
/// a dividend from a deposit, so the party that moves capital declares it:
/// `deal(who, wad)` BEFORE the transfer, positive for a deposit, negative for
/// a redemption. Declared capital is kept as a share count `pie` at the
/// implied index `chi = balance / pie`, so a declared flow leaves `chi`
/// unchanged (no PnL) and an undeclared arrival raises it (yield).
contract CapitalPip is Pip {
    mapping (address => uint256) public wards;
    function rely(address usr) external auth { wards[usr] = 1; emit Rely(usr); }
    function deny(address usr) external auth { wards[usr] = 0; emit Deny(usr); }
    modifier auth {
        require(wards[msg.sender] == 1, "CapitalPip/not-authorized");
        _;
    }

    TokenLike public immutable gem;
    uint8     public immutable dec;
    mapping (address => uint256) public chis;   // last nonempty index; retained across full exits
    mapping (address => uint256) public pies;   // declared capital, in index shares [wad]

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event Deal(address indexed who, int256 wad, uint256 pie);

    constructor(address gem_) {
        gem = TokenLike(gem_);
        dec = gem.decimals();
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    function _chi(address who, uint256 pie) internal view returns (uint256) {
        uint256 bal = _wad(gem.balanceOf(who), dec);
        return pie == 0 ? (chis[who] == 0 ? RAY : chis[who]) : bal * RAY / pie;
    }

    /// @notice Declare a capital movement of `wad` assets (wad, signed) for
    ///         `who`, in the same block and BEFORE the tokens move.
    function deal(address who, int256 wad) external auth {
        uint256 pie = pies[who];
        uint256 chi = _chi(who, pie);
        require(chi > 0, "CapitalPip/zero-index");
        chis[who] = chi;
        if (wad >= 0) pie += uint256(wad) * RAY / chi;
        else {
            require(uint256(-wad) <= _wad(gem.balanceOf(who), dec), "CapitalPip/excess-withdrawal");
            uint256 d = uint256(-wad) * RAY / chi;
            pie = uint256(-wad) == _wad(gem.balanceOf(who), dec) || d >= pie ? 0 : pie - d;
        }
        pies[who] = pie;
        emit Deal(who, wad, pie);
    }

    function peek(address who) external view override returns (uint256 pie, uint256 chi, uint256 own) {
        pie = pies[who];
        chi = _chi(who, pie);
        // Balance held with no declared capital is all yield-to-date, at par.
        own = pie == 0 ? _wad(gem.balanceOf(who), dec) : 0;
    }
}
