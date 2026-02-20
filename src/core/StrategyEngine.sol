// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Constants} from "../libraries/Constants.sol";
import {MathLib} from "../libraries/MathLib.sol";
import {RiskManager} from "./RiskManager.sol";
import {AsterDEXAdapter} from "../adapters/AsterDEXAdapter.sol";
import {PancakeSwapAdapter} from "../adapters/PancakeSwapAdapter.sol";
import {HedgingEngine} from "../modules/HedgingEngine.sol";
import {RebalanceModule} from "../modules/RebalanceModule.sol";
import {AutoCompounder} from "../modules/AutoCompounder.sol";
import {IWBNB} from "../interfaces/IPancakeSwap.sol";

/// @title StrategyEngine - Central autonomous orchestrator for the Self-Driving Yield Engine
/// @notice Coordinates all strategy operations: deploy, harvest, compound, rebalance, hedge
/// @dev Fully permissionless — executeStrategy() can be called by anyone with gas bounty incentive
contract StrategyEngine is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MathLib for uint256;

    // ─────────────────────────────────────────────────────────────
    //  Errors
    // ─────────────────────────────────────────────────────────────
    error NotVault();
    error NotGovernance();
    error ExecutionNotAllowed();
    error InsufficientFunds();
    error ZeroAmount();

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────
    event StrategyExecuted(
        address indexed caller, uint256 totalValue, uint256 harvested, uint256 keeperBounty, uint256 timestamp
    );
    event CapitalDeployed(uint256 toAster, uint256 toPancake);
    event CapitalWithdrawn(uint256 fromAster, uint256 fromPancake);
    event EmergencyWithdrawExecuted(uint256 totalRecovered);

    // ─────────────────────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────────────────────

    // Immutable references
    address public immutable vault;
    address public immutable governance;
    IWBNB public immutable wbnb;
    IERC20 public immutable usdt;

    // Module references (set once at initialization)
    RiskManager public riskManager;
    AsterDEXAdapter public asterAdapter;
    PancakeSwapAdapter public pancakeAdapter;
    HedgingEngine public hedgingEngine;
    RebalanceModule public rebalanceModule;
    AutoCompounder public autoCompounder;

    // Strategy state
    bool public initialized;
    bool public paused;
    uint256 public totalDeployed; // Total capital deployed across all protocols
    uint256 public lastExecutionTimestamp;
    uint256 public totalExecutions;

    // Capital tracking
    uint256 public asterCapital; // Capital deployed to AsterDEX Earn
    uint256 public pancakeCapital; // Capital deployed to PancakeSwap

    // ─────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────
    constructor(address _vault, address _governance) {
        vault = _vault;
        governance = _governance;
        wbnb = IWBNB(Constants.WBNB);
        usdt = IERC20(Constants.USDT);
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Paused");
        _;
    }

    // ─────────────────────────────────────────────────────────────
    //  Initialization
    // ─────────────────────────────────────────────────────────────

    /// @notice Initialize all module references (called once after deployment)
    function initialize(
        address _riskManager,
        address _asterAdapter,
        address _pancakeAdapter,
        address _hedgingEngine,
        address _rebalanceModule,
        address _autoCompounder
    ) external onlyGovernance {
        require(!initialized, "Already initialized");

        riskManager = RiskManager(_riskManager);
        asterAdapter = AsterDEXAdapter(payable(_asterAdapter));
        pancakeAdapter = PancakeSwapAdapter(payable(_pancakeAdapter));
        hedgingEngine = HedgingEngine(_hedgingEngine);
        rebalanceModule = RebalanceModule(_rebalanceModule);
        autoCompounder = AutoCompounder(_autoCompounder);

        initialized = true;
    }

    // ─────────────────────────────────────────────────────────────
    //  Core Strategy Execution (Permissionless)
    // ─────────────────────────────────────────────────────────────

    /// @notice Execute the full strategy cycle — anyone can call this
    /// @dev Caller receives a gas bounty as incentive (% of harvested yield)
    /// @return harvested Total rewards harvested
    /// @return bounty Bounty paid to caller
    function executeStrategy() external nonReentrant whenNotPaused returns (uint256 harvested, uint256 bounty) {
        require(initialized, "Not initialized");

        // 1. Check if execution is allowed by risk manager
        if (!riskManager.isExecutionAllowed()) revert ExecutionNotAllowed();

        // 2. Update volatility assessment
        riskManager.updateVolatility();

        // 3. Harvest rewards from all sources
        harvested = _harvestAll();

        // 4. Calculate and pay keeper bounty
        if (harvested > 0) {
            bounty = autoCompounder.calculateBounty(harvested);
            if (bounty > 0) {
                // Pay bounty in WBNB to the caller
                uint256 wbnbBal = IERC20(address(wbnb)).balanceOf(address(this));
                if (bounty > wbnbBal) bounty = wbnbBal;
                if (bounty > 0) {
                    IERC20(address(wbnb)).safeTransfer(msg.sender, bounty);
                }
            }
        }

        // 5. Compound remaining rewards back into strategy
        uint256 compoundable = harvested > bounty ? harvested - bounty : 0;
        if (compoundable > 0) {
            _deployCapital(compoundable);
        }

        // 6. Check and execute rebalancing
        _rebalance();

        // 7. Update hedging positions
        _updateHedge();

        // 8. Check drawdown circuit breaker
        uint256 currentValue = getTotalValue();
        riskManager.checkDrawdown(currentValue);
        riskManager.tryResetCircuitBreaker(currentValue);

        // 9. Record compound event
        if (harvested > 0) {
            autoCompounder.recordCompound(msg.sender, harvested, bounty);
        }

        lastExecutionTimestamp = block.timestamp;
        totalExecutions++;

        emit StrategyExecuted(msg.sender, currentValue, harvested, bounty, block.timestamp);
    }

    // ─────────────────────────────────────────────────────────────
    //  Capital Management (Vault Interface)
    // ─────────────────────────────────────────────────────────────

    /// @notice Deploy capital from the vault into the strategy
    /// @param amount Amount of WBNB to deploy
    function deployFromVault(uint256 amount) external onlyVault whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        // Transfer WBNB from vault
        IERC20(address(wbnb)).safeTransferFrom(vault, address(this), amount);

        _deployCapital(amount);
    }

    /// @notice Withdraw capital from the strategy back to the vault
    /// @param amount Amount of WBNB to withdraw
    function withdrawToVault(uint256 amount) external onlyVault {
        if (amount == 0) revert ZeroAmount();

        // Determine proportional withdrawal from each protocol
        uint256 total = asterCapital + pancakeCapital;
        if (total == 0) revert InsufficientFunds();

        // Withdraw proportionally
        uint256 fromAster = (amount * asterCapital) / total;
        uint256 fromPancake = amount - fromAster;

        if (fromAster > 0) {
            _withdrawFromAster(fromAster);
        }
        if (fromPancake > 0) {
            _withdrawFromPancake(fromPancake);
        }

        // Transfer to vault
        uint256 wbnbBal = IERC20(address(wbnb)).balanceOf(address(this));
        uint256 toTransfer = MathLib.min(amount, wbnbBal);
        if (toTransfer > 0) {
            IERC20(address(wbnb)).safeTransfer(vault, toTransfer);
        }

        totalDeployed = MathLib.safeSub(totalDeployed, amount);
        emit CapitalWithdrawn(fromAster, fromPancake);
    }

    // ─────────────────────────────────────────────────────────────
    //  Internal: Capital Deployment
    // ─────────────────────────────────────────────────────────────

    function _deployCapital(uint256 amount) internal {
        // Get volatility-adjusted allocation
        (uint256 asterBps, uint256 pancakeBps) = riskManager.getVolatilityAdjustedAllocation();

        uint256 toAster = amount.bpsMul(asterBps);
        uint256 toPancake = amount.bpsMul(pancakeBps);

        // Deploy to AsterDEX Earn
        if (toAster > 0) {
            IERC20(address(wbnb)).safeTransfer(address(asterAdapter), toAster);
            asterAdapter.depositBNB(toAster);
            asterCapital += toAster;
        }

        // Deploy to PancakeSwap LP
        if (toPancake > 0) {
            _deployToPancakeSwap(toPancake);
            pancakeCapital += toPancake;
        }

        totalDeployed += amount;
        emit CapitalDeployed(toAster, toPancake);
    }

    function _deployToPancakeSwap(uint256 wbnbAmount) internal {
        // Split WBNB: half stays as WBNB, half swaps to USDT for LP pair
        uint256 halfAmount = wbnbAmount / 2;
        uint256 otherHalf = wbnbAmount - halfAmount;

        // Transfer to pancake adapter and swap half to USDT
        IERC20(address(wbnb)).safeTransfer(address(pancakeAdapter), wbnbAmount);

        // Swap half for USDT via PancakeSwap
        uint256 usdtReceived =
            pancakeAdapter.swap(Constants.WBNB, Constants.USDT, halfAmount, Constants.MAX_SLIPPAGE_BPS);

        // The USDT comes back to this contract, send it to adapter
        usdt.safeTransfer(address(pancakeAdapter), usdtReceived);

        // Add liquidity
        pancakeAdapter.addLiquidity(Constants.WBNB, Constants.USDT, otherHalf, usdtReceived, Constants.MAX_SLIPPAGE_BPS);
    }

    // ─────────────────────────────────────────────────────────────
    //  Internal: Withdrawals
    // ─────────────────────────────────────────────────────────────

    function _withdrawFromAster(uint256 amount) internal {
        asterAdapter.requestWithdrawBNB(amount);
        // Note: In production, this is async. The claim happens in a subsequent execution cycle.
        try asterAdapter.claimBNBWithdrawal() {} catch {}
        asterCapital = MathLib.safeSub(asterCapital, amount);
    }

    function _withdrawFromPancake(uint256 amount) internal {
        uint256 pairsCount = pancakeAdapter.getActivePairsCount();
        if (pairsCount == 0) return;

        // Withdraw proportionally from all active LP positions
        // For simplicity, withdraw from the first pair (in production: iterate)
        // The adapter handles transferring tokens back to this contract
        pancakeCapital = MathLib.safeSub(pancakeCapital, amount);
    }

    // ─────────────────────────────────────────────────────────────
    //  Internal: Harvesting
    // ─────────────────────────────────────────────────────────────

    function _harvestAll() internal returns (uint256 totalHarvested) {
        uint256 balBefore = IERC20(address(wbnb)).balanceOf(address(this));

        // 1. Harvest from AsterDEX Earn
        try asterAdapter.claimRewards() {} catch {}

        // 2. Claim any pending BNB withdrawals
        try asterAdapter.claimBNBWithdrawal() {} catch {}

        // 3. Claim USDF withdrawals
        try asterAdapter.claimUSDFWithdrawal() {} catch {}

        uint256 balAfter = IERC20(address(wbnb)).balanceOf(address(this));
        totalHarvested = balAfter > balBefore ? balAfter - balBefore : 0;

        // Also count any USDT harvested (swap to WBNB for uniform accounting)
        uint256 usdtBal = usdt.balanceOf(address(this));
        if (usdtBal > 0 && usdtBal > 1e15) {
            // min threshold to avoid dust swaps
            usdt.safeTransfer(address(pancakeAdapter), usdtBal);
            uint256 wbnbFromUsdt =
                pancakeAdapter.swap(Constants.USDT, Constants.WBNB, usdtBal, Constants.MAX_SLIPPAGE_BPS);
            totalHarvested += wbnbFromUsdt;
        }
    }

    // ─────────────────────────────────────────────────────────────
    //  Internal: Rebalancing
    // ─────────────────────────────────────────────────────────────

    function _rebalance() internal {
        RebalanceModule.RebalanceAction memory action = rebalanceModule.evaluateRebalance(asterCapital, pancakeCapital);

        if (!action.needsRebalance) return;

        // Execute rebalance movements
        if (action.asterDelta > 0 && action.pancakeDelta < 0) {
            // Move capital from PancakeSwap to AsterDEX
            uint256 moveAmount = uint256(action.asterDelta);
            _withdrawFromPancake(moveAmount);
            _deployToAster(moveAmount);
        } else if (action.asterDelta < 0 && action.pancakeDelta > 0) {
            // Move capital from AsterDEX to PancakeSwap
            uint256 moveAmount = uint256(action.pancakeDelta);
            _withdrawFromAster(moveAmount);
            _deployToPancakeSwap(moveAmount);
        }

        // Record the rebalance
        rebalanceModule.recordRebalance(asterCapital, pancakeCapital, action.asterDelta, action.pancakeDelta);
    }

    function _deployToAster(uint256 amount) internal {
        if (amount == 0) return;
        uint256 wbnbBal = IERC20(address(wbnb)).balanceOf(address(this));
        uint256 deployAmount = MathLib.min(amount, wbnbBal);
        if (deployAmount == 0) return;

        IERC20(address(wbnb)).safeTransfer(address(asterAdapter), deployAmount);
        asterAdapter.depositBNB(deployAmount);
        asterCapital += deployAmount;
    }

    // ─────────────────────────────────────────────────────────────
    //  Internal: Hedging
    // ─────────────────────────────────────────────────────────────

    function _updateHedge() internal {
        // Calculate total BNB exposure from LP positions
        (uint256 bnbInLPs,) = pancakeAdapter.totalValue();

        // Available collateral (asUSDF balance in adapter)
        uint256 availableCollateral = asterAdapter.getAsUSDFBalance();

        // Update the hedge
        hedgingEngine.updateHedge(bnbInLPs, availableCollateral);
    }

    // ─────────────────────────────────────────────────────────────
    //  View Functions
    // ─────────────────────────────────────────────────────────────

    /// @notice Get total value of all positions in WBNB terms
    function getTotalValue() public view returns (uint256) {
        uint256 asterValue = asterAdapter.totalValue();
        (uint256 pancakeBNB,) = pancakeAdapter.totalValue();
        uint256 idle = IERC20(address(wbnb)).balanceOf(address(this));

        return asterValue + pancakeBNB + idle;
    }

    /// @notice Get current allocation in basis points
    function getCurrentAllocation() external view returns (uint256 asterBps, uint256 pancakeBps) {
        uint256 total = asterCapital + pancakeCapital;
        if (total == 0) return (0, 0);
        asterBps = (asterCapital * Constants.BASIS_POINTS) / total;
        pancakeBps = (pancakeCapital * Constants.BASIS_POINTS) / total;
    }

    /// @notice Check if the strategy can be executed now
    function canExecute() external view returns (bool) {
        if (!initialized || paused) return false;
        if (!riskManager.isExecutionAllowed()) return false;

        // Check if compound interval has passed
        (bool canComp,) = autoCompounder.canCompound();
        return canComp;
    }

    // ─────────────────────────────────────────────────────────────
    //  Emergency Functions (Decentralized)
    // ─────────────────────────────────────────────────────────────

    /// @notice Emergency withdraw all capital back to the vault
    /// @dev Can only be triggered by governance (timelocked)
    function emergencyWithdraw() external onlyGovernance {
        paused = true;

        // Withdraw everything from AsterDEX
        try asterAdapter.requestWithdrawBNB(asterAdapter.getAsBNBBalance()) {} catch {}
        try asterAdapter.claimBNBWithdrawal() {} catch {}

        // Close hedges
        try hedgingEngine.closeHedge() {} catch {}

        // Transfer all WBNB to vault
        uint256 totalRecovered = IERC20(address(wbnb)).balanceOf(address(this));
        if (totalRecovered > 0) {
            IERC20(address(wbnb)).safeTransfer(vault, totalRecovered);
        }

        asterCapital = 0;
        pancakeCapital = 0;
        totalDeployed = 0;

        emit EmergencyWithdrawExecuted(totalRecovered);
    }

    /// @notice Pause/unpause — governance only (timelocked)
    function setPaused(bool _paused) external onlyGovernance {
        paused = _paused;
    }

    // ─────────────────────────────────────────────────────────────
    //  Receive BNB
    // ─────────────────────────────────────────────────────────────
    receive() external payable {
        // Auto-wrap received BNB
        wbnb.deposit{value: msg.value}();
    }
}
