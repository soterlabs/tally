// SPDX-License-Identifier: AGPL-3.0-or-later

/// Erc7540Pip.sol -- pricing adapter support for Tally

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

// ERC-7540 async vault. Per ERC-7575 the share is a separate token
// (`share()`); the vault itself has no ERC-20 surface.
interface AsyncVaultLike {
    function asset() external view returns (address);
    function share() external view returns (address);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function pendingDepositRequest(uint256 requestId, address controller) external view returns (uint256 assets);
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256 shares);
    function maxMint(address controller) external view returns (uint256 shares);      // fulfilled deposits, shares claimable
    function maxWithdraw(address controller) external view returns (uint256 assets);  // fulfilled redeems, assets claimable
}

/// ERC-7540 (Centrifuge JAAA / JTRSY...). Four in-flight states, each at
/// the price it actually has:
///   pending redeem     shares in escrow, still floating       -> pie
///   claimable redeem   fulfilled at a fixed price: assets     -> own (maxWithdraw)
///   pending deposit    assets in escrow, at par                -> own
///   claimable deposit  fulfilled: shares already minted        -> pie (maxMint)
/// Request id 0. Balances and decimals come from the ERC-7575 share token.
contract Erc7540Pip is Pip {
    AsyncVaultLike public immutable vault;
    TokenLike      public immutable share;
    uint8          public immutable sdec;  // share decimals
    uint8          public immutable adec;  // asset decimals

    constructor(address vault_) {
        vault = AsyncVaultLike(vault_);
        share = TokenLike(vault.share());
        sdec  = share.decimals();
        adec  = TokenLike(vault.asset()).decimals();
    }

    function peek(address who) external view override returns (uint256 pie, uint256 chi, uint256 own) {
        pie = _wad(share.balanceOf(who) + vault.pendingRedeemRequest(0, who) + vault.maxMint(who), sdec);
        chi = _wad(vault.convertToAssets(10 ** sdec), adec) * RAY / WAD;
        own = _wad(vault.pendingDepositRequest(0, who) + vault.maxWithdraw(who), adec);
    }
}
