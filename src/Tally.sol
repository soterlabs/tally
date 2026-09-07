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
}

// dss-allocator
interface VaultLike {
    function draw(uint256 wad) external;
}
interface BufferLike {
    function withdraw(address asset, address destination, uint256 amount) external;
}

interface JoinLike {
    function join(address usr, uint256 wad) external;
}

interface GemLike {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
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
 *             send = owe + sv                     paid to the SubProxy
 *
 *           `mint` is `AllocatorVault.draw` into the AllocatorBuffer and
 *           withdrawn here; `send` is paid from it, and what is left
 *           (`mint - send`, Sky's net) is joined to the surplus buffer.
 *           When `send` exceeds `mint`, the difference is paid from USDS
 *           this contract holds (funded by governance) and otherwise
 *           carried. No Vat privileges are needed: only the prime-scoped
 *           AllocatorVault / AllocatorBuffer roles the ALM already has.
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
        uint256 cut;     // subsidised Base Rate, annual nominal, 0 = none     [ray]
        uint256 line;    // debt charged at `cut` (subsidy cap), 0 = none      [wad]
    }

    // Accruals since the last settle, plus carries.
    struct Book {
        uint256 tab;    // Base Rate charge                                    [wad]
        uint256 owe;    // demand side owed to the prime (agent rate, gifts, unpaid send) [wad]
        int256  gain;   // prime mark-to-market                                [wad]
        int256  sde;    // Sky-direct mark-to-market, incl. carried Sky share  [wad]
        uint256 rebate; // rebates to the prime (sUSDS spread, idle BR)        [wad]
        uint256 sin;    // negative prime share carried forward                [wad]
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
    event Settle(bytes32 indexed ilk, int256 sky, int256 sv, uint256 dv, uint256 mint, uint256 send, uint256 paid, uint256 kept);
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

    function file(bytes32 ilk, bytes32 what, uint256 data) external auth {
        require(live == 1, "Tally/not-live");
        // Rate changes must not apply retroactively: drip first.
        require(block.timestamp == ilks[ilk].rho, "Tally/rho-not-updated");
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
        else if (what == "sub")    ilks[ilk].sub    = data;
        else if (what == "vault")  ilks[ilk].vault  = data;
        else if (what == "buffer") ilks[ilk].buffer = data;
        else revert("Tally/file-unrecognized-param");
        emit File(ilk, what, data);
    }

    function file(bytes32 ilk, address gem, bytes32 what, uint256 data) external auth {
        require(live == 1, "Tally/not-live");
        Gem storage g = gems[ilk][gem];
        require(g.tag != 0, "Tally/gem-not-init");
        if (what == "fee") {
            require(data <= WAD, "Tally/fee-too-high");
            // Poke first so the haircut change itself is not booked as PnL.
            require(block.timestamp == g.rho, "Tally/rho-not-updated");
            g.fee = data;
            (g.pie, g.chi, g.own) = _read(ilk, gem);
        }
        else if (what == "cap") g.cap = data;
        else if (what == "tag") { require(data >= MTM && data <= NIL, "Tally/bad-tag"); g.tag = uint8(data); }
        else revert("Tally/file-unrecognized-param");
        emit File(ilk, gem, what, data);
    }

    function file(bytes32 ilk, address gem, bytes32 what, address data) external auth {
        require(live == 1, "Tally/not-live");
        Gem storage g = gems[ilk][gem];
        require(g.tag != 0, "Tally/gem-not-init");
        if      (what == "pip") g.pip = data;
        else if (what == "who") g.who = data;
        else revert("Tally/file-unrecognized-param");
        emit File(ilk, gem, what, data);
    }

