// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Constants} from "../libraries/Constants.sol";
import {MathLib} from "../libraries/MathLib.sol";
import {RiskManager} from "../core/RiskManager.sol";

/// @title RebalanceModule - Autonomous portfolio rebalancing logic
/// @notice Monitors allocation drift and triggers rebalancing between protocols
/// @dev Pure logic module — no token handling, just decision-making
contract RebalanceModule {
    using MathLib for uint256;

    // ─────────────────────────────────────────────────────────────
    //  Errors
    // ─────────────────────────────────────────────────────────────
    error NotStrategyEngine();
    error RebalanceTooFrequent();

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────
    event RebalanceTriggered(
        uint256 asterValue,
        uint256 pancakeValue,
        uint256 targetAsterBps,
        uint256 targetPancakeBps,
        int256 asterDelta,
        int256 pancakeDelta
    );
    event AllocationTargetsUpdated(uint256 asterBps, uint256 pancakeBps);

    // ─────────────────────────────────────────────────────────────
    //  Types
    // ─────────────────────────────────────────────────────────────
    struct RebalanceAction {
        bool needsRebalance;
        int256 asterDelta;     // Positive = add to Aster, Negative = remove from Aster
        int256 pancakeDelta;   // Positive = add to PancakeSwap, Negative = remove
        uint256 urgency;       // 0-10 how urgent the rebalance is
    }

    // ─────────────────────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────────────────────
    address public immutable strategyEngine;
    RiskManager public immutable riskManager;

    // Allocation targets (in bps, must sum to 10000)
    uint256 public targetAsterBps;
    uint256 public targetPancakeBps;

    // Rebalancing parameters
    uint256 public rebalanceThresholdBps;
    uint256 public lastRebalanceTimestamp;
    uint256 public minRebalanceInterval;
    uint256 public maxRebalanceInterval;

    // Tracking
    uint256 public totalRebalances;

    // ─────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────
    constructor(address _strategyEngine, address _riskManager) {
        strategyEngine = _strategyEngine;
        riskManager = RiskManager(_riskManager);

        targetAsterBps = Constants.DEFAULT_ASTER_ALLOCATION_BPS;
        targetPancakeBps = Constants.DEFAULT_PANCAKE_ALLOCATION_BPS;
        rebalanceThresholdBps = Constants.DEFAULT_REBALANCE_THRESHOLD_BPS;
        minRebalanceInterval = Constants.MIN_REBALANCE_INTERVAL;
        maxRebalanceInterval = Constants.MAX_REBALANCE_INTERVAL;
    }

    modifier onlyStrategyEngine() {
        if (msg.sender != strategyEngine) revert NotStrategyEngine();
        _;
    }

    // ─────────────────────────────────────────────────────────────
    //  Rebalance Logic
    // ─────────────────────────────────────────────────────────────

    /// @notice Evaluate whether rebalancing is needed and compute deltas
    /// @param asterValue Current value in AsterDEX Earn (in USD, 18 decimals)
    /// @param pancakeValue Current value in PancakeSwap LPs (in USD, 18 decimals)
    /// @return action The rebalancing action to take
    function evaluateRebalance(
        uint256 asterValue,
        uint256 pancakeValue
    ) external view returns (RebalanceAction memory action) {
        uint256 totalValue = asterValue + pancakeValue;
        if (totalValue == 0) return action;

        // Get volatility-adjusted targets
        (uint256 adjAsterBps, uint256 adjPancakeBps) = riskManager.getVolatilityAdjustedAllocation();

        // Current allocations in bps
        uint256 currentAsterBps = (asterValue * Constants.BASIS_POINTS) / totalValue;
        uint256 currentPancakeBps = (pancakeValue * Constants.BASIS_POINTS) / totalValue;

        // Calculate drift
        uint256 asterDrift = MathLib.absDiff(currentAsterBps, adjAsterBps);
        uint256 pancakeDrift = MathLib.absDiff(currentPancakeBps, adjPancakeBps);
        uint256 maxDrift = MathLib.max(asterDrift, pancakeDrift);

        // Check if time-based or drift-based rebalance needed
        bool timeBased = block.timestamp >= lastRebalanceTimestamp + maxRebalanceInterval;
        bool driftBased = maxDrift >= rebalanceThresholdBps;

        if (!timeBased && !driftBased) return action;

        // Ensure minimum interval
        if (block.timestamp < lastRebalanceTimestamp + minRebalanceInterval && !timeBased) {
            return action;
        }

        action.needsRebalance = true;

        // Calculate target values
        uint256 targetAsterValue = totalValue.bpsMul(adjAsterBps);
        uint256 targetPancakeValue = totalValue.bpsMul(adjPancakeBps);

        // Calculate deltas
        if (asterValue >= targetAsterValue) {
            action.asterDelta = -int256(asterValue - targetAsterValue);
        } else {
            action.asterDelta = int256(targetAsterValue - asterValue);
        }

        if (pancakeValue >= targetPancakeValue) {
            action.pancakeDelta = -int256(pancakeValue - targetPancakeValue);
        } else {
            action.pancakeDelta = int256(targetPancakeValue - pancakeValue);
        }

        // Urgency based on drift magnitude
        action.urgency = MathLib.min(maxDrift / 100, 10);
    }

    /// @notice Record that a rebalance was executed
    function recordRebalance(
        uint256 asterValue,
        uint256 pancakeValue,
        int256 asterDelta,
        int256 pancakeDelta
    ) external onlyStrategyEngine {
        (uint256 adjAsterBps, uint256 adjPancakeBps) = riskManager.getVolatilityAdjustedAllocation();

        lastRebalanceTimestamp = block.timestamp;
        totalRebalances++;

        emit RebalanceTriggered(
            asterValue,
            pancakeValue,
            adjAsterBps,
            adjPancakeBps,
            asterDelta,
            pancakeDelta
        );
    }

    // ─────────────────────────────────────────────────────────────
    //  View Functions
    // ─────────────────────────────────────────────────────────────

    /// @notice Get time until next allowed rebalance
    function timeUntilNextRebalance() external view returns (uint256) {
        if (lastRebalanceTimestamp == 0) return 0;
        uint256 nextAllowed = lastRebalanceTimestamp + minRebalanceInterval;
        if (block.timestamp >= nextAllowed) return 0;
        return nextAllowed - block.timestamp;
    }

    /// @notice Check if rebalance is overdue (past max interval)
    function isRebalanceOverdue() external view returns (bool) {
        if (lastRebalanceTimestamp == 0) return true;
        return block.timestamp >= lastRebalanceTimestamp + maxRebalanceInterval;
    }

    // ─────────────────────────────────────────────────────────────
    //  Governance
    // ─────────────────────────────────────────────────────────────

    function updateRebalanceParams(
        uint256 _thresholdBps,
        uint256 _minInterval,
        uint256 _maxInterval
    ) external onlyStrategyEngine {
        require(_thresholdBps >= 100 && _thresholdBps <= 2_000, "Invalid threshold");
        require(_minInterval >= 15 minutes, "Interval too short");
        require(_maxInterval >= _minInterval, "Max must exceed min");

        rebalanceThresholdBps = _thresholdBps;
        minRebalanceInterval = _minInterval;
        maxRebalanceInterval = _maxInterval;
    }

    function updateAllocationTargets(
        uint256 _asterBps,
        uint256 _pancakeBps
    ) external onlyStrategyEngine {
        require(_asterBps + _pancakeBps == Constants.BASIS_POINTS, "Must sum to 10000");
        targetAsterBps = _asterBps;
        targetPancakeBps = _pancakeBps;

        emit AllocationTargetsUpdated(_asterBps, _pancakeBps);
    }
}
