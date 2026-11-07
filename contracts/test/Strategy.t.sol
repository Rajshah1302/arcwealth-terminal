// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SIFStrategyVault} from "../core/SIFStrategyVault.sol";
import {RiskManager} from "../core/RiskManager.sol";
import {StrategyManager} from "../core/StrategyManager.sol";
import {InvestorVault} from "../core/InvestorVault.sol";
import {TacticalSleeveModule} from "../modules/TacticalSleeveModule.sol";
import {IInvestorVault, IRiskManager, IStrategyManager} from "../interfaces/IArcWealth.sol";

/// @notice Configuration validation for RiskManager, StrategyManager, InvestorVault and vault construction.
contract StrategyConfigTest is Base {
    RiskManager internal r;

    function setUp() public override {
        super.setUp();
        r = new RiskManager(address(this));
    }

    // ---------------------------------------------------------------- RiskManager
    function test_Risk_SetLimits_StoresAndEmits() public {
        vm.expectEmit(true, false, false, true, address(r));
        emit RiskManager.LimitsChanged(address(vault), 20e6, 500e6, 100e6, 2000);
        r.setLimits(address(vault), 20e6, 500e6, 100e6, 2000);
        assertEq(r.minDeposit(address(vault)), 20e6);
        assertEq(r.minIdleBps(address(vault)), 2000);
        assertEq(r.maxDeposit(address(vault), 0, 0), 100e6);
        assertEq(r.maxDeposit(address(vault), 450e6, 0), 50e6);
    }

    function test_Risk_SetLimits_Validation() public {
        vm.expectRevert(RiskManager.InvalidLimits.selector);
        r.setLimits(address(vault), 10e6, 1000e6, 250e6, 999); // idle floor 10%
        vm.expectRevert(RiskManager.InvalidLimits.selector);
        r.setLimits(address(vault), 10e6, 1000e6, 250e6, 10_001);
        vm.expectRevert(RiskManager.InvalidLimits.selector);
        r.setLimits(address(vault), 0, 1000e6, 250e6, 1000);
        vm.expectRevert(RiskManager.InvalidLimits.selector);
        r.setLimits(address(vault), 10e6, 100e6, 250e6, 1000); // user cap above TVL cap
        vm.expectRevert(RiskManager.ZeroAddress.selector);
        r.setLimits(address(0), 10e6, 1000e6, 250e6, 1000);
    }

    function test_Risk_Bands_AndAssetCaps() public {
        (uint16 lo, uint16 hi) = r.sleeveBand(address(vault), 0);
        assertEq(lo, 0);
        assertEq(hi, 10_000);
        r.setSleeveBand(address(vault), 0, 1000, 6000);
        (lo, hi) = r.sleeveBand(address(vault), 0);
        assertEq(lo, 1000);
        assertEq(hi, 6000);
        vm.expectRevert(RiskManager.InvalidBand.selector);
        r.setSleeveBand(address(vault), 0, 6001, 6000);
        vm.expectRevert(RiskManager.InvalidBand.selector);
        r.setSleeveBand(address(vault), 0, 0, 10_001);
        assertEq(r.assetMaxBps(address(vault), address(dBTC)), 10_000);
        r.setAssetMaxBps(address(vault), address(dBTC), 3500);
        assertEq(r.assetMaxBps(address(vault), address(dBTC)), 3500);
        vm.expectRevert(RiskManager.InvalidBand.selector);
        r.setAssetMaxBps(address(vault), address(dBTC), 10_001);
        vm.expectRevert(RiskManager.ZeroAddress.selector);
        r.setAssetMaxBps(address(vault), address(0), 100);
    }

    function test_Risk_CallLimits_Validation() public {
        IRiskManager.CallLimits memory l = IRiskManager.CallLimits(1 days, 30 days, 3, 9000, 11_000, 1500);
        r.setCallLimits(address(ccM), l);
        assertEq(r.callLimits(address(ccM)).minStrikeBps, 9000);
        l.minExpiry = 0;
        vm.expectRevert(RiskManager.InvalidLimits.selector);
        r.setCallLimits(address(ccM), l);
        l.minExpiry = 31 days;
        vm.expectRevert(RiskManager.InvalidLimits.selector);
        r.setCallLimits(address(ccM), l);
        l.minExpiry = 1 days;
        l.maxShortsPerAsset = 0;
        vm.expectRevert(RiskManager.InvalidLimits.selector);
        r.setCallLimits(address(ccM), l);
        l.maxShortsPerAsset = 3;
        l.minStrikeBps = 11_001;
        vm.expectRevert(RiskManager.InvalidLimits.selector);
        r.setCallLimits(address(ccM), l);
        l.minStrikeBps = 9000;
        l.maxPremiumBps = 10_001;
        vm.expectRevert(RiskManager.InvalidLimits.selector);
        r.setCallLimits(address(ccM), l);
        vm.expectRevert(RiskManager.ZeroAddress.selector);
        r.setCallLimits(address(0), l);
    }

    function test_Risk_ConstructorZeroAdmin() public {
        vm.expectRevert(RiskManager.ZeroAddress.selector);
        new RiskManager(address(0));
    }

    // ---------------------------------------------------------------- StrategyManager
    function test_Strategy_RegisterTwiceAndUnknown() public {
        StrategyManager s = new StrategyManager(address(this));
        uint16[] memory w = new uint16[](3);
        w[0] = 4000; w[1] = 3000; w[2] = 3000;
        s.registerStrategy(address(vault), "S1", w, CFG);
        vm.expectRevert(StrategyManager.AlreadyRegistered.selector);
        s.registerStrategy(address(vault), "S1", w, CFG);
        w[2] = 2000;
        StrategyManager s2 = new StrategyManager(address(this));
        vm.expectRevert(StrategyManager.InvalidWeights.selector);
        s2.registerStrategy(address(vault), "S1", w, CFG);
        vm.expectRevert(StrategyManager.ZeroAddress.selector);
        s2.registerStrategy(address(0xdead), "x", w, CFG); // no code
        s2.grantRole(s2.MANAGER_ROLE(), manager);
        vm.prank(manager);
        vm.expectRevert(StrategyManager.UnknownStrategy.selector);
        s2.setModuleWeights(address(vault), w, CFG, "x");
        vm.prank(manager);
        vm.expectRevert(StrategyManager.UnknownStrategy.selector);
        s2.setOptionsAvailable(address(vault), address(dBTC), true);
    }

    function test_Strategy_TacticalOverrideBounds() public {
        vm.startPrank(manager);
        vm.expectRevert(StrategyManager.InvalidOverride.selector);
        sm.tacticalOverride(address(vault), 1001, -1001, "too big");
        vm.expectRevert(StrategyManager.InvalidOverride.selector);
        sm.tacticalOverride(address(vault), -1001, 0, "too big");
        vm.expectRevert(StrategyManager.InvalidOverride.selector);
        sm.tacticalOverride(address(vault), 1000, 0, "puts would go negative in calm regime");
        sm.tacticalOverride(address(vault), 1000, -1000, "max allowed");
        vm.stopPrank();
        (uint16 c, uint16 t, uint16 p) = sm.tacticalAllocation(address(vault));
        assertEq(uint256(c) + t + p, 10_000);
        assertEq(c, 3000);
        assertEq(t, 7000);
    }

    function test_Strategy_OverrideEmitsConfigChangeWithActor() public {
        vm.expectEmit(true, true, false, false, address(sm));
        emit StrategyManager.StrategyConfigChanged(address(vault), CFG, bytes32(0), new uint16[](0), manager, "r");
        vm.prank(manager);
        sm.tacticalOverride(address(vault), 100, -100, "r");
        assertTrue(sm.configHash(address(vault)) != CFG);
    }

    function test_Strategy_RegimeInputsValidation() public {
        vm.prank(keeper);
        vm.expectRevert(StrategyManager.InvalidWeights.selector);
        sm.postRegimeInputs(10, true, 1, 10_001);
        vm.expectRevert(StrategyManager.ZeroAddress.selector);
        new StrategyManager(address(0));
    }

    // ---------------------------------------------------------------- InvestorVault registry
    function test_Registry_RegisterGuards() public {
        InvestorVault r2 = new InvestorVault(address(this));
        vm.expectRevert(InvestorVault.InvalidDisclosure.selector);
        r2.registerStrategy(address(vault), bytes32(0));
        vm.expectRevert(InvestorVault.ZeroAddress.selector);
        r2.registerStrategy(address(0), DISC);
        vm.expectRevert(InvestorVault.ZeroAddress.selector);
        r2.registerStrategy(address(0xdead), DISC);
        vm.expectRevert(InvestorVault.ZeroAddress.selector);
        new InvestorVault(address(0));
    }

    // ---------------------------------------------------------------- vault construction / mis-config
    function test_Vault_ConstructorGuards() public {
        IInvestorVault i = IInvestorVault(address(iv));
        IRiskManager rk = IRiskManager(address(risk));
        IStrategyManager m = IStrategyManager(address(sm));
        vm.expectRevert(SIFStrategyVault.ZeroAddress.selector);
        new SIFStrategyVault(IERC20(USDC), "x", "x", address(0), feeRecipient, i, rk, m);
        vm.expectRevert(SIFStrategyVault.ZeroAddress.selector);
        new SIFStrategyVault(IERC20(USDC), "x", "x", address(this), address(0), i, rk, m);
        vm.expectRevert(SIFStrategyVault.InvalidAssetDecimals.selector);
        new SIFStrategyVault(IERC20(address(dBTC)), "x", "x", address(this), feeRecipient, i, rk, m); // 18 decimals
    }

    function test_Vault_ModuleCountMismatch_DepositStaysIdleAndRebalanceReverts() public {
        TacticalSleeveModule extra = new TacticalSleeveModule(
            USDC, address(vault), address(router), address(oracle), address(sm), address(dTBILL)
        );
        _gov(address(vault), abi.encodeCall(SIFStrategyVault.addModule, (address(extra))));
        _deposit(alice, 100e6);
        assertEq(vault.idle(), 100e6, "invalid weights => nothing routed, deposit not stranded");
        vm.prank(keeper);
        vm.expectRevert(SIFStrategyVault.InvalidWeights.selector);
        vault.rebalance();
        // exits unaffected
        uint256 w = vault.maxWithdraw(alice);
        vm.prank(alice);
        vault.withdraw(w, alice, alice);
        assertEq(usdc.balanceOf(alice), w);
    }
}
