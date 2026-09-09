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

// ---------------------------------------------------------------------------
// Adapters added after the August 2026 backtests.
// ---------------------------------------------------------------------------

interface ChronicleLike {
    function read() external view returns (uint256);   // wad; reverts unless the caller is kissed
}

/// Token priced by a Chronicle oracle (STAC; JAAA / JTRSY fallback). The pip
/// must be `kiss`ed on the oracle by Chronicle's authed owners, as any
/// on-chain reader of a Chronicle feed is.
contract ChroniclePip is Pip {
    TokenLike     public immutable gem;
    ChronicleLike public immutable oracle;
    uint8         public immutable dec;

    constructor(address gem_, address oracle_) {
        gem    = TokenLike(gem_);
        oracle = ChronicleLike(oracle_);
        dec    = gem.decimals();
    }

    function peek(address who) external view override returns (uint256 pie, uint256 chi, uint256 own) {
        pie = _wad(gem.balanceOf(who), dec);
        chi = oracle.read() * RAY / WAD;
        own = 0;
    }
}

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

interface CurvePoolLike {
    function coins(uint256 i) external view returns (address);
    function balances(uint256 i) external view returns (uint256);
}

/// One leg of a Curve stableswap LP position: the holder's pro-rata share of
/// reserve `i`, in that coin. A par leg prices at 1; a yield-bearing 4626 leg
/// (sUSDS) prices through its vault and can carry the `SAV` tag, as the MSC
/// does for the sUSDS slice of a pool. One pip per leg, one gem per leg.
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

    function peek(address who) external view override returns (uint256 pie, uint256 chi, uint256 own) {
        uint256 supply = TokenSupplyLike(address(lp)).totalSupply();
        pie = supply == 0 ? 0 : _wad(lp.balanceOf(who) * pool.balances(i) / supply, dec);
        chi = address(vault) == address(0) ? RAY : _wad(vault.convertToAssets(10 ** dec), adec) * RAY / WAD;
        own = 0;
    }
}

interface TokenSupplyLike {
    function totalSupply() external view returns (uint256);
}

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
        return pie == 0 ? RAY : bal * RAY / pie;
    }

    /// @notice Declare a capital movement of `wad` assets (wad, signed) for
    ///         `who`, in the same block and BEFORE the tokens move.
    function deal(address who, int256 wad) external auth {
        uint256 pie = pies[who];
        uint256 chi = _chi(who, pie);
        if (wad >= 0) pie += uint256(wad) * RAY / chi;
        else {
            uint256 d = uint256(-wad) * RAY / chi;
            pie = d >= pie ? 0 : pie - d;
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
