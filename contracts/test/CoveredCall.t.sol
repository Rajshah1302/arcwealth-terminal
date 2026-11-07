// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {CoveredCallModule} from "../modules/CoveredCallModule.sol";
import {RiskManager} from "../core/RiskManager.sol";
import {DemoPriceOracle} from "../demo/DemoPriceOracle.sol";
import {DemoOptionsCounterparty} from "../demo/DemoOptionsCounterparty.sol";
import {IRiskManager} from "../interfaces/IArcWealth.sol";

/// @notice CoveredCallModule: coverage, strike/expiry limits, premium cap, settlement, NAV and access.
contract CoveredCallTest is Base {
    uint64 internal expiry;
    uint256 internal spot;

    function setUp() public override {
        super.setUp();
        _deposit(alice, 250e6);
        expiry = uint64(block.timestamp + 7 days);
        (spot,) = oracle.getPriceUnsafe(address(dBTC));
    }

    function _held() internal view returns (uint256) {
        return dBTC.balanceOf(address(ccM));
    }

    function _write(uint256 qty, uint256 strike, uint64 exp, uint256 premium) internal returns (uint256 id) {
        id = ccM.callCount();
        vm.prank(keeper);
        ccM.writeCall(address(dBTC), qty, strike, exp, premium);
    }

    // ---------------------------------------------------------------- deposit / write
    function test_Deposit_SplitsAcrossUnderlyingsByBps() public view {
        uint256 btcVal = _held() * spot / 1e20;
        uint256 ethVal = dETH.balanceOf(address(ccM)) * 3_000e8 / 1e20;
        assertGt(btcVal, 0);
        assertApproxEqRel(btcVal, ethVal, 0.001e18);
        assertApproxEqRel(ccM.totalValue(), 67.5e6, 0.01e18);
        assertEq(ccM.openShort(address(dBTC)), 0);
    }

    function test_WriteCall_HappyPath_EmitsAndPaysPremium() public {
        uint256 qty = _held() / 2;
        uint256 strike = spot * 105 / 100;
        uint256 cashBefore = usdc.balanceOf(address(ccM));
        uint256 cpBefore = cp.availableLiquidity();
        vm.expectEmit(true, true, false, true, address(ccM));
        emit CoveredCallModule.CallWritten(0, address(dBTC), qty, strike, expiry, 1e6, address(cp));
        uint256 id = _write(qty, strike, expiry, 1e6);
        assertEq(id, 0);
        assertEq(ccM.callCount(), 1);
        assertEq(ccM.openShort(address(dBTC)), qty);
        assertEq(usdc.balanceOf(address(ccM)) - cashBefore, 1e6, "premium paid in real USDC");
        assertEq(cpBefore - cp.availableLiquidity(), 1e6);
        CoveredCallModule.Call memory c = ccM.getCall(0);
        assertEq(c.underlying, address(dBTC));
        assertEq(c.qty, qty);
        assertEq(c.strike, strike);
        assertEq(uint8(c.status), uint8(CoveredCallModule.CallStatus.Open));
    }

    // ---------------------------------------------------------------- coverage (short > unlocked)
    function test_Coverage_ShortAboveHoldingsReverts() public {
        uint256 held = _held();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(RiskManager.CoverageViolation.selector, held, held + 1));
        ccM.writeCall(address(dBTC), held + 1, spot, expiry, 0);
    }

    function test_Coverage_SecondCallCannotOverlapLockedUnits() public {
        uint256 held = _held();
        uint256 first = held / 2;
        _write(first, spot * 105 / 100, expiry, 0);
        uint256 rest = held - first;
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(RiskManager.CoverageViolation.selector, held, held + 1));
        ccM.writeCall(address(dBTC), rest + 1, spot * 105 / 100, expiry, 0);
        _write(rest, spot * 105 / 100, expiry, 0); // exactly 100% coverage is allowed
        assertEq(ccM.openShort(address(dBTC)), held);
    }

    function test_Coverage_RiskManagerPureCheck() public view {
        risk.checkCoverage(10, 10);
        risk.checkCoverage(10, 0);
    }

    function test_Coverage_RiskManagerPureCheckReverts() public {
        vm.expectRevert(abi.encodeWithSelector(RiskManager.CoverageViolation.selector, 10, 11));
        risk.checkCoverage(10, 11);
    }

    // ---------------------------------------------------------------- strike range [90%, 110%]
    function test_Strike_LowerBoundary() public {
        uint256 qty = _held() / 10;
        vm.prank(keeper);
        vm.expectRevert(CoveredCallModule.InvalidStrike.selector);
        ccM.writeCall(address(dBTC), qty, spot * 8999 / 10_000, expiry, 0);
        _write(qty, spot * 9000 / 10_000, expiry, 0); // 10% ITM allowed
    }

    function test_Strike_UpperBoundary() public {
        uint256 qty = _held() / 10;
        vm.prank(keeper);
        vm.expectRevert(CoveredCallModule.InvalidStrike.selector);
        ccM.writeCall(address(dBTC), qty, spot * 11_001 / 10_000, expiry, 0);
        _write(qty, spot * 11_000 / 10_000, expiry, 0);
    }

    function test_Strike_ZeroReverts() public {
        vm.prank(keeper);
        vm.expectRevert(CoveredCallModule.InvalidStrike.selector);
        ccM.writeCall(address(dBTC), 1e12, 0, expiry, 0);
    }

    // ---------------------------------------------------------------- expiry / shorts / premium / validation
    function test_Expiry_Window() public {
        uint256 qty = _held() / 10;
        uint256 k = spot * 105 / 100;
        vm.startPrank(keeper);
        vm.expectRevert(CoveredCallModule.InvalidExpiry.selector);
        ccM.writeCall(address(dBTC), qty, k, uint64(block.timestamp + 1 days - 1), 0);
        vm.expectRevert(CoveredCallModule.InvalidExpiry.selector);
        ccM.writeCall(address(dBTC), qty, k, uint64(block.timestamp + 30 days + 1), 0);
        vm.expectRevert(CoveredCallModule.InvalidExpiry.selector);
        ccM.writeCall(address(dBTC), qty, k, uint64(block.timestamp), 0);
        ccM.writeCall(address(dBTC), qty, k, uint64(block.timestamp + 1 days), 0);
        ccM.writeCall(address(dBTC), qty, k, uint64(block.timestamp + 30 days), 0);
        vm.stopPrank();
    }

    function test_MaxShortsPerAsset() public {
        uint256 qty = _held() / 10;
        for (uint256 i; i < 3; ++i) _write(qty, spot * 105 / 100, expiry, 0);
        vm.prank(keeper);
        vm.expectRevert(CoveredCallModule.TooManyShorts.selector);
        ccM.writeCall(address(dBTC), qty, spot * 105 / 100, expiry, 0);
        // other asset has its own counter
        uint256 ethQty = dETH.balanceOf(address(ccM)) / 10;
        vm.prank(keeper);
        ccM.writeCall(address(dETH), ethQty, 3_150e8, expiry, 0);
    }

    function test_Premium_CapFifteenPercentOfNotional() public {
        uint256 qty = _held() / 2;
        uint256 notional = qty * spot / 1e20;
        uint256 cap = notional * 1500 / 10_000;
        vm.prank(keeper);
        vm.expectRevert(CoveredCallModule.PremiumTooLarge.selector);
        ccM.writeCall(address(dBTC), qty, spot * 105 / 100, expiry, cap + 1);
        _write(qty, spot * 105 / 100, expiry, cap);
    }

    function test_Write_RejectsNonWhitelistedAndZeroQty() public {
        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallModule.InvalidUnderlying.selector, address(dTBILL)));
        ccM.writeCall(address(dTBILL), 1e18, 105e8, expiry, 0);
        vm.expectRevert(CoveredCallModule.InvalidAmount.selector);
        ccM.writeCall(address(dBTC), 0, spot, expiry, 0);
        vm.stopPrank();
    }

    function test_Write_OnlyKeeper() public {
        uint256 qty = _held() / 10;
        vm.prank(attacker);
        vm.expectRevert(CoveredCallModule.OnlyKeeper.selector);
        ccM.writeCall(address(dBTC), qty, spot, expiry, 0);
        vm.prank(manager);
        vm.expectRevert(CoveredCallModule.OnlyKeeper.selector);
        ccM.writeCall(address(dBTC), qty, spot, expiry, 0);
        vm.prank(pauser);
        vm.expectRevert(CoveredCallModule.OnlyKeeper.selector);
        ccM.writeCall(address(dBTC), qty, spot, expiry, 0);
    }

    function test_Write_StaleOracleReverts() public {
        uint256 qty = _held() / 10;
        vm.warp(block.timestamp + 61 minutes);
        vm.prank(keeper);
        vm.expectPartialRevert(DemoPriceOracle.StalePrice.selector);
        ccM.writeCall(address(dBTC), qty, spot, uint64(block.timestamp + 7 days), 0);
        _refresh();
        _write(qty, spot * 105 / 100, uint64(block.timestamp + 7 days), 0);
    }

    // ---------------------------------------------------------------- settlement
    function test_Settle_AssignedWhenSpotAboveStrike() public {
        uint256 held = _held();
        uint256 qty = held / 2;
        uint256 strike = spot * 105 / 100;
        _write(qty, strike, expiry, 1e6);
        _skip(7 days);
        _setPrice(address(dBTC), spot * 110 / 100);
        uint256 cashBefore = usdc.balanceOf(address(ccM));
        uint256 expectedUsdc = qty * strike / 1e20;
        vm.expectEmit(true, false, false, true, address(ccM));
        emit CoveredCallModule.CallSettled(0, spot * 110 / 100, true);
        vm.prank(keeper);
        ccM.settle(0);
        assertEq(uint8(ccM.getCall(0).status), uint8(CoveredCallModule.CallStatus.Assigned));
        assertEq(usdc.balanceOf(address(ccM)) - cashBefore, expectedUsdc, "strike value received");
        assertEq(_held(), held - qty, "assigned units delivered to counterparty");
        assertEq(dBTC.balanceOf(address(cp)), qty);
        assertEq(ccM.openShort(address(dBTC)), 0);
        assertEq(dBTC.allowance(address(ccM), address(cp)), 0, "approval reset");
    }

    function test_Settle_ExpiredWorthlessWhenSpotBelowStrike() public {
        uint256 held = _held();
        _write(held / 2, spot * 105 / 100, expiry, 1e6);
        _skip(7 days);
        uint256 cashBefore = usdc.balanceOf(address(ccM));
        vm.expectEmit(true, false, false, true, address(ccM));
        emit CoveredCallModule.CallSettled(0, spot, false);
        vm.prank(keeper);
        ccM.settle(0);
        assertEq(uint8(ccM.getCall(0).status), uint8(CoveredCallModule.CallStatus.Expired));
        assertEq(_held(), held, "no delivery");
        assertEq(usdc.balanceOf(address(ccM)), cashBefore);
        assertEq(ccM.openShort(address(dBTC)), 0, "units unlocked");
    }

    function test_Settle_SpotEqualStrikeExpires() public {
        _write(_held() / 2, spot * 110 / 100, expiry, 0);
        _skip(7 days);
        _setPrice(address(dBTC), spot * 110 / 100);
        vm.prank(keeper);
        ccM.settle(0);
        assertEq(uint8(ccM.getCall(0).status), uint8(CoveredCallModule.CallStatus.Expired));
    }

    function test_Settle_Guards() public {
        _write(_held() / 2, spot * 105 / 100, expiry, 0);
        vm.startPrank(keeper);
        vm.expectRevert(CoveredCallModule.NotExpired.selector);
        ccM.settle(0);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallModule.InvalidCall.selector, 5));
        ccM.settle(5);
        vm.stopPrank();
        vm.prank(attacker);
        vm.expectRevert(CoveredCallModule.OnlyKeeper.selector);
        ccM.settle(0);
        _skip(7 days);
        vm.startPrank(keeper);
        ccM.settle(0);
        vm.expectRevert(CoveredCallModule.CallNotOpen.selector);
        ccM.settle(0);
        vm.stopPrank();
    }

    function test_Settle_StaleOracleReverts() public {
        _write(_held() / 2, spot * 105 / 100, expiry, 0);
        vm.warp(block.timestamp + 7 days); // no refresh
        vm.prank(keeper);
        vm.expectPartialRevert(DemoPriceOracle.StalePrice.selector);
        ccM.settle(0);
    }

    // ---------------------------------------------------------------- NAV
    function test_TotalValue_DeductsInTheMoneyLiability() public {
        uint256 qty = _held() / 2;
        uint256 strike = spot * 105 / 100;
        _write(qty, strike, expiry, 0);
        uint256 flat = ccM.totalValue();
        _setPrice(address(dBTC), spot * 110 / 100);
        uint256 newSpot = spot * 110 / 100;
        uint256 expected = usdc.balanceOf(address(ccM))
            + _held() * newSpot / 1e20 - (newSpot - strike) * qty / 1e20
            + dETH.balanceOf(address(ccM)) * 3_000e8 / 1e20;
        assertEq(ccM.totalValue(), expected);
        assertGt(ccM.totalValue(), flat, "still gains on the covered, unsold half");
    }

    function test_TotalValue_StaleOracleFallsBackToCheckpoint() public {
        uint256 v = ccM.totalValue();
        vm.warp(block.timestamp + 5 hours);
        assertEq(ccM.totalValue(), v, "cached value, no revert");
        assertEq(ccM.totalValue(), ccM.lastGoodValue());
    }

    function test_LiquidValue_ExcludesLockedUnits() public {
        uint256 before = ccM.liquidValue();
        _write(_held(), spot * 105 / 100, expiry, 0);
        assertLt(ccM.liquidValue(), before);
        assertEq(ccM.liquidValue(), usdc.balanceOf(address(ccM)) + _liquidEth());
    }

    function _liquidEth() internal view returns (uint256) {
        uint256 held = dETH.balanceOf(address(ccM));
        return router.quoteTokenForUsdc(address(dETH), held) * 9900 / 10_000;
    }

    // ---------------------------------------------------------------- access / reinvest / withdraw
    function test_OnlyVault_DepositWithdraw() public {
        vm.startPrank(attacker);
        vm.expectRevert(CoveredCallModule.OnlyVault.selector);
        ccM.deposit(1);
        vm.expectRevert(CoveredCallModule.OnlyVault.selector);
        ccM.withdraw(1);
        vm.stopPrank();
        vm.prank(keeper);
        vm.expectRevert(CoveredCallModule.OnlyVault.selector);
        ccM.withdraw(1);
    }

    function test_Reinvest_KeeperBuysFromModuleCash() public {
        _write(_held() / 2, spot * 105 / 100, expiry, 2e6);
        uint256 before = _held();
        vm.prank(keeper);
        ccM.reinvest(address(dBTC), 1e6);
        assertGt(_held(), before);
        uint256 tooMuch = usdc.balanceOf(address(ccM)) + 1;
        vm.startPrank(keeper);
        vm.expectRevert(CoveredCallModule.InvalidAmount.selector);
        ccM.reinvest(address(dBTC), tooMuch);
        vm.expectRevert(abi.encodeWithSelector(CoveredCallModule.InvalidUnderlying.selector, address(dTBILL)));
        ccM.reinvest(address(dTBILL), 1);
        vm.stopPrank();
        vm.prank(attacker);
        vm.expectRevert(CoveredCallModule.OnlyKeeper.selector);
        ccM.reinvest(address(dBTC), 1);
    }

    function test_Unwind_NeverSellsLockedUnits() public {
        _write(_held(), spot * 105 / 100, expiry, 0);
        uint256 heldBtc = _held();
        vm.prank(keeper);
        vault.unwind(1_000e6);
        assertEq(_held(), heldBtc, "locked underlying untouched");
        assertEq(dETH.balanceOf(address(ccM)), 0, "unlocked underlying sold");
    }

    // ---------------------------------------------------------------- wiring
    function test_Constructor_Validation() public {
        address[] memory u = new address[](1);
        u[0] = address(dBTC);
        uint16[] memory b = new uint16[](1);
        b[0] = 9_999;
        vm.expectRevert(CoveredCallModule.InvalidWeights.selector);
        new CoveredCallModule(USDC, address(vault), address(router), address(oracle), address(cp), address(risk), u, b);
        b[0] = 10_000;
        vm.expectRevert(CoveredCallModule.ZeroAddress.selector);
        new CoveredCallModule(USDC, address(0), address(router), address(oracle), address(cp), address(risk), u, b);
        u[0] = USDC;
        vm.expectRevert(abi.encodeWithSelector(CoveredCallModule.InvalidUnderlying.selector, USDC));
        new CoveredCallModule(USDC, address(vault), address(router), address(oracle), address(cp), address(risk), u, b);
    }

    function test_CallLimits_OnlyTimelockCanChange() public {
        IRiskManager.CallLimits memory l = IRiskManager.CallLimits(1 days, 60 days, 3, 9000, 11_000, 1500);
        vm.prank(manager);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        risk.setCallLimits(address(ccM), l);
        _gov(address(risk), abi.encodeCall(RiskManager.setCallLimits, (address(ccM), l)));
        assertEq(risk.callLimits(address(ccM)).maxExpiry, 60 days);
    }

    function test_Counterparty_ModuleRoleRequired_ForPremium() public {
        DemoOptionsCounterparty c = new DemoOptionsCounterparty(USDC, address(this));
        assertFalse(c.hasRole(c.MODULE_ROLE(), address(ccM)));
        assertTrue(cp.hasRole(cp.MODULE_ROLE(), address(ccM)));
    }

    /// @notice totalValue() iterates only open calls, so settled history does not raise gas.
    function test_TotalValueGasIndependentOfSettledHistory() public {
        vm.cool(address(ccM));
        uint256 g0 = gasleft();
        ccM.totalValue();
        uint256 gasBase = g0 - gasleft();
        for (uint256 cycle; cycle < 12; ++cycle) {
            uint256 qty = _held() / 50;
            for (uint256 i; i < 3; ++i) _write(qty, spot * 105 / 100, uint64(block.timestamp + 2 days), 0);
            _skip(2 days);
            vm.startPrank(keeper);
            for (uint256 i; i < 3; ++i) ccM.settle(ccM.callCount() - 3 + i);
            vm.stopPrank();
        }
        assertEq(ccM.callCount(), 36);
        assertEq(ccM.openShort(address(dBTC)), 0);
        vm.cool(address(ccM));
        uint256 g1 = gasleft();
        ccM.totalValue();
        uint256 gasAfter = g1 - gasleft();
        assertLt(gasAfter, gasBase + 5_000, "gas must not grow with settled-call history");
    }
}
