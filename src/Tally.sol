// SPDX-License-Identifier: AGPL-3.0-or-later

/// Tally.sol -- daily settlement cycle for one Sky allocator ilk: the books

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

import { PipLike } from "./pips/Pip.sol";

interface VatLike {
    function ilks(bytes32) external view returns (uint256 Art, uint256 rate, uint256 spot, uint256 line, uint256 dust);
    function Line() external view returns (uint256);
    function debt() external view returns (uint256);
}

interface TillLike {
    function tally() external view returns (address);
    function ilk() external view returns (bytes32);
    function usds() external view returns (address);
    function pay(uint256 drew, uint256 send, address to) external returns (uint256 paid, uint256 kept);
}

interface GemLike {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface SusdsLike {
    function balanceOf(address) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
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
 *           that drips before AND after every draw, wipe or transfer
 *           records each interval exactly. Endpoint sampling alone cannot
 *           detect a borrow-and-repay between observations. Integrations
 *           must bracket every capital movement atomically.
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
 *           gains only; the demand side is always paid. `mint` is capped
 *           by the ilk's debt-ceiling headroom (the rest is carried) and
 *           handed with `send` to the `Till`, which draws, pays the
 *           SubProxy and banks Sky's net. Whatever the Till could not pay
 *           is carried in `owe`. `Tally` holds no tokens and no roles.
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
    uint8 public constant SDE = 2; // Sky direct exposure (cap-aware share)    -> sde, remainder -> gain; BR rebated on Sky's slice
    uint8 public constant SAV = 3; // debt-funded Sky savings token: index -> gain; spread -> rebate
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
    GemLike   public immutable usds;
    SusdsLike public immutable susds;

    // Prime
    address public alm;      // ALM Proxy: default holder of the gems
    address public sub;      // SubProxy: paid at settle
    address public till;     // Till: draws, pays and banks on our instruction
    uint256 public pay;      // 1 if this ilk carries the prime's demand side (agent rate, gifts)

    // Rates
    uint256 public pad;      // Base Rate spread over SSR, annual nominal          [ray]
    uint256 public tip;      // agent-rate spread over SSR, annual nominal         [ray]
    uint256 public cut;      // subsidised Base Rate, annual nominal               [ray]
    uint256 public line;     // debt charged at `cut` (subsidy cap), 0 = no subsidy [wad]

    // Equity layer: recognition of value that entered or left without a debt change
    int256  public flux;     // Σ gem flows since last settle: Δvalue − index PnL        [wad]
    int256  public capital;  // Σ debt changes since last settle, less settlement draws [wad]
    int256  public gap;      // flux − capital, unrouted                                 [wad]
    uint8   public route;    // where a day's gap goes: MTM, SDE, or NIL = report and carry

    // Book: accruals since the last settle and carries
    uint256 public tab;      // Base Rate charge                                    [wad]
    uint256 public owe;      // demand side owed to the prime (agent rate, gifts, unpaid send) [wad]
    int256  public gain;     // prime mark-to-market                                [wad]
    int256  public sde;      // Sky-direct mark-to-market, incl. carried Sky share  [wad]
    uint256 public rebate;   // rebates to the prime (sUSDS spread, idle BR)        [wad]
    uint256 public sin;      // negative prime supply share carried forward         [wad]

    uint256 public zzz;      // time of last settle                                 [unix epoch time]

    // Samples at last drip
    uint256 public rho;      // time                                                [unix epoch time]
    uint256 public chi;      // sUSDS share price, the SSR index                    [wad]
    uint256 public art;      // ilk debt                                            [wad]
    uint256 public usd;      // SubProxy USDS                                       [wad]
    uint256 public sus;      // SubProxy sUSDS value                                [wad]

    mapping (address => Gem) public gems;
    mapping (address => uint256) public rvals; // rebate endpoints, separate from PnL marks [wad]
    address[]                public list;

    mapping (bytes32 => uint256) public notes; // consumed external-settlement references

