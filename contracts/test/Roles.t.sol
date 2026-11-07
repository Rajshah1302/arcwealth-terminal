// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {SIFStrategyVault} from "../core/SIFStrategyVault.sol";
import {RiskManager} from "../core/RiskManager.sol";
import {StrategyManager} from "../core/StrategyManager.sol";
import {InvestorVault} from "../core/InvestorVault.sol";
import {ArcWealthTimelock} from "../core/ArcWealthTimelock.sol";
import {TacticalSleeveModule} from "../modules/TacticalSleeveModule.sol";
import {DemoOptionsCounterparty} from "../demo/DemoOptionsCounterparty.sol";
import {DemoPriceOracle} from "../demo/DemoPriceOracle.sol";

/// @notice Role separation and the timelock handover.
contract RolesTest is Base {
    bytes4 internal constant UNAUTH = 0xe2517d3f; // AccessControlUnauthorizedAccount(address,bytes32)

    function setUp() public override {
        super.setUp();
        _deposit(alice, 250e6);
        _deposit(bob, 100e6);
    }

    // ---------------------------------------------------------------- handover state
    function test_Handover_TimelockHoldsAdminEverywhereDeployerNone() public view {
        address[11] memory ts = [
            address(oracle), address(router), address(issuer), address(cp), address(risk), address(sm),
            address(iv), address(vault), address(dBTC), address(dETH), address(dTBILL)
        ];
        for (uint256 i; i < ts.length; ++i) {
            assertTrue(IAccessControl(ts[i]).hasRole(0x00, address(tl)), "timelock is admin");
            assertFalse(IAccessControl(ts[i]).hasRole(0x00, address(this)), "deployer renounced");
            assertFalse(IAccessControl(ts[i]).hasRole(0x00, manager));
            assertFalse(IAccessControl(ts[i]).hasRole(0x00, keeper));
            assertFalse(IAccessControl(ts[i]).hasRole(0x00, pauser));
        }
        assertEq(tl.getMinDelay(), 600);
        assertFalse(router.hasRole(router.MANAGER_ROLE(), address(this)));
    }

    // ---------------------------------------------------------------- nobody can touch investor funds
    function _assertNoFundTheft(address who) internal {
        bytes32 keeperRole = vault.KEEPER_ROLE();
        uint256 whoBefore = usdc.balanceOf(who);
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 vaultUsdc = usdc.balanceOf(address(vault));
        vm.startPrank(who);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
        vault.withdraw(1e6, who, alice);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
        vault.redeem(1e12, who, alice);
        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector);
        vault.transferFrom(alice, who, 1e12);
        // governance-only surface
        vm.expectPartialRevert(UNAUTH);
        vault.addModule(address(0xdead));
        vm.expectPartialRevert(UNAUTH);
        vault.removeModule(address(ccM));
        vm.expectPartialRevert(UNAUTH);
        vault.grantRole(keeperRole, who);
        vm.expectPartialRevert(UNAUTH);
        vault.grantRole(0x00, who);
        vm.expectPartialRevert(UNAUTH);
        risk.setLimits(address(vault), 1, type(uint128).max, type(uint128).max, 1000);
        vm.expectPartialRevert(UNAUTH);
        risk.setSleeveBand(address(vault), 0, 0, 10_000);
        vm.expectPartialRevert(UNAUTH);
        risk.setAssetMaxBps(address(vault), address(dBTC), 10_000);
        vm.expectPartialRevert(UNAUTH);
        risk.setCallLimits(address(ccM), _limits());
        vm.expectPartialRevert(UNAUTH);
        iv.registerStrategy(address(vault), bytes32(uint256(1)));
        vm.expectPartialRevert(UNAUTH);
        sm.registerStrategy(address(0xdead), "x", new uint16[](0), bytes32(0));
        vm.expectPartialRevert(UNAUTH);
        sm.setNoOptions(address(dBTC), false);
        vm.expectPartialRevert(UNAUTH);
        cp.setRouter(address(router));
        vm.expectPartialRevert(UNAUTH);
        cp.setMaxPremiumBps(10_000);
        vm.expectPartialRevert(UNAUTH);
        oracle.resetPrice(address(dBTC), 1);
        vm.stopPrank();
        assertEq(vault.balanceOf(alice), aliceShares);
        assertEq(usdc.balanceOf(address(vault)), vaultUsdc);
        assertEq(usdc.balanceOf(who), whoBefore);
    }

    function _limits() internal pure returns (RiskManager.CallLimits memory l) {
        l.minExpiry = 1; l.maxExpiry = 2; l.maxShortsPerAsset = 1; l.minStrikeBps = 1; l.maxStrikeBps = 2; l.maxPremiumBps = 1;
    }

    function test_Manager_CannotMoveInvestorFundsOrChangeLimits() public { _assertNoFundTheft(manager); }
    function test_Keeper_CannotMoveInvestorFundsOrChangeLimits() public { _assertNoFundTheft(keeper); }
    function test_Pauser_CannotMoveInvestorFundsOrChangeLimits() public { _assertNoFundTheft(pauser); }
    function test_Attacker_CannotMoveInvestorFundsOrChangeLimits() public { _assertNoFundTheft(attacker); }
    function test_Deployer_NoLongerHasAnyPower() public { _assertNoFundTheft(address(this)); }

    function test_ProposerGov_CannotActDirectly() public {
        // gov proposes on the timelock but holds no role on the targets
        vm.prank(gov);
        vm.expectPartialRevert(UNAUTH);
        risk.setLimits(address(vault), 1, 2, 1, 1000);
        vm.prank(gov);
        vm.expectPartialRevert(UNAUTH);
        vault.addModule(address(0xdead));
    }

    function test_NoRole_CanPullFundsInto_Itself_ViaKeeperFunctions() public {
        uint256 total = vault.totalAssets();
        vm.startPrank(keeper);
        vault.unwind(100e6);
        vault.rebalance();
        vm.stopPrank();
        assertEq(usdc.balanceOf(keeper), 0);
        assertApproxEqRel(vault.totalAssets(), total, 0.01e18, "funds only move between vault and its modules");
        assertEq(usdc.balanceOf(manager) + usdc.balanceOf(pauser) + usdc.balanceOf(gov), 0);
    }

    function test_KeeperFunctions_RejectNonKeeper() public {
        vm.startPrank(manager);
        vm.expectPartialRevert(UNAUTH);
        vault.unwind(1);
        vm.expectPartialRevert(UNAUTH);
        vault.rebalance();
        vm.expectPartialRevert(UNAUTH);
        vault.fulfillRedeem(alice);
        vm.stopPrank();
        vm.startPrank(pauser);
        vm.expectPartialRevert(UNAUTH);
        vault.unwind(1);
        vm.expectPartialRevert(UNAUTH);
        sm.postRegimeInputs(1, true, 1, 1);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- what each role CAN do
    function test_Manager_CanSetModuleWeights_ButBandsAndSumEnforced() public {
        uint16[] memory w = new uint16[](3);
        w[0] = 5000; w[1] = 2500; w[2] = 2500;
        bytes32 newHash = keccak256("v2");
        vm.expectEmit(true, true, false, false, address(sm));
        emit StrategyManager.StrategyConfigChanged(address(vault), CFG, newHash, w, manager, "shift to bonds");
        vm.prank(manager);
        sm.setModuleWeights(address(vault), w, newHash, "shift to bonds");
        assertEq(sm.configHash(address(vault)), newHash);
        assertEq(sm.targetWeights(address(vault))[0], 5000);

        w[2] = 2499;
        vm.prank(manager);
        vm.expectRevert(StrategyManager.InvalidWeights.selector);
        sm.setModuleWeights(address(vault), w, newHash, "bad sum");

        // only the timelock can tighten the band the manager must respect
        _gov(address(risk), abi.encodeCall(RiskManager.setSleeveBand, (address(vault), 0, 3000, 5000)));
        w[0] = 6000; w[1] = 2000; w[2] = 2000;
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(StrategyManager.WeightOutsideBand.selector, 0));
        sm.setModuleWeights(address(vault), w, newHash, "outside band");
    }

    function test_Keeper_CanFulfillAndUnwind_ProceedsGoToUser() public {
        uint256 sh = vault.balanceOf(bob);
        vm.prank(bob);
        vault.requestRedeem(sh);
        vm.prank(keeper);
        vault.fulfillRedeem(bob);
        assertEq(vault.claimable(bob), vault.totalClaimable());
        assertEq(usdc.balanceOf(keeper), 0);
    }

    function test_Pauser_CanOnlyPauseAndUnpause() public {
        vm.startPrank(pauser);
        vault.pause();
        assertTrue(vault.paused());
        vault.unpause();
        vm.stopPrank();
        assertFalse(vault.paused());
        assertFalse(vault.hasRole(vault.KEEPER_ROLE(), pauser));
        assertFalse(vault.hasRole(vault.MANAGER_ROLE(), pauser));
    }

    function test_Timelock_CannotPause_RolesAreSeparate() public {
        _govExpectRevert(address(vault), abi.encodeCall(SIFStrategyVault.pause, ()), UNAUTH);
    }

    function test_Timelock_CannotMoveInvestorFunds() public {
        _govExpectRevert(
            address(vault), abi.encodeCall(vault.withdraw, (1e6, address(tl), alice)), IERC20Errors.ERC20InsufficientAllowance.selector
        );
        _govExpectRevert(address(vault), abi.encodeCall(vault.fulfillRedeem, (alice)), UNAUTH);
    }

    // ---------------------------------------------------------------- timelock mechanics
    function test_Timelock_ChangesLimits_OnlyAfterDelay() public {
        bytes memory data = abi.encodeCall(RiskManager.setLimits, (address(vault), 50e6, 1_000e6, 250e6, 1000));
        bytes32 salt = bytes32("s1");
        vm.startPrank(gov);
        tl.schedule(address(risk), 0, data, bytes32(0), salt, 600);
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        tl.execute(address(risk), 0, data, bytes32(0), salt);
        vm.warp(block.timestamp + 599);
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        tl.execute(address(risk), 0, data, bytes32(0), salt);
        vm.warp(block.timestamp + 1);
        tl.execute(address(risk), 0, data, bytes32(0), salt);
        vm.stopPrank();
        assertEq(risk.minDeposit(address(vault)), 50e6);
        _onboard(carol, 40e6);
        vm.prank(carol);
        vm.expectPartialRevert(SIFStrategyVault.DepositTooSmall.selector);
        vault.deposit(40e6, carol);
    }

    function test_Timelock_ScheduleRules() public {
        bytes memory data = abi.encodeCall(RiskManager.setLimits, (address(vault), 1, 2, 1, 1000));
        vm.prank(gov);
        vm.expectPartialRevert(TimelockController.TimelockInsufficientDelay.selector);
        tl.schedule(address(risk), 0, data, bytes32(0), bytes32("a"), 599);
        vm.prank(attacker);
        vm.expectPartialRevert(UNAUTH);
        tl.schedule(address(risk), 0, data, bytes32(0), bytes32("a"), 600);
        vm.prank(manager);
        vm.expectPartialRevert(UNAUTH);
        tl.schedule(address(risk), 0, data, bytes32(0), bytes32("a"), 600);
    }

    function test_Timelock_DelayFloorEnforced() public {
        address[] memory p = new address[](1);
        p[0] = gov;
        vm.expectRevert(ArcWealthTimelock.DelayBelowFloor.selector);
        new ArcWealthTimelock(599, p, p, address(0));
        _govExpectRevert(address(tl), abi.encodeCall(tl.updateDelay, (599)), ArcWealthTimelock.DelayBelowFloor.selector);
        _gov(address(tl), abi.encodeCall(tl.updateDelay, (900)));
        assertEq(tl.getMinDelay(), 900);
        vm.prank(gov);
        vm.expectPartialRevert(TimelockController.TimelockUnauthorizedCaller.selector);
        tl.updateDelay(700);
    }

    function test_Timelock_RejectsNativeValueAndZeroTarget() public {
        bytes memory data = abi.encodeCall(RiskManager.setLimits, (address(vault), 1, 2, 1, 1000));
        vm.deal(gov, 1 ether);
        vm.startPrank(gov);
        tl.schedule(address(risk), 1, data, bytes32(0), bytes32("v"), 600);
        tl.schedule(address(0), 0, "", bytes32(0), bytes32("z"), 600);
        vm.warp(block.timestamp + 600);
        vm.expectRevert(ArcWealthTimelock.NativeValueUnsupported.selector);
        tl.execute{value: 1}(address(risk), 1, data, bytes32(0), bytes32("v"));
        vm.expectRevert(ArcWealthTimelock.InvalidTarget.selector);
        tl.execute(address(0), 0, "", bytes32(0), bytes32("z"));
        vm.stopPrank();
    }

    function test_Timelock_ModuleChanges_OnlyViaTimelock() public {
        TacticalSleeveModule m = new TacticalSleeveModule(
            USDC, address(vault), address(router), address(oracle), address(sm), address(dTBILL)
        );
        vm.prank(manager);
        vm.expectPartialRevert(UNAUTH);
        vault.addModule(address(m));
        _gov(address(vault), abi.encodeCall(SIFStrategyVault.addModule, (address(m))));
        assertEq(vault.moduleCount(), 4);
        assertTrue(vault.isModule(address(m)));
        _gov(address(vault), abi.encodeCall(SIFStrategyVault.removeModule, (address(m))));
        assertEq(vault.moduleCount(), 3);
        assertFalse(vault.isModule(address(m)));
    }

    function test_Timelock_ModuleValidation_NonEmptyRemovalAndForeignVault() public {
        _govExpectRevert(address(vault), abi.encodeCall(SIFStrategyVault.removeModule, (address(ccM))), SIFStrategyVault.ModuleNotEmpty.selector);
        TacticalSleeveModule foreign = new TacticalSleeveModule(
            USDC, address(0xBEEF), address(router), address(oracle), address(sm), address(dTBILL)
        );
        _govExpectRevert(address(vault), abi.encodeCall(SIFStrategyVault.addModule, (address(foreign))), SIFStrategyVault.InvalidModule.selector);
        _govExpectRevert(address(vault), abi.encodeCall(SIFStrategyVault.addModule, (address(ccM))), SIFStrategyVault.InvalidModule.selector);
        _govExpectRevert(address(vault), abi.encodeCall(SIFStrategyVault.addModule, (address(0))), SIFStrategyVault.InvalidModule.selector);
    }

    function test_Vault_RejectsNativeValue() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(vault).call{value: 1}("");
        assertFalse(ok);
        (ok,) = address(iv).call{value: 1}("");
        assertFalse(ok);
        (ok,) = address(risk).call{value: 1}("");
        assertFalse(ok);
    }

    function _govExpectRevert(address target, bytes memory data, bytes4 sel) internal {
        bytes32 salt = keccak256(abi.encode("rev", target, data, govNonce++));
        vm.startPrank(gov);
        tl.schedule(target, 0, data, bytes32(0), salt, tl.getMinDelay());
        vm.warp(block.timestamp + tl.getMinDelay());
        vm.expectPartialRevert(sel);
        tl.execute(target, 0, data, bytes32(0), salt);
        vm.stopPrank();
    }
}
