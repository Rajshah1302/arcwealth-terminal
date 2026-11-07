// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {DemoERC20} from "../demo/DemoERC20.sol";
import {SIFStrategyVault} from "../core/SIFStrategyVault.sol";
import {StrategyManager} from "../core/StrategyManager.sol";
import {InvestorVault} from "../core/InvestorVault.sol";
import {AssetAllocatorModule} from "../modules/AssetAllocatorModule.sol";
import {IInvestorVault, IRiskManager, IStrategyManager} from "../interfaces/IArcWealth.sol";

/// @notice Stale-oracle behaviour, claimRedeemTo, faucet switch and open-call tracking.
contract StaleAndFixesTest is Base {
    uint256 internal spot;

    function setUp() public override {
        super.setUp();
        (spot,) = oracle.getPriceUnsafe(address(dBTC));
    }

    function _goStale() internal {
        vm.warp(block.timestamp + 1 hours + 1);
    }

    function _write(uint256 qty, uint256 strike, uint64 exp, uint256 premium) internal returns (uint256 id) {
        id = ccM.callCount();
        vm.prank(keeper);
        ccM.writeCall(address(dBTC), qty, strike, exp, premium);
    }

    function _fulfill(address u) internal {
        vm.prank(keeper);
        vault.fulfillRedeem(u);
    }

    // ================================================================ (1) stale oracle
    function test_Stale_BoundaryExactlyOneHourIsFresh() public {
        _deposit(alice, 100e6);
        vm.warp(block.timestamp + 1 hours);
        assertFalse(ccM.isStale());
        assertGt(vault.maxDeposit(alice), 0);
        vm.warp(block.timestamp + 1);
        assertTrue(ccM.isStale());
        assertEq(vault.maxDeposit(alice), 0);
    }

    function test_Stale_MaxFunctionsReturnZero() public {
        _deposit(alice, 100e6);
        _deposit(bob, 100e6);
        assertGt(vault.maxDeposit(alice), 0);
        assertGt(vault.maxMint(alice), 0);
        assertGt(vault.maxWithdraw(alice), 0);
        assertGt(vault.maxRedeem(alice), 0);
        _goStale();
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxRedeem(alice), 0);
        assertEq(vault.maxDeposit(bob), 0);
    }

    function test_Stale_DepositMintRedeemWithdrawRevert() public {
        uint256 sh = _deposit(alice, 100e6);
        _onboard(carol, 10e6);
        _goStale();
        vm.startPrank(carol);
        vm.expectPartialRevert(ERC4626.ERC4626ExceededMaxDeposit.selector);
        vault.deposit(10e6, carol);
        vm.expectPartialRevert(ERC4626.ERC4626ExceededMaxMint.selector);
        vault.mint(1e12, carol);
        vm.stopPrank();
        vm.startPrank(alice);
        vm.expectPartialRevert(ERC4626.ERC4626ExceededMaxRedeem.selector);
        vault.redeem(sh / 10, alice, alice);
        vm.expectPartialRevert(ERC4626.ERC4626ExceededMaxWithdraw.selector);
        vault.withdraw(1e6, alice, alice);
        vm.stopPrank();
    }

    function test_Stale_FulfillRedeemAndUnwindRevertPricesStale() public {
        uint256 sh = _deposit(alice, 100e6);
        vm.prank(alice);
        vault.requestRedeem(sh / 4);
        _goStale();
        vm.startPrank(keeper);
        vm.expectRevert(SIFStrategyVault.PricesStale.selector);
        vault.fulfillRedeem(alice);
        vm.expectRevert(SIFStrategyVault.PricesStale.selector);
        vault.unwind(1e6);
        vm.stopPrank();
    }

    function test_Stale_RequestCancelClaimStillWork() public {
        uint256 shA = _deposit(alice, 100e6);
        uint256 shB = _deposit(bob, 100e6);
        // alice gets a fulfilled claim while fresh
        vm.prank(alice);
        vault.requestRedeem(shA / 4);
        _fulfill(alice);
        uint256 owed = vault.claimable(alice);
        assertGt(owed, 0);
        _goStale();

        // request while stale
        vm.prank(bob);
        vault.requestRedeem(shB / 4);
        assertEq(vault.pendingRedeem(bob), shB / 4);
        vm.prank(bob);
        vault.requestRedeem(shB / 4);
        assertEq(vault.pendingRedeem(bob), (shB / 4) * 2);
        // cancel while stale
        uint256 balBefore = vault.balanceOf(bob);
        vm.prank(bob);
        vault.cancelRedeem();
        assertEq(vault.pendingRedeem(bob), 0);
        assertEq(vault.balanceOf(bob), balBefore + (shB / 4) * 2);
        // claim while stale
        uint256 usdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.claimRedeem();
        assertEq(usdc.balanceOf(alice) - usdcBefore, owed);
        assertEq(vault.claimable(alice), 0);
    }

    function test_Stale_RecoversAfterPriceRefresh() public {
        uint256 sh = _deposit(alice, 100e6);
        vm.prank(alice);
        vault.requestRedeem(sh / 4);
        _goStale();
        assertEq(vault.maxDeposit(alice), 0);
        _refresh();
        assertGt(vault.maxDeposit(alice), 0);
        _fulfill(alice);
        assertGt(vault.claimable(alice), 0);
    }

    // ================================================================ (2) stale unwind cannot overpay
    function test_StaleUnwind_CoveredCallCashMoveDoesNotIncreaseTotalAssets() public {
        _deposit(alice, 250e6);
        _write(dBTC.balanceOf(address(ccM)) / 2, spot * 105 / 100, uint64(block.timestamp + 7 days), 1e6);
        _goStale();
        assertTrue(ccM.isStale());
        uint256 before_ = vault.totalAssets();
        uint256 cash = usdc.balanceOf(address(ccM));
        uint256 btc = dBTC.balanceOf(address(ccM));
        assertGt(cash, 0);
        vm.prank(address(vault));
        ccM.withdraw(1_000e6);
        assertEq(usdc.balanceOf(address(ccM)), 0, "cash swept");
        assertEq(dBTC.balanceOf(address(ccM)), btc, "no stale-priced sale");
        assertLe(vault.totalAssets(), before_);
    }

    function test_StaleUnwind_TacticalCashMoveDoesNotIncreaseTotalAssets() public {
        _deposit(alice, 100e6);
        vm.prank(keeper);
        tacM.rebalanceTactical();
        assertGt(dTBILL.balanceOf(address(tacM)), 0);
        _goStale();
        assertTrue(tacM.isStale());
        uint256 before_ = vault.totalAssets();
        uint256 tb = dTBILL.balanceOf(address(tacM));
        uint256 idleBefore = vault.idle();
        vm.prank(address(vault));
        tacM.withdraw(1_000e6);
        assertGt(vault.idle(), idleBefore, "cash was moved");
        assertEq(dTBILL.balanceOf(address(tacM)), tb, "no stale-priced sale");
        assertLe(vault.totalAssets(), before_);
    }

    // ================================================================ (3) refreshCheckpoint
    function test_Refresh_PermissionlessUpdatesWhenFresh() public {
        _deposit(alice, 100e6);
        usdc.mint(address(tacM), 1e6);
        uint256 lg = tacM.lastGoodValue();
        vm.prank(attacker);
        tacM.refreshCheckpoint();
        assertEq(tacM.lastGoodValue(), lg + 1e6);
        assertEq(tacM.lastGoodValue(), tacM.totalValue());
        usdc.mint(address(ccM), 1e6);
        vm.prank(attacker);
        ccM.refreshCheckpoint();
        assertEq(ccM.lastGoodValue(), ccM.totalValue());
    }

    function test_Refresh_NoOpAndNoRevertWhenStale() public {
        _deposit(alice, 100e6);
        vm.prank(keeper);
        tacM.rebalanceTactical();
        _goStale();
        uint256 ccLg = ccM.lastGoodValue();
        uint256 tacLg = tacM.lastGoodValue();
        uint256 ccPx = ccM.lastGoodPrice(address(dBTC));
        usdc.mint(address(ccM), 5e6);
        usdc.mint(address(tacM), 5e6);
        vm.startPrank(attacker);
        ccM.refreshCheckpoint();
        tacM.refreshCheckpoint();
        vm.stopPrank();
        assertEq(ccM.lastGoodValue(), ccLg, "cc checkpoint untouched");
        assertEq(tacM.lastGoodValue(), tacLg, "tactical checkpoint untouched");
        assertEq(ccM.lastGoodPrice(address(dBTC)), ccPx);
    }

    // ================================================================ (4) claimRedeemTo
    function _blockedClaimant() internal returns (uint256 owed) {
        uint256 sh = _deposit(BLOCKED, 100e6);
        vm.prank(BLOCKED);
        vault.requestRedeem(sh / 4);
        _fulfill(BLOCKED);
        owed = vault.claimable(BLOCKED);
        assertGt(owed, 0);
    }

    function test_ClaimRedeemTo_BlocklistedReceiverRevertsStateIntact() public {
        uint256 owed = _blockedClaimant();
        uint256 total = vault.totalClaimable();
        vm.startPrank(BLOCKED);
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.Blocklisted.selector, BLOCKED));
        vault.claimRedeem();
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.Blocklisted.selector, BLOCKED));
        vault.claimRedeemTo(BLOCKED);
        vm.stopPrank();
        assertEq(vault.claimable(BLOCKED), owed, "claim preserved after failed payout");
        assertEq(vault.totalClaimable(), total);
    }

    function test_ClaimRedeemTo_OtherReceiverSucceeds() public {
        uint256 owed = _blockedClaimant();
        uint256 total = vault.totalClaimable();
        uint256 before_ = usdc.balanceOf(bob);
        vm.expectEmit(true, false, false, true, address(vault));
        emit SIFStrategyVault.RedeemClaimed(BLOCKED, owed);
        vm.prank(BLOCKED);
        vault.claimRedeemTo(bob);
        assertEq(usdc.balanceOf(bob) - before_, owed);
        assertEq(vault.claimable(BLOCKED), 0);
        assertEq(vault.totalClaimable(), total - owed);
        // cannot be claimed twice
        vm.prank(BLOCKED);
        vm.expectRevert(SIFStrategyVault.NothingToClaim.selector);
        vault.claimRedeemTo(bob);
    }

    function test_ClaimRedeemTo_ZeroReceiverReverts() public {
        _blockedClaimant();
        vm.prank(BLOCKED);
        vm.expectRevert(SIFStrategyVault.ZeroAddress.selector);
        vault.claimRedeemTo(address(0));
    }

    function test_ClaimRedeemTo_NothingToClaimReverts() public {
        vm.prank(carol);
        vm.expectRevert(SIFStrategyVault.NothingToClaim.selector);
        vault.claimRedeemTo(dave);
        // another user's claim is not claimable by an attacker
        uint256 sh = _deposit(alice, 100e6);
        vm.prank(alice);
        vault.requestRedeem(sh / 4);
        _fulfill(alice);
        vm.prank(attacker);
        vm.expectRevert(SIFStrategyVault.NothingToClaim.selector);
        vault.claimRedeemTo(attacker);
    }

    // ================================================================ (5) faucet switch
    function test_Faucet_AdminCanDisableAndReenable() public {
        vm.prank(alice);
        dBTC.faucet();
        assertEq(dBTC.balanceOf(alice), 1e18);

        _gov(address(dBTC), abi.encodeCall(DemoERC20.setFaucetAmount, (0)));
        assertEq(dBTC.faucetAmount(), 0);
        vm.prank(bob);
        vm.expectRevert(DemoERC20.FaucetDisabled.selector);
        dBTC.faucet();
        assertEq(dBTC.balanceOf(bob), 0);

        _gov(address(dBTC), abi.encodeCall(DemoERC20.setFaucetAmount, (5e18)));
        vm.prank(bob);
        dBTC.faucet();
        assertEq(dBTC.balanceOf(bob), 5e18);
    }

    function test_Faucet_NonAdminCannotSetAmount() public {
        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, bytes32(0)));
        dBTC.setFaucetAmount(0);
        vm.stopPrank();
        // deployer renounced admin in the handover
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), bytes32(0)));
        dBTC.setFaucetAmount(0);
        assertEq(dBTC.faucetAmount(), 1e18);
    }

    // ================================================================ (6) open-call tracking
    function _writeThree() internal returns (uint256 qty, uint256 strike) {
        _deposit(alice, 250e6);
        qty = dBTC.balanceOf(address(ccM)) / 10;
        strike = spot * 105 / 100;
        _write(qty, strike, uint64(block.timestamp + 5 days), 0); // id 0
        _write(qty, strike, uint64(block.timestamp + 3 days), 0); // id 1
        _write(qty, strike, uint64(block.timestamp + 7 days), 0); // id 2
    }

    function _expectedValue(uint256 px, uint256 qty, uint256 strike, uint256 openCalls) internal view returns (uint256) {
        uint256 gross = dBTC.balanceOf(address(ccM)) * px / 1e20;
        uint256 liab = px > strike ? openCalls * ((px - strike) * qty / 1e20) : 0;
        uint256 eth = dETH.balanceOf(address(ccM)) * 3_000e8 / 1e20;
        return usdc.balanceOf(address(ccM)) + (gross - liab) + eth;
    }

    function test_OpenCalls_SettleMiddleCountsOnlyOpen() public {
        (uint256 qty, uint256 strike) = _writeThree();
        assertEq(ccM.openShort(address(dBTC)), 3 * qty);
        assertEq(ccM.openShortCount(address(dBTC)), 3);

        _skip(3 days);
        vm.prank(keeper);
        ccM.settle(1);
        assertEq(uint8(ccM.getCall(1).status), 2, "middle call Expired");
        assertEq(uint8(ccM.getCall(0).status), 0, "first still Open");
        assertEq(uint8(ccM.getCall(2).status), 0, "last still Open");
        assertEq(ccM.openShort(address(dBTC)), 2 * qty);
        assertEq(ccM.openShortCount(address(dBTC)), 2);

        // push spot ITM for every strike: liability must count exactly the two open calls
        uint256 px = spot * 110 / 100;
        _setPrice(address(dBTC), px);
        assertEq(ccM.totalValue(), _expectedValue(px, qty, strike, 2));
        assertTrue(ccM.totalValue() != _expectedValue(px, qty, strike, 3));
        assertTrue(ccM.totalValue() != _expectedValue(px, qty, strike, 1));
    }

    function test_OpenCalls_SettleFirstAndLastKeepsRemainingTracked() public {
        (uint256 qty, uint256 strike) = _writeThree();
        _skip(7 days); // all three expired, spot flat (below strike) -> expire worthless
        vm.startPrank(keeper);
        ccM.settle(0); // swap-and-pop moves id 2 into slot 0
        vm.stopPrank();
        assertEq(ccM.openShort(address(dBTC)), 2 * qty);
        assertEq(ccM.openShortCount(address(dBTC)), 2);

        uint256 px = spot * 110 / 100;
        _setPrice(address(dBTC), px);
        assertEq(ccM.totalValue(), _expectedValue(px, qty, strike, 2));

        _setPrice(address(dBTC), spot); // OTM again so settling expires (no delivery)
        vm.prank(keeper);
        ccM.settle(2);
        assertEq(ccM.openShort(address(dBTC)), qty);
        _setPrice(address(dBTC), px);
        assertEq(ccM.totalValue(), _expectedValue(px, qty, strike, 1));
        // the remaining open call (id 1) is still settleable; afterwards no liability remains
        _setPrice(address(dBTC), spot);
        vm.prank(keeper);
        ccM.settle(1);
        assertEq(ccM.openShort(address(dBTC)), 0);
        assertEq(ccM.openShortCount(address(dBTC)), 0);
        assertEq(ccM.totalValue(), _expectedValue(spot, qty, strike, 0) + 0);
    }
}

