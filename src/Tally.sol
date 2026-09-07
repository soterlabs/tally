// SPDX-License-Identifier: AGPL-3.0-or-later

/// Tally.sol -- daily settlement cycle for one Sky allocator ilk

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
 * @notice Daily Settlement Cycle (DSC) for one Sky allocator ilk.
 *
 *         One instance per ilk (e.g. ALLOCATOR-SPARK-A). It points at an
 *         ALM Proxy (`alm`, whose positions are marked), a SubProxy (`sub`,
 *         paid at settle; when `pay` is set its idle USDS / sUSDS earn the
 *         agent rate), and the prime's AllocatorVault / AllocatorBuffer
 *         (through which the Sky share is drawn as new ilk debt). A prime
 *         with several ilks deploys several instances that share `sub` and
 *         sets `pay` on exactly one of them.
 *
 *         Jug-style, anyone can advance the clocks:
 *
 *         - `drip()` accrues the Sky side. The Base Rate charge over the
 *           interval is `debt * (dchi + pad * dt)`, where `dchi` is the
 *           growth of the sUSDS share price since the last drip (the SSR,
 *           compounded per second by sUSDS itself, so every SP-BEAM change
 *           inside the interval is priced exactly) and `pad` is the
 *           governance spread. Also accrues the agent rate on the SubProxy
 *           and the sUSDS-spread / idle rebates on tagged positions.
 *
 *           Balances are sampled, not integrated, so every accrual is
 *           taken on the balance that is WORSE for the prime over the
 *           interval: the larger of the debt at the two ends, the smaller
 *           of the SubProxy / rebated balances at the two ends. A prime
 *           that drips before it draws, wipes or moves funds is charged
 *           and credited exactly; one that does not pays for the interval
 *           at the higher balance. Nothing the prime does can under-charge
 *           Sky.
 *
 *         - `poke(gem)` marks a position through its `pip` adapter and
 *           books `pie * (chi_new - chi_old)` as gain or loss. PnL is taken
 *           on the index, so relayer deposits and withdrawals between
 *           pokes are flows, not revenue. Each gem carries a `tag`: prime
 *           mark-to-market, Sky direct exposure, Sky savings token, idle,
 *           or position-only.
 *
 *         - `settle()` does both, then executes the MSC identity in whole
 *           USDS:
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
 *         `pad`, `tip`, `cut` are NOMINAL annual rates applied as
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

    struct Gem {
        address pip;   // pricing adapter
        address who;   // holder override, 0 = alm
        uint8   tag;   // MTM, SDE, SAV, IDL or NIL
        uint256 fee;   // redemption haircut on vault value                    [wad] (1e16 = 1%)
        uint256 cap;   // SDE only: Sky's capped slice, 0 = whole position     [wad]
        uint256 rho;   // time of last poke                                    [unix epoch time]
        uint256 chi;   // net price per 1e18 shares at last poke              [ray]
        uint256 pie;   // shares at last poke                                  [wad]
        uint256 own;   // queued assets at last poke                           [wad]
    }

    // System
    bytes32   public immutable ilk;
    VatLike   public immutable vat;
    address   public immutable vow;    // surplus buffer
    JoinLike  public immutable join;   // UsdsJoin
    GemLike   public immutable usds;
    SusdsLike public immutable susds;

    // Prime
    address public alm;      // ALM Proxy: default holder of the gems
    address public sub;      // SubProxy: paid at settle
    address public vault;    // AllocatorVault: draws the mint as ilk debt
    address public buffer;   // AllocatorBuffer: where the vault delivers USDS
    uint256 public pay;      // 1 if this ilk carries the prime's demand side (agent rate, gifts)

    // Rates
    uint256 public pad;      // Base Rate spread over SSR, annual nominal          [ray]
    uint256 public tip;      // agent-rate spread over SSR, annual nominal         [ray]
    uint256 public cut;      // subsidised Base Rate, annual nominal               [ray]
    uint256 public line;     // debt charged at `cut` (subsidy cap), 0 = no subsidy [wad]

    // Book: accruals since the last settle and carries
    uint256 public tab;      // Base Rate charge                                    [wad]
    uint256 public owe;      // demand side owed to the prime (agent rate, gifts, unpaid send) [wad]
    int256  public gain;     // prime mark-to-market                                [wad]
    int256  public sde;      // Sky-direct mark-to-market, incl. carried Sky share  [wad]
    uint256 public rebate;   // rebates to the prime (sUSDS spread, idle BR)        [wad]
    uint256 public sin;      // negative prime supply share carried forward         [wad]

    // Samples at last drip
    uint256 public rho;      // time                                                [unix epoch time]
    uint256 public chi;      // sUSDS share price, the SSR index                    [wad]
    uint256 public art;      // ilk debt                                            [wad]
    uint256 public usd;      // SubProxy USDS                                       [wad]
    uint256 public sus;      // SubProxy sUSDS value                                [wad]

    mapping (address => Gem) public gems;
    address[]                public list;

    uint256 public live;

    uint256 constant WAD  = 10 ** 18;
    uint256 constant RAY  = 10 ** 27;
    uint256 constant YEAR = 365 days;

    // --- Events ---
    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event Init(address indexed gem, address pip, uint8 tag);
    event File(bytes32 indexed what, uint256 data);
    event File(bytes32 indexed what, address data);
    event File(address indexed gem, bytes32 indexed what, uint256 data);
    event File(address indexed gem, bytes32 indexed what, address data);
    event Drip(uint256 debt, uint256 dchi, uint256 fee, uint256 agentRate, uint256 rebates);
    event Poke(address indexed gem, uint256 pie, uint256 chi, uint256 own, uint256 val, int256 dpnl);
    event Gift(uint256 wad);
    event Settle(int256 sky, int256 sv, uint256 dv, uint256 mint, uint256 drew, uint256 send, uint256 paid, uint256 kept);
    event Quit(address indexed gem, address indexed dst, uint256 wad);
    event Cage();

    // --- Init ---
    constructor(bytes32 ilk_, address vat_, address vow_, address join_, address usds_, address susds_) {
        ilk   = ilk_;
        vat   = VatLike(vat_);
        vow   = vow_;
        join  = JoinLike(join_);
        usds  = GemLike(usds_);
        susds = SusdsLike(susds_);
        live  = 1;
        rho   = block.timestamp;
        chi   = susds.convertToAssets(WAD);
        art   = debt();
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
    // whole USDS
    function _whole(uint256 wad) internal pure returns (uint256) {
        return wad / WAD * WAD;
    }
    // annual nominal rate [ray] -> per-second nominal rate [ray]
    function _ps(uint256 annual) internal pure returns (uint256) {
        return annual / YEAR;
    }
    // value of a mark
    function _val(uint256 pie, uint256 chi_, uint256 own) internal pure returns (uint256) {
        return _rmul(pie, chi_) + own;
    }

    // --- Administration ---

    function init(address gem, address pip, uint8 tag) external auth {
        require(live == 1, "Tally/not-live");
        require(gems[gem].tag == 0, "Tally/gem-already-init");
        require(tag >= MTM && tag <= NIL, "Tally/bad-tag");
        Gem storage g = gems[gem];
        g.pip = pip;
        g.tag = tag;
        g.rho = block.timestamp;
        list.push(gem);
        // Seed the index so the first real poke books no phantom PnL.
        (g.pie, g.chi, g.own) = _read(gem);
        emit Init(gem, pip, tag);
    }

    // Rate parameters and the demand-side flag. Requires a drip AND a poke of
    // every gem in this block, so no open interval is re-priced retroactively.
    function file(bytes32 what, uint256 data) external auth {
        require(live == 1, "Tally/not-live");
        require(block.timestamp == rho, "Tally/rho-not-updated");
        for (uint256 k = 0; k < list.length; k++) {
            require(block.timestamp == gems[list[k]].rho, "Tally/gem-rho-not-updated");
        }
        if      (what == "pad")  pad  = data;
        else if (what == "tip")  tip  = data;
        else if (what == "cut")  cut  = data;
        else if (what == "line") line = data;
        else if (what == "pay")  { require(data <= 1, "Tally/bad-flag"); pay = data; }
        else revert("Tally/file-unrecognized-param");
        emit File(what, data);
    }

    function file(bytes32 what, address data) external auth {
        require(live == 1, "Tally/not-live");
        if      (what == "alm")    alm    = data;
        else if (what == "vault")  vault  = data;
        else if (what == "buffer") buffer = data;
        else if (what == "sub") {
            // Drip first so the old SubProxy's interval is credited to it.
            require(block.timestamp == rho, "Tally/rho-not-updated");
            sub = data;
            (usd, sus) = _subs();
        }
        else revert("Tally/file-unrecognized-param");
        emit File(what, data);
    }

    // Gem parameters. Every change re-bases the gem: poke first so the open
    // interval is booked under the old parameters, then re-seed the mark so
    // the change itself is never booked as PnL or re-routed.
    function file(address gem, bytes32 what, uint256 data) external auth {
        require(live == 1, "Tally/not-live");
        Gem storage g = gems[gem];
        require(g.tag != 0, "Tally/gem-not-init");
        require(block.timestamp == g.rho, "Tally/rho-not-updated");
        if (what == "fee") {
            require(data <= WAD, "Tally/fee-too-high");
            g.fee = data;
        }
        else if (what == "cap") g.cap = data;
        else if (what == "tag") { require(data >= MTM && data <= NIL, "Tally/bad-tag"); g.tag = uint8(data); }
        else revert("Tally/file-unrecognized-param");
        (g.pie, g.chi, g.own) = _read(gem);
        emit File(gem, what, data);
    }

    function file(address gem, bytes32 what, address data) external auth {
        require(live == 1, "Tally/not-live");
        Gem storage g = gems[gem];
        require(g.tag != 0, "Tally/gem-not-init");
        require(block.timestamp == g.rho, "Tally/rho-not-updated");
        if      (what == "pip") g.pip = data;
        else if (what == "who") g.who = data;
        else revert("Tally/file-unrecognized-param");
        (g.pie, g.chi, g.own) = _read(gem);
        emit File(gem, what, data);
    }

    /// @notice Credit an off-chain demand-side amount (e.g. Distribution
    ///         Rewards) to be paid at the next settle. The hybrid hook.
    function gift(uint256 wad) external auth {
        require(live == 1, "Tally/not-live");
        require(pay == 1, "Tally/not-paying");
        owe += wad;
        emit Gift(wad);
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

    // --- Reads ---

    /// @notice Ilk debt read from the Vat, `Art * rate` [wad]: the MSC's `cum_debt`.
    function debt() public view returns (uint256) {
        (uint256 Art, uint256 rate,,,) = vat.ilks(ilk);
        return _rmul(Art, rate);
    }

    /// @notice How much more the ilk can draw today [wad]: the tighter of the
    ///         ilk ceiling and the global ceiling, less one USDS for the
    ///         vault's round-up.
    function room() public view returns (uint256) {
        (uint256 Art, uint256 rate,, uint256 line_,) = vat.ilks(ilk);
        uint256 d = Art * rate;
        uint256 a = line_ > d ? (line_ - d) / RAY : 0;
        uint256 L = vat.Line(); uint256 D = vat.debt();
        uint256 b = L > D ? (L - D) / RAY : 0;
        uint256 r = _min(a, b);
        return r > WAD ? r - WAD : 0;
    }

    function _subs() internal view returns (uint256 u, uint256 sv) {
        u = usds.balanceOf(sub);
        uint256 s = susds.balanceOf(sub);
        sv = s > 0 ? susds.convertToAssets(s) : 0;
    }

    // --- Sky side ---

    /// @notice Accrue since the last drip, then re-sample. Calling `drip` in
    ///         the same block as a draw, wipe or SubProxy transfer (before
    ///         it) makes the accrual exact; the samples are always refreshed
    ///         so a drip-then-move sequence starts the next interval on the
    ///         post-move balance.
    function drip() public {
        uint256 dt = block.timestamp - rho;
        uint256 d  = debt();
        (uint256 u, uint256 sv) = _subs();
        uint256 c  = susds.convertToAssets(WAD);

        if (dt > 0) {
            // SSR over the interval, as sUSDS itself compounded it [ray].
            uint256 dchi = chi > 0 ? c * RAY / chi - RAY : 0;
            uint256 br   = dchi + _ps(pad) * dt;          // Base Rate over the interval [ray]

            // Base Rate on the larger of the debt at both ends, subsidised up to `line`.
            uint256 base = _max(d, art);
            uint256 fee;
            if (line > 0) {
                uint256 lo = _min(base, line);
                fee = _rmul(lo, _ps(cut) * dt) + _rmul(base - lo, br);
            } else {
                fee = _rmul(base, br);
            }
            tab += fee;

            // Agent rate on the smaller of the SubProxy balances at both ends:
            // USDS earns SSR + tip, sUSDS earns tip (the SSR already arrives
            // through the share price). Only on the ilk that carries the
            // prime's demand side.
            uint256 ar;
            if (pay == 1) {
                ar = _rmul(_min(u, usd), dchi + _ps(tip) * dt)
                   + _rmul(_min(sv, sus), _ps(tip) * dt);
                owe += ar;
            }

            // Rebates on the smaller of the tagged positions' values at both
            // ends. SAV hands back the spread; IDL hands back what the
            // marginal unit of debt pays. Bounded by `tab` at settle.
            uint256 rb = _rebates(dt, br, (line > 0 && base <= line) ? _ps(cut) * dt : br);
            rebate += rb;

            rho = block.timestamp;
            emit Drip(d, dchi, fee, ar, rb);
        }

        chi = c;
        art = d;
        usd = u;
        sus = sv;
    }

    function _rebates(uint256 dt, uint256, uint256 marginal) internal view returns (uint256 rb) {
        uint256 spread = _ps(pad) * dt;
        for (uint256 k = 0; k < list.length; k++) {
            Gem storage g = gems[list[k]];
            if (g.tag != SAV && g.tag != IDL) continue;
            (uint256 pie, uint256 chi_, uint256 own) = _read(list[k]);
            uint256 v = _min(_val(pie, chi_, own), _val(g.pie, g.chi, g.own));
            rb += _rmul(v, g.tag == SAV ? spread : marginal);
        }
    }

    // --- Positions ---

    function _read(address gem) internal view returns (uint256 pie, uint256 chi_, uint256 own) {
        Gem storage g = gems[gem];
        address who = g.who == address(0) ? alm : g.who;
        (pie, chi_, own) = PipLike(g.pip).peek(who);
        chi_ = _wmul(chi_, WAD - g.fee);
    }

    /// @notice Mark one position and route the index move by tag.
    function poke(address gem) public returns (uint256 val) {
        Gem storage g = gems[gem];
        require(g.tag != 0, "Tally/gem-not-init");

        (uint256 pie, uint256 chi_, uint256 own) = _read(gem);
        val = _val(pie, chi_, own);
        uint256 was = _val(g.pie, g.chi, g.own);

        // PnL on the shares carried through the interval, at the new index.
        int256 dpnl = int256(_rmul(g.pie, chi_)) - int256(_rmul(g.pie, g.chi));

        if (g.tag == MTM) {
            gain += dpnl;
        } else if (g.tag == SDE) {
            // Sky's share of the move: the whole position, or the capped
            // slice of the value the move was measured on.
            uint256 share = g.cap == 0 ? WAD : (was == 0 ? 0 : _min(WAD, g.cap * WAD / was));
            int256 s = dpnl * int256(share) / int256(WAD);
            sde  += s;
            gain += dpnl - s;
        }
        // SAV / IDL: rebated in drip; NIL: nothing booked.

        g.pie = pie;
        g.chi = chi_;
        g.own = own;
        g.rho = block.timestamp;
        emit Poke(gem, pie, chi_, own, val, dpnl);
    }

    /// @notice Mark every position. Returns the NAV.
    function poke() public returns (uint256 tot) {
        for (uint256 k = 0; k < list.length; k++) {
            tot += poke(list[k]);
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
    function settle() external {
        require(live == 1, "Tally/not-live");
        drip();
        poke();

        Day memory d;

        // A rebate hands back Base Rate that was charged; never more.
        uint256 rb = _min(rebate, tab);

        d.sky = int256(tab) + sde - int256(rb);
        d.sv  = gain + int256(rb) - int256(tab) - int256(sin);
        d.dv  = owe;

        // The demand side is always owed; a supply loss is carried against
        // future supply gains only, never netted against the demand side.
        d.up   = d.sv > 0 ? uint256(d.sv) : 0;
        d.send = _whole(d.dv + d.up);

        // Whole USDS today; fractions and a negative Sky share carry forward.
        int256 mint_ = d.sky + int256(d.up);
        int256 carry;
        if (mint_ < 0) { carry = mint_; }
        else { d.mint = _whole(uint256(mint_)); carry = mint_ - int256(d.mint); }

        d.drew = _draw(d.mint);
        carry += int256(d.mint - d.drew);

        tab = 0; gain = 0; rebate = 0;
        sde = carry;
        sin = d.sv < 0 ? uint256(-d.sv) : 0;
        owe = (d.dv + d.up) - d.send;

        // Send: pay the SubProxy from the fresh draw, then from any USDS
        // governance keeps here; whatever cannot be paid is owed.
        d.paid = _min(d.send, usds.balanceOf(address(this)));
        if (d.paid > 0) require(usds.transfer(sub, d.paid), "Tally/transfer-failed");
        owe += d.send - d.paid;

        // Keep: Sky's net goes to the surplus buffer.
        d.kept = d.drew > d.send ? d.drew - d.send : 0;
        if (d.kept > 0) join.join(vow, d.kept);

        emit Settle(d.sky, d.sv, d.dv, d.mint, d.drew, d.send, d.paid, d.kept);
    }

    // Draw `mint` as new ilk debt through the prime's allocator stack, within
    // today's ceiling headroom, and pull it here. Returns what was drawn.
    function _draw(uint256 mint) internal returns (uint256 drew) {
        if (mint == 0) return 0;
        require(vault != address(0) && buffer != address(0), "Tally/vault-not-set");
        drew = _whole(_min(mint, room()));
        if (drew > 0) {
            VaultLike(vault).draw(drew);
            require(usds.transferFrom(buffer, address(this), drew), "Tally/transfer-failed");
        }
    }

    // --- Views ---

    function value(address gem) external view returns (uint256) {
        require(gems[gem].tag != 0, "Tally/gem-not-init");
        (uint256 pie, uint256 chi_, uint256 own) = _read(gem);
        return _val(pie, chi_, own);
    }

    function nav() external view returns (uint256 tot) {
        for (uint256 k = 0; k < list.length; k++) {
            (uint256 pie, uint256 chi_, uint256 own) = _read(list[k]);
            tot += _val(pie, chi_, own);
        }
    }

    function count() external view returns (uint256) {
        return list.length;
    }
}
