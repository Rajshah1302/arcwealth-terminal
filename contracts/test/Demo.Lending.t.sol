// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {DemoLendingPool} from "../demo/DemoLendingPool.sol";
import {DemoPriceOracle} from "../demo/DemoPriceOracle.sol";

/// @notice DemoLendingPool (P1): LTV, interest, liquidation and pull-based collateral claims.
contract DemoLendingTest is Base {
    DemoLendingPool internal pool;

    function setUp() public override {
        super.setUp();
        pool = new DemoLendingPool(USDC, address(oracle), address(this));
        pool.registerCollateral(address(dBTC));
        // lender supplies liquidity
        usdc.mint(bob, 100_000e6);
        vm.startPrank(bob);
        usdc.approve(address(pool), type(uint256).max);
        pool.supply(100_000e6);
        vm.stopPrank();
        // borrower posts 1 dBTC (= $60,000)
        vm.startPrank(alice);
        dBTC.faucet();
        dBTC.approve(address(pool), type(uint256).max);
        usdc.approve(address(pool), type(uint256).max);
        pool.depositCollateral(address(dBTC), 1e18);
        vm.stopPrank();
    }

    function test_Pool_BorrowUpToSeventyPercentLtv() public {
        assertEq(pool.collateralValue(alice), 60_000e6);
        vm.startPrank(alice);
        pool.borrow(42_000e6);
        assertEq(usdc.balanceOf(alice), 42_000e6);
        vm.expectRevert(DemoLendingPool.UnsafePosition.selector);
        pool.borrow(1e6);
        vm.stopPrank();
        assertEq(pool.debtOf(alice), 42_000e6);
    }

    function test_Pool_BorrowRevertsAboveLtv_ZeroAmount_Liquidity() public {
        vm.startPrank(alice);
        vm.expectRevert(DemoLendingPool.UnsafePosition.selector);
        pool.borrow(42_000e6 + 1);
        vm.expectRevert(DemoLendingPool.InvalidAmount.selector);
        pool.borrow(0);
        vm.expectRevert(DemoLendingPool.InsufficientLiquidity.selector);
        pool.borrow(200_000e6);
        vm.stopPrank();
    }

    function test_Pool_RepayAndWithdrawCollateral() public {
        vm.startPrank(alice);
        pool.borrow(10_000e6);
        vm.expectRevert(DemoLendingPool.UnsafePosition.selector);
        pool.withdrawCollateral(address(dBTC), 1e18);
        uint256 paid = pool.repay(type(uint256).max);
        assertEq(paid, 10_000e6);
        assertEq(pool.debtOf(alice), 0);
        pool.withdrawCollateral(address(dBTC), 1e18);
        vm.stopPrank();
        assertEq(dBTC.balanceOf(alice), 1e18);
    }

    function test_Pool_InterestAccruesAndSupplierEarnsNinetyPercent() public {
        vm.prank(alice);
        pool.borrow(20_000e6);
        vm.warp(block.timestamp + 365 days);
        uint256 debt = pool.debtOf(alice);
        assertGt(debt, 20_000e6);
        uint256 supplied = pool.suppliedBalance(bob);
        assertGt(supplied, 100_000e6);
        uint256 interest = debt - 20_000e6;
        assertApproxEqRel(supplied - 100_000e6, interest * 9 / 10, 0.001e18);
        assertGt(pool.borrowApr(), 2e16);
        assertGt(pool.supplyApr(), 0);
        assertLt(pool.supplyApr(), pool.borrowApr());
    }

    function test_Pool_HealthFactorAndLiquidation() public {
        vm.prank(alice);
        pool.borrow(42_000e6);
        assertGt(pool.healthFactor(alice), 1e18);
        usdc.mint(carol, 20_000e6);
        vm.startPrank(carol);
        usdc.approve(address(pool), type(uint256).max);
        vm.expectRevert(DemoLendingPool.NotLiquidatable.selector);
        pool.liquidate(alice, 10_000e6);
        vm.stopPrank();

        _setPrice(address(dBTC), 54_000e8);
        _setPrice(address(dBTC), 48_600e8); // collateral $48.6k, 80% = 38.88k < 42k debt
        assertLt(pool.healthFactor(alice), 1e18);

        vm.startPrank(carol);
        vm.expectRevert(DemoLendingPool.SelfLiquidation.selector);
        pool.liquidate(carol, 1);
        vm.expectRevert(DemoLendingPool.ZeroAddress.selector);
        pool.liquidate(address(0), 1);
        uint256 paid = pool.liquidate(alice, 10_000e6);
        assertEq(paid, 10_000e6);
        uint256 claim = pool.claimableCollateral(carol, address(dBTC));
        // 10,000 repaid + 5% bonus = $10,500 of dBTC at $48.6k
        uint256 seizeUsdc = 10_500e6;
        assertApproxEqRel(claim, seizeUsdc * 1e20 / 48_600e8, 0.0001e18);
        pool.claimCollateral(address(dBTC), claim);
        vm.stopPrank();
        assertEq(dBTC.balanceOf(carol), claim);
        vm.prank(carol);
        vm.expectRevert(DemoLendingPool.InsufficientPosition.selector);
        pool.claimCollateral(address(dBTC), 1);
    }

    function test_Pool_StalePriceBlocksBorrow() public {
        vm.warp(block.timestamp + 2 hours);
        vm.prank(alice);
        vm.expectPartialRevert(DemoPriceOracle.StalePrice.selector);
        pool.borrow(1e6);
    }

    function test_Pool_SupplyWithdraw_LimitedByLiquidity() public {
        vm.prank(alice);
        pool.borrow(40_000e6);
        vm.startPrank(bob);
        vm.expectRevert(DemoLendingPool.InsufficientLiquidity.selector);
        pool.withdraw(70_000e6);
        pool.withdraw(60_000e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(bob), 60_000e6);
    }

    function test_Pool_Guards() public {
        vm.expectRevert(DemoLendingPool.ZeroAddress.selector);
        new DemoLendingPool(address(0), address(oracle), address(this));
        vm.expectRevert(DemoLendingPool.InvalidCollateral.selector);
        pool.registerCollateral(address(dBTC)); // duplicate
        vm.expectRevert(DemoLendingPool.InvalidCollateral.selector);
        pool.registerCollateral(USDC);
        vm.prank(attacker);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        pool.registerCollateral(address(dETH));
        vm.prank(alice);
        vm.expectRevert(DemoLendingPool.InvalidCollateral.selector);
        pool.depositCollateral(address(dETH), 1);
        assertTrue(pool.isDemo());
        (bool ok,) = address(pool).call{value: 1}("");
        assertFalse(ok);
    }
}
