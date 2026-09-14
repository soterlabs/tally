// SPDX-License-Identifier: AGPL-3.0-or-later

/// CurveLegPip.sol -- pricing adapter support for Tally

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
import { VaultLike } from "./Erc4626Pip.sol";

interface CurvePoolLike {
    function coins(uint256 i) external view returns (address);
    function balances(uint256 i) external view returns (uint256);
}

/// One leg of a Curve stableswap LP position. The LP token is the share and
/// the leg's reserve per LP token is the index, so swap fees accruing to the
/// reserves read as yield and LP mints / burns read as flows. A par leg prices
/// at 1; a yield-bearing 4626 leg (sUSDS) prices through its vault and can
/// carry the `SAV` tag, as the MSC does for the sUSDS slice of a pool. One
/// pip per leg, one gem per leg.
contract CurveLegPip is Pip {
    CurvePoolLike public immutable pool;
    TokenLike     public immutable lp;     // the LP token (the pool itself on stableswap-ng)
    uint256       public immutable i;
    TokenLike     public immutable coin;
    uint8         public immutable dec;
    VaultLike     public immutable vault;  // 0 for a par leg, else the leg's own 4626 vault
    uint8         public immutable adec;

    constructor(address pool_, address lp_, uint256 i_, address vault_) {
        pool  = CurvePoolLike(pool_);
        lp    = TokenLike(lp_);
        i     = i_;
        coin  = TokenLike(pool.coins(i_));
        dec   = coin.decimals();
        vault = VaultLike(vault_);
        adec  = vault_ == address(0) ? dec : TokenLike(VaultLike(vault_).asset()).decimals();
    }

    /// @dev Leg value per 1e18 LP tokens [ray].
    function _chi() internal view returns (uint256) {
        uint256 supply = TokenSupplyLike(address(lp)).totalSupply();
        if (supply == 0) return 0;
        uint256 reserve = _wad(pool.balances(i), dec);                       // coin units, wad
        if (address(vault) != address(0)) {
            reserve = reserve * _wad(vault.convertToAssets(10 ** dec), adec) / WAD;   // to the asset
        }
        return reserve * RAY / supply;
    }

    function peek(address who) external view override returns (uint256 pie, uint256 chi, uint256 own) {
        pie = lp.balanceOf(who);   // LP tokens are 18 decimals
        chi = _chi();
        own = 0;
    }
}

interface TokenSupplyLike {
    function totalSupply() external view returns (uint256);
}
