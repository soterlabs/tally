// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

import { Test } from "forge-std/Test.sol";
import { Tally } from "../src/Tally.sol";
import { RawPip, Erc4626Pip, Erc7540Pip, ATokenPip, RelayPip } from "../src/Pips.sol";

// --- Mocks ---

contract MockToken {
    uint8 public decimals;
    mapping (address => uint256) public balanceOf;
    mapping (address => mapping (address => uint256)) public allowance;
    constructor(uint8 dec) { decimals = dec; }
    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function burn(address from, uint256 amt) external {
        if (from != msg.sender) { allowance[from][msg.sender] -= amt; }
        balanceOf[from] -= amt;
    }
    function slash(address from, uint256 amt) external { balanceOf[from] -= amt; }   // test helper
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 amt) external returns (bool) { balanceOf[msg.sender] -= amt; balanceOf[to] += amt; return true; }
}

// ERC-4626 with a settable price per share and ERC-7540 queues.
contract MockVault is MockToken {
    address public asset;
    uint256 public pps;                            // assets per one share, in asset decimals
    uint256 public pendR; uint256 public claimR;   // shares
    uint256 public pendD; uint256 public claimD;   // assets
    constructor(address asset_, uint8 dec, uint256 pps_) MockToken(dec) { asset = asset_; pps = pps_; }
    function setPps(uint256 p) external { pps = p; }
    function setQueues(uint256 pr, uint256 cr, uint256 pd, uint256 cd) external { pendR = pr; claimR = cr; pendD = pd; claimD = cd; }
    function convertToAssets(uint256 shares) external view returns (uint256) { return shares * pps / 10 ** decimals; }
    function pendingDepositRequest(uint256, address) external view returns (uint256) { return pendD; }
    function claimableDepositRequest(uint256, address) external view returns (uint256) { return claimD; }
    function pendingRedeemRequest(uint256, address) external view returns (uint256) { return pendR; }
    function claimableRedeemRequest(uint256, address) external view returns (uint256) { return claimR; }
}

// sUSDS: a vault with a per-second savings rate.
contract MockSusds is MockVault {
    uint256 public ssr;
    constructor(address usds, uint256 ssr_, uint256 pps_) MockVault(usds, 18, pps_) { ssr = ssr_; }
    function setSsr(uint256 r) external { ssr = r; }
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
    mapping (address => uint256) public dai;   // rad
    function set(bytes32 ilk, uint256 Art_, uint256 rate_) external { Art[ilk] = Art_; rate[ilk] = rate_; }
    function ilks(bytes32 ilk) external view returns (uint256, uint256, uint256, uint256, uint256) {
        return (Art[ilk], rate[ilk], 0, 0, 0);
    }
    function frob(bytes32 ilk, uint256 dart) external { Art[ilk] += dart; }
    function debt(bytes32 ilk) external view returns (uint256) { return Art[ilk] * rate[ilk] / RAY; }
}

// UsdsJoin: join burns USDS from the caller and credits internal dai to usr.
contract MockJoin {
    MockVat vat; MockToken usds;
    constructor(address vat_, address usds_) { vat = MockVat(vat_); usds = MockToken(usds_); }
    function join(address usr, uint256 wad) external {
        usds.burn(msg.sender, wad);
        _credit(usr, wad * 1e27);
    }
    mapping (address => uint256) public credited;
    function _credit(address usr, uint256 rad) internal { credited[usr] += rad; }
    function exit(address usr, uint256 wad) external { usds.mint(usr, wad); }
}

// AllocatorVault: draw frobs the ilk and exits USDS to the buffer.
contract MockAllocatorVault {
    MockVat vat; MockJoin join; bytes32 ilk; address public buffer;
    mapping (address => uint256) public wards;
    constructor(address vat_, address join_, bytes32 ilk_, address buffer_) { vat = MockVat(vat_); join = MockJoin(join_); ilk = ilk_; buffer = buffer_; wards[msg.sender] = 1; }
    function rely(address u) external { wards[u] = 1; }
    function draw(uint256 wad) external {
        require(wards[msg.sender] == 1, "AllocatorVault/not-authorized");
        (, uint256 rate,,,) = vat.ilks(ilk);
        uint256 dart = (wad * 1e27 + rate - 1) / rate;
        vat.frob(ilk, dart);
        join.exit(buffer, wad);
    }
}

