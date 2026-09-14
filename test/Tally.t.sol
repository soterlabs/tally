// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { Test } from "forge-std/Test.sol";
import { Tally } from "../src/Tally.sol";
import { Till } from "../src/Till.sol";
import { RawPip, Erc4626Pip, Erc7540Pip, ATokenPip, RelayPip } from "../src/Pips.sol";

// --- Mocks ---

contract MockToken {
    uint8 public decimals;
    mapping (address => uint256) public balanceOf;
    mapping (address => mapping (address => uint256)) public allowance;
    constructor(uint8 dec) { decimals = dec; }
    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function slash(address from, uint256 amt) external { balanceOf[from] -= amt; }   // test helper
    function burn(address from, uint256 amt) external {
        if (from != msg.sender) { allowance[from][msg.sender] -= amt; }
        balanceOf[from] -= amt;
    }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 amt) external returns (bool) { balanceOf[msg.sender] -= amt; balanceOf[to] += amt; return true; }
    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt; balanceOf[to] += amt; return true;
    }
}

// ERC-4626 with a settable price per share.
contract MockVault is MockToken {
    address public asset;
    uint256 public pps;   // assets per one share, in asset decimals
    constructor(address asset_, uint8 dec, uint256 pps_) MockToken(dec) { asset = asset_; pps = pps_; }
    function setPps(uint256 p) external { pps = p; }
    function convertToAssets(uint256 shares) external view returns (uint256) { return shares * pps / 10 ** decimals; }
}

// ERC-7540 / ERC-7575: the vault has no ERC-20 surface; the share is a token.
contract MockAsyncVault {
    address public asset; MockToken public shareToken;
    uint256 public pps;
    uint256 public pendR; uint256 public pendD; uint256 public maxM; uint256 public maxW;
    constructor(address asset_, uint8 dec, uint256 pps_) { asset = asset_; shareToken = new MockToken(dec); pps = pps_; }
    function share() external view returns (address) { return address(shareToken); }
    function setPps(uint256 p) external { pps = p; }
    function setQueues(uint256 pr, uint256 pd, uint256 mm, uint256 mw) external { pendR = pr; pendD = pd; maxM = mm; maxW = mw; }
    function convertToAssets(uint256 shares) external view returns (uint256) { return shares * pps / 10 ** shareToken.decimals(); }
    function pendingRedeemRequest(uint256, address) external view returns (uint256) { return pendR; }
    function pendingDepositRequest(uint256, address) external view returns (uint256) { return pendD; }
    function maxMint(address) external view returns (uint256) { return maxM; }
    function maxWithdraw(address) external view returns (uint256) { return maxW; }
}

