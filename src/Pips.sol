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

// ---------------------------------------------------------------------------
// Uniswap V3
// ---------------------------------------------------------------------------

interface NPMLike {
    function balanceOf(address owner) external view returns (uint256);
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
    function positions(uint256 tokenId) external view returns (
        uint96 nonce, address operator, address token0, address token1, uint24 fee,
        int24 tickLower, int24 tickUpper, uint128 liquidity,
        uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128,
        uint128 tokensOwed0, uint128 tokensOwed1
    );
}

interface UniV3PoolLike {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
    function feeGrowthGlobal0X128() external view returns (uint256);
    function feeGrowthGlobal1X128() external view returns (uint256);
    function ticks(int24 tick) external view returns (
        uint128 liquidityGross, int128 liquidityNet,
        uint256 feeGrowthOutside0X128, uint256 feeGrowthOutside1X128,
        int56, uint160, uint32, bool
    );
}

/// Uniswap V3 NFT positions of a holder in one stablecoin pool. Both tokens
/// are valued at par. Value = amounts for the liquidity at the current price
/// + fees owed + fees accrued since the position was last touched + fees
/// already collected (declared with `deal`, since a collect moves value out
/// of the position and would otherwise read as a loss).
///
/// The share is each position's NOTIONAL AT PARITY: the token amounts its
/// liquidity would hold with the price exactly at 1. That is additive across
/// positions with different tick ranges (raw liquidity is not: a wider range
/// holds far more value per unit of liquidity), invariant to fee accrual and
/// to price moves inside the range, and equal to the capital deposited for a
/// stable pair near parity. Value per unit of notional is the index, so
/// adding or removing liquidity is a flow and fee accrual is yield. When all
/// liquidity is gone the residue is reported as `own`.
contract UniV3Pip is Pip {
    mapping (address => uint256) public wards;
    function rely(address usr) external auth { wards[usr] = 1; emit Rely(usr); }
    function deny(address usr) external auth { wards[usr] = 0; emit Deny(usr); }
    modifier auth {
        require(wards[msg.sender] == 1, "UniV3Pip/not-authorized");
        _;
    }

    NPMLike        public immutable npm;
    UniV3PoolLike  public immutable pool;
    address        public immutable token0;
    address        public immutable token1;
    uint24         public immutable fee;
    uint8          public immutable dec0;
    uint8          public immutable dec1;

    mapping (address => uint256) public collected;   // fees collected out of the position [wad]

    uint256 constant Q96  = 2 ** 96;
    uint256 constant Q128 = 2 ** 128;

    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event Deal(address indexed who, uint256 wad);

    constructor(address npm_, address pool_) {
        npm    = NPMLike(npm_);
        pool   = UniV3PoolLike(pool_);
        token0 = pool.token0();
        token1 = pool.token1();
        fee    = pool.fee();
        dec0   = TokenLike(token0).decimals();
        dec1   = TokenLike(token1).decimals();
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    /// @notice Record fees collected out of the position (par, wad).
    function deal(address who, uint256 wad) external auth {
        collected[who] += wad;
        emit Deal(who, wad);
    }

    // --- math (Uniswap v3-core, 0.8 semantics) ---

    function _mulDiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256 r) {
        unchecked {
            uint256 p0; uint256 p1;
            assembly { let mm := mulmod(a, b, not(0)) p0 := mul(a, b) p1 := sub(sub(mm, p0), lt(mm, p0)) }
            if (p1 == 0) return p0 / d;
            require(d > p1, "UniV3Pip/overflow");
            uint256 rem; assembly { rem := mulmod(a, b, d) p1 := sub(p1, gt(rem, p0)) p0 := sub(p0, rem) }
            uint256 twos = d & (~d + 1);
            assembly { d := div(d, twos) p0 := div(p0, twos) twos := add(div(sub(0, twos), twos), 1) }
            p0 |= p1 * twos;
            uint256 inv = (3 * d) ^ 2;
            inv *= 2 - d * inv; inv *= 2 - d * inv; inv *= 2 - d * inv;
            inv *= 2 - d * inv; inv *= 2 - d * inv; inv *= 2 - d * inv;
            r = p0 * inv;
        }
    }

    function _sqrtAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        unchecked {
            uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
            require(absTick <= 887272, "UniV3Pip/tick");
            uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
            if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
            if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
            if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
            if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
            if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
            if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
            if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
            if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
            if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
            if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
            if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
            if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
            if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
            if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
            if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
            if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
            if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
            if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;
            if (tick > 0) ratio = type(uint256).max / ratio;
            sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
        }
    }

    function _amounts(uint160 sp, uint160 sa, uint160 sb, uint128 L) internal pure returns (uint256 a0, uint256 a1) {
        if (sp <= sa) {
            a0 = _mulDiv(uint256(L) << 96, sb - sa, sb) / sa;
        } else if (sp < sb) {
            a0 = _mulDiv(uint256(L) << 96, sb - sp, sb) / sp;
            a1 = _mulDiv(L, sp - sa, Q96);
        } else {
            a1 = _mulDiv(L, sb - sa, Q96);
        }
    }

    function _outside(int24 t) internal view returns (uint256 o0, uint256 o1) {
        (,, o0, o1,,,,) = pool.ticks(t);
    }

    // Fee growth inside [lower, upper], per unit of liquidity (Uniswap's wrapping arithmetic).
    function _inside(int24 tick, int24 lower, int24 upper) internal view returns (uint256 i0, uint256 i1) {
        (uint256 lo0, uint256 lo1) = _outside(lower);
        (uint256 up0, uint256 up1) = _outside(upper);
        uint256 g0 = pool.feeGrowthGlobal0X128();
        uint256 g1 = pool.feeGrowthGlobal1X128();
        unchecked {
            i0 = g0 - (tick >= lower ? lo0 : g0 - lo0) - (tick < upper ? up0 : g0 - up0);
            i1 = g1 - (tick >= lower ? lo1 : g1 - lo1) - (tick < upper ? up1 : g1 - up1);
        }
    }

    // Mirrors the ABI layout of NonfungiblePositionManager.positions().
    struct Pos {
        uint96 nonce; address operator; address t0; address t1; uint24 f;
        int24 lower; int24 upper; uint128 liq;
        uint256 last0; uint256 last1;
        uint128 owed0; uint128 owed1;
    }

    function _pos(uint256 id) internal view returns (Pos memory q) {
        (bool ok, bytes memory data) = address(npm).staticcall(abi.encodeWithSelector(NPMLike.positions.selector, id));
        require(ok, "UniV3Pip/positions");
        q = abi.decode(data, (Pos));
    }

    // Value of one NFT in this pool: (token0 units, token1 units, notional at parity in wad).
    // Zero if the NFT belongs to another pool.
    function _position(uint256 id, uint160 sp, int24 tick) internal view returns (uint256 v0, uint256 v1, uint256 N) {
        Pos memory q = _pos(id);
        if (q.t0 != token0 || q.t1 != token1 || q.f != fee) return (0, 0, 0);
        uint160 sa = _sqrtAtTick(q.lower);
        uint160 sb = _sqrtAtTick(q.upper);
        (v0, v1) = _amounts(sp, sa, sb, q.liq);
        v0 += q.owed0; v1 += q.owed1;
        if (q.liq > 0) {
            (uint256 i0, uint256 i1) = _inside(tick, q.lower, q.upper);
            unchecked {
                v0 += _mulDiv(i0 - q.last0, q.liq, Q128);
                v1 += _mulDiv(i1 - q.last1, q.liq, Q128);
            }
            (uint256 n0, uint256 n1) = _amounts(uint160(Q96), sa, sb, q.liq);   // price exactly 1
            N = _wad(n0, dec0) + _wad(n1, dec1);
        }
    }

    function _slot() internal view returns (uint160 sp, int24 tick) {
        (sp, tick,,,,,) = pool.slot0();
    }

    function _sum(address who) internal view returns (uint256 v0, uint256 v1, uint256 N) {
        (uint160 sp, int24 tick) = _slot();
        uint256 n = npm.balanceOf(who);
        for (uint256 k = 0; k < n; k++) {
            (uint256 a, uint256 b, uint256 m) = _position(npm.tokenOfOwnerByIndex(who, k), sp, tick);
            v0 += a; v1 += b; N += m;
        }
    }

    function peek(address who) external view override returns (uint256 pie, uint256 chi, uint256 own) {
        (uint256 v0, uint256 v1, uint256 N) = _sum(who);
        uint256 val = _wad(v0, dec0) + _wad(v1, dec1) + collected[who];
        if (N == 0) return (0, RAY, val);
        pie = N;
        chi = val * RAY / N;
        own = 0;
    }
}
