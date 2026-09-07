// SPDX-License-Identifier: AGPL-3.0-or-later

/// Pips.sol -- pricing adapters for Tally

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

interface VaultLike is TokenLike {
    function asset() external view returns (address);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

interface AsyncVaultLike is VaultLike {
    function pendingDepositRequest(uint256 requestId, address controller) external view returns (uint256 assets);
    function claimableDepositRequest(uint256 requestId, address controller) external view returns (uint256 assets);
    function pendingRedeemRequest(uint256 requestId, address controller) external view returns (uint256 shares);
    function claimableRedeemRequest(uint256 requestId, address controller) external view returns (uint256 shares);
}

interface ATokenLike is TokenLike {
    function scaledBalanceOf(address user) external view returns (uint256);
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
    function POOL() external view returns (address);
}

interface PoolLike {
    function getReserveNormalizedIncome(address asset) external view returns (uint256);
}

/// Every pip answers `peek(who) -> (pie, chi, own)`:
///   pie  shares held by `who`, incl. in-flight                 [wad]
///   chi  price per 1e18 shares in the asset, gross of fees     [ray]
///   own  assets owned by `who` outside the shares               [wad]
abstract contract Pip {
    uint256 constant WAD = 10 ** 18;
    uint256 constant RAY = 10 ** 27;

    function _wad(uint256 amt, uint8 dec) internal pure returns (uint256) {
        return dec <= 18 ? amt * 10 ** (18 - dec) : amt / 10 ** (dec - 18);
    }

    function peek(address who) external view virtual returns (uint256 pie, uint256 chi, uint256 own);
}

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

/// ERC-7540 (Centrifuge JAAA / JTRSY...). Shares moved to escrow by
/// `requestRedeem` are still the holder's; assets queued by `requestDeposit`
/// are the holder's cash at par until shares are minted. Request id 0.
contract Erc7540Pip is Erc4626Pip {
    constructor(address vault_) Erc4626Pip(vault_) {}

    function peek(address who) external view override returns (uint256 pie, uint256 chi, uint256 own) {
        AsyncVaultLike v = AsyncVaultLike(address(vault));
        pie = _wad(v.balanceOf(who) + v.pendingRedeemRequest(0, who) + v.claimableRedeemRequest(0, who), sdec);
        chi = _chi();
        own = _wad(v.pendingDepositRequest(0, who) + v.claimableDepositRequest(0, who), adec);
    }
}

/// Aave v3 / SparkLend aTokens: `scaledBalanceOf` is the share, the pool's
/// normalized income is the index. Both are already the right shape.
contract ATokenPip is Pip {
    ATokenLike public immutable gem;
    PoolLike   public immutable pool;
    address    public immutable asset;
    uint8      public immutable dec;

    constructor(address gem_) {
        gem   = ATokenLike(gem_);
        pool  = PoolLike(gem.POOL());
        asset = gem.UNDERLYING_ASSET_ADDRESS();
        dec   = gem.decimals();
    }

    function peek(address who) external view override returns (uint256 pie, uint256 chi, uint256 own) {
        pie = _wad(gem.scaledBalanceOf(who), dec);
        chi = pool.getReserveNormalizedIncome(asset);
        own = 0;
    }
}

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