    mapping (address => uint256) public stopped; // quarantined marks; settlement blocked
    mapping (bytes32 => uint256) public refs;    // flow/recovery references
    uint256 public stops;
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
    event Note(bytes32 indexed ref, uint256 wad);
    event Settle(int256 sky, int256 sv, uint256 dv, uint256 mint, uint256 drew, uint256 send, uint256 paid, uint256 kept);
    event Gap(int256 flux, int256 capital, int256 gap, uint8 route);
    event Sort(int256 wad, uint8 to);
    event Quit(address indexed gem, address indexed dst, uint256 wad);
    event Cage();
    event Sync(address indexed gem, bytes32 indexed ref, int256 flow);
    event Halt(address indexed gem);
    event Mend(address indexed gem, address pip, bytes32 indexed ref, int256 unresolved);

    // --- Init ---
    constructor(bytes32 ilk_, address vat_, address usds_, address susds_) {
        ilk   = ilk_;
        vat   = VatLike(vat_);
        usds  = GemLike(usds_);
        susds = SusdsLike(susds_);
        live  = 1;
        route = NIL;
        rho   = block.timestamp;
        chi   = susds.convertToAssets(WAD);
        art   = debt();
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
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
        // A gem that earns a rebate must not be added mid-interval: `drip`
        // prices rebates over the whole elapsed interval, so a position in the
        // book for one second would be credited for a full day.
        if (tag == SAV || tag == IDL || tag == SDE) require(block.timestamp == rho, "Tally/rho-not-updated");
        Gem storage g = gems[gem];
        g.pip = pip;
        g.tag = tag;
        g.rho = block.timestamp;
        list.push(gem);
        // Seed the index so the first real poke books no phantom PnL.
        _seed(gem);
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
        else if (what == "route") { require(data == MTM || data == SDE || data == NIL, "Tally/bad-route"); route = uint8(data); }
        else revert("Tally/file-unrecognized-param");
        emit File(what, data);
    }