    /// @notice Credit an off-chain demand-side amount (e.g. Distribution
    ///         Rewards) to be paid at the next settle. The hybrid hook.
    function gift(bytes32 ilk, uint256 wad) external auth {
        require(live == 1, "Tally/not-live");
        books[ilk].owe += wad;
        emit Gift(ilk, wad);
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

    /// @notice Ilk debt read from the Vat, `Art * rate` [wad]: the MSC's `cum_debt`.
    function debt(bytes32 ilk) public view returns (uint256) {
        (uint256 Art, uint256 rate,,,) = vat.ilks(ilk);
        return _rmul(Art, rate);
    }

    // --- Sky side ---

    /// @notice Accrue the Base Rate charge and the agent rate since the last drip.
    function drip(bytes32 ilk) public {
        Ilk  storage i = ilks[ilk];
        Book storage b = books[ilk];
        require(i.alm != address(0), "Tally/ilk-not-init");
        require(block.timestamp >= i.rho, "Tally/invalid-now");
        uint256 dt = block.timestamp - i.rho;
        if (dt == 0) return;

        // Base Rate on the ilk debt, subsidised up to `line`.
        uint256 d   = debt(ilk);
        uint256 fee;
        if (i.line > 0 && i.cut > 0) {
            uint256 lo = _min(d, i.line);
            fee = _rmul(lo, _ps(i.cut) * dt) + _rmul(d - lo, duty(ilk) * dt);
        } else {
            fee = _rmul(d, duty(ilk) * dt);
        }
        b.tab += fee;

        // Agent rate on the SubProxy: USDS earns SSR + tip, sUSDS earns tip
        // (the SSR already arrives through the share price).
        uint256 s   = susds.balanceOf(i.sub);
        uint256 ar  = _rmul(usds.balanceOf(i.sub), (ssrps() + _ps(i.tip)) * dt)
                    + (s > 0 ? _rmul(susds.convertToAssets(s), _ps(i.tip) * dt) : 0);
        b.owe += ar;

        i.rho = block.timestamp;
        emit Drip(ilk, d, fee, ar);
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
        val = _rmul(pie, chi) + own;

        // PnL on the shares carried through the interval, at the new index.
        int256 dpnl = int256(_rmul(g.pie, chi)) - int256(_rmul(g.pie, g.chi));

        if (g.tag == MTM) {
            b.gain += dpnl;
        } else if (g.tag == SDE) {
            // Sky's share: whole position, or the capped slice of today's value.
            uint256 share = (g.cap == 0 || val == 0) ? WAD : _min(WAD, g.cap * WAD / val);
            int256 s = dpnl * int256(share) / int256(WAD);
            b.sde  += s;
            b.gain += dpnl - s;
        } else if (g.tag == SAV) {
            // SSR appreciation stays in the token and is not revenue; Sky
            // charges BR on it, so the spread is rebated for neutrality.
            b.rebate += _rmul(val, _ps(ilks[ilk].pad) * (block.timestamp - g.rho));
        } else if (g.tag == IDL) {
            // Not utilized (idle USDS, PSM3 USDS leg...): the Base Rate
            // charged on it in `drip` is rebated. Priced at the marginal
            // (unsubsidised) rate, exact while idle <= debt - line.
            b.rebate += _rmul(val, duty(ilk) * (block.timestamp - g.rho));
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

    /// @notice Run the day: accrue, mark, and execute the MSC identity in whole USDS.
    function settle(bytes32 ilk) external {
        require(live == 1, "Tally/not-live");
        drip(ilk);
        poke(ilk);

        Ilk  storage i = ilks[ilk];
        Book storage b = books[ilk];

        int256  sky = int256(b.tab) + b.sde - int256(b.rebate);
        int256  sv  = b.gain + int256(b.rebate) - int256(b.tab) - int256(b.sin);
        uint256 dv  = b.owe;

        int256 mint_ = sky + _max(sv, 0);
        int256 send_ = int256(dv) + sv;

        // Whole USDS today; fractions and anything negative carry forward.
        uint256 mint; uint256 send; int256 carry; uint256 owe; uint256 sin;
        if (mint_ < 0) { carry = mint_; }
        else { mint = _whole(uint256(mint_)); carry = mint_ - int256(mint); }
        if (send_ < 0) { sin = uint256(-send_); }
        else { send = _whole(uint256(send_)); owe = uint256(send_) - send; }

        b.tab = 0; b.gain = 0; b.rebate = 0;
        b.sde = carry;
        b.owe = owe;
        b.sin = sin;

        // Mint: draw the Sky share (and the prime's positive share) as new
        // ilk debt through the prime's own allocator stack.
        if (mint > 0) {
            VaultLike(i.vault).draw(mint);
            BufferLike(i.buffer).withdraw(address(usds), address(this), mint);
        }

        // Send: pay the SubProxy from the fresh mint, then from any USDS
        // governance has left here; whatever cannot be paid is owed.
        uint256 paid = _min(send, usds.balanceOf(address(this)));
        if (paid > 0) usds.transfer(i.sub, paid);
        if (send > paid) b.owe += send - paid;

        // Keep: Sky's net goes to the surplus buffer.
        uint256 kept = mint > send ? mint - send : 0;
        if (kept > 0) join.join(vow, kept);

        emit Settle(ilk, sky, sv, dv, mint, send, paid, kept);
    }

    // --- Views ---

    function value(bytes32 ilk, address gem) external view returns (uint256) {
        require(gems[ilk][gem].tag != 0, "Tally/gem-not-init");
        (uint256 pie, uint256 chi, uint256 own) = _read(ilk, gem);
        return _rmul(pie, chi) + own;
    }

    function nav(bytes32 ilk) external view returns (uint256 tot) {
        address[] storage l = list[ilk];
        for (uint256 k = 0; k < l.length; k++) {
            (uint256 pie, uint256 chi, uint256 own) = _read(ilk, l[k]);
            tot += _rmul(pie, chi) + own;
        }
    }

    function count(bytes32 ilk) external view returns (uint256) {
        return list[ilk].length;
    }
}
