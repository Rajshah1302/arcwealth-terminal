// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {DemoERC20} from "../demo/DemoERC20.sol";
import {DemoPriceOracle} from "../demo/DemoPriceOracle.sol";
import {DemoSwapRouter} from "../demo/DemoSwapRouter.sol";
import {DemoBondIssuer} from "../demo/DemoBondIssuer.sol";
import {DemoOptionsCounterparty} from "../demo/DemoOptionsCounterparty.sol";
import {RiskManager} from "../core/RiskManager.sol";
import {StrategyManager} from "../core/StrategyManager.sol";
import {InvestorVault} from "../core/InvestorVault.sol";
import {SIFStrategyVault} from "../core/SIFStrategyVault.sol";
import {ArcWealthTimelock} from "../core/ArcWealthTimelock.sol";
import {BondInvestmentModule} from "../modules/BondInvestmentModule.sol";
import {CoveredCallModule} from "../modules/CoveredCallModule.sol";
import {TacticalSleeveModule} from "../modules/TacticalSleeveModule.sol";
import {IInvestorVault, IRiskManager, IStrategyManager} from "../interfaces/IArcWealth.sol";

/// @notice Shared S1 fixture: full ARCWEALTH system with the timelock handover already done.
/// The test contract is the deployer; after setUp it holds NO admin power.
abstract contract Base is Test {
    address internal constant USDC = 0x3600000000000000000000000000000000000000;
    address internal constant BLOCKED = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    bytes32 internal constant DISC = keccak256("ARCWEALTH-S1-DISCLOSURE-v1");
    bytes32 internal constant CFG = keccak256("S1-config-v1");
    uint256 internal constant T0 = 1_700_000_000;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal erin = makeAddr("erin");
    address internal manager = makeAddr("manager");
    address internal keeper = makeAddr("keeper");
    address internal pauser = makeAddr("pauser");
    address internal gov = makeAddr("gov");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal attacker = makeAddr("attacker");

    MockUSDC internal usdc;
    DemoPriceOracle internal oracle;
    DemoSwapRouter internal router;
    DemoERC20 internal dBTC;
    DemoERC20 internal dETH;
    DemoERC20 internal dTBILL;
    DemoBondIssuer internal issuer;
    DemoOptionsCounterparty internal cp;
    RiskManager internal risk;
    StrategyManager internal sm;
    InvestorVault internal iv;
    SIFStrategyVault internal vault;
    BondInvestmentModule internal bondM;
    CoveredCallModule internal ccM;
    TacticalSleeveModule internal tacM;
    ArcWealthTimelock internal tl;
    uint256 internal govNonce;

    function setUp() public virtual {
        vm.warp(T0);
        // --- USDC mock at the hardcoded Arc address -------------------------------------------
        MockUSDC impl = new MockUSDC();
        vm.etch(USDC, address(impl).code);
        usdc = MockUSDC(USDC);

        // --- demo layer ---------------------------------------------------------------------
        oracle = new DemoPriceOracle(address(this), keeper);
        dBTC = new DemoERC20("Demo BTC", "dBTC", 18, address(this), 1e18);
        dETH = new DemoERC20("Demo ETH", "dETH", 18, address(this), 10e18);
        dTBILL = new DemoERC20("Demo TBILL", "dTBILL", 18, address(this), 100e18);
        router = new DemoSwapRouter(USDC, address(oracle), address(this));
        _registerToken(dBTC, 60_000e8);
        _registerToken(dETH, 3_000e8);
        _registerToken(dTBILL, 100e8);

        issuer = new DemoBondIssuer(USDC, address(this));
        issuer.createSeries("Arc Treasury 30d", "AAA", 400, uint64(block.timestamp + 30 days));
        issuer.createSeries("Arc Corporate 60d", "AA", 450, uint64(block.timestamp + 60 days));
        issuer.createSeries("Arc Corporate 90d", "A", 500, uint64(block.timestamp + 90 days));

        cp = new DemoOptionsCounterparty(USDC, address(this));
        cp.setRouter(address(router));

        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(router), type(uint256).max);
        usdc.approve(address(issuer), type(uint256).max);
        usdc.approve(address(cp), type(uint256).max);
        router.fundReserve(200_000e6);
        issuer.fundReserve(200_000e6);
        cp.fundReserve(200_000e6);

        // --- core -----------------------------------------------------------------------------
        risk = new RiskManager(address(this));
        sm = new StrategyManager(address(this));
        iv = new InvestorVault(address(this));
        vault = new SIFStrategyVault(
            IERC20(USDC), "ARC SIF S1", "aS1", address(this), feeRecipient,
            IInvestorVault(address(iv)), IRiskManager(address(risk)), IStrategyManager(address(sm))
        );

        // --- modules (order: bond, covered call, tactical) -----------------------------------
        uint256[] memory ids = new uint256[](3);
        ids[0] = 0; ids[1] = 1; ids[2] = 2;
        bondM = new BondInvestmentModule(USDC, address(vault), address(issuer), ids);
        address[] memory und = new address[](2);
        und[0] = address(dBTC); und[1] = address(dETH);
        uint16[] memory undBps = new uint16[](2);
        undBps[0] = 5000; undBps[1] = 5000;
        ccM = new CoveredCallModule(USDC, address(vault), address(router), address(oracle), address(cp), address(risk), und, undBps);
        tacM = new TacticalSleeveModule(USDC, address(vault), address(router), address(oracle), address(sm), address(dTBILL));
        vault.addModule(address(bondM));
        vault.addModule(address(ccM));
        vault.addModule(address(tacM));

        // --- config ---------------------------------------------------------------------------
        iv.registerStrategy(address(vault), DISC);
        risk.setLimits(address(vault), 10e6, 1_000e6, 250e6, 1000);
        risk.setCallLimits(address(ccM), IRiskManager.CallLimits({
            minExpiry: 1 days, maxExpiry: 30 days, maxShortsPerAsset: 3,
            minStrikeBps: 9000, maxStrikeBps: 11_000, maxPremiumBps: 1500
        }));
        uint16[] memory w = new uint16[](3);
        w[0] = 4000; w[1] = 3000; w[2] = 3000;
        sm.registerStrategy(address(vault), "S1", w, CFG);
        cp.grantRole(cp.MODULE_ROLE(), address(ccM));

        // --- operating roles --------------------------------------------------------------------
        sm.grantRole(sm.MANAGER_ROLE(), manager);
        sm.grantRole(sm.KEEPER_ROLE(), keeper);
        vault.grantRole(vault.MANAGER_ROLE(), manager);
        vault.grantRole(vault.KEEPER_ROLE(), keeper);
        vault.grantRole(vault.PAUSER_ROLE(), pauser);
        router.grantRole(router.MANAGER_ROLE(), manager);
        issuer.grantRole(issuer.MANAGER_ROLE(), manager);
        cp.grantRole(cp.KEEPER_ROLE(), keeper);

        _handover();
    }

    // ------------------------------------------------------------------------------------------
    // setup helpers
    // ------------------------------------------------------------------------------------------
    function _registerToken(DemoERC20 t, uint256 price8) internal {
        t.grantRole(t.MINTER_ROLE(), address(router));
        router.registerToken(address(t));
        vm.prank(keeper);
        oracle.setPrice(address(t), price8);
    }

    /// @dev Moves DEFAULT_ADMIN of everything to a 600s timelock and drops the deployer's powers.
    function _handover() internal {
        address[] memory props = new address[](1);
        props[0] = gov;
        tl = new ArcWealthTimelock(600, props, props, address(0));
        bytes32 admin = 0x00;
        address[11] memory targets = [
            address(oracle), address(router), address(issuer), address(cp), address(risk), address(sm),
            address(iv), address(vault), address(dBTC), address(dETH), address(dTBILL)
        ];
        for (uint256 i; i < targets.length; ++i) {
            IAccessControl(targets[i]).grantRole(admin, address(tl));
            IAccessControl(targets[i]).renounceRole(admin, address(this));
        }
        router.renounceRole(router.MANAGER_ROLE(), address(this));
        issuer.renounceRole(issuer.MANAGER_ROLE(), address(this));
        cp.renounceRole(cp.KEEPER_ROLE(), address(this));
    }

    /// @dev Executes `data` on `target` as the timelock (schedule -> wait 600s -> execute).
    function _gov(address target, bytes memory data) internal {
        bytes32 salt = keccak256(abi.encode(target, data, govNonce++));
        vm.startPrank(gov);
        tl.schedule(target, 0, data, bytes32(0), salt, 600);
        vm.warp(block.timestamp + 600);
        tl.execute(target, 0, data, bytes32(0), salt);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------
    // user helpers
    // ------------------------------------------------------------------------------------------
    function _onboard(address u, uint256 amt) internal {
        usdc.mint(u, amt);
        vm.startPrank(u);
        usdc.approve(address(vault), type(uint256).max);
        iv.acceptDisclosure(address(vault), DISC);
        vm.stopPrank();
    }

    function _deposit(address u, uint256 amt) internal returns (uint256 sh) {
        _onboard(u, amt);
        vm.prank(u);
        sh = vault.deposit(amt, u);
    }

    /// @dev Re-posts the current price of every demo token so the oracle is fresh again.
    function _refresh() internal {
        address[3] memory ts = [address(dBTC), address(dETH), address(dTBILL)];
        vm.startPrank(keeper);
        for (uint256 i; i < 3; ++i) {
            (uint256 p,) = oracle.getPriceUnsafe(ts[i]);
            oracle.setPrice(ts[i], p);
        }
        vm.stopPrank();
    }

    function _setPrice(address token, uint256 p) internal {
        vm.prank(keeper);
        oracle.setPrice(token, p);
    }

    function _skip(uint256 dt) internal {
        vm.warp(block.timestamp + dt);
        _refresh();
    }

    function _moduleSum() internal view returns (uint256 s) {
        s = bondM.totalValue() + ccM.totalValue() + tacM.totalValue();
    }
}