    function file(bytes32 what, address data) external auth {
        require(live == 1, "Tally/not-live");
        if (what == "alm") {
            require(stops == 0, "Tally/stopped");
            require(block.timestamp == rho, "Tally/rho-not-updated");
            // The default holder of every gem: poke first so the open interval
            // is booked against the old holder, then re-seed every mark so the
            // move itself is not booked as PnL or paid out as an arrival.
            for (uint256 k = 0; k < list.length; k++) {
                require(block.timestamp == gems[list[k]].rho, "Tally/gem-rho-not-updated");
            }
            alm = data;
            for (uint256 k = 0; k < list.length; k++) {
                _seed(list[k]);
            }
        }
        else if (what == "till") {
            if (data != address(0)) {
                require(TillLike(data).tally() == address(this), "Tally/wrong-tally");
                require(TillLike(data).ilk() == ilk, "Tally/wrong-ilk");
                require(TillLike(data).usds() == address(usds), "Tally/wrong-usds");
            }
            till = data;
        }
        else if (what == "sub") {
            require(data != address(0), "Tally/no-payee");
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
        require(stopped[gem] == 0, "Tally/gem-unavailable");
        require(block.timestamp == rho && block.timestamp == g.rho, "Tally/rho-not-updated");
        if (what == "fee") {
            require(data <= WAD, "Tally/fee-too-high");
            g.fee = data;
        }
        else if (what == "cap") g.cap = data;
        else if (what == "tag") { require(data >= MTM && data <= NIL, "Tally/bad-tag"); g.tag = uint8(data); }
        else revert("Tally/file-unrecognized-param");
        _seed(gem);
        emit File(gem, what, data);
    }

    function file(address gem, bytes32 what, address data) external auth {
        require(live == 1, "Tally/not-live");
        Gem storage g = gems[gem];
        require(g.tag != 0, "Tally/gem-not-init");
        require(stopped[gem] == 0, "Tally/gem-unavailable");
        require(block.timestamp == rho && block.timestamp == g.rho, "Tally/rho-not-updated");
        if      (what == "pip") g.pip = data;
        else if (what == "who") g.who = data;
        else revert("Tally/file-unrecognized-param");
        _seed(gem);
        emit File(gem, what, data);
    }

    // Mark performance before an operation, then refresh after it in the same
    // transaction. The entire value change here is a flow, not index income.
    // Authorized callers attest that no performance was hidden in that change.
    function sync(address gem, bytes32 ref) external auth {
        require(live == 1, "Tally/not-live");
        Gem storage g = gems[gem];
        require(g.tag != 0 && stopped[gem] == 0, "Tally/gem-unavailable");
        require(rho == block.timestamp && g.rho == block.timestamp, "Tally/rho-not-updated");
        _ref(ref);
        int256 delta = _seed(gem);
        if (g.tag != IDL && g.tag != NIL) flux += delta;
        emit Sync(gem, ref, delta);
    }

    // No dependency reads: several broken feeds can be quarantined separately.
    // Frozen values are last-known marks, NOT current valuations. During the
    // outage no rebate is granted for this gem and no settlement can execute.
    function halt(address gem) external auth {
        require(live == 1, "Tally/not-live");
        require(gems[gem].tag != 0 && stopped[gem] == 0, "Tally/gem-unavailable");
        stopped[gem] = 1;
        stops++;
        route = NIL;
        emit File("route", uint256(NIL));
        emit Halt(gem);
    }

    // Close the missed interval conservatively, then read the replacement.
    // Value differences remain unresolved equity, never implicit index yield.
    // Governance may classify them with sort after reviewing the evidence.
    function mend(address gem, address pip, bytes32 ref) external auth {
        require(live == 1, "Tally/not-live");
        require(stopped[gem] == 1, "Tally/not-stopped");
        _ref(ref);
        drip();
        gems[gem].pip = pip;
        stopped[gem] = 0;
        stops--;
        int256 delta = _seed(gem);
        if (gems[gem].tag != IDL && gems[gem].tag != NIL) gap += delta;
        route = NIL;
        emit File("route", uint256(NIL));
        emit Mend(gem, pip, ref, delta);
    }

    function _ref(bytes32 ref) internal {
        require(ref != bytes32(0) && refs[ref] == 0, "Tally/bad-reference");
        refs[ref] = 1;
    }

    function _seed(address gem) internal returns (int256 delta) {
        Gem storage g = gems[gem];
        uint256 was = _val(g.pie, g.chi, g.own);
        (g.pie, g.chi, g.own) = _read(gem);
        g.rho = block.timestamp;
        uint256 val = _val(g.pie, g.chi, g.own);
        rvals[gem] = val;
        delta = int256(val) - int256(was);
    }

    /// @notice Classify a just-executed external settlement's debt increase.
    ///         An authorized spell MUST call drip(), increase debt without
    ///         funding the ALM, then note(ref), atomically in that order.
    ///         No intervening drip or settle: the unsampled debt delta is the
    ///         receipt. This is an attribution hook, not a payment or debt write.
    ///         It does not remove this debt from the interest-bearing balance.
    function note(bytes32 ref) external auth {
        require(live == 1, "Tally/not-live");
        require(block.timestamp == rho, "Tally/rho-not-updated");
        require(ref != bytes32(0) && notes[ref] == 0, "Tally/bad-reference");
        uint256 d = debt();
        require(d > art, "Tally/no-settlement-debt");
        notes[ref] = 1;
        emit Note(ref, d - art);
        // Do not add this delta to capital: no proceeds entered the ALM.
        art = d;
        (usd, sus) = _subs();
    }

    /// @notice Credit an off-chain demand-side amount (e.g. Distribution
    ///         Rewards) to be paid at the next settle. The hybrid hook.
    function gift(uint256 wad) external auth {
        require(live == 1, "Tally/not-live");
        require(pay == 1, "Tally/not-paying");
        owe += wad;
        emit Gift(wad);
    }

    /// @notice Attribute `wad` of the unrouted gap to a bucket: MTM (prime) or
    ///         SDE (Sky). The equity layer recognises unlabelled arrivals; this
    ///         is how the operator says whose they are (e.g. BUIDL dividends
    ///         to Sky). Signed, so a mis-sort can be undone.
    function sort(int256 wad, uint8 to) external auth {
        require(live == 1, "Tally/not-live");
        require(to == MTM || to == SDE, "Tally/bad-bucket");
        gap -= wad;
        if (to == MTM) gain += wad; else sde += wad;
        emit Sort(wad, to);
    }

    /// @notice Move a mistaken transfer out. Tally holds nothing by design;
    ///         the float lives in the Till. Works after `cage`.
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

    /// @notice Accrue since the last drip, then re-sample. Integrations call
    ///         before AND after every draw, wipe or SubProxy transfer in one
    ///         transaction. A same-block call refreshes without accruing.
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
            uint256 fee = _charge(base, dt, br);
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

            // Rebates use the smaller endpoint position values. SAV returns
            // the spread; IDL/SDE reduce the utilized principal across the
            // entire subsidy curve. Bounded by `tab` at settle.
            uint256 rb = _rebates(base, dt, br);
            rebate += rb;

            rho = block.timestamp;
            emit Drip(d, dchi, fee, ar, rb);
        } else {
            // Post-movement hooks refresh rebate endpoints even without elapsed time.
            _rebates(0, 0, 0);
        }

