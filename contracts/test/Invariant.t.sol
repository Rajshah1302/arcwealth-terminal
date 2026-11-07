// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Base} from "./Base.t.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {SIFStrategyVault} from "../core/SIFStrategyVault.sol";
import {InvestorVault} from "../core/InvestorVault.sol";
import {DemoPriceOracle} from "../demo/DemoPriceOracle.sol";
import {CoveredCallModule} from "../modules/CoveredCallModule.sol";

/// @dev Random-action driver: deposits, instant exits, async exits, claims, pause, time, prices, calls.
contract VaultHandler is Test {
    SIFStrategyVault public vault;
    InvestorVault public iv;
    MockUSDC public usdc;
    DemoPriceOracle public oracle;
    CoveredCallModule public cc;
    address public keeper;
    address public pauser;
    address[3] public tokens;
    address[] public actors;
    uint256 public calls;

    constructor(
        SIFStrategyVault v, InvestorVault i, MockUSDC u, DemoPriceOracle o, CoveredCallModule c,
        address k, address p, address[3] memory t, bytes32 disc
    ) {
        vault = v; iv = i; usdc = u; oracle = o; cc = c; keeper = k; pauser = p; tokens = t;
        for (uint256 a; a < 4; ++a) {
            address actor = makeAddr(string.concat("actor", vm.toString(a)));
            actors.push(actor);
            vm.startPrank(actor);
            usdc.approve(address(vault), type(uint256).max);
            iv.acceptDisclosure(address(vault), disc);
            vm.stopPrank();
        }
    }

    function actorCount() external view returns (uint256) { return actors.length; }

    function _a(uint256 seed) internal view returns (address) { return actors[seed % actors.length]; }

    function deposit(uint256 seed, uint256 amt) external {
        address a = _a(seed);
        uint256 cap = vault.maxDeposit(a);
        if (cap < 10e6) return;
        amt = bound(amt, 10e6, cap);
        usdc.mint(a, amt);
        vm.prank(a);
        vault.deposit(amt, a);
    }

    function instantRedeem(uint256 seed, uint256 shares) external {
        address a = _a(seed);
        uint256 m = vault.maxRedeem(a);
        if (m == 0) return;
        shares = bound(shares, 1, m);
        vm.prank(a);
        vault.redeem(shares, a, a);
    }

    function requestRedeem(uint256 seed, uint256 shares) external {
        address a = _a(seed);
        uint256 bal = vault.balanceOf(a);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        vm.prank(a);
        vault.requestRedeem(shares);
    }

    function cancelRedeem(uint256 seed) external {
        address a = _a(seed);
        if (vault.pendingRedeem(a) == 0) return;
        vm.prank(a);
        vault.cancelRedeem();
    }

    function fulfill(uint256 seed) external {
        address a = _a(seed);
        if (vault.pendingRedeem(a) == 0) return;
        vm.prank(keeper);
        try vault.fulfillRedeem(a) {} catch {}
    }

    function claim(uint256 seed) external {
        address a = _a(seed);
        if (vault.claimable(a) == 0) return;
        vm.prank(a);
        vault.claimRedeem();
    }

    function unwind(uint256 amt) external {
        vm.prank(keeper);
        vault.unwind(bound(amt, 0, 300e6));
    }

    function rebalance() external {
        vm.prank(keeper);
        try vault.rebalance() {} catch {}
    }

    function togglePause(uint256 seed) external {
        bool isPaused = vault.paused();
        if (isPaused) {
            vm.prank(pauser);
            vault.unpause();
        } else if (seed % 4 == 0) {
            vm.prank(pauser);
            vault.pause();
        }
    }

    function passTime(uint256 dt, uint256 moveSeed) external {
        vm.warp(block.timestamp + bound(dt, 1, 3 days));
        vm.startPrank(keeper);
        for (uint256 i; i < 3; ++i) {
            (uint256 p,) = oracle.getPriceUnsafe(tokens[i]);
            uint256 range = i == 2 ? 100 : 1000; // +-0.5% for tbill, +-5% for crypto
            uint256 bps = 10_000 - range / 2 + (uint256(keccak256(abi.encode(moveSeed, i))) % (range + 1));
            oracle.setPrice(tokens[i], p * bps / 10_000);
        }
        vm.stopPrank();
    }

    function writeCall(uint256 seed, uint256 frac) external {
        address t = tokens[seed % 2];
        uint256 held = IERCBal(t).balanceOf(address(cc));
        uint256 open = cc.openShort(t);
        if (held <= open) return;
        uint256 qty = bound(frac, 1, held - open);
        (uint256 spot,) = oracle.getPriceUnsafe(t);
        vm.prank(keeper);
        try cc.writeCall(t, qty, spot * 105 / 100, uint64(block.timestamp + 2 days), 0) { ++calls; } catch {}
    }

    function settle(uint256 id) external {
        uint256 n = cc.callCount();
        if (n == 0) return;
        vm.prank(keeper);
        try cc.settle(id % n) {} catch {}
    }
}