contract MockBuffer {
    mapping (address => uint256) public wards;
    constructor() { wards[msg.sender] = 1; }
    function rely(address u) external { wards[u] = 1; }
    function withdraw(address asset, address to, uint256 amt) external {
        require(wards[msg.sender] == 1, "AllocatorBuffer/not-authorized");
        MockToken(asset).transfer(to, amt);
    }
}

// --- Tests ---

contract TallyTest is Test {
    bytes32 constant ILK = "ALLOCATOR-SPARK-A";
    uint256 constant WAD = 1e18;
    uint256 constant RAY = 1e27;
    // sUSDS per-second rate for a 3.52% APY: 1.0352^(1/31536000)
    uint256 constant SSR = 1000000001096988989836188434;
    // (1.0352)^(1/365) - 1
    uint256 constant DAY_SLICE = 0.00009478434042e27;

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

    MockVault sUsdc;   // 6-dec shares over USDC
    MockVault jtrsy;   // ERC-7540, 6-dec over USDC
    MockPool  pool;
    MockAToken spUsds;

    function setUp() public {
        vm.warp(1_757_000_000);
        vat    = new MockVat();
        usds   = new MockToken(18);
        usdc   = new MockToken(6);
        susds  = new MockSusds(address(usds), SSR, 1.05e18);
        join   = new MockJoin(address(vat), address(usds));
        buffer = new MockBuffer();
        vault  = new MockAllocatorVault(address(vat), address(join), ILK, address(buffer));
        tally  = new Tally(address(vat), vow, address(join), address(usds), address(susds));
        vault.rely(address(tally));
        buffer.rely(address(tally));

        sUsdc  = new MockVault(address(usdc), 6, 1_050_000);
        jtrsy  = new MockVault(address(usdc), 6, 1_000_000);
        pool   = new MockPool();
        spUsds = new MockAToken(address(pool), address(usds), 18);

        usds.mint(alm, 1_000_000e18);
        usdc.mint(alm, 500_000e6);
        sUsdc.mint(alm, 100_000e6);
        jtrsy.mint(alm, 200_000e6);
        spUsds.mint(alm, 300_000e18);
        susds.mint(alm, 400_000e18);

        tally.init(ILK, alm, sub);
        tally.file(ILK, "vault",  address(vault));
        tally.file(ILK, "buffer", address(buffer));
        tally.file(ILK, "pad", 0.002e27);   // BR = SSR + 20 bps
        tally.file(ILK, "tip", 0.002e27);   // agent rate = SSR + 20 bps
        tally.init(ILK, address(usds),   address(new RawPip(address(usds))),      tally.MTM());
        tally.init(ILK, address(usdc),   address(new RawPip(address(usdc))),      tally.MTM());
        tally.init(ILK, address(sUsdc),  address(new Erc4626Pip(address(sUsdc))), tally.MTM());
        tally.init(ILK, address(jtrsy),  address(new Erc7540Pip(address(jtrsy))), tally.SDE());
        tally.init(ILK, address(spUsds), address(new ATokenPip(address(spUsds))), tally.MTM());
        tally.init(ILK, address(susds),  address(new Erc4626Pip(address(susds))), tally.SAV());
    }

    function _book() internal view returns (uint256 tab, uint256 owe, int256 gain, int256 sde, uint256 rebate, uint256 sin) {
        return tally.books(ILK);
    }

    // --- pricing ---

    function test_nav() public view {
        // 1,000,000 + 500,000 + 105,000 + 200,000 + 300,000 + 420,000
        assertEq(tally.nav(ILK), 2_525_000e18);
    }

    function test_ssr_daily_nominal_matches_apy_slice() public view {
        uint256 day = tally.ssrps() * 1 days;
        assertApproxEqRel(day, DAY_SLICE, 1e12);   // 1e-6 relative
        assertEq(tally.duty(ILK), tally.ssrps() + uint256(0.002e27) / 365 days);
    }

    function test_poke_books_index_move_not_flows() public {
        usdc.mint(alm, 9_000_000e6);              // flow
        tally.poke(ILK);
        (,, int256 gain,,,) = _book();
        assertEq(gain, 0);

        sUsdc.setPps(1_060_000);                  // +1,000 on 100,000 shares
        pool.set(1.01e27);                        // +3,000 on 300,000 scaled
        tally.poke(ILK);
        (,, gain,,,) = _book();
        assertEq(gain, 4_000e18);

        sUsdc.setPps(1_000_000);                  // -6,000
        tally.poke(ILK);
        (,, gain,,,) = _book();
        assertEq(gain, -2_000e18);
    }

    function test_fee_haircut_is_not_booked_as_loss() public {
        tally.poke(ILK, address(sUsdc));
        tally.file(ILK, address(sUsdc), "fee", 0.01e18);
        assertEq(tally.value(ILK, address(sUsdc)), 103_950e18);   // 105,000 * 0.99
        tally.poke(ILK, address(sUsdc));
        (,, int256 gain,,,) = _book();
        assertEq(gain, 0);
    }

    function test_async_escrow_and_queues() public {
        jtrsy.slash(alm, 50_000e6);
        jtrsy.setQueues(30_000e6, 20_000e6, 10_000e6, 0);
        assertEq(tally.value(ILK, address(jtrsy)), 210_000e18);
        tally.poke(ILK, address(jtrsy));
        (,, int256 gain, int256 sde,,) = _book();
        assertEq(gain, 0);
        assertEq(sde, 0);
    }

    function test_sde_routes_to_sky_with_cap() public {
        jtrsy.setPps(1_010_000);                  // +2,000 on 200,000
        tally.poke(ILK, address(jtrsy));
        (,, int256 gain, int256 sde,,) = _book();
        assertEq(sde, 2_000e18);
        assertEq(gain, 0);

        // Cap Sky's slice at half of today's value (204,000): 50/50 split.
        tally.file(ILK, address(jtrsy), "cap", 102_000e18);
        jtrsy.setPps(1_020_000);                  // +2,000 more
        tally.poke(ILK, address(jtrsy));
        (,, gain, sde,,) = _book();
        assertEq(sde, 3_000e18);
        assertEq(gain, 1_000e18);
    }

    function test_sav_rebates_spread_and_ignores_appreciation() public {
        vm.warp(block.timestamp + 1 days);
        susds.setPps(1.0501e18);                  // SSR accrual on the token
        tally.poke(ILK, address(susds));
        (,, int256 gain,, uint256 rebate,) = _book();
        assertEq(gain, 0);
        // 400,000 * 1.0501 * 0.002 / 365 = 2.3016
        assertApproxEqAbs(rebate, 2.3016e18, 1e15);
    }

    function test_idl_rebates_full_base_rate_on_relayed_idle() public {
        // Idle USDS sitting at the Base ALM, relayed to mainnet.
        RelayPip relay = new RelayPip();
        relay.poke(alm, 90_000_000e18, RAY, 0);
        tally.init(ILK, address(0xBA5E), address(relay), tally.IDL());
        vm.warp(block.timestamp + 1 days);
        tally.poke(ILK, address(0xBA5E));
        (,,,, uint256 rebate,) = _book();
        // 90e6 * (9.47843e-5 + 5.4795e-6) = 8,530.6 + 493.2 = 9,023.7
        assertApproxEqRel(rebate, 9_023.74e18, 1e13);
    }

    function test_relay_pip() public {
        RelayPip relay = new RelayPip();
        relay.poke(alm, 1_000e18, RAY, 0);
        tally.init(ILK, address(0xCAFE), address(relay), tally.MTM());
        relay.poke(alm, 1_000e18, 1.01e27, 0);
        tally.poke(ILK, address(0xCAFE));
        (,, int256 gain,,,) = _book();
        assertEq(gain, 10e18);
    }

    function test_relay_pip_stale_mark_blocks_settlement() public {
        RelayPip relay = new RelayPip();
        vm.expectRevert("RelayPip/no-mark");
        relay.peek(alm);

        relay.poke(alm, 1_000e18, RAY, 0);
        tally.init(ILK, address(0xCAFE), address(relay), tally.IDL());
        vat.set(ILK, 1e18, RAY);

        // Fresh enough: settles.
        vm.warp(block.timestamp + 1 days);
        tally.settle(ILK);

        // One second past `hop` without a new mark: the whole settle stops.
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert("RelayPip/stale");
        tally.settle(ILK);

        // Operator re-marks, or governance widens `hop`: settles again.
        relay.file("hop", 3 days);
        tally.settle(ILK);
    }

    // --- drip ---

    function test_drip_charges_base_rate_and_agent_rate() public {
        vat.set(ILK, 1_000_000_000e18, RAY);
        usds.mint(sub, 30_000_000e18);
        susds.mint(sub, 1_000_000e18);
        vm.warp(block.timestamp + 1 days);
        tally.drip(ILK);
        (uint256 tab, uint256 owe,,,,) = _book();
        // 1e9 * (9.47843e-5 + 0.002/365 = 5.4795e-6) = 94,784.3 + 5,479.5 = 100,263.8
        assertApproxEqRel(tab, 100_263.79e18, 1e13);
        // 30e6 * (9.47843e-5 + 5.4795e-6) + 1.05e6 * 5.4795e-6 = 3,007.9 + 5.75 = 3,013.67
        assertApproxEqRel(owe, 3_013.67e18, 1e13);
    }

    function test_drip_subsidy_first_line_at_cut() public {
        vat.set(ILK, 1_500_000_000e18, RAY);
        tally.file(ILK, "cut", 0.03e27);          // subsidised BR 3.00% nominal
        tally.file(ILK, "line", 1_000_000_000e18);
        vm.warp(block.timestamp + 1 days);
        tally.drip(ILK);
        (uint256 tab,,,,,) = _book();
        // 1e9 * 0.03/365 + 0.5e9 * (9.47843e-5 + 5.4795e-6) = 82,191.8 + 50,131.9
        assertApproxEqRel(tab, 132_323.68e18, 1e13);
    }

    function test_file_rate_requires_fresh_drip() public {
        vm.warp(block.timestamp + 1);
        vm.expectRevert("Tally/rho-not-updated");
        tally.file(ILK, "pad", 1);
    }

    // --- settle ---

    function test_settle_draws_sky_share_pays_prime_keeps_net() public {
        vat.set(ILK, 1_000_000_000e18, RAY);
        usds.mint(sub, 30_000_000e18);
        vm.warp(block.timestamp + 1 days);
        sUsdc.setPps(2_100_000);                  // +105,000 gain on 100,000 shares
        jtrsy.setPps(1_010_000);                  // +2,000 SDE to Sky
        uint256 debtBefore = vat.debt(ILK);

        tally.settle(ILK);

        // tab = 100,263.79  rebate = 2.30
        // sky = tab + 2,000 - rebate = 102,261.49 ; sv = 105,000 + rebate - tab = 4,738.51
        // mint = 107,000.00 -> 107,000 ; dv = 3,007.91 ; send = 7,746.42 -> 7,746 (0.42 owed)
        assertApproxEqAbs(vat.debt(ILK) - debtBefore, 107_000e18, 1e9);   // drawn as ilk debt
        assertEq(usds.balanceOf(sub) - 30_000_000e18, 7_746e18);           // whole USDS to SubProxy
        assertEq(join.credited(vow), (107_000e18 - 7_746e18) * RAY);       // Sky's net to surplus
        assertEq(usds.balanceOf(address(tally)), 0);                        // nothing stranded

        (uint256 tab, uint256 owe, int256 gain, int256 sde, uint256 rebate, uint256 sin) = _book();
        assertEq(tab, 0); assertEq(gain, 0); assertEq(rebate, 0); assertEq(sin, 0);
        assertApproxEqAbs(owe, 0.42e18, 0.01e18);                           // send fraction carried
        assertGe(sde, 0); assertLt(sde, 1e18);                              // mint fraction carried
    }

    function test_settle_carries_negative_prime_share() public {
        vat.set(ILK, 1_000_000_000e18, RAY);
        vm.warp(block.timestamp + 1 days);
        sUsdc.setPps(500_000);                    // -55,000 loss on 100,000 shares
        tally.settle(ILK);
        (,,,,, uint256 sin) = _book();
        // sv = -55,000 + 2.3 - 100,263.8 = -155,261.5 ; dv = 0 => carried
        assertApproxEqRel(sin, 155_261.49e18, 1e13);
        // Sky still drew its full share: floor(tab - rebate)
        assertEq(join.credited(vow), 100_261e18 * RAY);
        assertEq(usds.balanceOf(sub), 0);

        // Next day the prime recovers; the carry nets against the send.
        vm.warp(block.timestamp + 1 days);
        sUsdc.setPps(4_050_000);                  // +355,000
        tally.settle(ILK);
        (,,,,, sin) = _book();
        assertEq(sin, 0);
        assertGt(usds.balanceOf(sub), 0);
    }

    function test_settle_sky_pays_from_hoard_when_send_exceeds_mint() public {
        // Keel-like: no debt, demand side only.
        usds.mint(sub, 10_000_000e18);
        vm.warp(block.timestamp + 1 days);
        // Governance left USDS here for exactly this.
        usds.mint(address(tally), 5_000e18);
        tally.settle(ILK);
        // dv = 10e6 * (9.47843e-5 + 5.4795e-6) = 1,002.64 ; sv = sUSDS rebate 2.30
        // send = 1,004.94 -> 1,004 whole
        assertEq(usds.balanceOf(sub) - 10_000_000e18, 1_004e18);
        assertEq(usds.balanceOf(address(tally)), 3_996e18);
        assertEq(join.credited(vow), 0);
    }

    function test_settle_carries_unpaid_send_when_hoard_is_empty() public {
        usds.mint(sub, 10_000_000e18);
        vm.warp(block.timestamp + 1 days);
        tally.settle(ILK);
        assertEq(usds.balanceOf(sub), 10_000_000e18);
        (, uint256 owe,,,,) = _book();
        assertApproxEqRel(owe, 1_004.94e18, 1e13);   // whole + fraction, all owed
        // Funded later: paid at the next settle, floor(1,004.94 + 1,004.94).
        usds.mint(address(tally), 5_000e18);
        vm.warp(block.timestamp + 1 days);
        tally.settle(ILK);
        assertEq(usds.balanceOf(sub) - 10_000_000e18, 2_009e18);
    }

    function test_gift_pays_out_at_settle() public {
        vat.set(ILK, 1e18, RAY);
        tally.gift(ILK, 1_000e18);
        usds.mint(address(tally), 1_000e18);
        tally.settle(ILK);
        assertEq(usds.balanceOf(sub), 1_000e18);
    }

    function test_settle_permissionless() public {
        vat.set(ILK, 1e18, RAY);
        vm.prank(address(0xDEAD));
        tally.settle(ILK);
    }

    function test_settle_needs_only_allocator_roles() public {
        // A Tally without vault/buffer roles cannot draw: the prime-scoped
        // permission is the only privilege in play.
        MockBuffer b2 = new MockBuffer();
        MockAllocatorVault v2 = new MockAllocatorVault(address(vat), address(join), ILK, address(b2));
        tally.file(ILK, "vault", address(v2));
        vat.set(ILK, 1_000_000_000e18, RAY);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert("AllocatorVault/not-authorized");
        tally.settle(ILK);
    }
}
