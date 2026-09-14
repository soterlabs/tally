// SPDX-License-Identifier: AGPL-3.0-or-later

/// Erc4626Pip.sol -- pricing adapter support for Tally

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

interface VaultLike is TokenLike {
    function asset() external view returns (address);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// ERC-4626 (sUSDS, sUSDC, syrupUSDC, MetaMorpho...): `convertToAssets`.
contract Erc4626Pip is Pip {
    VaultLike public immutable vault;
    uint8     public immutable sdec;  // share decimals
    uint8     public immutable adec;  // asset decimals

    constructor(address vault_) {
        vault = VaultLike(vault_);
        sdec  = vault.decimals();
        adec  = TokenLike(vault.asset()).decimals();
    }

    function _chi() internal view returns (uint256) {
        return _wad(vault.convertToAssets(10 ** sdec), adec) * RAY / WAD;
    }

    function peek(address who) external view virtual override returns (uint256 pie, uint256 chi, uint256 own) {
        pie = _wad(vault.balanceOf(who), sdec);
        chi = _chi();
        own = 0;
    }
}