interface IERCBal { function balanceOf(address) external view returns (uint256); }

/// @notice Stateful invariants over the fully wired S1 system.
contract InvariantTest is Base {
    VaultHandler internal h;

    function setUp() public override {
        super.setUp();
        address[3] memory ts = [address(dBTC), address(dETH), address(dTBILL)];
        h = new VaultHandler(vault, iv, usdc, oracle, ccM, keeper, pauser, ts, DISC);
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](11);
        sel[0] = VaultHandler.deposit.selector;
        sel[1] = VaultHandler.instantRedeem.selector;
        sel[2] = VaultHandler.requestRedeem.selector;
        sel[3] = VaultHandler.cancelRedeem.selector;
        sel[4] = VaultHandler.fulfill.selector;
        sel[5] = VaultHandler.claim.selector;
        sel[6] = VaultHandler.unwind.selector;
        sel[7] = VaultHandler.passTime.selector;
        sel[8] = VaultHandler.writeCall.selector;
        sel[9] = VaultHandler.settle.selector;
        sel[10] = VaultHandler.togglePause.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
    }

    function _holders() internal view returns (address[] memory hs) {
        uint256 n = h.actorCount();
        hs = new address[](n + 1);
        for (uint256 i; i < n; ++i) hs[i] = h.actors(i);
        hs[n] = feeRecipient;
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    function invariant_VaultPlusModulesCoverClaimsAndShareBackedAssets() public view {
        uint256 raw = usdc.balanceOf(address(vault)) + bondM.totalValue() + ccM.totalValue() + tacM.totalValue();
        uint256 shareBacked = vault.convertToAssets(vault.totalSupply());
        assertGe(raw, vault.totalClaimable() + shareBacked, "vault USDC + module values >= claims + share-backed assets");
        // and no holder's redeemable value can exceed the NAV
        uint256 sum;
        address[] memory hs = _holders();
        for (uint256 i; i < hs.length; ++i) {
            sum += vault.convertToAssets(vault.balanceOf(hs[i]) + vault.pendingRedeem(hs[i]));
        }
        assertLe(sum, vault.totalAssets());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    function invariant_ClaimsAreFullyCashBackedAndLedgerConsistent() public view {
        assertGe(usdc.balanceOf(address(vault)), vault.totalClaimable(), "claims always backed by vault cash");
        uint256 sum;
        for (uint256 i; i < h.actorCount(); ++i) sum += vault.claimable(h.actors(i));
        assertEq(sum, vault.totalClaimable(), "per-user claims sum to total");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    function invariant_EscrowedSharesMatchPendingRequests() public view {
        uint256 sum;
        for (uint256 i; i < h.actorCount(); ++i) sum += vault.pendingRedeem(h.actors(i));
        assertEq(vault.balanceOf(address(vault)), sum);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    function invariant_RegistrySharesEqualSupply() public view {
        uint256 sum;
        address[] memory hs = _holders();
        for (uint256 i; i < hs.length; ++i) {
            (, uint256 s,) = iv.positionOf(hs[i], address(vault));
            sum += s;
        }
        assertEq(sum, vault.totalSupply(), "investor registry shares == ERC20 supply");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    function invariant_IdleNeverCountsReservedClaims() public view {
        assertEq(vault.idle() + vault.totalClaimable() >= usdc.balanceOf(address(vault)), true);
        assertLe(vault.idle(), usdc.balanceOf(address(vault)));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    function invariant_NoOperatorEverHoldsUsdc() public view {
        assertEq(usdc.balanceOf(keeper), 0);
        assertEq(usdc.balanceOf(manager), 0);
        assertEq(usdc.balanceOf(pauser), 0);
    }
}