// sUSDS: share price compounds per second at `ssr`, like the real one.
contract MockSusds is MockToken {
    uint256 constant RAY = 1e27;
    address public asset;
    uint256 public ssr; uint256 public chi; uint256 public rho;
    constructor(address usds, uint256 ssr_, uint256 chi_) MockToken(18) { asset = usds; ssr = ssr_; chi = chi_; rho = block.timestamp; }
    function _rpow(uint256 x, uint256 n, uint256 b) internal pure returns (uint256 z) {
        assembly {
            switch x case 0 {switch n case 0 {z := b} default {z := 0}}
            default {
                switch mod(n, 2) case 0 { z := b } default { z := x }
                let half := div(b, 2)
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
    function nowChi() public view returns (uint256) { return chi * _rpow(ssr, block.timestamp - rho, RAY) / RAY; }
    function convertToAssets(uint256 shares) external view returns (uint256) { return shares * nowChi() / 1e18; }
    function file(uint256 ssr_) external { chi = nowChi(); rho = block.timestamp; ssr = ssr_; }   // SP-BEAM: drip then set
}

// aToken + pool with a settable liquidity index.
contract MockPool {
    uint256 public index = 1e27;
    function set(uint256 i) external { index = i; }
    function getReserveNormalizedIncome(address) external view returns (uint256) { return index; }
}
contract MockAToken is MockToken {
    address public POOL; address public UNDERLYING_ASSET_ADDRESS;
    constructor(address pool, address asset, uint8 dec) MockToken(dec) { POOL = pool; UNDERLYING_ASSET_ADDRESS = asset; }
    function scaledBalanceOf(address who) external view returns (uint256) { return balanceOf[who]; }
}

contract MockVat {
    uint256 constant RAY = 1e27;
    mapping (bytes32 => uint256) public Art;
    mapping (bytes32 => uint256) public rate;
    mapping (bytes32 => uint256) public line;   // rad
    uint256 public Line = type(uint256).max / 2;
    uint256 public debt;                        // rad
    function set(bytes32 ilk, uint256 Art_, uint256 rate_) external {
        debt = debt - Art[ilk] * rate[ilk] + Art_ * rate_;
        Art[ilk] = Art_; rate[ilk] = rate_; line[ilk] = type(uint256).max / 2;
    }
    function setLine(bytes32 ilk, uint256 rad) external { line[ilk] = rad; }
    function ilks(bytes32 ilk) external view returns (uint256, uint256, uint256, uint256, uint256) {
        return (Art[ilk], rate[ilk], 0, line[ilk], 0);
    }
    function frob(bytes32 ilk, uint256 dart) external {
        Art[ilk] += dart; debt += dart * rate[ilk];
        require(Art[ilk] * rate[ilk] <= line[ilk] && debt <= Line, "Vat/ceiling-exceeded");
    }
    function ilkDebt(bytes32 ilk) external view returns (uint256) { return Art[ilk] * rate[ilk] / RAY; }
}

// UsdsJoin: join burns USDS from the caller and credits internal dai to usr.
contract MockJoin {
    MockToken usds;
    mapping (address => uint256) public credited;
    constructor(address usds_) { usds = MockToken(usds_); }
    function join(address usr, uint256 wad) external { usds.burn(msg.sender, wad); credited[usr] += wad * 1e27; }
    function exit(address usr, uint256 wad) external { usds.mint(usr, wad); }
}

// AllocatorVault: draw frobs the ilk and exits USDS to the buffer.
contract MockAllocatorVault {
    MockVat vat; MockJoin join; bytes32 public ilk; address public buffer;
    mapping (address => uint256) public wards;
    constructor(address vat_, address join_, bytes32 ilk_, address buffer_) { vat = MockVat(vat_); join = MockJoin(join_); ilk = ilk_; buffer = buffer_; wards[msg.sender] = 1; }
    function rely(address u) external { wards[u] = 1; }
    function draw(uint256 wad) external {
        require(wards[msg.sender] == 1, "AllocatorVault/not-authorized");
        (, uint256 rate,,,) = vat.ilks(ilk);
        vat.frob(ilk, (wad * 1e27 + rate - 1) / rate);
        join.exit(buffer, wad);
    }
}

// AllocatorBuffer: the real one only exposes `approve` (no withdraw).
contract MockBuffer {
    mapping (address => uint256) public wards;
    constructor() { wards[msg.sender] = 1; }
    function approve(address asset, address spender, uint256 amt) external {
        require(wards[msg.sender] == 1, "AllocatorBuffer/not-authorized");
        MockToken(asset).approve(spender, amt);
    }
}

// --- Tests ---

contract TallyTest is Test {
    bytes32 constant ILK = "ALLOCATOR-SPARK-A";
    uint256 constant WAD = 1e18;
    uint256 constant RAY = 1e27;
    // sUSDS per-second rate for a 3.52% APY: 1.0352^(1/31536000)
    uint256 constant SSR = 1000000001096988989836188434;
    // one day of Base Rate at SSR + 20 bps, as a fraction of debt:
    // (1.0352)^(1/365) - 1 + 0.002/365 = 9.478434e-5 + 5.4795e-6 = 1.0026384e-4

    address alm = address(0xA1);
    address sub = address(0x5B);
    address vow = address(0xB0);

    MockVat   vat;
    MockToken usds;
    MockToken usdc;
    MockSusds susds;
    MockJoin  join;
    MockBuffer buffer;
    MockAllocatorVault vault;
    Tally     tally;
    Till      till;

    MockVault      sUsdc;   // 6-dec shares over USDC
    MockAsyncVault jtrsy;   // ERC-7540, 6-dec share over USDC
    MockToken      jtrsyShare;
    MockPool       pool;
    MockAToken     spUsds;
    Erc4626Pip     sUsdcPip;

    function setUp() public {
        vm.warp(1_757_000_000);
        vat    = new MockVat();
        usds   = new MockToken(18);
        usdc   = new MockToken(6);
        susds  = new MockSusds(address(usds), SSR, 1.05e18);
        join   = new MockJoin(address(usds));
        buffer = new MockBuffer();
        vault  = new MockAllocatorVault(address(vat), address(join), ILK, address(buffer));
        vat.set(ILK, 0, RAY);
        tally  = new Tally(ILK, address(vat), address(usds), address(susds));
        till   = new Till(address(tally), vow, address(join), address(usds));
        till.rely(address(tally));
        vault.rely(address(till));
        buffer.approve(address(usds), address(till), type(uint256).max);
        till.file("vault",  address(vault));
        till.file("buffer", address(buffer));

        sUsdc      = new MockVault(address(usdc), 6, 1_050_000);
        jtrsy      = new MockAsyncVault(address(usdc), 6, 1_000_000);
        jtrsyShare = jtrsy.shareToken();
        pool       = new MockPool();
        spUsds     = new MockAToken(address(pool), address(usds), 18);
        sUsdcPip   = new Erc4626Pip(address(sUsdc));

        usds.mint(alm, 1_000_000e18);
        usdc.mint(alm, 500_000e6);
        sUsdc.mint(alm, 100_000e6);
        jtrsyShare.mint(alm, 200_000e6);
        spUsds.mint(alm, 300_000e18);
        susds.mint(alm, 400_000e18);

        tally.file("alm",    alm);
        tally.file("sub",    sub);
        tally.file("till",   address(till));
        tally.file("pad", 0.002e27);   // BR = SSR + 20 bps
        tally.file("tip", 0.002e27);   // agent rate = SSR + 20 bps
        tally.file("pay", 1);
        tally.init(address(usds),   address(new RawPip(address(usds))),      tally.MTM());
        tally.init(address(usdc),   address(new RawPip(address(usdc))),      tally.MTM());
        tally.init(address(sUsdc),  address(sUsdcPip),                       tally.MTM());
        tally.init(address(jtrsy),  address(new Erc7540Pip(address(jtrsy))), tally.SDE());
        tally.init(address(spUsds), address(new ATokenPip(address(spUsds))), tally.MTM());
        tally.init(address(susds),  address(new Erc4626Pip(address(susds))), tally.SAV());
    }

    // Set the ilk debt and sample it, as a prime that drips before drawing would.
    function _debt(uint256 wad) internal { vat.set(ILK, wad, RAY); tally.drip(); }
    // Fund the SubProxy and sample it.
    function _fund(uint256 wad) internal { usds.mint(sub, wad); tally.drip(); }
    // Borrow: debt up AND the drawn USDS lands at the ALM (what a real draw does).
    function _borrow(uint256 wad) internal { vat.set(ILK, wad, RAY); usds.mint(alm, wad); tally.drip(); }

    // --- pricing ---

    function test_nav() public view {
        // 1,000,000 + 500,000 + 105,000 + 200,000 + 300,000 + 420,000
        assertEq(tally.nav(), 2_525_000e18);
    }

    function test_poke_books_index_move_not_flows() public {
        usdc.mint(alm, 9_000_000e6);              // flow
        tally.poke();
        assertEq(tally.gain(), 0);

        sUsdc.setPps(1_060_000);                  // +1,000 on 100,000 shares
        pool.set(1.01e27);                        // +3,000 on 300,000 scaled
        tally.poke();
        assertEq(tally.gain(), 4_000e18);

        sUsdc.setPps(1_000_000);                  // -6,000
        tally.poke();
        assertEq(tally.gain(), -2_000e18);
    }

    function test_fee_haircut_is_not_booked_as_loss() public {
        tally.poke(address(sUsdc));
        tally.file(address(sUsdc), "fee", 0.01e18);
        assertEq(tally.value(address(sUsdc)), 103_950e18);   // 105,000 * 0.99
        tally.poke(address(sUsdc));
        assertEq(tally.gain(), 0);
    }

    function test_gem_refile_requires_poke_and_reseeds() public {
        vm.warp(block.timestamp + 1);
        vm.expectRevert("Tally/rho-not-updated");
        tally.file(address(sUsdc), "pip", address(sUsdcPip));

        tally.drip();
        // Wrong adapter (par) corrected to the real one (1.05): no phantom PnL.
        tally.poke(address(usdc));
        tally.file(address(usdc), "pip", address(sUsdcPip));
        tally.poke(address(usdc));
        assertEq(tally.gain(), 0);
    }

    function test_async_four_in_flight_states() public {
        // 50,000 shares requested for redemption: 30,000 pending (floating),
        // 20,000 fulfilled at 1.00 -> 20,000 USDC claimable (fixed).
        // 10,000 USDC requested for deposit: 6,000 pending (par), 4,000 fulfilled -> 4,000 shares.
        jtrsyShare.slash(alm, 50_000e6);
        jtrsy.setQueues(30_000e6, 6_000e6, 4_000e6, 20_000e6);
        // pie = 150,000 + 30,000 + 4,000 = 184,000 ; own = 6,000 + 20,000
        assertEq(tally.value(address(jtrsy)), 210_000e18);
        tally.poke(address(jtrsy));
        assertEq(tally.gain(), 0);
        assertEq(tally.sde(), 0);

        // Index +1%: only floating shares move; the fixed claimable USDC does not.
        jtrsy.setPps(1_010_000);
        tally.poke(address(jtrsy));
        assertEq(tally.sde(), 1_840e18);
    }

    function test_sde_cap_share_is_on_prior_value() public {
        tally.file(address(jtrsy), "cap", 20_000e18);        // Sky's slice: 10% of 200,000
        jtrsy.setPps(1_010_000);                             // +2,000
        tally.poke(address(jtrsy));
        assertEq(tally.sde(), 200e18);
        assertEq(tally.gain(), 1_800e18);

        // Full redemption before the next poke plus another +1%: Sky still
        // takes only its slice of the move (20,000 / 202,000), not 100%.
        jtrsyShare.slash(alm, 200_000e6);
        jtrsy.setPps(1_020_000);
        tally.poke(address(jtrsy));
        assertApproxEqAbs(tally.sde(), 200e18 + 198.02e18, 0.01e18);
        assertApproxEqAbs(tally.gain(), 1_800e18 + 1_801.98e18, 0.01e18);

        // Crash on a fresh position: Sky's loss is bounded by its slice.
        jtrsyShare.mint(alm, 200_000e6);
        tally.poke(address(jtrsy));                          // flow, no PnL
        jtrsy.setPps(102_000);                               // -90%
        tally.poke(address(jtrsy));
        // dpnl = 200,000 * (0.102 - 1.02) = -183,600 ; share = 20,000 / 204,000
        assertApproxEqAbs(tally.sde(), 398.02e18 - 18_000e18, 0.01e18);
    }

    function test_sav_rebates_spread_and_books_appreciation() public {
        _debt(1_000_000_000e18);
        vm.warp(block.timestamp + 1 days);                   // sUSDS accrues a day of SSR
        tally.drip();
        tally.poke(address(susds));
        assertEq(tally.gain(), int256(tally.value(address(susds))) - 420_000e18);
        // sUSDS: min(420,039.8, 420,000) * 0.002 / 365 = 2.3014
        // JTRSY (SDE): 200,000 * 1.0026384e-4 = 20.0528 of Base Rate handed back
        assertApproxEqAbs(tally.rebate(), 2.3014e18 + 20.0528e18, 1e15);
    }

    function test_idl_rebate_bounded_by_tab() public {
        tally.file(address(susds), "tag", tally.NIL()); // isolate idle rebates from savings yield
        // 90M idle relayed, but the ilk has no debt: nothing was charged, nothing is rebated.
        RelayPip relay = new RelayPip();
        relay.poke(alm, 90_000_000e18, RAY, 0);
        tally.init(address(0xBA5E), address(relay), tally.IDL());
        usds.mint(address(till), 5_000e18);      // float
        vm.warp(block.timestamp + 1 days);
        relay.poke(alm, 90_000_000e18, RAY, 0);
        tally.settle();
        assertEq(usds.balanceOf(address(till)), 5_000e18);
        assertEq(usds.balanceOf(sub), 0);
    }

    function test_sde_slice_is_excluded_from_base_rate() public {
        // Debt 1e9 above the cap, JTRSY 200,000 fully SDE: Sky charges no BR on it.
        _debt(1_000_000_000e18);
        vm.warp(block.timestamp + 1 days);
        tally.drip();
        // 200,000 * 1.0026384e-4 = 20.05 (plus the 2.30 sUSDS spread rebate)
        assertApproxEqAbs(tally.rebate() - 2.3014e18, 20.0528e18, 0.01e18);

        // Capped SDE: only Sky's slice is excluded.
        tally.poke();
        tally.file(address(jtrsy), "cap", 50_000e18);
        vm.warp(block.timestamp + 1 days);
        uint256 before = tally.rebate();
        tally.drip();
        assertApproxEqAbs(tally.rebate() - before - 2.3014e18, 5.0132e18, 0.01e18);
    }

    function test_idl_rebate_at_subsidised_rate_inside_cap() public {
        _debt(500_000_000e18);
        tally.poke();
        tally.file("cut", 0.03e27);
        tally.file("line", 1_000_000_000e18);
        RelayPip relay = new RelayPip();
        relay.poke(alm, 500_000_000e18, RAY, 0);
        tally.init(address(0xBA5E), address(relay), tally.IDL());
        vm.warp(block.timestamp + 1 days);
        relay.poke(alm, 500_000_000e18, RAY, 0);
        tally.drip();
        // Everything idle and everything subsidised: idle rebate == charge,
        // 500M * 0.03 / 365; overlapping excess SDE deductions cannot
        // reduce net principal below zero. Only the savings spread remains.
        assertApproxEqRel(tally.tab(), 41_095.89e18, 1e13);
        assertApproxEqAbs(tally.rebate() - tally.tab(), 2.3014e18, 1e15);
    }

    function test_relay_pip_stale_mark_blocks_settlement() public {
        RelayPip relay = new RelayPip();
        vm.expectRevert("RelayPip/no-mark");
        relay.peek(alm);

        relay.poke(alm, 1_000e18, RAY, 0);
        tally.init(address(0xCAFE), address(relay), tally.MTM());
        _debt(1e18);

        vm.warp(block.timestamp + 1 days);
        tally.settle();
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert("RelayPip/stale");
        tally.settle();
        relay.file("hop", 3 days);
        tally.settle();
    }

    // --- drip ---

    function test_drip_charges_base_rate_and_agent_rate() public {
        _debt(1_000_000_000e18);
        _fund(30_000_000e18);
        susds.mint(sub, 1_000_000e18); tally.drip();
        vm.warp(block.timestamp + 1 days);
        tally.drip();
        // 1e9 * 1.0026384e-4 = 100,263.8
        assertApproxEqRel(tally.tab(), 100_263.79e18, 1e13);
        // 30e6 * 1.0026384e-4 + 1.05e6 * 5.4795e-6 = 3,007.9 + 5.75 = 3,013.67
        assertApproxEqRel(tally.owe(), 3_013.67e18, 1e13);
    }

    function test_drip_prices_ssr_change_inside_interval_exactly() public {
        _debt(1_000_000_000e18);
        tally.file("pad", 0);
        // Ten days at 3.52%, then SP-BEAM cuts the SSR to zero for twenty days.
        vm.warp(block.timestamp + 10 days);
        susds.file(RAY);
        vm.warp(block.timestamp + 20 days);
        tally.drip();
        // The sUSDS index grew (1.0352)^(10/365) - 1 = 9.48248e-4 over the whole
        // gap: exactly ten days of SSR, none of the twenty at zero.
        assertApproxEqRel(tally.tab(), 948_247.79e18, 1e12);
    }

    function test_drip_samples_worse_balance_for_prime() public {
        _debt(1_000_000_000e18);
        _fund(30_000_000e18);
        vm.warp(block.timestamp + 1 days);

        // Wipe 300M and pull 20M from the SubProxy right before the drip:
        // still charged on 1e9, still credited on 10M only.
        vat.set(ILK, 700_000_000e18, RAY);
        usds.slash(sub, 20_000_000e18);
        tally.drip();
        uint256 tab = tally.tab(); uint256 owe = tally.owe();
        assertApproxEqRel(tab, 100_263.79e18, 1e13);
        assertApproxEqRel(owe, 1_002.64e18, 1e13);

        // Redraw and refund right after: next day is again charged on 1e9,
        // credited on 10M. The prime is never better off by timing.
        vat.set(ILK, 1_000_000_000e18, RAY);
        usds.mint(sub, 20_000_000e18);
        vm.warp(block.timestamp + 1 days);
        tally.drip();
        assertApproxEqRel(tally.tab() - tab, 100_263.79e18, 1e13);
        assertApproxEqRel(tally.owe() - owe, 1_002.64e18, 1e13);
        tab = tally.tab();

        // A prime that drips before moving funds is charged exactly.
        tally.drip();                            // same block: samples only
        vat.set(ILK, 700_000_000e18, RAY);
        tally.drip();                            // re-sample post-wipe
        vm.warp(block.timestamp + 1 days);
        tally.drip();
        assertApproxEqRel(tally.tab() - tab, 70_184.65e18, 1e13);
    }

    function test_drip_subsidy_first_line_at_cut() public {
        _debt(1_500_000_000e18);
        tally.poke();
        tally.file("cut", 0.03e27);               // subsidised BR 3.00% nominal
        tally.file("line", 1_000_000_000e18);
        vm.warp(block.timestamp + 1 days);
        tally.drip();
        // 1e9 * 0.03/365 + 0.5e9 * 1.0026384e-4 = 82,191.8 + 50,131.9
        assertApproxEqRel(tally.tab(), 132_323.68e18, 1e13);
    }

    function test_pay_flag_gates_demand_side() public {
        // A second instance on another ilk of the same prime shares the
        // SubProxy but does not carry the demand side.
        Tally t2 = new Tally("ALLOCATOR-SPARK-B", address(vat), address(usds), address(susds));
        t2.file("sub", sub);
        t2.file("tip", 0.002e27);
        usds.mint(sub, 30_000_000e18);
        t2.drip(); tally.drip();
        vm.warp(block.timestamp + 1 days);
        t2.drip(); tally.drip();
        assertEq(t2.owe(), 0);
        assertGt(tally.owe(), 0);
        vm.expectRevert("Tally/not-paying");
        t2.gift(1e18);
    }

    function test_file_rate_requires_fresh_drip_and_pokes() public {
        vm.warp(block.timestamp + 1);
        vm.expectRevert("Tally/rho-not-updated");
        tally.file("pad", 1);
        tally.drip();
        vm.expectRevert("Tally/gem-rho-not-updated");
        tally.file("pad", 1);
        tally.poke();
        tally.file("pad", 1);
    }

    // --- equity layer ---

    function test_gap_is_zero_for_internal_moves_and_draws() public {
        _borrow(1_000_000_000e18);
        vm.warp(block.timestamp + 1 days);
        // Draw 10M into the ALM as USDS, swap 5M USDC into sUSDC shares, price moves: all internal.
        vat.set(ILK, 1_010_000_000e18, RAY); usds.mint(alm, 10_000_000e18);
        usdc.slash(alm, 5_000e6); sUsdc.mint(alm, 4_761_904_761);   // 5,000 USDC at 1.05
        sUsdc.setPps(1_060_000);
        tally.settle();
        // Draw and swap cancel exactly. What is left is the index method's
        // flow-timing approximation: the 4,761.9 shares that arrived mid-interval
        // earned 0.01 each, which the index booked as a flow and equity sees as
        // an arrival: 47.62. With route = MTM this lands in the prime's revenue,
        // so the combined total equals the equity delta exactly.
        assertApproxEqAbs(tally.gap(), 47.62e18, 0.01e18);
    }

    function test_index_pnl_plus_gap_equals_equity_delta() public {
        _borrow(1_000_000_000e18);
        tally.poke();
        uint256 nav0 = tally.nav();   // SAV appreciation is included in both NAV and gain
        vm.warp(block.timestamp + 1 days);
        usdc.slash(alm, 5_000e6); sUsdc.mint(alm, 4_761_904_761);   // swap 5,000 USDC into sUSDC at 1.05
        sUsdc.setPps(1_060_000);                                    // then +1%
        tally.drip(); tally.poke();
        uint256 nav1 = tally.nav();
        // ΔNAV = -5,000 + 5,047.62 + 1,000 = 1,047.62 = index PnL (1,000) + gap (47.62)
        assertApproxEqAbs(nav1 - nav0, 1_047.62e18 + tally.value(address(susds)) - 420_000e18, 0.01e18);
        assertEq(tally.gain() + tally.flux() - tally.capital(), int256(nav1) - int256(nav0));
    }

    function test_gap_recognises_unlabelled_arrivals_and_leaks() public {
        _borrow(1_000_000e18);
        vm.warp(block.timestamp + 1 days);
        usdc.mint(alm, 2_100e6);             // a dividend or a sweep: nobody drew for it
        tally.settle();
        assertApproxEqAbs(tally.gap(), 2_100e18, 1e12);   // route = NIL: reported, carried

        vm.warp(block.timestamp + 1 days);
        usdc.slash(alm, 500e6);              // bridged out: left without a wipe
        tally.settle();
        assertApproxEqAbs(tally.gap(), 1_600e18, 1e12);
    }

    function test_gap_routes_and_sorts() public {
        _borrow(1_000_000e18);
        usds.mint(address(till), 10_000e18);   // float
        tally.poke(); tally.file("route", tally.MTM());
        vm.warp(block.timestamp + 1 days);
        usdc.mint(alm, 3_400e6);             // 2,100 BUIDL dividend (Sky's) + 1,300 sweep (prime's)
        // Operator attributes the Sky part before the settle books the rest to the prime.
        tally.drip(); tally.poke();          // accrue before replacing rebate samples
        tally.sort(2_100e18, tally.SDE());   // gap goes negative by 2,100 until settle nets flux in
        tally.settle();
        assertEq(tally.gap(), 0);
        // sv = gain(1,300) - tab(~100) ... paid to the SubProxy; sde 2,100 went to Sky's share.
        assertGt(usds.balanceOf(sub), 1_100e18);
        assertLt(usds.balanceOf(sub), 1_300e18);
    }

    function test_gap_excludes_tallys_own_draw() public {
        _borrow(1_000_000_000e18);
        _fund(30_000_000e18);
        vm.warp(block.timestamp + 1 days);
        sUsdc.setPps(2_100_000);
        tally.settle();                      // draws ~107,000 of new debt that never enters the ALM
        vm.warp(block.timestamp + 1 days);
        tally.settle();
        assertEq(tally.gap(), 0);
    }

    // --- settle ---

    function test_settle_draws_sky_share_pays_prime_keeps_net() public {
        _debt(1_000_000_000e18);
        _fund(30_000_000e18);
        vm.warp(block.timestamp + 1 days);
        sUsdc.setPps(2_100_000);                  // +105,000 gain on 100,000 shares
        jtrsy.setPps(1_010_000);                  // +2,000 SDE to Sky
        uint256 debtBefore = vat.ilkDebt(ILK);

        tally.settle();

        // tab = 100,263.79  rebate = 2.30 (sUSDS spread) + 20.05 (BR on the SDE slice) = 22.36
        // sky = tab + 2,000 - rebate = 102,241.43 ; sv = 105,000 + rebate - tab = 4,758.57
        // SAV also earns 39.8094: mint floors to 107,039; send to 7,806.
        assertApproxEqAbs(vat.ilkDebt(ILK) - debtBefore, 107_039e18, 1e9);
        assertEq(usds.balanceOf(sub) - 30_000_000e18, 7_806e18);
        assertEq(join.credited(vow), (107_039e18 - 7_806e18) * RAY);
        assertEq(usds.balanceOf(address(till)), 0);
        assertEq(tally.tab(), 0); assertEq(tally.gain(), 0); assertEq(tally.rebate(), 0); assertEq(tally.sin(), 0);
        assertApproxEqAbs(tally.owe(), 0.29e18, 0.01e18);
        assertGe(tally.sde(), 0); assertLt(tally.sde(), 1e18);
    }

    function test_settle_respects_debt_ceiling_and_carries_the_rest() public {
        _debt(1_000_000_000e18);
        _fund(30_000_000e18);
        vat.setLine(ILK, (1_000_000_000e18 + 50_000e18) * RAY);   // 50,000 of headroom
        vm.warp(block.timestamp + 1 days);
        sUsdc.setPps(2_100_000);
        jtrsy.setPps(1_010_000);
        tally.settle();

        // Wanted 107,039.8094; room = 50,000 - 1 -> drew 49,999. Send is still paid in full.
        assertApproxEqAbs(vat.ilkDebt(ILK), 1_000_049_999e18, 1e9);
        assertEq(usds.balanceOf(sub) - 30_000_000e18, 7_806e18);
        assertEq(join.credited(vow), (49_999e18 - 7_806e18) * RAY);
        assertApproxEqAbs(tally.sde(), 57_040.81e18, 0.01e18);   // carried Sky share

        vat.setLine(ILK, type(uint256).max / 2);
        vm.warp(block.timestamp + 1 days);
        tally.settle();
        assertLt(tally.sde(), 1e18);
    }

    function test_settle_at_ceiling_still_pays_demand_side_from_float() public {
        _debt(1_000_000_000e18);
        _fund(30_000_000e18);
        vat.setLine(ILK, 1_000_000_000e18 * RAY);   // no headroom at all
        usds.mint(address(till), 5_000e18);
        vm.warp(block.timestamp + 1 days);
        tally.settle();
        assertEq(usds.balanceOf(sub) - 30_000_000e18, 3_007e18);   // dv 3,007.91 -> 3,007 (sv < 0, carried)
        assertApproxEqRel(tally.sde(), 100_241e18, 1e13);            // Sky share waits for headroom
    }

    function test_settle_carries_negative_prime_share() public {
        _debt(1_000_000_000e18);
        vm.warp(block.timestamp + 1 days);
        sUsdc.setPps(500_000);                    // -55,000 loss on 100,000 shares
        tally.settle();
        // sv includes +39.8094 SAV gain: loss carried is about 155,201.63
        assertApproxEqRel(tally.sin(), 155_201.63e18, 1e13);
        assertEq(join.credited(vow), 100_241e18 * RAY);
        assertEq(usds.balanceOf(sub), 0);

        vm.warp(block.timestamp + 1 days);
        sUsdc.setPps(4_050_000);                  // +355,000
        tally.settle();
        assertEq(tally.sin(), 0);
        assertGt(usds.balanceOf(sub), 0);
    }

    function test_settle_never_nets_demand_side_against_supply_loss() public {
        usds.mint(address(till), 1_000e18);
        tally.poke();
        tally.file(address(susds), "tag", tally.NIL());   // silence the sUSDS rebate
        vm.warp(block.timestamp + 1 days);
        tally.gift(30e18);
        sUsdc.setPps(1_049_000);                  // -100
        tally.settle();
        assertEq(tally.sin(), 100e18);
        assertEq(tally.owe(), 0);
        assertEq(usds.balanceOf(sub), 30e18);     // demand side paid in full

        vm.warp(block.timestamp + 1 days);
        tally.gift(30e18);
        sUsdc.setPps(1_050_000);                  // +100, exactly recovers
        tally.settle();
        assertEq(tally.sin(), 0);
        assertEq(usds.balanceOf(sub), 60e18);     // the prime never borrowed its own agent rate
        assertEq(vat.ilkDebt(ILK), 0);
    }

    function test_settle_sky_pays_from_float_when_send_exceeds_mint() public {
        tally.file(address(susds), "tag", tally.NIL()); // isolate demand-side funding
        _fund(10_000_000e18);
        usds.mint(address(till), 5_000e18);
        vm.warp(block.timestamp + 1 days);
        tally.settle();
        // dv = 10e6 * 1.0026384e-4 = 1,002.64 ; rebate bounded by tab = 0 ; send -> 1,002
        assertEq(usds.balanceOf(sub) - 10_000_000e18, 1_002e18);
        assertEq(usds.balanceOf(address(till)), 3_998e18);
        assertEq(join.credited(vow), 0);
    }

    function test_settle_carries_unpaid_send_when_float_is_empty() public {
        tally.file(address(susds), "tag", tally.NIL()); // isolate demand-side funding
        _fund(10_000_000e18);
        vm.warp(block.timestamp + 1 days);
        tally.settle();
        assertEq(usds.balanceOf(sub), 10_000_000e18);
        assertApproxEqRel(tally.owe(), 1_002.64e18, 1e13);
        usds.mint(address(till), 5_000e18);
        vm.warp(block.timestamp + 1 days);
        tally.settle();
        assertEq(usds.balanceOf(sub) - 10_000_000e18, 2_005e18);
    }

    function test_gift_pays_out_at_settle() public {
        _debt(1e18);
        tally.gift(1_000e18);
        usds.mint(address(till), 1_000e18);
        tally.settle();
        assertEq(usds.balanceOf(sub), 1_000e18);
    }

    function test_settle_permissionless() public {
        _debt(1e18);
        vm.prank(address(0xDEAD));
        tally.settle();
    }

    function test_settle_needs_only_allocator_roles() public {
        MockBuffer b2 = new MockBuffer();
        MockAllocatorVault v2 = new MockAllocatorVault(address(vat), address(join), ILK, address(b2));
        till.file("vault", address(v2));
        _debt(1_000_000_000e18);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert("AllocatorVault/not-authorized");
        tally.settle();
    }

    function test_settle_requires_vault_when_minting() public {
        till.file("vault", address(0));
        _debt(1_000_000_000e18);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert("Till/vault-not-set");
        tally.settle();
    }

    function test_settle_carries_when_the_till_is_unset() public {
        // No Till: the day still closes, the Sky share is carried, nothing stalls.
        tally.file("till", address(0));
        _borrow(1_000_000_000e18);
        _fund(30_000_000e18);
        vm.warp(block.timestamp + 1 days);
        tally.settle();
        assertEq(tally.zzz(), block.timestamp);           // zzz advanced: TallyJob is satisfied
        assertEq(usds.balanceOf(sub), 30_000_000e18);     // nothing paid
        assertApproxEqRel(tally.sde(), 100_241e18, 1e13); // Sky share waits
        assertApproxEqRel(tally.owe(), 3_007.91e18, 1e13); // demand side owed
        assertEq(vat.ilkDebt(ILK), 1_000_000_000e18);     // nothing drawn

        // Till wired later: the carry is drawn and the arrears paid.
        tally.file("till", address(till));
        vm.warp(block.timestamp + 1 days);
        tally.settle();
        assertGt(usds.balanceOf(sub), 30_006_000e18);
        assertLt(tally.sde(), 1e18);
        // The carry never leaked into the equity gap.
        assertEq(tally.gap(), 0);
    }

    function test_only_tally_can_make_the_till_pay() public {
        // Not even a ward: the paired Tally is the sole caller.
        assertEq(till.wards(address(this)), 1);
        vm.expectRevert("Till/not-tally");
        till.pay(1_000e18, 1_000e18, address(0xDEAD));
        vm.prank(address(0xDEAD));
        vm.expectRevert("Till/not-tally");
        till.pay(0, 1e18, sub);
        assertEq(till.tally(), address(tally));
        assertEq(till.ilk(), ILK);
    }

    function test_till_rejects_a_vault_on_another_ilk() public {
        MockBuffer b2 = new MockBuffer();
        MockAllocatorVault other = new MockAllocatorVault(address(vat), address(join), "ALLOCATOR-SPARK-B", address(b2));
        vm.expectRevert("Till/wrong-ilk");
        till.file("vault", address(other));
        till.file("vault", address(0));   // unsetting is allowed
        assertEq(till.vault(), address(0));
    }

    function test_till_cage_disarms_the_money_path() public {
        _debt(1_000_000_000e18);
        _fund(30_000_000e18);
        till.cage();
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert("Till/not-live");
        tally.settle();
        // Governance can still unwind: file and quit stay open.
        usds.mint(address(till), 1_000e18);
        till.quit(address(usds), address(0xF10A7), 1_000e18);
        assertEq(usds.balanceOf(address(0xF10A7)), 1_000e18);
    }

    function test_till_pay_rejects_a_zero_payee() public {
        vm.expectRevert("Tally/no-payee");
        tally.file("sub", address(0));
    }

    function test_till_approve_is_reissuable() public {
        assertEq(usds.allowance(address(till), address(join)), type(uint256).max);
        vm.prank(address(till));
        usds.approve(address(join), 0);
        till.approve();
        assertEq(usds.allowance(address(till), address(join)), type(uint256).max);
    }

    function test_init_of_a_rebated_gem_requires_a_fresh_drip() public {
        RelayPip relay = new RelayPip();
        relay.poke(alm, 90_000_000e18, RAY, 0);
        _debt(1_000_000_000e18);            // so an IDL gem would earn a rebate
        uint8 idl = tally.IDL();            // hoisted: expectRevert arms the NEXT call
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert("Tally/rho-not-updated");
        tally.init(address(0xBA5E), address(relay), idl);
        tally.init(address(0xBA5F), address(relay), tally.MTM());   // MTM books no rebate: fine
        tally.drip();
        tally.init(address(0xBA5E), address(relay), idl);
        // The freshly inited gem earns nothing for the interval before it existed.
        uint256 rb = tally.rebate();
        tally.drip();
        assertEq(tally.rebate(), rb);
    }

    function test_file_alm_requires_pokes_and_reseeds() public {
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert("Tally/rho-not-updated");
        tally.file("alm", address(0xA2));

        // A new, empty ALM: the whole NAV difference must not book as revenue.
        tally.drip(); tally.poke();
        int256 gainBefore = tally.gain();
        int256 fluxBefore = tally.flux();
        tally.file("alm", address(0xA2));
        assertEq(tally.nav(), 0);
        tally.poke();
        assertEq(tally.gain(), gainBefore);
        assertEq(tally.flux(), fluxBefore);
    }

    function test_quit_recovers_float_after_cage() public {
        usds.mint(address(till), 5_000e18);
        tally.cage();
        vm.expectRevert("Tally/not-live");
        tally.settle();
        till.quit(address(usds), address(0xF10A7), 5_000e18);
        assertEq(usds.balanceOf(address(0xF10A7)), 5_000e18);
        assertEq(usds.balanceOf(address(till)), 0);
    }
}