/// @notice Stale behaviour of the AssetAllocatorModule (S2 vault).
contract StaleAllocatorTest is Base {
    SIFStrategyVault internal vault2;
    AssetAllocatorModule internal alloc;
    DemoERC20 internal dCOPR;
    address[] internal toks;
    bytes32 internal constant H2 = keccak256("S2-config");

    function setUp() public override {
        super.setUp();
        dCOPR = new DemoERC20("Demo COPR", "dCOPR", 18, address(this), 1e18);
        dCOPR.grantRole(dCOPR.MINTER_ROLE(), address(router));
        vm.prank(manager);
        router.registerToken(address(dCOPR));
        _setPrice(address(dCOPR), 25e8);

        vault2 = new SIFStrategyVault(
            IERC20(USDC), "ARC SIF S2", "aS2", address(this), feeRecipient,
            IInvestorVault(address(iv)), IRiskManager(address(risk)), IStrategyManager(address(sm))
        );
        toks.push(address(dBTC));
        toks.push(address(dETH));
        toks.push(address(dTBILL));
        toks.push(address(dCOPR));
        alloc = new AssetAllocatorModule(USDC, address(vault2), address(router), address(oracle), address(sm), address(risk), toks);
        vault2.addModule(address(alloc));
        vault2.grantRole(vault2.KEEPER_ROLE(), keeper);

        uint16[] memory w = new uint16[](1);
        w[0] = 10_000;
        _gov(address(sm), abi.encodeCall(StrategyManager.registerStrategy, (address(vault2), "S2", w, H2)));
        _gov(address(iv), abi.encodeCall(InvestorVault.registerStrategy, (address(vault2), DISC)));
        _refresh();
        _setPrice(address(dCOPR), 25e8);
        uint16[] memory bps = new uint16[](4);
        bps[0] = 3000; bps[1] = 3000; bps[2] = 3000; bps[3] = 1000;
        vm.prank(manager);
        sm.setAssetWeights(address(vault2), toks, bps, keccak256("w"), "weights");
    }

    function _dep2(address u, uint256 amt) internal {
        usdc.mint(u, amt);
        vm.startPrank(u);
        usdc.approve(address(vault2), type(uint256).max);
        iv.acceptDisclosure(address(vault2), DISC);
        vault2.deposit(amt, u);
        vm.stopPrank();
    }

    function test_StaleUnwind_AllocatorCashMoveDoesNotIncreaseTotalAssets() public {
        _dep2(alice, 100e6);
        usdc.mint(address(alloc), 5e6); // module cash on hand
        vm.warp(block.timestamp + 1 hours + 1);
        assertTrue(alloc.isStale());
        assertEq(vault2.maxRedeem(alice), 0);
        uint256 before_ = vault2.totalAssets();
        uint256 btc = dBTC.balanceOf(address(alloc));
        vm.prank(address(vault2));
        alloc.withdraw(1_000e6);
        assertEq(dBTC.balanceOf(address(alloc)), btc, "no stale-priced sale");
        assertLe(vault2.totalAssets(), before_);
    }

    function test_Refresh_AllocatorNoOpWhenStalePermissionlessWhenFresh() public {
        _dep2(alice, 100e6);
        usdc.mint(address(alloc), 2e6);
        vm.prank(attacker);
        alloc.refreshCheckpoint();
        assertEq(alloc.lastGoodValue(), alloc.totalValue());
        uint256 lg = alloc.lastGoodValue();
        vm.warp(block.timestamp + 1 hours + 1);
        usdc.mint(address(alloc), 3e6);
        vm.prank(attacker);
        alloc.refreshCheckpoint();
        assertEq(alloc.lastGoodValue(), lg);
    }
}
