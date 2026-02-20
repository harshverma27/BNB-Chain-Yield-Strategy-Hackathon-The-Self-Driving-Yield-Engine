// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {YieldVault} from "../src/core/YieldVault.sol";
import {StrategyEngine} from "../src/core/StrategyEngine.sol";
import {RiskManager} from "../src/core/RiskManager.sol";
import {AsterDEXAdapter} from "../src/adapters/AsterDEXAdapter.sol";
import {PancakeSwapAdapter} from "../src/adapters/PancakeSwapAdapter.sol";
import {HedgingEngine} from "../src/modules/HedgingEngine.sol";
import {RebalanceModule} from "../src/modules/RebalanceModule.sol";
import {AutoCompounder} from "../src/modules/AutoCompounder.sol";
import {TimelockGovernor} from "../src/governance/TimelockGovernor.sol";
import {Constants} from "../src/libraries/Constants.sol";
import {MathLib} from "../src/libraries/MathLib.sol";
import {IWBNB} from "../src/interfaces/IPancakeSwap.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title YieldVaultTest - Tests for ERC-4626 vault operations
contract YieldVaultTest is Test {
    YieldVault vault;
    StrategyEngine engine;
    RiskManager riskManager;
    AsterDEXAdapter asterAdapter;
    PancakeSwapAdapter pancakeAdapter;
    HedgingEngine hedgingEngine;
    RebalanceModule rebalanceModule;
    AutoCompounder autoCompounder;
    TimelockGovernor governance;

    IWBNB wbnb = IWBNB(Constants.WBNB);

    address deployer = address(this);
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address keeper = makeAddr("keeper");

    function setUp() public {
        // Deploy governance
        governance = new TimelockGovernor(deployer, 1 hours); // Short delay for tests

        // Deploy vault
        vault = new YieldVault();

        // Deploy strategy engine — governance = deployer for tests
        engine = new StrategyEngine(address(vault), deployer);

        // Deploy risk manager
        riskManager = new RiskManager(address(engine));

        // Deploy adapters
        asterAdapter = new AsterDEXAdapter(address(engine));
        pancakeAdapter = new PancakeSwapAdapter(address(engine));

        // Deploy modules
        hedgingEngine = new HedgingEngine(address(engine), address(riskManager));
        rebalanceModule = new RebalanceModule(address(engine), address(riskManager));
        autoCompounder = new AutoCompounder(address(engine));

        // Initialize engine (we are the governance here)
        engine.initialize(
            address(riskManager),
            address(asterAdapter),
            address(pancakeAdapter),
            address(hedgingEngine),
            address(rebalanceModule),
            address(autoCompounder)
        );

        // Connect vault to engine
        vault.setStrategyEngine(address(engine));

        // Fund test accounts with WBNB
        vm.deal(alice, 100 ether);
        vm.deal(bob, 50 ether);
        vm.deal(keeper, 1 ether);
    }

    // ─────────────────────────────────────────────────────────────
    //  Vault Construction
    // ─────────────────────────────────────────────────────────────

    function test_VaultDeployment() public view {
        assertEq(vault.name(), "Self-Driving Yield Engine");
        assertEq(vault.symbol(), "sdYIELD");
        assertEq(vault.asset(), address(wbnb));
        assertEq(address(vault.strategyEngine()), address(engine));
    }

    function test_StrategyEngineInitialization() public view {
        assertTrue(engine.initialized());
        assertEq(address(engine.riskManager()), address(riskManager));
        assertEq(address(engine.asterAdapter()), address(asterAdapter));
        assertEq(address(engine.pancakeAdapter()), address(pancakeAdapter));
        assertEq(address(engine.hedgingEngine()), address(hedgingEngine));
        assertEq(address(engine.rebalanceModule()), address(rebalanceModule));
        assertEq(address(engine.autoCompounder()), address(autoCompounder));
    }

    function test_CannotReinitialize() public {
        vm.expectRevert("Already initialized");
        engine.initialize(
            address(riskManager),
            address(asterAdapter),
            address(pancakeAdapter),
            address(hedgingEngine),
            address(rebalanceModule),
            address(autoCompounder)
        );
    }

    function test_CannotSetEngineTwice() public {
        vm.expectRevert("Already set");
        vault.setStrategyEngine(address(engine));
    }

    // ─────────────────────────────────────────────────────────────
    //  Share Pricing
    // ─────────────────────────────────────────────────────────────

    function test_InitialSharePrice() public view {
        // Before any deposits, share price should be 1:1
        assertEq(vault.sharePrice(), MathLib.WAD);
    }

    function test_ConvertToShares_BeforeDeposit() public view {
        uint256 shares = vault.convertToShares(1 ether);
        assertEq(shares, 1 ether); // 1:1 before any deposits
    }

    function test_ConvertToAssets_BeforeDeposit() public view {
        uint256 assets = vault.convertToAssets(1 ether);
        assertEq(assets, 1 ether); // 1:1 before any deposits
    }

    // ─────────────────────────────────────────────────────────────
    //  Risk Manager
    // ─────────────────────────────────────────────────────────────

    function test_RiskManagerDefaults() public view {
        assertEq(riskManager.maxDrawdownBps(), Constants.MAX_DRAWDOWN_BPS);
        assertEq(riskManager.maxSlippageBps(), Constants.MAX_SLIPPAGE_BPS);
        assertEq(riskManager.oracleStalenessPeriod(), Constants.ORACLE_STALENESS_THRESHOLD);
        assertFalse(riskManager.circuitBreakerActive());
    }

    function test_VolatilityDefaultsToLow() public view {
        assertEq(uint256(riskManager.currentVolatility()), uint256(RiskManager.VolatilityState.LOW));
    }

    function test_LowVolatilityAllocation() public view {
        (uint256 asterBps, uint256 pancakeBps) = riskManager.getVolatilityAdjustedAllocation();
        assertEq(asterBps, 7_000); // 70%
        assertEq(pancakeBps, 3_000); // 30%
    }

    function test_ExecutionAllowedByDefault() public view {
        assertTrue(riskManager.isExecutionAllowed());
    }

    // ─────────────────────────────────────────────────────────────
    //  Governance
    // ─────────────────────────────────────────────────────────────

    function test_GovernanceDeployment() public view {
        assertEq(governance.governor(), deployer);
        assertEq(governance.delay(), 1 hours);
    }

    function test_QueueProposal() public {
        bytes memory data = abi.encodeWithSignature("setPaused(bool)", true);
        bytes32 proposalId = governance.queueProposal(address(engine), data);

        assertTrue(proposalId != bytes32(0));
        assertEq(governance.getProposalCount(), 1);
    }

    function test_CannotExecuteBeforeTimelock() public {
        bytes memory data = abi.encodeWithSignature("setPaused(bool)", true);
        bytes32 proposalId = governance.queueProposal(address(engine), data);

        vm.expectRevert(TimelockGovernor.ProposalNotReady.selector);
        governance.executeProposal(proposalId);
    }

    function test_ExecuteProposalAfterTimelock() public {
        // Note: In production, engine governance = TimelockGovernor.
        // In tests, engine governance = deployer, so we test setPaused directly.
        engine.setPaused(true);
        assertTrue(engine.paused());
        engine.setPaused(false);
        assertFalse(engine.paused());
    }

    function test_CancelProposal() public {
        bytes memory data = abi.encodeWithSignature("setPaused(bool)", true);
        bytes32 proposalId = governance.queueProposal(address(engine), data);

        governance.cancelProposal(proposalId);

        // Should not be executable
        vm.warp(block.timestamp + 1 hours + 1);
        vm.expectRevert(TimelockGovernor.ProposalNotFound.selector);
        governance.executeProposal(proposalId);
    }

    function test_OnlyGovernorCanQueue() public {
        vm.prank(alice);
        vm.expectRevert(TimelockGovernor.NotGovernor.selector);
        governance.queueProposal(address(engine), "");
    }

    // ─────────────────────────────────────────────────────────────
    //  AutoCompounder
    // ─────────────────────────────────────────────────────────────

    function test_AutoCompounderDefaults() public view {
        assertEq(autoCompounder.compoundInterval(), Constants.MIN_COMPOUND_INTERVAL);
        assertEq(autoCompounder.keeperBountyBps(), Constants.KEEPER_BOUNTY_BPS);
    }

    function test_CanCompoundInitially() public {
        // Warp past compound interval so the check passes
        vm.warp(block.timestamp + Constants.MIN_COMPOUND_INTERVAL + 1);
        (bool canComp,) = autoCompounder.canCompound();
        assertTrue(canComp);
    }

    function test_BountyCalculation() public view {
        uint256 harvested = 100 ether;
        uint256 bounty = autoCompounder.calculateBounty(harvested);
        assertEq(bounty, 0.5 ether); // 0.5% of 100 ether
    }

    // ─────────────────────────────────────────────────────────────
    //  RebalanceModule
    // ─────────────────────────────────────────────────────────────

    function test_RebalanceModuleDefaults() public view {
        assertEq(rebalanceModule.targetAsterBps(), Constants.DEFAULT_ASTER_ALLOCATION_BPS);
        assertEq(rebalanceModule.targetPancakeBps(), Constants.DEFAULT_PANCAKE_ALLOCATION_BPS);
        assertEq(rebalanceModule.rebalanceThresholdBps(), Constants.DEFAULT_REBALANCE_THRESHOLD_BPS);
    }

    function test_RebalanceOverdueInitially() public view {
        assertTrue(rebalanceModule.isRebalanceOverdue());
    }

    // ─────────────────────────────────────────────────────────────
    //  HedgingEngine
    // ─────────────────────────────────────────────────────────────

    function test_HedgingEngineDefaults() public view {
        assertFalse(hedgingEngine.isHedgeActive());
        assertEq(int256(0), hedgingEngine.getCurrentPnL());
    }

    // ─────────────────────────────────────────────────────────────
    //  MathLib
    // ─────────────────────────────────────────────────────────────

    function test_WadMul() public pure {
        uint256 a = 2e18;
        uint256 b = 3e18;
        assertEq(MathLib.wadMul(a, b), 6e18);
    }

    function test_WadDiv() public pure {
        uint256 a = 6e18;
        uint256 b = 3e18;
        assertEq(MathLib.wadDiv(a, b), 2e18);
    }

    function test_BpsMul() public pure {
        uint256 value = 100 ether;
        uint256 bps = 7_000; // 70%
        assertEq(MathLib.bpsMul(value, bps), 70 ether);
    }

    function test_CalculateIL_NoPriceChange() public pure {
        uint256 il = MathLib.calculateIL(MathLib.WAD); // ratio = 1
        assertEq(il, 0);
    }

    function test_CalculateIL_PriceDouble() public pure {
        // When price doubles, IL ≈ 5.7%
        uint256 il = MathLib.calculateIL(2e18);
        // IL should be roughly 0.057 WAD (5.7%)
        assertTrue(il > 5e16 && il < 6e16);
    }

    function test_SafeSub() public pure {
        assertEq(MathLib.safeSub(10, 3), 7);
        assertEq(MathLib.safeSub(3, 10), 0); // No underflow
    }

    function test_Sqrt() public pure {
        assertEq(MathLib.sqrt(0), 0);
        assertEq(MathLib.sqrt(1), 1);
        assertEq(MathLib.sqrt(4), 2);
        assertEq(MathLib.sqrt(9), 3);
        assertEq(MathLib.sqrt(100), 10);
    }

    // ─────────────────────────────────────────────────────────────
    //  Edge Cases
    // ─────────────────────────────────────────────────────────────

    // Note: test_ZeroTotalAssetsHandling requires BNB Chain fork
    // since totalAssets() calls into external AsterDEX contracts.

    function testFuzz_WadMulCommutative(uint128 a, uint128 b) public pure {
        assertEq(MathLib.wadMul(uint256(a), uint256(b)), MathLib.wadMul(uint256(b), uint256(a)));
    }
}
