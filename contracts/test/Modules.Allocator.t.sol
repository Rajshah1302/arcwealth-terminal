// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "./Base.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DemoERC20} from "../demo/DemoERC20.sol";
import {SIFStrategyVault} from "../core/SIFStrategyVault.sol";
import {StrategyManager} from "../core/StrategyManager.sol";
import {InvestorVault} from "../core/InvestorVault.sol";
import {RiskManager} from "../core/RiskManager.sol";
import {AssetAllocatorModule} from "../modules/AssetAllocatorModule.sol";
import {IInvestorVault, IRiskManager, IStrategyManager} from "../interfaces/IArcWealth.sol";

/// @notice S2 AssetAllocatorModule: basket routing, asset caps and the dCOPR options-disabled overlay.
contract AllocatorTest is Base {
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
        _gov(address(sm), abi.encodeCall(StrategyManager.setNoOptions, (address(dCOPR), true)));
        _refresh();
        _setPrice(address(dCOPR), 25e8);
        _setAssetWeights(3000, 3000, 3000, 1000);
    }

    function _setAssetWeights(uint16 a, uint16 b, uint16 c, uint16 d) internal {
        uint16[] memory bps = new uint16[](4);
        bps[0] = a; bps[1] = b; bps[2] = c; bps[3] = d;
        vm.prank(manager);
        sm.setAssetWeights(address(vault2), toks, bps, keccak256(abi.encode(a, b, c, d)), "weights");
    }

    function _dep2(address u, uint256 amt) internal returns (uint256) {
        usdc.mint(u, amt);
        vm.startPrank(u);
        usdc.approve(address(vault2), type(uint256).max);
        iv.acceptDisclosure(address(vault2), DISC);
        uint256 sh = vault2.deposit(amt, u);
        vm.stopPrank();
        return sh;
    }

    // ---------------------------------------------------------------- routing
    function test_Deposit_BuysBasketPerAssetWeights() public {
        _dep2(alice, 100e6);
        assertEq(vault2.idle(), 10e6);
        assertApproxEqRel(dBTC.balanceOf(address(alloc)) * 60_000e8 / 1e20, 27e6, 0.004e18);
        assertApproxEqRel(dETH.balanceOf(address(alloc)) * 3_000e8 / 1e20, 27e6, 0.004e18);
        assertApproxEqRel(dTBILL.balanceOf(address(alloc)) * 100e8 / 1e20, 27e6, 0.004e18);
        assertApproxEqRel(dCOPR.balanceOf(address(alloc)) * 25e8 / 1e20, 9e6, 0.004e18);
        assertApproxEqRel(alloc.totalValue(), 90e6, 0.004e18);
        assertTrue(alloc.isDemo());
    }

    function test_AssetCap_RiskLowerThanWeights_ManagerCannotExceed() public {
        _gov(address(risk), abi.encodeCall(RiskManager.setAssetMaxBps, (address(vault2), address(dBTC), 2000)));
        uint16[] memory bps = new uint16[](4);
        bps[0] = 3000; bps[1] = 3000; bps[2] = 3000; bps[3] = 1000;
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(StrategyManager.WeightOutsideBand.selector, 0));
        sm.setAssetWeights(address(vault2), toks, bps, H2, "too much btc");
    }

    function test_AssetCap_TightenedAfterwards_DepositRoutingFailsSafely() public {
        _gov(address(risk), abi.encodeCall(RiskManager.setAssetMaxBps, (address(vault2), address(dBTC), 2000)));
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(vault2), type(uint256).max);
        iv.acceptDisclosure(address(vault2), DISC);
        vm.expectEmit(true, false, false, false, address(vault2));
        emit SIFStrategyVault.RouteFailed(address(alloc), 0, "");
        uint256 sh = vault2.deposit(100e6, alice);
        vm.stopPrank();
        assertGt(sh, 0, "deposit not bricked by a module failure");
        assertEq(vault2.idle(), 100e6, "funds stay idle");
        // exits remain possible
        vm.prank(alice);
        vault2.withdraw(10e6, alice, alice);
    }

    function test_Rebalance_KeeperOnly_AndRestoresWeights() public {
        _dep2(alice, 100e6);
        vm.prank(attacker);
        vm.expectRevert(AssetAllocatorModule.OnlyKeeper.selector);
        alloc.rebalance();
        _setPrice(address(dBTC), 66_000e8);
        _setPrice(address(dETH), 3_000e8);
        _setPrice(address(dTBILL), 100e8);
        _setPrice(address(dCOPR), 25e8);
        uint256 nav = alloc.totalValue();
        vm.prank(keeper);
        alloc.rebalance();
        assertApproxEqRel(alloc.totalValue(), nav, 0.01e18, "rebalance only costs fees");
        uint256 btcShare = dBTC.balanceOf(address(alloc)) * 66_000e8 / 1e20 * 10_000 / alloc.totalValue();
        assertApproxEqAbs(btcShare, 3000, 60);
    }

    function test_Withdraw_OnlyVault_AndSellsBasket() public {
        _dep2(alice, 100e6);
        vm.prank(attacker);
        vm.expectRevert(AssetAllocatorModule.OnlyVault.selector);
        alloc.withdraw(1);
        uint256 before = usdc.balanceOf(address(vault2));
        vm.prank(address(vault2));
        uint256 sent = alloc.withdraw(30e6);
        assertApproxEqAbs(sent, 30e6, 2);
        assertEq(usdc.balanceOf(address(vault2)) - before, sent);
    }

    function test_TotalValue_StaleOracleUsesCheckpoint() public {
        _dep2(alice, 100e6);
        uint256 v = alloc.totalValue();
        vm.warp(block.timestamp + 3 hours);
        assertEq(alloc.totalValue(), v);
    }

    // ---------------------------------------------------------------- dCOPR options disabled in overlay
    function test_Overlay_dCOPR_OptionsDisabled() public {
        // admin flagged dCOPR noOptions; even the manager cannot turn it on
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(StrategyManager.OptionsDisabled.selector, address(dCOPR)));
        sm.setOptionsAvailable(address(vault2), address(dCOPR), true);
        assertFalse(sm.optionsAvailable(address(vault2), address(dCOPR)));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AssetAllocatorModule.OptionsDisabled.selector, address(dCOPR)));
        alloc.recordOverlay(address(dCOPR), "COVERED_CALL", 2000, "attempt");
    }

    function test_Overlay_dCOPR_StaysDisabledEvenIfFlagSetBeforeNoOptions() public {
        // enable on a token, then admin disables globally: overlay must be blocked immediately
        vm.prank(manager);
        sm.setOptionsAvailable(address(vault2), address(dETH), true);
        assertTrue(sm.optionsAvailable(address(vault2), address(dETH)));
        _gov(address(sm), abi.encodeCall(StrategyManager.setNoOptions, (address(dETH), true)));
        assertFalse(sm.optionsAvailable(address(vault2), address(dETH)));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(AssetAllocatorModule.OptionsDisabled.selector, address(dETH)));
        alloc.recordOverlay(address(dETH), "COVERED_CALL", 1000, "x");
    }

    function test_Overlay_EnabledAssetEmitsRecordOnly() public {
        vm.prank(manager);
        sm.setOptionsAvailable(address(vault2), address(dBTC), true);
        uint256 navBefore = alloc.totalValue();
        vm.expectEmit(true, true, false, true, address(alloc));
        emit AssetAllocatorModule.OverlayRecorded(address(dBTC), "COVERED_CALL", 2000, "income overlay");
        vm.prank(keeper);
        alloc.recordOverlay(address(dBTC), "COVERED_CALL", 2000, "income overlay");
        assertEq(alloc.totalValue(), navBefore, "recorded only: no funds or assets move");
    }

    function test_Overlay_Guards() public {
        vm.prank(manager);
        sm.setOptionsAvailable(address(vault2), address(dBTC), true);
        vm.prank(attacker);
        vm.expectRevert(AssetAllocatorModule.OnlyKeeper.selector);
        alloc.recordOverlay(address(dBTC), "X", 1, "r");
        vm.startPrank(keeper);
        vm.expectRevert(AssetAllocatorModule.InvalidNotional.selector);
        alloc.recordOverlay(address(dBTC), "X", 10_001, "r");
        vm.expectRevert(abi.encodeWithSelector(AssetAllocatorModule.InvalidToken.selector, USDC));
        alloc.recordOverlay(USDC, "X", 1, "r");
        vm.stopPrank();
    }

    function test_Manager_OnlyAdminCanFlagNoOptions() public {
        vm.prank(manager);
        vm.expectPartialRevert(bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")));
        sm.setNoOptions(address(dBTC), true);
    }

    // ---------------------------------------------------------------- manager config validation
    function test_AssetWeights_MustSumTo10000_NoDuplicates() public {
        uint16[] memory bps = new uint16[](4);
        bps[0] = 3000; bps[1] = 3000; bps[2] = 3000; bps[3] = 999;
        vm.prank(manager);
        vm.expectRevert(StrategyManager.InvalidWeights.selector);
        sm.setAssetWeights(address(vault2), toks, bps, H2, "sum");
        address[] memory dup = new address[](2);
        dup[0] = address(dBTC); dup[1] = address(dBTC);
        uint16[] memory b2 = new uint16[](2);
        b2[0] = 5000; b2[1] = 5000;
        vm.prank(manager);
        vm.expectRevert(StrategyManager.InvalidWeights.selector);
        sm.setAssetWeights(address(vault2), dup, b2, H2, "dup");
        vm.prank(manager);
        vm.expectRevert(StrategyManager.InvalidWeights.selector);
        sm.setAssetWeights(address(vault2), toks, b2, H2, "len");
    }

    function test_Constructor_Guards() public {
        address[] memory bad = new address[](2);
        bad[0] = address(dBTC);
        bad[1] = address(dBTC);
        vm.expectRevert(abi.encodeWithSelector(AssetAllocatorModule.InvalidToken.selector, address(dBTC)));
        new AssetAllocatorModule(USDC, address(vault2), address(router), address(oracle), address(sm), address(risk), bad);
        address[] memory none = new address[](0);
        vm.expectRevert(AssetAllocatorModule.InvalidWeights.selector);
        new AssetAllocatorModule(USDC, address(vault2), address(router), address(oracle), address(sm), address(risk), none);
    }
}
