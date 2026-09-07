// SPDX-License-Identifier: AGPL-3.0-or-later

/// Tally.sol -- daily settlement cycle for a Sky prime agent

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

interface VatLike {
    function ilks(bytes32) external view returns (uint256 Art, uint256 rate, uint256 spot, uint256 line, uint256 dust);
    function Line() external view returns (uint256);
    function debt() external view returns (uint256);
}

// dss-allocator: `draw` mints new ilk debt as USDS into the AllocatorBuffer;
// the buffer itself only exposes `approve`, so we pull with `transferFrom`.
interface VaultLike {
    function draw(uint256 wad) external;
}

interface JoinLike {
    function join(address usr, uint256 wad) external;
}

interface GemLike {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface SusdsLike {
    function ssr() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// Pricing adapter. Returns, for holder `who`:
///   pie  shares held, incl. in-flight                     [wad]
///   chi  price per 1e18 shares in the asset, gross of fees [ray]
///   own  assets owned outside the shares (queued deposits) [wad]
interface PipLike {
    function peek(address who) external view returns (uint256 pie, uint256 chi, uint256 own);
}

/**
 * @title  Tally
 * @notice Daily Settlement Cycle (DSC) for a Sky prime agent.
 *
 *         One instance per allocator ilk (e.g. ALLOCATOR-SPARK-A). The ilk
 *         points at an ALM Proxy (`alm`, whose positions are marked), a
 *         SubProxy (`sub`, paid at settle; its idle USDS / sUSDS earn the
 *         agent rate), and the prime's AllocatorVault / AllocatorBuffer
 *         (through which the Sky share is drawn as new ilk debt).
 *
 *         Jug-style, anyone can advance the clocks:
 *
 *         - `drip(ilk)` accrues the Sky side. The Base Rate charge is
 *           `debt * duty * dt` with `debt = Art * rate` read from the Vat
 *           and `duty` derived on-chain from `sUSDS.ssr()` at DAILY
 *           compounding plus a governance spread (`pad`). Also accrues
 *           the agent rate owed on the SubProxy's holdings.
 *
 *           Balances are sampled, not integrated, so every accrual is
 *           taken on the balance that is WORSE for the prime over the
 *           interval: the larger of the debt at the two ends, the smaller
 *           of the SubProxy / idle balances at the two ends. A prime that
 *           drips before it draws, wipes or moves funds is charged and
 *           credited exactly; one that does not pays for the interval at
 *           the higher balance. Nothing the prime does can under-charge Sky.
 *
 *         - `poke(ilk, gem)` marks a position through its `pip` adapter and
 *           books `pie * (chi_new - chi_old)` as gain or loss. PnL is taken
 *           on the index, so relayer deposits and withdrawals between
 *           pokes are flows, not revenue. Each gem carries a `tag` that
 *           routes it: prime mark-to-market, Sky direct exposure, Sky
 *           savings token (spread rebate), idle (Base Rate rebate), or
 *           position-only.
 *
 *         - `settle(ilk)` does both, then executes the MSC identity in
 *           whole USDS:
 *
 *             sky  = tab + sde - rebate           Sky share
 *             sv   = gain + rebate - tab - sin    prime supply share
 *             mint = sky + max(sv, 0)             drawn as new ilk debt
 *             send = owe + max(sv, 0)             paid to the SubProxy
 *
 *           A negative `sv` is carried in `sin` against future supply
 *           gains only; the demand side is always paid. `mint` is drawn
 *           through `AllocatorVault.draw` within the ilk's debt ceiling
 *           (the rest is carried), pulled from the AllocatorBuffer, and
 *           pays `send` first; what is left is Sky's net and is joined to
 *           the surplus buffer. When `send` exceeds the draw, the
 *           difference is paid from USDS governance keeps here and
 *           otherwise carried in `owe`. No Vat privileges are needed.
 *
 *         Amounts are wad regardless of token decimals; rates are ray.
 *         Annual rates (`pad`, `tip`, `cut`) are NOMINAL, applied as
 *         `rate / 365 days` per second, per the MSC convention.
 */
contract Tally {

    // --- Auth ---
    mapping (address => uint256) public wards;
    function rely(address usr) external auth { wards[usr] = 1; emit Rely(usr); }
    function deny(address usr) external auth { wards[usr] = 0; emit Deny(usr); }
    modifier auth {
        require(wards[msg.sender] == 1, "Tally/not-authorized");
        _;
    }

    // --- Data ---
    // Where a gem's marks go.
    uint8 public constant MTM = 1; // prime mark-to-market                    -> gain
    uint8 public constant SDE = 2; // Sky direct exposure (cap-aware share)    -> sde, remainder -> gain
    uint8 public constant SAV = 3; // Sky savings token: SSR stays in the token; spread rebated   -> rebate
    uint8 public constant IDL = 4; // idle USDS-equivalent, not utilized:      Base Rate rebated  -> rebate
    uint8 public constant NIL = 5; // position-only, tracked but never booked

    struct Ilk {
        address alm;     // ALM Proxy: default holder of the gems
        address sub;     // SubProxy: paid at settle, earns the agent rate
        address vault;   // AllocatorVault: draws the mint as ilk debt
        address buffer;  // AllocatorBuffer: where the vault delivers USDS
        uint256 rho;     // time of last drip                                  [unix epoch time]
        uint256 pad;     // Base Rate spread over SSR, annual nominal          [ray]
        uint256 tip;     // agent-rate spread over SSR, annual nominal         [ray]
        uint256 cut;     // subsidised Base Rate, annual nominal               [ray]
        uint256 line;    // debt charged at `cut` (subsidy cap), 0 = no subsidy [wad]
    }

    // Accruals since the last settle, carries, and the balances last seen.
    struct Book {
        uint256 tab;    // Base Rate charge                                    [wad]
        uint256 owe;    // demand side owed to the prime (agent rate, gifts, unpaid send) [wad]
        int256  gain;   // prime mark-to-market                                [wad]
        int256  sde;    // Sky-direct mark-to-market, incl. carried Sky share  [wad]
        uint256 rebate; // rebates to the prime (sUSDS spread, idle BR)        [wad]
        uint256 sin;    // negative prime supply share carried forward         [wad]
        uint256 art;    // ilk debt at last drip                               [wad]
        uint256 usd;    // SubProxy USDS at last drip                          [wad]
        uint256 sus;    // SubProxy sUSDS value at last drip                   [wad]
    }

    struct Gem {
        address pip;   // pricing adapter
        address who;   // holder override, 0 = ilk.alm
        uint8   tag;   // MTM, SDE, SAV, IDL or NIL
        uint256 fee;   // redemption haircut on vault value                    [wad] (1e16 = 1%)
        uint256 cap;   // SDE only: Sky's capped slice, 0 = whole position     [wad]
        uint256 rho;   // time of last poke                                    [unix epoch time]
        uint256 chi;   // net price per 1e18 shares at last poke              [ray]
        uint256 pie;   // shares at last poke                                  [wad]
        uint256 own;   // queued assets at last poke                           [wad]
    }

    mapping (bytes32 => Ilk)                       public ilks;
    mapping (bytes32 => Book)                      public books;
    mapping (bytes32 => mapping (address => Gem))  public gems;
    mapping (bytes32 => address[])                 public list;

    VatLike   public immutable vat;
    address   public immutable vow;   // surplus buffer
    JoinLike  public immutable join;  // UsdsJoin
    GemLike   public immutable usds;
    SusdsLike public immutable susds;

    uint256 public live;

    uint256 constant WAD  = 10 ** 18;
    uint256 constant RAY  = 10 ** 27;
    uint256 constant YEAR = 365 days;

    // --- Events ---
    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event Init(bytes32 indexed ilk, address alm, address sub);
    event Init(bytes32 indexed ilk, address indexed gem, address pip, uint8 tag);
    event File(bytes32 indexed ilk, bytes32 indexed what, uint256 data);
    event File(bytes32 indexed ilk, bytes32 indexed what, address data);
    event File(bytes32 indexed ilk, address indexed gem, bytes32 indexed what, uint256 data);
    event File(bytes32 indexed ilk, address indexed gem, bytes32 indexed what, address data);
    event Drip(bytes32 indexed ilk, uint256 debt, uint256 fee, uint256 agentRate);
    event Poke(bytes32 indexed ilk, address indexed gem, uint256 pie, uint256 chi, uint256 own, uint256 val, int256 dpnl);
    event Gift(bytes32 indexed ilk, uint256 wad);
    event Settle(bytes32 indexed ilk, int256 sky, int256 sv, uint256 dv, uint256 mint, uint256 drew, uint256 send, uint256 paid, uint256 kept);
    event Quit(address indexed gem, address indexed dst, uint256 wad);
    event Cage();

    // --- Init ---
    constructor(address vat_, address vow_, address join_, address usds_, address susds_) {
        vat   = VatLike(vat_);
        vow   = vow_;
        join  = JoinLike(join_);
        usds  = GemLike(usds_);
        susds = SusdsLike(susds_);
        live  = 1;
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
        // The join burns from us when we credit the surplus buffer.
        usds.approve(join_, type(uint256).max);
    }

    // --- Math ---
    function _rmul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x * y / RAY;
    }
    function _wmul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x * y / WAD;
    }
    function _min(uint256 x, uint256 y) internal pure returns (uint256) {
        return x <= y ? x : y;
    }
    function _max(uint256 x, uint256 y) internal pure returns (uint256) {
        return x >= y ? x : y;
    }
    function _max(int256 x, int256 y) internal pure returns (int256) {
        return x >= y ? x : y;
    }
    // whole USDS
    function _whole(uint256 wad) internal pure returns (uint256) {
        return wad / WAD * WAD;
    }
    // annual nominal rate [ray] -> per-second nominal rate [ray]
    function _ps(uint256 annual) internal pure returns (uint256) {
        return annual / YEAR;
    }
    // value of a mark
    function _val(uint256 pie, uint256 chi, uint256 own) internal pure returns (uint256) {
        return _rmul(pie, chi) + own;
    }
    // Jug's rpow.
    function _rpow(uint256 x, uint256 n, uint256 b) internal pure returns (uint256 z) {
        assembly {
            switch x case 0 {switch n case 0 {z := b} default {z := 0}}
            default {
                switch mod(n, 2) case 0 { z := b } default { z := x }
                let half := div(b, 2)  // for rounding.
                for { n := div(n, 2) } n { n := div(n,2) } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) { revert(0,0) }
                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) { revert(0,0) }
                    x := div(xxRound, b)
                    if mod(n,2) {
                        let zx := mul(z, x)
                        if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0,0) }
                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) { revert(0,0) }
                        z := div(zxRound, b)
                    }
                }
            }
        }
    }

    // --- Administration ---
    function init(bytes32 ilk, address alm, address sub) external auth {
        require(ilks[ilk].alm == address(0), "Tally/ilk-already-init");
        ilks[ilk].alm = alm;
        ilks[ilk].sub = sub;
        ilks[ilk].rho = block.timestamp;
        _seed(ilk);
        emit Init(ilk, alm, sub);
    }

    function init(bytes32 ilk, address gem, address pip, uint8 tag) external auth {
        require(ilks[ilk].alm != address(0), "Tally/ilk-not-init");
        require(gems[ilk][gem].tag == 0, "Tally/gem-already-init");
        require(tag >= MTM && tag <= NIL, "Tally/bad-tag");
        Gem storage g = gems[ilk][gem];
        g.pip = pip;
        g.tag = tag;
        g.rho = block.timestamp;
        list[ilk].push(gem);
        // Seed the index so the first real poke books no phantom PnL.
        (g.pie, g.chi, g.own) = _read(ilk, gem);
        emit Init(ilk, gem, pip, tag);
    }

    // Rate parameters. Requires a drip AND a poke of every gem in this block,
    // so no open interval (Base Rate, agent rate, SAV / IDL rebates) is
    // re-priced retroactively.
    function file(bytes32 ilk, bytes32 what, uint256 data) external auth {
        require(live == 1, "Tally/not-live");
        require(block.timestamp == ilks[ilk].rho, "Tally/rho-not-updated");
        address[] storage l = list[ilk];
        for (uint256 k = 0; k < l.length; k++) {
            require(block.timestamp == gems[ilk][l[k]].rho, "Tally/gem-rho-not-updated");
        }
        if      (what == "pad")  ilks[ilk].pad  = data;
        else if (what == "tip")  ilks[ilk].tip  = data;
        else if (what == "cut")  ilks[ilk].cut  = data;
        else if (what == "line") ilks[ilk].line = data;
        else revert("Tally/file-unrecognized-param");
        emit File(ilk, what, data);
    }

    function file(bytes32 ilk, bytes32 what, address data) external auth {
        require(live == 1, "Tally/not-live");
        if      (what == "alm")    ilks[ilk].alm    = data;
        else if (what == "vault")  ilks[ilk].vault  = data;
        else if (what == "buffer") ilks[ilk].buffer = data;
        else if (what == "sub") {
            // Drip first so the old SubProxy's interval is credited to it.
            require(block.timestamp == ilks[ilk].rho, "Tally/rho-not-updated");
            ilks[ilk].sub = data;
            _seed(ilk);
        }
        else revert("Tally/file-unrecognized-param");
        emit File(ilk, what, data);
    }

    // Gem parameters. Every change re-bases the gem: poke first so the open
    // interval is booked under the old parameters, then re-seed the mark so
    // the change itself is never booked as PnL or re-routed.
    function file(bytes32 ilk, address gem, bytes32 what, uint256 data) external auth {
        require(live == 1, "Tally/not-live");
        Gem storage g = gems[ilk][gem];
        require(g.tag != 0, "Tally/gem-not-init");
        require(block.timestamp == g.rho, "Tally/rho-not-updated");
        if (what == "fee") {
            require(data <= WAD, "Tally/fee-too-high");
            g.fee = data;
        }
        else if (what == "cap") g.cap = data;
        else if (what == "tag") { require(data >= MTM && data <= NIL, "Tally/bad-tag"); g.tag = uint8(data); }
        else revert("Tally/file-unrecognized-param");
        (g.pie, g.chi, g.own) = _read(ilk, gem);
        emit File(ilk, gem, what, data);
    }

    function file(bytes32 ilk, address gem, bytes32 what, address data) external auth {
        require(live == 1, "Tally/not-live");
        Gem storage g = gems[ilk][gem];
        require(g.tag != 0, "Tally/gem-not-init");
        require(block.timestamp == g.rho, "Tally/rho-not-updated");
        if      (what == "pip") g.pip = data;
        else if (what == "who") g.who = data;
        else revert("Tally/file-unrecognized-param");
        (g.pie, g.chi, g.own) = _read(ilk, gem);
        emit File(ilk, gem, what, data);
    }

    /// @notice Credit an off-chain demand-side amount (e.g. Distribution
    ///         Rewards) to be paid at the next settle. The hybrid hook.
    function gift(bytes32 ilk, uint256 wad) external auth {
        require(live == 1, "Tally/not-live");
        books[ilk].owe += wad;
        emit Gift(ilk, wad);
    }

    /// @notice Move tokens out (the USDS float, a mistaken transfer). Works
    ///         after `cage`, so nothing is ever stranded here.
    function quit(address gem, address dst, uint256 wad) external auth {
        require(GemLike(gem).transfer(dst, wad), "Tally/transfer-failed");
        emit Quit(gem, dst, wad);
    }

    function cage() external auth {
        live = 0;
        emit Cage();
    }

    // --- Rates ---

    /// @notice SSR as a per-second NOMINAL rate at daily compounding [ray]:
    ///         `(ssr^86400 - 1) / 86400`. Summed over a day this is exactly
    ///         the day's slice of the SSR APY, i.e. `n = 365` in the MSC's
    ///         APY -> APR conversion, matching daily capitalisation.
    function ssrps() public view returns (uint256) {
        return (_rpow(susds.ssr(), 1 days, RAY) - RAY) / 1 days;
    }

    /// @notice Base Rate, per-second nominal [ray].
    function duty(bytes32 ilk) public view returns (uint256) {
        return ssrps() + _ps(ilks[ilk].pad);
    }

    /// @notice Rate paid on the marginal unit of debt `d`: `cut` inside the
    ///         subsidy cap, the full Base Rate above it [ray, per second].
    function _marginal(bytes32 ilk, uint256 d, uint256 sps) internal view returns (uint256) {
        Ilk storage i = ilks[ilk];
        return (i.line > 0 && d <= i.line) ? _ps(i.cut) : sps + _ps(i.pad);
    }

    /// @notice Ilk debt read from the Vat, `Art * rate` [wad]: the MSC's `cum_debt`.
    function debt(bytes32 ilk) public view returns (uint256) {
        (uint256 Art, uint256 rate,,,) = vat.ilks(ilk);
        return _rmul(Art, rate);
    }

    /// @notice How much more the ilk can draw today [wad]: the tighter of the
    ///         ilk ceiling and the global ceiling, less one USDS for the
    ///         vault's round-up.
    function room(bytes32 ilk) public view returns (uint256) {
        (uint256 Art, uint256 rate,, uint256 line,) = vat.ilks(ilk);
        uint256 d = Art * rate;
        uint256 a = line > d ? (line - d) / RAY : 0;
        uint256 L = vat.Line(); uint256 D = vat.debt();
        uint256 b = L > D ? (L - D) / RAY : 0;
        uint256 r = _min(a, b);
        return r > WAD ? r - WAD : 0;
    }

    // Remember the balances an accrual is sampled against.
    function _seed(bytes32 ilk) internal {
        Book storage b = books[ilk];
        address sub = ilks[ilk].sub;
        b.art = debt(ilk);
        b.usd = usds.balanceOf(sub);
        uint256 s = susds.balanceOf(sub);
        b.sus = s > 0 ? susds.convertToAssets(s) : 0;
    }

    // --- Sky side ---

    /// @notice Accrue the Base Rate charge and the agent rate since the last
    ///         drip, then re-sample the balances. Calling `drip` in the same
    ///         block as a draw, wipe or SubProxy transfer (before it) makes
    ///         the accrual exact; the samples are always refreshed so a
    ///         drip-then-move sequence starts the next interval on the
    ///         post-move balance.
    function drip(bytes32 ilk) public {
        Ilk  storage i = ilks[ilk];
        Book storage b = books[ilk];
        require(i.alm != address(0), "Tally/ilk-not-init");
        uint256 dt = block.timestamp - i.rho;

        uint256 d  = debt(ilk);
        uint256 u  = usds.balanceOf(i.sub);
        uint256 s  = susds.balanceOf(i.sub);
        uint256 sv = s > 0 ? susds.convertToAssets(s) : 0;

        if (dt > 0) {
            uint256 sps = ssrps();

            // Base Rate on the larger of the debt at both ends, subsidised up to `line`.
            uint256 base = _max(d, b.art);
            uint256 fee;
            if (i.line > 0) {
                uint256 lo = _min(base, i.line);
                fee = _rmul(lo, _ps(i.cut) * dt) + _rmul(base - lo, (sps + _ps(i.pad)) * dt);
            } else {
                fee = _rmul(base, (sps + _ps(i.pad)) * dt);
            }
            b.tab += fee;

            // Agent rate on the smaller of the SubProxy balances at both ends:
            // USDS earns SSR + tip, sUSDS earns tip (the SSR already arrives
            // through the share price).
            uint256 ar = _rmul(_min(u, b.usd), (sps + _ps(i.tip)) * dt)
                       + _rmul(_min(sv, b.sus), _ps(i.tip) * dt);
            b.owe += ar;

            i.rho = block.timestamp;
            emit Drip(ilk, d, fee, ar);
        }

        b.art = d;
        b.usd = u;
        b.sus = sv;
    }

    // --- Positions ---

    function _read(bytes32 ilk, address gem) internal view returns (uint256 pie, uint256 chi, uint256 own) {
        Gem storage g = gems[ilk][gem];
        address who = g.who == address(0) ? ilks[ilk].alm : g.who;
        (pie, chi, own) = PipLike(g.pip).peek(who);
        chi = _wmul(chi, WAD - g.fee);
    }

    /// @notice Mark one position and route the index move by tag.
    function poke(bytes32 ilk, address gem) public returns (uint256 val) {
        Gem  storage g = gems[ilk][gem];
        Book storage b = books[ilk];
        require(g.tag != 0, "Tally/gem-not-init");

        (uint256 pie, uint256 chi, uint256 own) = _read(ilk, gem);
        val = _val(pie, chi, own);
        uint256 was = _val(g.pie, g.chi, g.own);

        // PnL on the shares carried through the interval, at the new index.
        int256 dpnl = int256(_rmul(g.pie, chi)) - int256(_rmul(g.pie, g.chi));

        if (g.tag == MTM) {
            b.gain += dpnl;
        } else if (g.tag == SDE) {
            // Sky's share of the move: the whole position, or the capped
            // slice of the value the move was measured on.
            uint256 share = g.cap == 0 ? WAD : (was == 0 ? 0 : _min(WAD, g.cap * WAD / was));
            int256 s = dpnl * int256(share) / int256(WAD);
            b.sde  += s;
            b.gain += dpnl - s;
        } else if (g.tag == SAV) {
            // SSR appreciation stays in the token and is not revenue; Sky
            // charges BR on it, so the spread is rebated for neutrality.
            b.rebate += _rmul(_min(val, was), _ps(ilks[ilk].pad) * (block.timestamp - g.rho));
        } else if (g.tag == IDL) {
            // Not utilized (idle USDS, PSM3 USDS leg...): the Base Rate
            // charged on it in `drip` is handed back at the rate the
            // marginal unit of debt pays. Bounded by `tab` at settle.
            b.rebate += _rmul(_min(val, was), _marginal(ilk, b.art, ssrps()) * (block.timestamp - g.rho));
        }
        // NIL: tracked, nothing booked.

        g.pie = pie;
        g.chi = chi;
        g.own = own;
        g.rho = block.timestamp;
        emit Poke(ilk, gem, pie, chi, own, val, dpnl);
    }

    /// @notice Mark every position of an ilk. Returns the ilk NAV.
    function poke(bytes32 ilk) public returns (uint256 tot) {
        address[] storage l = list[ilk];
        for (uint256 k = 0; k < l.length; k++) {
            tot += poke(ilk, l[k]);
        }
    }

    // --- Settlement ---

    struct Day {
        int256  sky;   // Sky share
        int256  sv;    // prime supply share
        uint256 dv;    // demand side
        uint256 up;    // max(sv, 0)
        uint256 mint;  // whole USDS to draw
        uint256 drew;  // actually drawn within the ceiling
        uint256 send;  // whole USDS owed to the SubProxy today
        uint256 paid;  // actually paid
        uint256 kept;  // Sky's net, joined to the surplus buffer
    }

    /// @notice Run the day: accrue, mark, and execute the MSC identity in whole USDS.
    function settle(bytes32 ilk) external {
        require(live == 1, "Tally/not-live");
        drip(ilk);
        poke(ilk);

        Book storage b = books[ilk];
        Day memory d;

        // A rebate hands back Base Rate that was charged; never more.
        uint256 rebate = _min(b.rebate, b.tab);

        d.sky = int256(b.tab) + b.sde - int256(rebate);
        d.sv  = b.gain + int256(rebate) - int256(b.tab) - int256(b.sin);
        d.dv  = b.owe;

        // The demand side is always owed; a supply loss is carried against
        // future supply gains only, never netted against the demand side.
        d.up   = d.sv > 0 ? uint256(d.sv) : 0;
        d.send = _whole(d.dv + d.up);

        // Whole USDS today; fractions and a negative Sky share carry forward.
        int256 mint_ = d.sky + int256(d.up);
        int256 carry;
        if (mint_ < 0) { carry = mint_; }
        else { d.mint = _whole(uint256(mint_)); carry = mint_ - int256(d.mint); }

        d.drew = _draw(ilk, d.mint);
        carry += int256(d.mint - d.drew);

        b.tab = 0; b.gain = 0; b.rebate = 0;
        b.sde = carry;
        b.sin = d.sv < 0 ? uint256(-d.sv) : 0;
        b.owe = (d.dv + d.up) - d.send;

        // Send: pay the SubProxy from the fresh draw, then from any USDS
        // governance keeps here; whatever cannot be paid is owed.
        d.paid = _min(d.send, usds.balanceOf(address(this)));
        if (d.paid > 0) require(usds.transfer(ilks[ilk].sub, d.paid), "Tally/transfer-failed");
        b.owe += d.send - d.paid;

        // Keep: Sky's net goes to the surplus buffer.
        d.kept = d.drew > d.send ? d.drew - d.send : 0;
        if (d.kept > 0) join.join(vow, d.kept);

        emit Settle(ilk, d.sky, d.sv, d.dv, d.mint, d.drew, d.send, d.paid, d.kept);
    }

    // Draw `mint` as new ilk debt through the prime's allocator stack, within
    // today's ceiling headroom, and pull it here. Returns what was drawn.
    function _draw(bytes32 ilk, uint256 mint) internal returns (uint256 drew) {
        if (mint == 0) return 0;
        Ilk storage i = ilks[ilk];
        require(i.vault != address(0) && i.buffer != address(0), "Tally/vault-not-set");
        drew = _whole(_min(mint, room(ilk)));
        if (drew > 0) {
            VaultLike(i.vault).draw(drew);
            require(usds.transferFrom(i.buffer, address(this), drew), "Tally/transfer-failed");
        }
    }

    // --- Views ---

    function value(bytes32 ilk, address gem) external view returns (uint256) {
        require(gems[ilk][gem].tag != 0, "Tally/gem-not-init");
        (uint256 pie, uint256 chi, uint256 own) = _read(ilk, gem);
        return _val(pie, chi, own);
    }

    function nav(bytes32 ilk) external view returns (uint256 tot) {
        address[] storage l = list[ilk];
        for (uint256 k = 0; k < l.length; k++) {
            (uint256 pie, uint256 chi, uint256 own) = _read(ilk, l[k]);
            tot += _val(pie, chi, own);
        }
    }

    function count(bytes32 ilk) external view returns (uint256) {
        return list[ilk].length;
    }
}
