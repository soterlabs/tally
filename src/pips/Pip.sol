// SPDX-License-Identifier: AGPL-3.0-or-later

/// Pip.sol -- pricing adapter support for Tally

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

interface TokenLike {
    function decimals() external view returns (uint8);
    function balanceOf(address) external view returns (uint256);
}

/// Common adapter ABI. All monetary values are USDS-equivalent.
interface PipLike {
    function peek(address who) external view returns (uint256 pie, uint256 chi, uint256 own);
}

/// Every pip answers `peek(who) -> (pie, chi, own)`:
///   pie  shares held by `who`, incl. in-flight                 [wad]
///   chi  price per 1e18 shares in the asset, gross of fees     [ray]
///   own  assets owned by `who` outside the shares               [wad]
abstract contract Pip is PipLike {
    uint256 constant WAD = 10 ** 18;
    uint256 constant RAY = 10 ** 27;

    function _wad(uint256 amt, uint8 dec) internal pure returns (uint256) {
        return dec <= 18 ? amt * 10 ** (18 - dec) : amt / 10 ** (dec - 18);
    }

    function peek(address who) external view virtual returns (uint256 pie, uint256 chi, uint256 own);
}
