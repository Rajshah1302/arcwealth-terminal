// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {SIFStrategyVault} from "../core/SIFStrategyVault.sol";
import {InvestorVault} from "../core/InvestorVault.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

/// @notice Async exits, blocklisted/zero recipients, disclosure gate, share transfers and fuzz round-trips.
contract VaultRedeemTest is Base {
    // ---------------------------------------------------------------- request / cancel
    function test_RequestRedeem_EscrowsAndIsAdditive() public {
        uint256 sh = _deposit(alice, 100e6);
        vm.expectEmit(true, false, false, true, address(vault));
        emit SIFStrategyVault.RedeemRequested(alice, sh / 4);
        vm.prank(alice);
        vault.requestRedeem(sh / 4);
        vm.prank(alice);
        vault.requestRedeem(sh / 4);
        assertEq(vault.pendingRedeem(alice), sh / 2);
        assertEq(vault.balanceOf(alice), sh - sh / 2);
        assertEq(vault.balanceOf(address(vault)), sh / 2, "shares escrowed in vault");
    }

    function test_RequestRedeem_ZeroOrTooMuchReverts() public {
        uint256 sh = _deposit(alice, 100e6);
        vm.startPrank(alice);
        vm.expectRevert(SIFStrategyVault.InvalidShares.selector);
        vault.requestRedeem(0);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientBalance.selector);
        vault.requestRedeem(sh + 1);
        vm.stopPrank();
    }

    function test_CancelRedeem_ReturnsShares() public {
        uint256 sh = _deposit(alice, 100e6);
        vm.startPrank(alice);
        vault.requestRedeem(sh);
        vault.cancelRedeem();
        vm.stopPrank();
        assertEq(vault.balanceOf(alice), sh);
        assertEq(vault.pendingRedeem(alice), 0);
        vm.prank(alice);
        vm.expectRevert(SIFStrategyVault.InvalidShares.selector);
        vault.cancelRedeem();
    }

    function test_EscrowedShares_CannotBeMovedByOthersOrTransferredIn() public {
        uint256 sh = _deposit(alice, 100e6);
        vm.prank(alice);
        vault.requestRedeem(sh / 2);
        vm.prank(alice);
        vm.expectRevert(SIFStrategyVault.EscrowOnly.selector);
        vault.transfer(address(vault), 1);
        vm.prank(attacker);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
        vault.transferFrom(address(vault), attacker, 1);
    }

    function test_PendingRedeem_StillCountsTowardUserCap() public {
        uint256 sh = _deposit(alice, 250e6);
        vm.prank(alice);
        vault.requestRedeem(sh);
        _onboard(alice, 20e6);
        assertLt(vault.maxDeposit(alice), 10e6, "escrowed position counts toward 250 cap");
        vm.prank(alice);
        vm.expectPartialRevert(ERC4626.ERC4626ExceededMaxDeposit.selector);
        vault.deposit(10e6, alice);
    }

    // ---------------------------------------------------------------- fulfill / claim
    function test_FulfillAndClaim_FullPosition() public {
        uint256 sh = _deposit(alice, 250e6);
        uint256 expected = vault.convertToAssets(sh);
        vm.prank(alice);
        vault.requestRedeem(sh);

        vm.expectEmit(true, false, false, false, address(vault));
        emit SIFStrategyVault.RedeemFulfilled(alice, sh, expected);
        vm.prank(keeper);
        vault.fulfillRedeem(alice);

        assertEq(vault.pendingRedeem(alice), 0);
        assertEq(vault.balanceOf(address(vault)), 0, "escrow burned");
        uint256 claim = vault.claimable(alice);
        assertEq(claim, vault.totalClaimable());
        assertApproxEqAbs(claim, expected, expected / 1000);
        assertGe(usdc.balanceOf(address(vault)), claim, "claim fully cash backed");
        (uint256 basis, uint256 held,) = iv.positionOf(alice, address(vault));
        assertEq(held, 0);
        assertEq(basis, 0);

        uint256 before = usdc.balanceOf(alice);
        vm.expectEmit(true, false, false, true, address(vault));
        emit SIFStrategyVault.RedeemClaimed(alice, claim);
        vm.prank(alice);
        vault.claimRedeem();
        assertEq(usdc.balanceOf(alice) - before, claim);
        assertEq(vault.claimable(alice), 0);
        assertEq(vault.totalClaimable(), 0);
        assertLe(claim, 250e6);
        assertGt(claim, 249e6);
    }

    function test_Fulfill_OnlyRequestedUserGetsProceeds_KeeperCannotRedirect() public {
        uint256 sh = _deposit(alice, 100e6);
        vm.prank(alice);
        vault.requestRedeem(sh);
        vm.prank(keeper);
        vault.fulfillRedeem(alice);
        assertEq(usdc.balanceOf(keeper), 0);
        assertEq(vault.claimable(keeper), 0);
        vm.prank(keeper);
        vm.expectRevert(SIFStrategyVault.NothingToClaim.selector);
        vault.claimRedeem();
        vm.prank(attacker);
        vm.expectRevert(SIFStrategyVault.NothingToClaim.selector);
        vault.claimRedeem();
    }

    function test_Fulfill_AccessAndEmptyReverts() public {
        uint256 sh = _deposit(alice, 100e6);
        vm.prank(alice);
        vault.requestRedeem(sh);
        vm.prank(alice);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        vault.fulfillRedeem(alice);
        vm.prank(keeper);
        vm.expectRevert(SIFStrategyVault.InvalidShares.selector);
        vault.fulfillRedeem(bob);
    }

    function test_Claim_Twice_Reverts() public {
        uint256 sh = _deposit(alice, 100e6);
        vm.prank(alice);
        vault.requestRedeem(sh);
        vm.prank(keeper);
        vault.fulfillRedeem(alice);
        vm.startPrank(alice);
        vault.claimRedeem();
        vm.expectRevert(SIFStrategyVault.NothingToClaim.selector);
        vault.claimRedeem();
        vm.stopPrank();
    }

    function test_Fulfill_ClaimsAreReservedFromIdleAndNav() public {
        uint256 shA = _deposit(alice, 100e6);
        _deposit(bob, 100e6);
        uint256 bobAssetsBefore = vault.convertToAssets(vault.balanceOf(bob));
        vm.prank(alice);
        vault.requestRedeem(shA);
        vm.prank(keeper);
        vault.fulfillRedeem(alice);
        assertEq(vault.idle(), usdc.balanceOf(address(vault)) - vault.totalClaimable());
        assertLe(vault.maxWithdraw(bob), vault.idle(), "bob cannot touch alice's reserved claim");
        assertApproxEqRel(vault.convertToAssets(vault.balanceOf(bob)), bobAssetsBefore, 0.002e18);
    }

    function test_Fulfill_PartialRequestWorks() public {
        uint256 sh = _deposit(alice, 250e6);
        vm.prank(alice);
        vault.requestRedeem(sh / 5);
        vm.prank(keeper);
        vault.fulfillRedeem(alice);
        assertApproxEqRel(vault.claimable(alice), 50e6, 0.002e18);
        assertEq(vault.balanceOf(alice), sh - sh / 5);
    }

    function test_Fulfill_RevertsInsufficientUnwound_WhenUnderlyingIsLockedByCalls() public {
        uint256 sh = _deposit(alice, 250e6);
        _writeCallOnAllHoldings();
        vm.prank(alice);
        vault.requestRedeem(sh);
        vm.prank(keeper);
        vm.expectPartialRevert(SIFStrategyVault.InsufficientUnwound.selector);
        vault.fulfillRedeem(alice);
        // a smaller request that can be met from liquid sleeves still works
        vm.startPrank(alice);
        vault.cancelRedeem();
        vault.requestRedeem(sh / 5);
        vm.stopPrank();
        vm.prank(keeper);
        vault.fulfillRedeem(alice);
        assertGt(vault.claimable(alice), 49e6);
    }

    function _writeCallOnAllHoldings() internal {
        address[2] memory ts = [address(dBTC), address(dETH)];
        for (uint256 i; i < 2; ++i) {
            uint256 qty = IERC20(ts[i]).balanceOf(address(ccM));
            (uint256 spot,) = oracle.getPriceUnsafe(ts[i]);
            vm.prank(keeper);
            ccM.writeCall(ts[i], qty, spot * 105 / 100, uint64(block.timestamp + 7 days), 1e6);
        }
    }

    // ---------------------------------------------------------------- blocklisted / zero recipient
    function test_Blocklisted_ClaimReverts_ButOthersAreNotBricked() public {
        uint256 shB = _deposit(BLOCKED, 100e6);
        uint256 shA = _deposit(alice, 100e6);
        vm.prank(BLOCKED);
        vault.requestRedeem(shB);
        vm.prank(alice);
        vault.requestRedeem(shA);

        // fulfilment is bookkeeping only: it never pushes USDC, so a blocked user cannot jam the keeper queue
        vm.startPrank(keeper);
        vault.fulfillRedeem(BLOCKED);
        vault.fulfillRedeem(alice);
        vm.stopPrank();

        vm.prank(BLOCKED);
        vm.expectPartialRevert(MockUSDC.Blocklisted.selector);
        vault.claimRedeem();
        assertGt(vault.claimable(BLOCKED), 0, "blocked user's claim stays reserved");

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.claimRedeem();
        assertGt(usdc.balanceOf(alice), before);

        // new users can deposit and instantly exit while the blocked claim sits in the vault
        _deposit(bob, 50e6);
        uint256 w = vault.maxWithdraw(bob);
        assertGt(w, 0);
        vm.prank(bob);
        vault.withdraw(w, bob, bob);
        assertEq(vault.totalClaimable(), vault.claimable(BLOCKED));
        assertGe(usdc.balanceOf(address(vault)), vault.totalClaimable());
    }

    function test_Blocklisted_RecipientOfInstantExitReverts_SelfExitStillWorks() public {
        uint256 sh = _deposit(alice, 250e6);
        uint256 maxR = vault.maxRedeem(alice) / 2;
        vm.startPrank(alice);
        vm.expectPartialRevert(MockUSDC.Blocklisted.selector);
        vault.redeem(maxR, BLOCKED, alice);
        vm.expectPartialRevert(MockUSDC.Blocklisted.selector);
        vault.withdraw(1e6, BLOCKED, alice);
        vault.redeem(maxR, alice, alice);
        vm.stopPrank();
        assertEq(vault.balanceOf(alice), sh - maxR, "failed redeem left shares untouched");
    }

    function test_Blocklisted_OwnerCanStillExitInstantlyToAnotherAddress() public {
        _deposit(BLOCKED, 100e6);
        uint256 w = vault.maxWithdraw(BLOCKED);
        vm.prank(BLOCKED);
        vault.withdraw(w, bob, BLOCKED);
        assertEq(usdc.balanceOf(bob), w);
    }

    function test_MockedUsdcTransferRevert_ForSingleRecipientDoesNotAffectOthers() public {
        uint256 shC = _deposit(carol, 100e6);
        uint256 shA = _deposit(alice, 100e6);
        vm.prank(carol);
        vault.requestRedeem(shC);
        vm.prank(alice);
        vault.requestRedeem(shA);
        vm.startPrank(keeper);
        vault.fulfillRedeem(carol);
        vault.fulfillRedeem(alice);
        vm.stopPrank();

        vm.mockCallRevert(USDC, abi.encodeWithSelector(IERC20.transfer.selector, carol), "USDC: blocklisted");
        vm.prank(carol);
        vm.expectRevert();
        vault.claimRedeem();
        vm.prank(alice);
        vault.claimRedeem();
        assertGt(usdc.balanceOf(alice), 0);

        vm.clearMockedCalls();
        vm.prank(carol);
        vault.claimRedeem();
        assertGt(usdc.balanceOf(carol), 0);
    }

    function test_ZeroAddressRecipientReverts() public {
        _deposit(alice, 250e6);
        vm.startPrank(alice);
        vm.expectRevert(SIFStrategyVault.ZeroAddress.selector);
        vault.withdraw(1e6, address(0), alice);
        vm.expectRevert(SIFStrategyVault.ZeroAddress.selector);
        vault.redeem(1e12, address(0), alice);
        vm.stopPrank();
        _onboard(bob, 20e6);
        vm.prank(bob);
        vm.expectPartialRevert(ERC4626.ERC4626ExceededMaxDeposit.selector);
        vault.deposit(10e6, address(0));
        vm.prank(bob);
        vm.expectPartialRevert(ERC4626.ERC4626ExceededMaxDeposit.selector);
        vault.deposit(10e6, address(vault));
    }

    // ---------------------------------------------------------------- disclosure gate
    function test_Disclosure_RequiredBeforeDeposit() public {
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        // the max* views no longer encode disclosure; the deposit hook reverts with the custom error
        assertGt(vault.maxDeposit(alice), 0);
        vm.expectRevert(SIFStrategyVault.DisclosureRequired.selector);
        vault.deposit(100e6, alice);
        vm.expectRevert(SIFStrategyVault.DisclosureRequired.selector);
        vault.mint(1e14, alice);
        assertEq(usdc.balanceOf(alice), 100e6, "no funds moved on rejected deposit");
        iv.acceptDisclosure(address(vault), DISC);
        vault.deposit(100e6, alice);
        vm.stopPrank();
        assertTrue(iv.hasAccepted(alice, address(vault)));
    }

    function test_Disclosure_AcceptEmitsEventAndRejectsWrongHash() public {
        vm.expectEmit(true, true, false, true, address(iv));
        emit InvestorVault.DisclosureAccepted(alice, address(vault), DISC);
        vm.startPrank(alice);
        iv.acceptDisclosure(address(vault), DISC);
        vm.expectRevert(InvestorVault.InvalidDisclosure.selector);
        iv.acceptDisclosure(address(vault), keccak256("other"));
        vm.expectRevert(InvestorVault.InvalidDisclosure.selector);
        iv.acceptDisclosure(address(vault), bytes32(0));
        vm.expectRevert(InvestorVault.UnregisteredStrategy.selector);
        iv.acceptDisclosure(address(0xdead), DISC);
        vm.stopPrank();
    }

    function test_Disclosure_DepositForOtherRequiresReceiverAcceptance() public {
        _onboard(alice, 100e6);
        vm.prank(alice);
        vm.expectRevert(SIFStrategyVault.DisclosureRequired.selector);
        vault.deposit(50e6, bob);
    }

    function test_Disclosure_RotationInvalidatesPriorAcceptance() public {
        _deposit(alice, 50e6);
        bytes32 v2 = keccak256("ARCWEALTH-S1-DISCLOSURE-v2");
        _gov(address(iv), abi.encodeCall(InvestorVault.registerStrategy, (address(vault), v2)));
        assertFalse(iv.hasAccepted(alice, address(vault)));
        usdc.mint(alice, 20e6);
        vm.startPrank(alice);
        vm.expectRevert(SIFStrategyVault.DisclosureRequired.selector);
        vault.deposit(20e6, alice);
        iv.acceptDisclosure(address(vault), v2);
        vault.deposit(20e6, alice);
        vm.stopPrank();
    }

    function test_InvestorRegistry_OnlyRegisteredStrategyCanRecord() public {
        vm.startPrank(attacker);
        vm.expectRevert(InvestorVault.UnregisteredStrategy.selector);
        iv.recordDeposit(attacker, 1e6, 1e6);
        vm.expectRevert(InvestorVault.UnregisteredStrategy.selector);
        iv.recordWithdraw(alice, 1e6, 1e6);
        vm.expectRevert(InvestorVault.UnregisteredStrategy.selector);
        iv.recordTransfer(alice, attacker, 1);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- share transfers
    function test_ShareTransfer_CarriesCostBasisProportionally() public {
        uint256 sh = _deposit(alice, 100e6);
        vm.prank(alice);
        vault.transfer(bob, sh / 2);
        (uint256 bA, uint256 sA,) = iv.positionOf(alice, address(vault));
        (uint256 bB, uint256 sB,) = iv.positionOf(bob, address(vault));
        assertEq(bA, 50e6);
        assertEq(bB, 50e6);
        assertEq(sA, sh - sh / 2);
        assertEq(sB, sh / 2);
    }

    function test_ThirdPartyRedeem_NeedsAllowance() public {
        _deposit(alice, 250e6);
        uint256 w = vault.maxWithdraw(alice) / 2;
        vm.prank(attacker);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
        vault.withdraw(w, attacker, alice);
        vm.prank(attacker);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
        vault.redeem(1e12, attacker, alice);
    }

    // ---------------------------------------------------------------- fuzz
    function testFuzz_DepositThenInstantRedeem_NoFreeMoney(uint256 amt, uint256 frac) public {
        amt = bound(amt, 10e6, 250e6);
        uint256 sh = _deposit(alice, amt);
        uint256 s = bound(frac, 1, vault.maxRedeem(alice));
        vm.prank(alice);
        uint256 out = vault.redeem(s, alice, alice);
        assertLe(out, amt * s / sh, "cannot withdraw more than pro-rata contribution");
        assertEq(usdc.balanceOf(alice), out);
        assertEq(vault.balanceOf(alice), sh - s);
        assertGe(usdc.balanceOf(address(vault)), vault.totalClaimable());
    }

    function testFuzz_DepositThenInstantWithdraw_SharesBurnedCoverAssets(uint256 amt, uint256 w) public {
        amt = bound(amt, 10e6, 250e6);
        uint256 sh = _deposit(alice, amt);
        w = bound(w, 1, vault.maxWithdraw(alice));
        vm.prank(alice);
        uint256 burned = vault.withdraw(w, alice, alice);
        assertEq(usdc.balanceOf(alice), w);
        assertEq(vault.balanceOf(alice), sh - burned);
        assertGe(vault.convertToAssets(burned) + 1, w, "burned shares are worth at least what was paid");
    }

    function testFuzz_RequestFulfillClaim_RoundTrip(uint256 amt) public {
        amt = bound(amt, 10e6, 250e6);
        uint256 sh = _deposit(alice, amt);
        vm.prank(alice);
        vault.requestRedeem(sh);
        vm.prank(keeper);
        vault.fulfillRedeem(alice);
        vm.prank(alice);
        vault.claimRedeem();
        uint256 got = usdc.balanceOf(alice);
        assertLe(got, amt, "no profit from an immediate round-trip");
        assertGe(got, amt * 99 / 100, "loss bounded by swap fees on invested sleeves");
        assertEq(vault.balanceOf(alice), 0);
    }

    function testFuzz_DepositCaps(uint256 amt) public {
        amt = bound(amt, 0, 2_000e6);
        _onboard(alice, amt);
        vm.prank(alice);
        if (amt < 10e6 || amt > 250e6) {
            vm.expectRevert();
            vault.deposit(amt, alice);
        } else {
            assertGt(vault.deposit(amt, alice), 0);
        }
    }

    function testFuzz_FeeSharesLinearInTime(uint256 dt) public {
        dt = bound(dt, 1, 3 * 365 days);
        _deposit(alice, 100e6);
        uint256 supply = vault.totalSupply();
        vm.warp(block.timestamp + dt);
        vault.checkpointFee();
        assertEq(vault.balanceOf(feeRecipient), supply * 100 * dt / (10_000 * 365 days));
    }
}