        capital += int256(d) - int256(art);
        chi = c;
        art = d;
        usd = u;
        sus = sv;
    }

    // Interest on a principal, applying the subsidy cap before full BR.
    function _charge(uint256 principal, uint256 dt, uint256 br) internal view returns (uint256) {
        uint256 lo = _min(principal, line);
        return _rmul(lo, _ps(cut) * dt) + _rmul(principal - lo, br);
    }

    // Aggregate idle/Sky-direct deductions, then apply the SAME charge curve
    // to the net principal. A single marginal rate is wrong if deductions
    // cross the subsidy cap. SAV's spread credit is separate; settle caps the
    // combined credit by accrued tab. Registration must avoid overlapping slices.
    function _rebates(uint256 base, uint256 dt, uint256 br) internal returns (uint256 rb) {
        uint256 idle;
        uint256 spread = _ps(pad) * dt;
        for (uint256 k = 0; k < list.length; k++) {
            Gem storage g = gems[list[k]];
            if (stopped[list[k]] == 1) continue;
            if (g.tag != SAV && g.tag != IDL && g.tag != SDE) continue;
            (uint256 pie, uint256 chi_, uint256 own) = _read(list[k]);
            uint256 val = _val(pie, chi_, own);
            uint256 v = _min(val, rvals[list[k]]);
            rvals[list[k]] = val;
            if (g.tag == SAV) rb += _rmul(v, spread);
            else {
                if (g.tag == SDE && g.cap > 0) v = _min(v, g.cap);
                idle += _min(v, base - idle);
            }
        }
        rb += _charge(base, dt, br) - _charge(base - idle, dt, br);
    }

    // --- Positions ---

    function _read(address gem) internal view returns (uint256 pie, uint256 chi_, uint256 own) {
        Gem storage g = gems[gem];
        if (stopped[gem] == 1) return (g.pie, g.chi, g.own);
        address who = g.who == address(0) ? alm : g.who;
        (pie, chi_, own) = PipLike(g.pip).peek(who);
        chi_ = _wmul(chi_, WAD - g.fee);
    }

    /// @notice Mark one position and route the index move by tag.
    function poke(address gem) public returns (uint256 val) {
        Gem storage g = gems[gem];
        require(g.tag != 0, "Tally/gem-not-init");
        // A frozen read must not make the last valid mark appear fresh.
        if (stopped[gem] == 1) return _val(g.pie, g.chi, g.own);

        // Rebate samples belong to drip's interval, not to an arbitrary
        // caller's mark cadence. Do not overwrite them before accruing.
        if (g.tag == SAV || g.tag == IDL || g.tag == SDE) {
            require(block.timestamp == rho, "Tally/rho-not-updated");
        }
        (uint256 pie, uint256 chi_, uint256 own) = _read(gem);
        val = _val(pie, chi_, own);
        uint256 was = _val(g.pie, g.chi, g.own);

        // PnL on the shares carried through the interval, at the new index.
        int256 dpnl = int256(_rmul(g.pie, chi_)) - int256(_rmul(g.pie, g.chi));

        // Equity layer: what moved in or out of this holding. IDL gems are memo
        // items inside other holdings and NIL gems are outside the scope.
        if (g.tag != IDL && g.tag != NIL) flux += int256(val) - int256(was) - dpnl;

        if (g.tag == MTM || g.tag == SAV) {
            gain += dpnl;
        } else if (g.tag == SDE) {
            // Sky's share of the move: the whole position, or the capped
            // slice of the value the move was measured on.
            uint256 share = g.cap == 0 ? WAD : (was == 0 ? 0 : _min(WAD, g.cap * WAD / was));
            int256 s = dpnl * int256(share) / int256(WAD);
            sde  += s;
            gain += dpnl - s;
        }
        // SAV also earns its spread rebate in drip; IDL / NIL book no PnL.

        g.pie = pie;
        g.chi = chi_;
        g.own = own;
        g.rho = block.timestamp;
        rvals[gem] = val;
        emit Poke(gem, pie, chi_, own, val, dpnl);
    }

