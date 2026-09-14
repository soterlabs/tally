// SPDX-License-Identifier: AGPL-3.0-or-later

/// RawPip.sol -- pricing adapter support for Tally

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

/// Par stablecoin (USDS, USDC, USDT...): one unit is one dollar, forever.
contract RawPip is Pip {
    TokenLike public immutable gem;
    uint8     public immutable dec;

    constructor(address gem_) {
        gem = TokenLike(gem_);
        dec = gem.decimals();
    }

    function peek(address who) external view override returns (uint256 pie, uint256 chi, uint256 own) {
        pie = _wad(gem.balanceOf(who), dec);
        chi = RAY;
        own = 0;
    }
}
