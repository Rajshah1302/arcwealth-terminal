// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {SIFStrategyVault} from "../core/SIFStrategyVault.sol";
import {RiskManager} from "../core/RiskManager.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Deposit path, limits, pause, share price / NAV, fees and instant exits.
contract VaultTest is Base {
    // ---------------------------------------------------------------- deployment / deposit
    function test_Deploy_InitialState() public view {
        assertEq(vault.decimals(), 12);
        assertEq(vault.asset(), USDC);
        assertEq(vault.moduleCount(), 3);
        assertEq(vault.sharePrice(), 1e6, "initial share price is 1.0 USDC");
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.feeRecipient(), feeRecipient);
        assertEq(vault.FEE_BPS(), 100);
        assertTrue(vault.isModule(address(bondM)) && vault.isModule(address(ccM)) && vault.isModule(address(tacM)));
    }

    function test_Deposit_MintsSharesRoutesAndKeepsIdleBuffer() public {
        _onboard(alice, 100e6);
        vm.expectEmit(true, true, false, true, address(vault));
        emit IERC4626.Deposit(alice, alice, 100e6, 100e6 * 1e6);
        vm.prank(alice);
        uint256 sh = vault.deposit(100e6, alice);
        assertEq(sh, 100e6 * 1e6);
        assertEq(vault.balanceOf(alice), sh);
        assertEq(vault.idle(), 10e6, "exactly the 10% idle floor stays in the vault");
        (address[] memory mods, uint256[] memory vals) = vault.moduleBreakdown();
        assertEq(mods.length, 3);
        assertEq(vals[0], 36e6, "bond sleeve = 40% of 90");
        assertEq(vals[2], 27e6, "tactical sleeve = 30% of 90");
        assertApproxEqRel(vals[1], 27e6, 0.01e18, "covered-call sleeve ~ 27 less swap fee");
        (uint256 basis, uint256 held, uint256 at) = iv.positionOf(alice, address(vault));
        assertEq(basis, 100e6);
        assertEq(held, sh);
        assertEq(at, block.timestamp);
    }

    function test_Mint_Works() public {
        _onboard(alice, 100e6);
        vm.prank(alice);
        uint256 spent = vault.mint(50e6 * 1e6, alice);
        assertApproxEqAbs(spent, 50e6, 1);
        assertEq(vault.balanceOf(alice), 50e6 * 1e6);
    }

    function test_NavEqualsCashPlusModules() public {
        _deposit(alice, 120e6);
        assertEq(vault.totalAssets(), usdc.balanceOf(address(vault)) + _moduleSum());
    }

    // ---------------------------------------------------------------- limits
    function test_MinDeposit_BelowTenUsdcReverts() public {
        _onboard(alice, 100e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SIFStrategyVault.DepositTooSmall.selector, 10e6 - 1, 10e6));
        vault.deposit(10e6 - 1, alice);
    }

    function test_MinDeposit_ExactlyTenUsdcWorks() public {
        assertGt(_deposit(alice, 10e6), 0);
    }

    function test_UserCap_Exactly250Works_Above250Reverts() public {
        assertGt(_deposit(alice, 250e6), 0);
        _onboard(bob, 251e6);
        vm.prank(bob);
        vm.expectPartialRevert(ERC4626.ERC4626ExceededMaxDeposit.selector);
        vault.deposit(250e6 + 1, bob);
    }

    function test_UserCap_SecondDepositBeyondCapReverts() public {
        _deposit(alice, 200e6);
        _onboard(alice, 100e6);
        vm.prank(alice);
        vm.expectPartialRevert(ERC4626.ERC4626ExceededMaxDeposit.selector);
        vault.deposit(60e6, alice);
        vm.prank(alice);
        vault.deposit(40e6, alice); // still inside the cap
    }

    function test_TvlCap_1000_BlocksFifthDepositor() public {
        _deposit(alice, 250e6);
        _deposit(bob, 250e6);
        _deposit(carol, 250e6);
        _deposit(dave, 250e6);
        assertLe(vault.totalAssets(), 1_000e6);
        _onboard(erin, 10e6);
        assertLt(vault.maxDeposit(erin), 10e6, "less than the min deposit of headroom left");
        vm.prank(erin);
        vm.expectPartialRevert(ERC4626.ERC4626ExceededMaxDeposit.selector);
        vault.deposit(10e6, erin);
    }

    function test_TvlCap_ExactHeadroomBoundary() public {
        _gov(address(risk), abi.encodeCall(RiskManager.setLimits, (address(vault), 10e6, 300e6, 250e6, 1000)));
        _deposit(alice, 250e6);
        _onboard(bob, 300e6);
        uint256 room = vault.maxDeposit(bob);
        assertEq(room, 300e6 - vault.totalAssets());
        vm.prank(bob);
        vm.expectPartialRevert(ERC4626.ERC4626ExceededMaxDeposit.selector);
        vault.deposit(room + 1, bob);
        vm.prank(bob);
        vault.deposit(room, bob);
    }

    function test_MaxDeposit_NotZeroedByMissingDisclosure() public view {
        // disclosure is enforced by the deposit hook (DisclosureRequired), not by the max* views
        assertFalse(iv.hasAccepted(alice, address(vault)));
        assertEq(vault.maxDeposit(alice), 250e6);
        assertGt(vault.maxMint(alice), 0);
    }

    function test_RiskManager_Defaults_AreS1Limits() public {
        RiskManager fresh = new RiskManager(address(this));
        assertEq(fresh.minDeposit(address(vault)), 10e6);
        assertEq(fresh.maxDeposit(address(vault), 0, 0), 250e6);
        assertEq(fresh.maxDeposit(address(vault), 900e6, 0), 100e6);
        assertEq(fresh.maxDeposit(address(vault), 1_000e6, 0), 0);
        assertEq(fresh.maxDeposit(address(vault), 0, 250e6), 0);
        assertEq(fresh.minIdleBps(address(vault)), 1000);
    }

    // ---------------------------------------------------------------- pause
    function test_Pause_BlocksDepositsAndMint() public {
        _onboard(alice, 100e6);
        vm.prank(pauser);
        vault.pause();
        assertEq(vault.maxDeposit(alice), 0);
        vm.startPrank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.deposit(50e6, alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.mint(1e12, alice);
        vm.stopPrank();
    }

    function test_Pause_DoesNotBlockExits() public {
        _deposit(alice, 200e6);
        vm.prank(pauser);
        vault.pause();
        uint256 maxW = vault.maxWithdraw(alice);
        assertGt(maxW, 0);
        vm.prank(alice);
        vault.withdraw(maxW / 2, alice, alice);
        uint256 maxR = vault.maxRedeem(alice);
        vm.prank(alice);
        vault.redeem(maxR / 2, alice, alice);
        // async exit also works while paused
        uint256 left = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(left);
        vm.prank(keeper);
        vault.fulfillRedeem(alice);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.claimRedeem();
        assertGt(usdc.balanceOf(alice), before);
    }

    function test_Pause_StopsRebalance_UnpauseResumes() public {
        _deposit(alice, 100e6);
        vm.prank(pauser);
        vault.pause();
        vm.prank(keeper);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.rebalance();
        vm.prank(pauser);
        vault.unpause();
        vm.prank(keeper);
        vault.rebalance();
        _deposit(bob, 20e6);
    }

    function test_Pause_OnlyPauser() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.pause();
        vm.prank(keeper);
        vm.expectRevert();
        vault.pause();
    }

    // ---------------------------------------------------------------- share price == NAV
    function test_SharePrice_EqualsNavPerShare() public {
        _deposit(alice, 200e6);
        _deposit(bob, 100e6);
        uint256 nav = vault.totalAssets();
        assertApproxEqRel(vault.sharePrice(), nav * 1e12 / vault.totalSupply(), 1e12);
        assertEq(vault.sharePrice(), vault.convertToAssets(1e12));
    }

    function test_SharePrice_TracksUnderlyingPriceMove() public {
        _deposit(alice, 200e6);
        uint256 p0 = vault.sharePrice();
        uint256 nav0 = vault.totalAssets();
        _setPrice(address(dBTC), 66_000e8); // +10%
        _setPrice(address(dETH), 3_300e8);
        _refresh();
        uint256 nav1 = vault.totalAssets();
        uint256 p1 = vault.sharePrice();
        assertGt(nav1, nav0);
        assertGt(p1, p0);
        assertApproxEqRel(p1, nav1 * 1e12 / vault.totalSupply(), 1e12);
    }

    function test_SharePrice_NewDepositorPaysNav() public {
        _deposit(alice, 100e6);
        _setPrice(address(dBTC), 66_000e8);
        _refresh();
        uint256 navBefore = vault.totalAssets();
        uint256 supplyBefore = vault.totalSupply();
        uint256 sh = _deposit(bob, 100e6);
        assertApproxEqRel(sh, 100e6 * supplyBefore / navBefore, 1e12, "shares minted at NAV");
    }

    // ---------------------------------------------------------------- fee shares
    function test_Fee_OnePercentPerYearInShares() public {
        _deposit(alice, 200e6);
        uint256 supply = vault.totalSupply();
        vm.warp(block.timestamp + 365 days);
        vault.checkpointFee(); // anyone
        assertEq(vault.balanceOf(feeRecipient), supply / 100, "1% of supply minted over one year");
        assertEq(vault.totalSupply(), supply + supply / 100);
        assertEq(vault.lastFeeTs(), block.timestamp);
        (, uint256 heldShares,) = iv.positionOf(feeRecipient, address(vault));
        assertEq(heldShares, supply / 100, "fee shares tracked in the investor registry");
    }

    function test_Fee_ProRata() public {
        _deposit(alice, 200e6);
        uint256 supply = vault.totalSupply();
        vm.warp(block.timestamp + 73 days);
        vm.prank(attacker);
        vault.checkpointFee();
        assertEq(vault.balanceOf(feeRecipient), supply * 100 * 73 days / (10_000 * 365 days));
    }

    function test_Fee_EventCarriesSharesAndDt() public {
        _deposit(alice, 200e6);
        uint256 supply = vault.totalSupply();
        vm.warp(block.timestamp + 30 days);
        vm.recordLogs();
        vault.checkpointFee();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == SIFStrategyVault.FeeCheckpoint.selector) {
                (uint256 feeShares, uint256 dt, uint256 price) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                assertEq(feeShares, supply * 100 * 30 days / (10_000 * 365 days));
                assertEq(dt, 30 days);
                assertEq(price, vault.sharePrice());
                found = true;
            }
        }
        assertTrue(found, "FeeCheckpoint emitted");
    }

    function test_Fee_NoDoubleChargeInSameBlock() public {
        _deposit(alice, 200e6);
        vm.warp(block.timestamp + 10 days);
        vault.checkpointFee();
        uint256 f = vault.balanceOf(feeRecipient);
        vault.checkpointFee();
        assertEq(vault.balanceOf(feeRecipient), f);
    }

    function test_Fee_AccruedOnDepositAndNeverInUsdc() public {
        _deposit(alice, 100e6);
        uint256 supply = vault.totalSupply();
        _skip(100 days);
        uint256 feeUsdcBefore = usdc.balanceOf(feeRecipient);
        _deposit(bob, 50e6);
        assertEq(vault.balanceOf(feeRecipient), supply * 100 * 100 days / (10_000 * 365 days));
        assertEq(usdc.balanceOf(feeRecipient), feeUsdcBefore, "fee is paid in shares, not USDC");
    }

    function test_NoEntryOrExitFee() public {
        uint256 sh = _deposit(alice, 100e6);
        assertEq(sh, 100e6 * 1e6, "no entry fee at par");
        uint256 maxW = vault.maxWithdraw(alice);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(maxW, alice, alice);
        assertEq(usdc.balanceOf(alice) - before, maxW, "exact assets out, no exit fee");
    }

    // ---------------------------------------------------------------- instant withdraw limited to idle
    function test_InstantWithdraw_LimitedToIdleBuffer() public {
        _deposit(alice, 250e6);
        uint256 idle = vault.idle();
        assertEq(idle, 25e6);
        assertEq(vault.maxWithdraw(alice), idle);
        assertLt(idle, vault.convertToAssets(vault.balanceOf(alice)));
        vm.prank(alice);
        vm.expectPartialRevert(ERC4626.ERC4626ExceededMaxWithdraw.selector);
        vault.withdraw(idle + 1, alice, alice);
        vm.prank(alice);
        vault.withdraw(idle, alice, alice);
        assertEq(usdc.balanceOf(alice), idle);
        assertEq(vault.idle(), 0);
        assertEq(vault.maxWithdraw(alice), 0);
    }

    function test_InstantRedeem_LimitedToIdleBuffer() public {
        uint256 sh = _deposit(alice, 250e6);
        uint256 maxR = vault.maxRedeem(alice);
        assertLt(maxR, sh);
        assertEq(maxR, vault.convertToShares(vault.idle()));
        vm.prank(alice);
        vm.expectPartialRevert(ERC4626.ERC4626ExceededMaxRedeem.selector);
        vault.redeem(maxR + 1, alice, alice);
        vm.prank(alice);
        uint256 out = vault.redeem(maxR, alice, alice);
        assertLe(out, 25e6);
        assertGe(out, 25e6 - 1);
    }

    function test_InstantWithdraw_SmallPositionFullyLiquid() public {
        // min-idle floor is 10% so a 10 USDC deposit can only pull ~1 USDC instantly
        _deposit(alice, 10e6);
        assertEq(vault.maxWithdraw(alice), 1e6);
    }

    function test_Withdraw_RecordsCostBasisReduction() public {
        _deposit(alice, 250e6);
        (uint256 basis0, uint256 sh0,) = iv.positionOf(alice, address(vault));
        uint256 maxR = vault.maxRedeem(alice);
        vm.prank(alice);
        vault.redeem(maxR, alice, alice);
        (uint256 basis1, uint256 sh1,) = iv.positionOf(alice, address(vault));
        assertEq(sh1, sh0 - maxR);
        assertEq(basis1, basis0 - basis0 * maxR / sh0);
    }

    // ---------------------------------------------------------------- stale oracle in routing
    function test_StaleOracle_DepositStillSucceeds_RouteFailedEmitted() public {
        vm.warp(block.timestamp + 2 hours); // oracle is now stale (> 1h)
        _onboard(alice, 100e6);
        vm.expectEmit(true, false, false, false, address(vault));
        emit SIFStrategyVault.RouteFailed(address(ccM), 0, "");
        vm.prank(alice);
        uint256 sh = vault.deposit(100e6, alice);
        assertGt(sh, 0);
        assertEq(vault.balanceOf(alice), sh);
        assertEq(ccM.totalValue(), 0, "nothing invested into the covered-call sleeve");
        assertGt(vault.idle(), 10e6, "failed allocation stays idle");
        assertEq(vault.totalAssets(), 100e6, "no funds lost");
    }

    // ---------------------------------------------------------------- rebalance / unwind keep funds in vault
    function test_Unwind_MovesModuleCashToIdle() public {
        _deposit(alice, 250e6);
        uint256 idleBefore = vault.idle();
        uint256 navBefore = vault.totalAssets();
        vm.prank(keeper);
        vault.unwind(50e6);
        assertGe(vault.idle(), idleBefore + 50e6 - 1);
        assertApproxEqAbs(vault.totalAssets(), navBefore, 1e6);
        assertEq(usdc.balanceOf(keeper), 0);
    }

    function test_Rebalance_KeepsIdleFloorAndNav() public {
        _deposit(alice, 250e6);
        uint256 nav = vault.totalAssets();
        vm.prank(keeper);
        vault.rebalance();
        assertApproxEqRel(vault.totalAssets(), nav, 0.01e18);
        assertGe(vault.idle() + 1, nav / 10 - nav / 200);
    }
}