    /// @notice Mark every position. Returns the NAV (IDL gems are memo items
    ///         inside other positions and are not added).
    function poke() public returns (uint256 tot) {
        for (uint256 k = 0; k < list.length; k++) {
            uint256 v = poke(list[k]);
            if (gems[list[k]].tag != IDL) tot += v;
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
        uint256 kept;  // Sky's net, banked by the Till
    }

    /// @notice Run the day: accrue, mark, and execute the MSC identity in whole USDS.
    function settle() external {
        require(stops == 0, "Tally/stopped");
        require(live == 1, "Tally/not-live");
        drip();
        poke();

        Day memory d;

        // Equity layer: value that entered without a debt increase, or left
        // without a debt decrease, since the last settle. Routed by `route`;
        // NIL reports and carries it.
        emit Gap(flux, capital, gap + flux - capital, route);
        gap += flux - capital;
        flux = 0; capital = 0;
        if (route == MTM) { gain += gap; gap = 0; }
        else if (route == SDE) { sde += gap; gap = 0; }

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

        // Draw within today's ceiling headroom; the rest waits on the Sky side.
        if (d.mint > 0) d.drew = _whole(_min(d.mint, room()));
        carry += int256(d.mint - d.drew);

        tab = 0; gain = 0; rebate = 0;
        sde = carry;
        sin = d.sv < 0 ? uint256(-d.sv) : 0;
        owe = (d.dv + d.up) - d.send;

        zzz = block.timestamp;

        // The Till draws, pays the SubProxy and banks Sky's net. If there is
        // no Till, or it cannot pay in full, the day still closes and the
        // balance is owed: the cycle carries rather than stalling. A draw the
        // Till did not make is carried on the Sky side too.
        if ((d.drew > 0 || d.send > 0) && till != address(0)) {
            (d.paid, d.kept) = TillLike(till).pay(d.drew, d.send, sub);
        } else if (d.drew > 0) {
            sde += int256(d.drew);        // undo the carry deduction above
            d.drew = 0;
        }
        owe += d.send > d.paid ? d.send - d.paid : 0;

        // Close the interval on POST-payment balances. Absorb the actual Vat
        // debt delta, including vault rounding, without treating it as ALM
        // capital. The next drip must neither rebook our draw nor miss the
        // first day's agent rate on our own payout.
        art = debt();
        (usd, sus) = _subs();

        emit Settle(d.sky, d.sv, d.dv, d.mint, d.drew, d.send, d.paid, d.kept);
    }

    // --- Views ---

    function value(address gem) external view returns (uint256) {
        require(gems[gem].tag != 0, "Tally/gem-not-init");
        (uint256 pie, uint256 chi_, uint256 own) = _read(gem);
        return _val(pie, chi_, own);
    }

    function nav() external view returns (uint256 tot) {
        for (uint256 k = 0; k < list.length; k++) {
            if (gems[list[k]].tag == IDL) continue;   // memo item, not an asset
            (uint256 pie, uint256 chi_, uint256 own) = _read(list[k]);
            tot += _val(pie, chi_, own);
        }
    }

    function count() external view returns (uint256) {
        return list.length;
    }
}
