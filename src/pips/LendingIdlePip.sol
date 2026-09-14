// SPDX-License-Identifier: AGPL-3.0-or-later

/// LendingIdlePip.sol -- pricing adapter support for Tally

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
import { ATokenLike } from "./ATokenPip.sol";

interface ATokenSupplyLike is ATokenLike {
    function totalSupply() external view returns (uint256);
}

/// The holder's share of the underlying sitting UNBORROWED in an Aave /
/// SparkLend pool: `balanceOf / totalSupply x underlying.balanceOf(aToken)`.
/// Not utilized by anyone, so the MSC deducts it from the Base Rate base.
/// Tag `IDL` alongside the `ATokenPip` gem that carries the position itself.
contract LendingIdlePip is Pip {
    ATokenSupplyLike public immutable gem;
    TokenLike        public immutable asset;
    uint8            public immutable dec;

    constructor(address gem_) {
        gem   = ATokenSupplyLike(gem_);
        asset = TokenLike(gem.UNDERLYING_ASSET_ADDRESS());
        dec   = gem.decimals();
    }

    function peek(address who) external view override returns (uint256 pie, uint256 chi, uint256 own) {
        uint256 supply = gem.totalSupply();
        pie = supply == 0 ? 0 : _wad(gem.balanceOf(who) * asset.balanceOf(address(gem)) / supply, dec);
        chi = RAY;
        own = 0;
    }
}
