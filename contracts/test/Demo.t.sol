// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {DemoERC20} from "../demo/DemoERC20.sol";
import {DemoPriceOracle} from "../demo/DemoPriceOracle.sol";
import {DemoSwapRouter} from "../demo/DemoSwapRouter.sol";
import {DemoBondIssuer} from "../demo/DemoBondIssuer.sol";
import {DemoOptionsCounterparty} from "../demo/DemoOptionsCounterparty.sol";

/// @notice DemoERC20 faucet, oracle guards, swap router, bond issuer and options counterparty.
contract DemoTest is Base {
    // ================================================================ DemoERC20
    function test_Faucet_MintsConfiguredAmountThenCooldown() public {
        vm.prank(alice);
        dBTC.faucet();
        assertEq(dBTC.balanceOf(alice), 1e18);
        vm.prank(alice);
        vm.expectRevert(DemoERC20.FaucetCooldown.selector);
        dBTC.faucet();
        vm.warp(block.timestamp + 1 hours - 1);
        vm.prank(alice);
        vm.expectRevert(DemoERC20.FaucetCooldown.selector);
        dBTC.faucet();
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        dBTC.faucet();
        assertEq(dBTC.balanceOf(alice), 2e18);
    }

    function test_Faucet_CooldownIsPerAddress() public {
        vm.prank(alice);
        dETH.faucet();
        vm.prank(bob);
        dETH.faucet();
        assertEq(dETH.balanceOf(bob), 10e18);
        assertEq(dETH.nextFaucetAt(alice), block.timestamp + 1 hours);
    }

    function test_DemoToken_MintOnlyMinter_ZeroRecipient_Decimals_IsDemo() public {
        vm.prank(attacker);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        dBTC.mint(attacker, 1);
        assertEq(dBTC.decimals(), 18);
        assertTrue(dBTC.isDemo());
        vm.prank(address(router));
        vm.expectRevert(DemoERC20.ZeroAddress.selector);
        dBTC.mint(address(0), 1);
        vm.prank(address(router));
        dBTC.mint(alice, 5);
        assertEq(dBTC.balanceOf(alice), 5);
    }

    function test_DemoToken_ConstructorZeroAdminReverts() public {
        vm.expectRevert(DemoERC20.ZeroAddress.selector);
        new DemoERC20("x", "x", 18, address(0), 1);
    }

    function test_DemoToken_Burnable() public {
        vm.prank(alice);
        dBTC.faucet();
        vm.prank(alice);
        dBTC.burn(4e17);
        assertEq(dBTC.balanceOf(alice), 6e17);
    }

    // ================================================================ DemoPriceOracle
    function test_Oracle_StaleAfterOneHour() public {
        (uint256 p,) = oracle.getPriceUnsafe(address(dBTC));
        assertEq(oracle.getPrice(address(dBTC)), p);
        vm.warp(block.timestamp + 1 hours); // exactly the window: still fresh
        assertEq(oracle.getPrice(address(dBTC)), p);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(DemoPriceOracle.StalePrice.selector, address(dBTC), 1 hours + 1));
        oracle.getPrice(address(dBTC));
    }

    function test_Oracle_RefreshClearsStaleness() public {
        vm.warp(block.timestamp + 3 hours);
        vm.expectPartialRevert(DemoPriceOracle.StalePrice.selector);
        oracle.getPrice(address(dETH));
        _refresh();
        assertGt(oracle.getPrice(address(dETH)), 0);
        assertEq(oracle.lastUpdated(address(dETH)), block.timestamp);
    }

    function test_Oracle_PriceNotSet() public {
        vm.expectRevert(DemoPriceOracle.PriceNotSet.selector);
        oracle.getPrice(address(0x1234));
    }

    function test_Oracle_TenPercentStep_ExactlyAllowed_BeyondReverts() public {
        _setPrice(address(dBTC), 66_000e8); // +10% exactly
        _setPrice(address(dBTC), 59_400e8); // -10% exactly
        vm.prank(keeper);
        vm.expectRevert(DemoPriceOracle.StepTooLarge.selector);
        oracle.setPrice(address(dBTC), 59_400e8 * 11 / 10 + 1); // just above +10%
        vm.prank(keeper);
        vm.expectRevert(DemoPriceOracle.StepTooLarge.selector);
        oracle.setPrice(address(dBTC), 59_400e8 * 9 / 10 - 1); // just below -10%
        vm.prank(keeper);
        vm.expectRevert(DemoPriceOracle.StepTooLarge.selector);
        oracle.setPrice(address(dBTC), 120_000e8); // 2x
    }

    function test_Oracle_BatchIsAtomicAndStepChecked() public {
        address[] memory ts = new address[](2);
        ts[0] = address(dBTC);
        ts[1] = address(dETH);
        uint256[] memory ps = new uint256[](2);
        ps[0] = 61_000e8;
        ps[1] = 6_000e8; // 2x -> revert whole batch
        vm.prank(keeper);
        vm.expectRevert(DemoPriceOracle.StepTooLarge.selector);
        oracle.setPrices(ts, ps);
        (uint256 p,) = oracle.getPriceUnsafe(address(dBTC));
        assertEq(p, 60_000e8, "first leg rolled back");
        ps[1] = 3_100e8;
        vm.prank(keeper);
        oracle.setPrices(ts, ps);
        (p,) = oracle.getPriceUnsafe(address(dBTC));
        assertEq(p, 61_000e8);
        uint256[] memory short_ = new uint256[](1);
        vm.prank(keeper);
        vm.expectRevert(DemoPriceOracle.LengthMismatch.selector);
        oracle.setPrices(ts, short_);
    }

    function test_Oracle_Auth_ZeroPrice_ZeroToken() public {
        vm.prank(attacker);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        oracle.setPrice(address(dBTC), 1);
        vm.prank(manager);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        oracle.setPrice(address(dBTC), 1);
        vm.startPrank(keeper);
        vm.expectRevert(DemoPriceOracle.InvalidPrice.selector);
        oracle.setPrice(address(dBTC), 0);
        vm.expectRevert(DemoPriceOracle.ZeroAddress.selector);
        oracle.setPrice(address(0), 1);
        vm.stopPrank();
    }

    function test_Oracle_ResetPrice_OnlyAdminTimelock() public {
        vm.prank(keeper);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        oracle.resetPrice(address(dBTC), 30_000e8);
        _gov(address(oracle), abi.encodeCall(DemoPriceOracle.resetPrice, (address(dBTC), 30_000e8)));
        (uint256 p,) = oracle.getPriceUnsafe(address(dBTC));
        assertEq(p, 30_000e8);
    }

    function test_Oracle_FirstPriceAnyValue_AndVol() public {
        address t = address(0xBEEF);
        _setPrice(t, 123_456_789e8);
        (uint256 p,) = oracle.getPriceUnsafe(t);
        assertEq(p, 123_456_789e8);
        vm.prank(keeper);
        oracle.setVol(t, 4500);
        assertEq(oracle.vol30dBps(t), 4500);
        assertTrue(oracle.isDemo());
    }

    function test_Oracle_ConstructorZeroRoleHolders() public {
        vm.expectRevert(DemoPriceOracle.ZeroAddress.selector);
        new DemoPriceOracle(address(0), keeper);
        vm.expectRevert(DemoPriceOracle.ZeroAddress.selector);
        new DemoPriceOracle(address(this), address(0));
    }

    // ================================================================ DemoSwapRouter
    function test_Router_BuyAppliesThirtyBpsFeeAndMintsToRecipient() public {
        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(router), 1_000e6);
        uint256 reserveBefore = usdc.balanceOf(address(router));
        uint256 net = 1_000e6 - 3e6;
        uint256 expectedOut = net * 1e20 / 60_000e8;
        assertEq(router.quoteUsdcForToken(address(dBTC), 1_000e6), expectedOut);
        uint256 out = router.swapExactUsdcForToken(address(dBTC), 1_000e6, expectedOut, bob);
        vm.stopPrank();
        assertEq(out, expectedOut);
        assertEq(dBTC.balanceOf(bob), expectedOut);
        assertEq(usdc.balanceOf(address(router)) - reserveBefore, 1_000e6, "fee stays in the reserve");
    }

    function test_Router_SellBurnsTokensAndPaysNetOfFee() public {
        vm.startPrank(alice);
        dBTC.faucet(); // 1e18 -> $60,000
        dBTC.approve(address(router), 1e18);
        uint256 q = router.quoteTokenForUsdc(address(dBTC), 1e18);
        assertEq(q, 60_000e6 - 60_000e6 * 30 / 10_000);
        uint256 out = router.swapExactTokenForUsdc(address(dBTC), 1e18, q, alice);
        vm.stopPrank();
        assertEq(out, q);
        assertEq(usdc.balanceOf(alice), q);
        assertEq(dBTC.balanceOf(alice), 0);
        assertEq(dBTC.totalSupply(), 0, "sold tokens are burned");
    }

    function test_Router_Reverts_Unsupported_ZeroRecipient_Slippage_Stale() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(router), type(uint256).max);
        vm.expectRevert(DemoSwapRouter.TokenNotSupported.selector);
        router.swapExactUsdcForToken(address(0xCAFE), 10e6, 0, alice);
        vm.expectRevert(DemoSwapRouter.ZeroAddress.selector);
        router.swapExactUsdcForToken(address(dBTC), 10e6, 0, address(0));
        vm.expectRevert(DemoSwapRouter.SlippageExceeded.selector);
        router.swapExactUsdcForToken(address(dBTC), 10e6, type(uint256).max, alice);
        vm.expectRevert(DemoSwapRouter.ZeroAddress.selector);
        router.swapExactTokenForUsdc(address(dBTC), 1, 0, address(0));
        vm.warp(block.timestamp + 2 hours);
        vm.expectPartialRevert(DemoPriceOracle.StalePrice.selector);
        router.swapExactUsdcForToken(address(dBTC), 10e6, 0, alice);
        vm.stopPrank();
    }

    function test_Router_SellRevertsWhenReserveShort() public {
        DemoSwapRouter r2 = new DemoSwapRouter(USDC, address(oracle), address(this));
        r2.registerToken(address(dBTC));
        // r2 is not a minter of dBTC but burnFrom does not need it; reserve is empty
        vm.startPrank(alice);
        dBTC.faucet();
        dBTC.approve(address(r2), 1e18);
        vm.expectRevert(DemoSwapRouter.InsufficientLiquidity.selector);
        r2.swapExactTokenForUsdc(address(dBTC), 1e18, 0, alice);
        vm.stopPrank();
    }

    function test_Router_RegisterToken_OnlyManager_AndValidation() public {
        DemoERC20 t6 = new DemoERC20("six", "SIX", 6, address(this), 1);
        vm.prank(attacker);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        router.registerToken(address(t6));
        vm.startPrank(manager);
        vm.expectRevert(DemoSwapRouter.InvalidToken.selector);
        router.registerToken(address(t6)); // not 18 decimals
        vm.expectRevert(DemoSwapRouter.InvalidToken.selector);
        router.registerToken(USDC);
        vm.expectRevert(DemoSwapRouter.ZeroAddress.selector);
        router.registerToken(address(0));
        vm.stopPrank();
        DemoERC20 t18 = new DemoERC20("new", "NEW", 18, address(this), 1);
        vm.prank(manager);
        router.registerToken(address(t18));
        assertTrue(router.registeredTokens(address(t18)));
    }

    function test_Router_ConstantsAndNoNativeValue() public {
        assertEq(router.FEE_BPS(), 30);
        assertTrue(router.isDemo());
        (bool ok,) = address(router).call{value: 1}("");
        assertFalse(ok, "router rejects native value");
    }

    // ================================================================ DemoBondIssuer (Actual/365)
    function _sub(address who, uint256 id, uint256 amt) internal {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(issuer), amt);
        issuer.subscribe(id, amt);
        vm.stopPrank();
    }

    function test_Bond_CouponActual365_Exact() public {
        _sub(alice, 0, 1_000e6);
        assertEq(issuer.pendingCoupon(0, alice), 0);
        vm.warp(block.timestamp + 15 days);
        assertEq(issuer.pendingCoupon(0, alice), uint256(1_000e6) * 400 * 15 / (10_000 * 365));
        assertEq(issuer.pendingCoupon(0, alice), 1_643_835);
        vm.warp(block.timestamp + 15 days);
        assertEq(issuer.pendingCoupon(0, alice), uint256(1_000e6) * 400 * 30 / (10_000 * 365));
    }

    function test_Bond_CouponStopsAtMaturity() public {
        _sub(alice, 0, 1_000e6);
        vm.warp(block.timestamp + 30 days);
        uint256 atMaturity = issuer.pendingCoupon(0, alice);
        vm.warp(block.timestamp + 200 days);
        assertEq(issuer.pendingCoupon(0, alice), atMaturity);
    }

    function test_Bond_ClaimCouponPaysAndResets() public {
        _sub(alice, 2, 1_000e6);
        vm.warp(block.timestamp + 73 days);
        uint256 expected = uint256(1_000e6) * 500 * 73 / (10_000 * 365);
        assertEq(expected, 10_000_000);
        vm.expectEmit(true, true, false, true, address(issuer));
        emit DemoBondIssuer.CouponPaid(2, alice, expected);
        vm.prank(alice);
        uint256 paid = issuer.claimCoupon(2);
        assertEq(paid, expected);
        assertEq(usdc.balanceOf(alice), expected);
        assertEq(issuer.pendingCoupon(2, alice), 0);
        vm.warp(block.timestamp + 10 days);
        assertEq(issuer.pendingCoupon(2, alice), uint256(1_000e6) * 500 * 10 / (10_000 * 365));
    }

    function test_Bond_TopUpCarriesAccruedCoupon() public {
        _sub(alice, 0, 1_000e6);
        vm.warp(block.timestamp + 10 days);
        uint256 first = uint256(1_000e6) * 400 * 10 / (10_000 * 365);
        _sub(alice, 0, 1_000e6);
        assertEq(issuer.unitsOf(0, alice), 2_000e6);
        assertEq(issuer.pendingCoupon(0, alice), first, "accrued carried, nothing lost or double counted");
        vm.warp(block.timestamp + 10 days);
        assertEq(issuer.pendingCoupon(0, alice), first + uint256(2_000e6) * 400 * 10 / (10_000 * 365));
    }

    function test_Bond_RedeemPaysPrincipalPlusCoupon_EarlyAtPar() public {
        _sub(alice, 1, 500e6);
        vm.warp(block.timestamp + 20 days);
        uint256 coupon = uint256(500e6) * 450 * 20 / (10_000 * 365);
        vm.expectEmit(true, true, false, true, address(issuer));
        emit DemoBondIssuer.Redeemed(1, alice, 200e6, 200e6 + coupon);
        vm.prank(alice);
        uint256 paid = issuer.redeem(1, 200e6);
        assertEq(paid, 200e6 + coupon);
        assertEq(issuer.unitsOf(1, alice), 300e6);
        assertEq(issuer.pendingCoupon(1, alice), 0);
    }

    function test_Bond_Reverts() public {
        vm.startPrank(alice);
        vm.expectRevert(DemoBondIssuer.InvalidAmount.selector);
        issuer.subscribe(0, 0);
        vm.expectRevert(DemoBondIssuer.InvalidSeries.selector);
        issuer.subscribe(9, 1);
        vm.expectRevert(DemoBondIssuer.InvalidAmount.selector);
        issuer.redeem(0, 0);
        vm.expectRevert(DemoBondIssuer.InsufficientUnits.selector);
        issuer.redeem(0, 1);
        vm.stopPrank();
        vm.warp(block.timestamp + 31 days);
        vm.prank(alice);
        vm.expectRevert(DemoBondIssuer.SeriesMatured.selector);
        issuer.subscribe(0, 1);
    }

    function test_Bond_InsufficientReserveReverts() public {
        DemoBondIssuer fresh = new DemoBondIssuer(USDC, address(this));
        fresh.createSeries("s", "A", 500, uint64(block.timestamp + 90 days));
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(fresh), 100e6);
        fresh.subscribe(0, 100e6);
        vm.warp(block.timestamp + 90 days);
        // coupon cannot consume principal: reserve is empty, principal still redeems, coupon stays as pull entitlement
        assertEq(fresh.couponReserve(), 0);
        uint256 before = usdc.balanceOf(alice);
        fresh.redeem(0, 100e6);
        assertEq(usdc.balanceOf(alice) - before, 100e6);
        assertGt(fresh.pendingCoupon(0, alice), 0);
        vm.expectRevert(DemoBondIssuer.InsufficientCouponReserve.selector);
        fresh.claimCoupon(0);
        vm.stopPrank();
        usdc.approve(address(fresh), 10e6);
        fresh.fundReserve(10e6);
        vm.prank(alice);
        fresh.claimCoupon(0);
        assertGt(usdc.balanceOf(alice) - before, 100e6);
    }

    function test_Bond_CreateSeries_MaturityWindowAndAuth() public {
        vm.startPrank(manager);
        vm.expectRevert(DemoBondIssuer.InvalidMaturity.selector);
        issuer.createSeries("x", "A", 100, uint64(block.timestamp + 14 days - 1));
        vm.expectRevert(DemoBondIssuer.InvalidMaturity.selector);
        issuer.createSeries("x", "A", 100, uint64(block.timestamp + 90 days + 1));
        issuer.createSeries("ok14", "A", 100, uint64(block.timestamp + 14 days));
        issuer.createSeries("ok90", "A", 100, uint64(block.timestamp + 90 days));
        vm.stopPrank();
        assertEq(issuer.seriesCount(), 5);
        vm.prank(attacker);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        issuer.createSeries("x", "A", 100, uint64(block.timestamp + 20 days));
        (, , uint16 bps, , , bool active) = issuer.seriesInfo(0);
        assertEq(bps, 400);
        assertTrue(active);
    }

    function testFuzz_BondAccrual_MatchesActual365(uint256 units, uint256 dt, uint8 series) public {
        units = bound(units, 1e6, 1_000_000e6);
        series = uint8(bound(series, 0, 2));
        dt = bound(dt, 0, 200 days);
        (, , uint16 bps, , uint64 maturity,) = issuer.seriesInfo(series);
        _sub(alice, series, units);
        uint256 start = block.timestamp;
        vm.warp(start + dt);
        uint256 effective = start + dt > maturity ? maturity - start : dt;
        uint256 expected = units * bps * effective / (10_000 * 365 days);
        assertEq(issuer.pendingCoupon(series, alice), expected);
        vm.prank(alice);
        assertEq(issuer.claimCoupon(series), expected);
        assertEq(usdc.balanceOf(alice), expected);
    }

    function testFuzz_BondAccrual_Monotonic(uint256 units, uint256 d1, uint256 d2) public {
        units = bound(units, 1e6, 1_000_000e6);
        d1 = bound(d1, 0, 100 days);
        d2 = bound(d2, 0, 100 days);
        _sub(alice, 2, units);
        vm.warp(block.timestamp + d1);
        uint256 p1 = issuer.pendingCoupon(2, alice);
        vm.warp(block.timestamp + d2);
        assertGe(issuer.pendingCoupon(2, alice), p1);
    }

    // ================================================================ DemoOptionsCounterparty
    function test_Counterparty_PayPremium_RoleGated_CapAndRecipient() public {
        // ccM holds MODULE_ROLE: drive through a test-owned counterparty to avoid the module
        DemoOptionsCounterparty c = new DemoOptionsCounterparty(USDC, address(this));
        usdc.approve(address(c), 1_000e6);
        c.fundReserve(1_000e6);
        c.grantRole(c.MODULE_ROLE(), alice);
        vm.startPrank(alice);
        c.payPremium(alice, 150e6, 1_000e6); // exactly 15%
        assertEq(usdc.balanceOf(alice), 150e6);
        vm.expectRevert(DemoOptionsCounterparty.PremiumTooLarge.selector);
        c.payPremium(alice, 150e6 + 1, 1_000e6);
        vm.expectRevert(DemoOptionsCounterparty.InvalidRecipient.selector);
        c.payPremium(bob, 1, 1_000e6);
        vm.expectRevert(DemoOptionsCounterparty.ZeroAddress.selector);
        c.payPremium(address(0), 1, 1_000e6);
        vm.expectRevert(DemoOptionsCounterparty.InsufficientLiquidity.selector);
        c.payPremium(alice, 1_000e6, 10_000e6);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        c.payPremium(bob, 1, 1_000e6);
    }

    function test_Counterparty_SettleAssignment_Guards() public {
        vm.prank(attacker);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        cp.settleAssignment(address(dBTC), 1, 1, attacker);
        vm.prank(address(ccM));
        vm.expectRevert(DemoOptionsCounterparty.InvalidRecipient.selector);
        cp.settleAssignment(address(dBTC), 1, 1, attacker);
        vm.prank(address(ccM));
        vm.expectRevert(DemoOptionsCounterparty.InvalidUnderlying.selector);
        cp.settleAssignment(USDC, 1, 1, address(ccM));
    }

    function test_Counterparty_AdminSettersViaTimelockOnly_RecycleKeeperOnly() public {
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        cp.setMaxPremiumBps(100);
        _gov(address(cp), abi.encodeCall(DemoOptionsCounterparty.setMaxPremiumBps, (100)));
        assertEq(cp.maxPremiumBps(), 100);
        vm.prank(attacker);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        cp.recycle(address(dBTC), 1);
        assertEq(cp.availableLiquidity(), usdc.balanceOf(address(cp)));
    }
}
