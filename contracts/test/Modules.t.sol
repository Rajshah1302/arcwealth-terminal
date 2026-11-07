// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {BondInvestmentModule} from "../modules/BondInvestmentModule.sol";
import {TacticalSleeveModule} from "../modules/TacticalSleeveModule.sol";
import {DemoPriceOracle} from "../demo/DemoPriceOracle.sol";
import {DemoBondIssuer} from "../demo/DemoBondIssuer.sol";
import {StrategyManager} from "../core/StrategyManager.sol";

/// @notice BondInvestmentModule and TacticalSleeveModule.
contract ModulesTest is Base {
    // ================================================================ BondInvestmentModule
    function test_Bond_DepositSplitsEquallyAcrossActiveSeries() public {
        _deposit(alice, 100e6);
        for (uint256 i; i < 3; ++i) assertEq(issuer.unitsOf(i, address(bondM)), 12e6);
        assertEq(bondM.totalValue(), 36e6);
        assertTrue(bondM.isDemo());
        assertEq(bondM.vault(), address(vault));
    }

    function test_Bond_TotalValueIncludesAccruedCoupons() public {
        _deposit(alice, 100e6);
        uint256 navBefore = vault.totalAssets();
        vm.warp(block.timestamp + 15 days);
        uint256 expected = 36e6;
        expected += uint256(12e6) * 400 * 15 / (10_000 * 365);
        expected += uint256(12e6) * 450 * 15 / (10_000 * 365);
        expected += uint256(12e6) * 500 * 15 / (10_000 * 365);
        assertEq(bondM.totalValue(), expected);
        assertGt(vault.totalAssets(), navBefore, "NAV rises with coupon accrual");
    }

    function test_Bond_ClaimCoupons_PublicButPaysModuleOnly() public {
        _deposit(alice, 100e6);
        vm.warp(block.timestamp + 30 days);
        uint256 navBefore = bondM.totalValue();
        uint256 cashBefore = usdc.balanceOf(address(bondM));
        vm.expectEmit(false, false, false, false, address(bondM));
        emit BondInvestmentModule.CouponsClaimed(0);
        vm.prank(attacker);
        bondM.claimCoupons();
        assertEq(usdc.balanceOf(attacker), 0, "caller receives nothing");
        assertGt(usdc.balanceOf(address(bondM)), cashBefore);
        assertEq(bondM.totalValue(), navBefore, "claiming only converts pending coupon to cash");
    }

    function test_Bond_WithdrawSendsOnlyToVault() public {
        _deposit(alice, 100e6);
        uint256 before = usdc.balanceOf(address(vault));
        vm.prank(address(vault));
        uint256 sent = bondM.withdraw(20e6);
        assertEq(sent, 20e6);
        assertEq(usdc.balanceOf(address(vault)) - before, 20e6);
        assertEq(usdc.balanceOf(attacker), 0);
    }

    function test_Bond_OnlyVaultGuards() public {
        vm.startPrank(attacker);
        vm.expectRevert(BondInvestmentModule.OnlyVault.selector);
        bondM.deposit(1);
        vm.expectRevert(BondInvestmentModule.OnlyVault.selector);
        bondM.withdraw(1);
        vm.stopPrank();
    }

    function test_Bond_RollMatured_KeeperOnlyAndReinvests() public {
        _deposit(alice, 100e6);
        vm.warp(block.timestamp + 31 days); // series 0 matured
        vm.prank(attacker);
        vm.expectRevert(BondInvestmentModule.OnlyKeeper.selector);
        bondM.rollMatured();
        vm.prank(manager);
        vm.expectRevert(BondInvestmentModule.OnlyKeeper.selector);
        bondM.rollMatured();
        uint256 navBefore = bondM.totalValue();
        vm.prank(keeper);
        bondM.rollMatured();
        assertEq(issuer.unitsOf(0, address(bondM)), 0, "matured series redeemed");
        assertGt(issuer.unitsOf(1, address(bondM)), 12e6, "rolled into live series");
        assertGt(issuer.unitsOf(2, address(bondM)), 12e6);
        assertApproxEqAbs(bondM.totalValue(), navBefore, 3, "rolling does not change NAV");
    }

    function test_Bond_LiquidValueCappedByIssuerReserve() public {
        _deposit(alice, 100e6);
        assertApproxEqAbs(bondM.liquidValue(), bondM.totalValue(), 1);
    }

    function test_Bond_InstantExitViaVaultRedeemsAtPar() public {
        uint256 sh = _deposit(alice, 250e6);
        vm.prank(alice);
        vault.requestRedeem(sh / 2);
        vm.prank(keeper);
        vault.fulfillRedeem(alice);
        assertGt(vault.claimable(alice), 120e6);
    }

    function test_Bond_ConstructorGuards() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 1;
        vm.expectRevert(abi.encodeWithSelector(BondInvestmentModule.DuplicateSeries.selector, 1));
        new BondInvestmentModule(USDC, address(vault), address(issuer), ids);
        ids[1] = 9;
        vm.expectRevert(DemoBondIssuer.InvalidSeries.selector);
        new BondInvestmentModule(USDC, address(vault), address(issuer), ids);
        ids[1] = 2;
        vm.expectRevert(BondInvestmentModule.ZeroAddress.selector);
        new BondInvestmentModule(USDC, address(0), address(issuer), ids);
    }

    // ================================================================ TacticalSleeveModule
    function test_Tactical_DepositHoldsCashUntilRebalance() public {
        _deposit(alice, 100e6);
        assertEq(usdc.balanceOf(address(tacM)), 27e6);
        assertEq(dTBILL.balanceOf(address(tacM)), 0);
        assertEq(tacM.totalValue(), 27e6);
    }

    function _tbillValue() internal view returns (uint256) {
        return dTBILL.balanceOf(address(tacM)) * 100e8 / 1e20;
    }

    function test_Tactical_RebalanceToCalmRegimeTarget() public {
        _deposit(alice, 100e6);
        vm.expectEmit(false, false, false, false, address(tacM));
        emit TacticalSleeveModule.TacticalRebalanced(0, 0, 0);
        vm.prank(keeper);
        tacM.rebalanceTactical();
        // regime 3 (Calm): cash 20 / tbill 80 / puts 0
        assertApproxEqRel(_tbillValue(), 21.6e6, 0.005e18);
        assertApproxEqRel(tacM.totalValue(), 27e6, 0.005e18);
    }

    function test_Tactical_RegimeChangeSellsDownToRiskOffTarget() public {
        _deposit(alice, 100e6);
        vm.prank(keeper);
        tacM.rebalanceTactical();
        uint256 heldCalm = _tbillValue();
        vm.prank(keeper);
        sm.postRegimeInputs(90, true, 500, 1000); // RiskOff: tbill 40%
        assertEq(sm.currentRegime(), 0);
        vm.prank(keeper);
        tacM.rebalanceTactical();
        uint256 nav = tacM.totalValue();
        assertLt(_tbillValue(), heldCalm);
        assertApproxEqAbs(_tbillValue(), nav * 4000 / 10_000, nav * 200 / 10_000 + 1);
        assertEq(tacM.putCollateral(), nav * 1000 / 10_000, "puts bucket = reserved USDC only");
    }

    function test_Tactical_ManagerOverrideShiftsTarget() public {
        _deposit(alice, 100e6);
        vm.prank(manager);
        sm.tacticalOverride(address(vault), 500, -500, "de-risk");
        (uint16 c, uint16 t, uint16 p) = sm.tacticalAllocation(address(vault));
        assertEq(c, 2500);
        assertEq(t, 7500);
        assertEq(p, 0);
        vm.prank(keeper);
        tacM.rebalanceTactical();
        assertApproxEqRel(_tbillValue(), 27e6 * 75 / 100, 0.01e18);
    }

    function test_Tactical_WithinToleranceBandDoesNotTrade() public {
        _deposit(alice, 100e6);
        vm.prank(keeper);
        tacM.rebalanceTactical();
        uint256 held = dTBILL.balanceOf(address(tacM));
        vm.prank(keeper);
        tacM.rebalanceTactical();
        assertEq(dTBILL.balanceOf(address(tacM)), held);
    }

    function test_Tactical_KeeperOnly_VaultOnly() public {
        vm.prank(attacker);
        vm.expectRevert(TacticalSleeveModule.OnlyKeeper.selector);
        tacM.rebalanceTactical();
        vm.prank(pauser);
        vm.expectRevert(TacticalSleeveModule.OnlyKeeper.selector);
        tacM.rebalanceTactical();
        vm.startPrank(attacker);
        vm.expectRevert(TacticalSleeveModule.OnlyVault.selector);
        tacM.deposit(1);
        vm.expectRevert(TacticalSleeveModule.OnlyVault.selector);
        tacM.withdraw(1);
        vm.stopPrank();
    }

    function test_Tactical_StaleOracleRevertsRebalance_ButNavFallsBack() public {
        _deposit(alice, 100e6);
        vm.prank(keeper);
        tacM.rebalanceTactical();
        uint256 nav = tacM.totalValue();
        vm.warp(block.timestamp + 2 hours);
        vm.prank(keeper);
        vm.expectPartialRevert(DemoPriceOracle.StalePrice.selector);
        tacM.rebalanceTactical();
        assertEq(tacM.totalValue(), nav, "cached NAV so vault accounting never reverts");
        assertEq(vault.totalAssets(), usdc.balanceOf(address(vault)) + _moduleSum());
    }

    function test_Tactical_WithdrawSellsTbillWhenCashShort() public {
        _deposit(alice, 100e6);
        vm.prank(keeper);
        tacM.rebalanceTactical();
        uint256 before = usdc.balanceOf(address(vault));
        vm.prank(address(vault));
        uint256 sent = tacM.withdraw(20e6);
        assertApproxEqAbs(sent, 20e6, 2);
        assertEq(usdc.balanceOf(address(vault)) - before, sent);
    }

    function test_Tactical_ConstructorGuards() public {
        vm.expectRevert(TacticalSleeveModule.InvalidAllocation.selector);
        new TacticalSleeveModule(USDC, address(vault), address(router), address(oracle), address(sm), USDC);
        vm.expectRevert(TacticalSleeveModule.ZeroAddress.selector);
        new TacticalSleeveModule(USDC, address(vault), address(0), address(oracle), address(sm), address(dTBILL));
    }

    function test_Tactical_SleeveHasNoOnChainPuts_Documented() public view {
        // putsBps only reserves cash; there is no function that writes options from this module
        assertEq(tacM.putCollateral(), 0, "calm regime: puts 0");
    }

    function test_Regime_Table() public {
        _checkRegime(90, true, 0, 5000, 4000, 1000);
        _checkRegime(81, true, 0, 5000, 4000, 1000);
        _checkRegime(80, true, 1, 3000, 3000, 4000);
        _checkRegime(60, true, 1, 3000, 3000, 4000);
        _checkRegime(59, true, 2, 2500, 5500, 2000);
        _checkRegime(31, true, 2, 2500, 5500, 2000);
        _checkRegime(30, true, 3, 2000, 8000, 0);
        _checkRegime(10, false, 0, 5000, 4000, 1000); // downtrend always RiskOff
    }

    function _checkRegime(uint16 vol, bool up, uint8 id, uint16 cash, uint16 tbill, uint16 puts) internal {
        vm.prank(keeper);
        sm.postRegimeInputs(vol, up, 450, 1000);
        assertEq(sm.currentRegime(), id);
        (uint16 c, uint16 t, uint16 p) = sm.tacticalAllocation(address(vault));
        assertEq(c, cash);
        assertEq(t, tbill);
        assertEq(p, puts);
        assertEq(uint256(c) + t + p, 10_000);
    }

    function test_Regime_EventAndKeeperOnly() public {
        vm.expectEmit(true, true, false, true, address(sm));
        emit StrategyManager.RegimeChanged(3, 0, 95, true, 450, 1000);
        vm.prank(keeper);
        sm.postRegimeInputs(95, true, 450, 1000);
        vm.prank(manager);
        vm.expectPartialRevert(bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")));
        sm.postRegimeInputs(10, true, 1, 1);
    }
}
