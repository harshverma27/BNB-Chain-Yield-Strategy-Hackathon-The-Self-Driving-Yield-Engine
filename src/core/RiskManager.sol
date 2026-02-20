// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IChainlinkOracle} from "../interfaces/IChainlinkOracle.sol";
import {Constants} from "../libraries/Constants.sol";
import {MathLib} from "../libraries/MathLib.sol";

/// @title RiskManager - Circuit breakers, oracle validation, and exposure limits
/// @notice Protects the protocol from adverse market conditions without admin intervention
/// @dev All risk parameters are immutable or governed by timelock — no admin keys
contract RiskManager {
    using MathLib for uint256;

    // ─────────────────────────────────────────────────────────────
    //  Errors
    // ─────────────────────────────────────────────────────────────
    error OracleStale(address oracle, uint256 lastUpdate);
    error OracleInvalidPrice(address oracle, int256 price);
    error CircuitBreakerTriggered(uint256 drawdown);
    error SlippageTooHigh(uint256 slippage, uint256 maxSlippage);
    error AllocationExceedsLimit(uint256 allocation, uint256 limit);
    error NotAuthorized();

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────
    event CircuitBreakerActivated(uint256 timestamp, uint256 drawdownBps);
    event CircuitBreakerReset(uint256 timestamp);
    event HighWaterMarkUpdated(uint256 newHighWaterMark);
    event VolatilityStateChanged(VolatilityState newState);

    // ─────────────────────────────────────────────────────────────
    //  Types
    // ─────────────────────────────────────────────────────────────
    enum VolatilityState {
        LOW,       // Normal operations, full LP exposure
        MEDIUM,    // Reduced LP, increased hedging
        HIGH,      // Minimal LP, shift to stables
        EXTREME    // Emergency: pause new deployments
    }

    // ─────────────────────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────────────────────
    address public immutable strategyEngine;

    // Oracle references
    IChainlinkOracle public immutable bnbOracle;
    IChainlinkOracle public immutable usdtOracle;

    // Circuit breaker state
    bool public circuitBreakerActive;
    uint256 public circuitBreakerTimestamp;
    uint256 public highWaterMark;
    uint256 public lastTotalValue;
    uint256 public lastCheckTimestamp;

    // Volatility tracking
    VolatilityState public currentVolatility;
    uint256 public lastBnbPrice;
    uint256 public priceChangeAccumulator; // Tracks recent price changes
    uint256 public volatilityWindow = 1 hours;
    uint256 public lastVolatilityCheck;

    // Risk parameters (settable via timelock)
    uint256 public maxDrawdownBps;
    uint256 public maxSlippageBps;
    uint256 public maxSingleProtocolBps; // Max % in any one protocol
    uint256 public oracleStalenessPeriod;
    uint256 public circuitBreakerCooldown;

    // ─────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────
    constructor(address _strategyEngine) {
        strategyEngine = _strategyEngine;
        bnbOracle = IChainlinkOracle(Constants.CHAINLINK_BNB_USD);
        usdtOracle = IChainlinkOracle(Constants.CHAINLINK_USDT_USD);

        maxDrawdownBps = Constants.MAX_DRAWDOWN_BPS;
        maxSlippageBps = Constants.MAX_SLIPPAGE_BPS;
        maxSingleProtocolBps = 8_000; // 80% max in one protocol
        oracleStalenessPeriod = Constants.ORACLE_STALENESS_THRESHOLD;
        circuitBreakerCooldown = 6 hours;

        currentVolatility = VolatilityState.LOW;
    }

    modifier onlyStrategyEngine() {
        if (msg.sender != strategyEngine) revert NotAuthorized();
        _;
    }

    // ─────────────────────────────────────────────────────────────
    //  Oracle Functions
    // ─────────────────────────────────────────────────────────────

    /// @notice Get validated BNB/USD price
    /// @return price BNB price in USD with 8 decimals
    function getBnbPrice() public view returns (uint256 price) {
        return _getValidatedPrice(bnbOracle);
    }

    /// @notice Get validated USDT/USD price
    /// @return price USDT price in USD with 8 decimals
    function getUsdtPrice() public view returns (uint256 price) {
        return _getValidatedPrice(usdtOracle);
    }

    function _getValidatedPrice(IChainlinkOracle oracle) internal view returns (uint256) {
        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = oracle.latestRoundData();

        // Staleness check
        if (block.timestamp - updatedAt > oracleStalenessPeriod) {
            revert OracleStale(address(oracle), updatedAt);
        }

        // Sanity checks
        if (answer <= 0) {
            revert OracleInvalidPrice(address(oracle), answer);
        }

        // Round completeness check
        if (answeredInRound < roundId) {
            revert OracleStale(address(oracle), updatedAt);
        }

        return uint256(answer);
    }

    // ─────────────────────────────────────────────────────────────
    //  Circuit Breaker
    // ─────────────────────────────────────────────────────────────

    /// @notice Check drawdown and trigger circuit breaker if needed
    /// @param currentTotalValue The current total value of all positions
    function checkDrawdown(uint256 currentTotalValue) external onlyStrategyEngine {
        // Update high water mark
        if (currentTotalValue > highWaterMark) {
            highWaterMark = currentTotalValue;
            emit HighWaterMarkUpdated(currentTotalValue);
        }

        // Calculate drawdown from high water mark
        if (highWaterMark > 0 && currentTotalValue < highWaterMark) {
            uint256 drawdown = ((highWaterMark - currentTotalValue) * Constants.BASIS_POINTS) / highWaterMark;

            if (drawdown >= maxDrawdownBps) {
                circuitBreakerActive = true;
                circuitBreakerTimestamp = block.timestamp;
                emit CircuitBreakerActivated(block.timestamp, drawdown);
                revert CircuitBreakerTriggered(drawdown);
            }
        }

        lastTotalValue = currentTotalValue;
        lastCheckTimestamp = block.timestamp;
    }

    /// @notice Auto-reset circuit breaker after cooldown if value has recovered
    function tryResetCircuitBreaker(uint256 currentTotalValue) external onlyStrategyEngine {
        if (!circuitBreakerActive) return;

        // Must wait for cooldown period
        if (block.timestamp < circuitBreakerTimestamp + circuitBreakerCooldown) return;

        // Value must have recovered to at least 95% of high water mark
        uint256 recoveryThreshold = (highWaterMark * 9_500) / Constants.BASIS_POINTS;
        if (currentTotalValue >= recoveryThreshold) {
            circuitBreakerActive = false;
            emit CircuitBreakerReset(block.timestamp);
        }
    }

    // ─────────────────────────────────────────────────────────────
    //  Volatility Assessment
    // ─────────────────────────────────────────────────────────────

    /// @notice Update volatility state based on price movements
    function updateVolatility() external {
        uint256 currentPrice = getBnbPrice();

        if (lastBnbPrice > 0) {
            uint256 change = MathLib.absDiff(currentPrice, lastBnbPrice);
            uint256 changeBps = (change * Constants.BASIS_POINTS) / lastBnbPrice;

            // Accumulate volatility (decay old readings)
            if (block.timestamp > lastVolatilityCheck + volatilityWindow) {
                priceChangeAccumulator = changeBps;
            } else {
                priceChangeAccumulator = (priceChangeAccumulator + changeBps) / 2;
            }

            // Classify volatility
            VolatilityState newState;
            if (priceChangeAccumulator < 200) {       // < 2%
                newState = VolatilityState.LOW;
            } else if (priceChangeAccumulator < 500) { // 2-5%
                newState = VolatilityState.MEDIUM;
            } else if (priceChangeAccumulator < 1000) { // 5-10%
                newState = VolatilityState.HIGH;
            } else {                                     // > 10%
                newState = VolatilityState.EXTREME;
            }

            if (newState != currentVolatility) {
                currentVolatility = newState;
                emit VolatilityStateChanged(newState);
            }
        }

        lastBnbPrice = currentPrice;
        lastVolatilityCheck = block.timestamp;
    }

    // ─────────────────────────────────────────────────────────────
    //  Validation Helpers
    // ─────────────────────────────────────────────────────────────

    /// @notice Validate slippage is within bounds
    function validateSlippage(uint256 expected, uint256 actual) external view {
        if (expected == 0) return;
        if (actual < expected) {
            uint256 slippage = ((expected - actual) * Constants.BASIS_POINTS) / expected;
            if (slippage > maxSlippageBps) {
                revert SlippageTooHigh(slippage, maxSlippageBps);
            }
        }
    }

    /// @notice Validate protocol allocation doesn't exceed limits
    function validateAllocation(uint256 protocolValue, uint256 totalValue) external view {
        if (totalValue == 0) return;
        uint256 allocationBps = (protocolValue * Constants.BASIS_POINTS) / totalValue;
        if (allocationBps > maxSingleProtocolBps) {
            revert AllocationExceedsLimit(allocationBps, maxSingleProtocolBps);
        }
    }

    /// @notice Get recommended allocation adjustments based on volatility
    /// @return asterBps Recommended AsterDEX allocation in bps
    /// @return pancakeBps Recommended PancakeSwap allocation in bps
    function getVolatilityAdjustedAllocation()
        external
        view
        returns (uint256 asterBps, uint256 pancakeBps)
    {
        if (currentVolatility == VolatilityState.LOW) {
            // Normal: 70/30 split
            return (7_000, 3_000);
        } else if (currentVolatility == VolatilityState.MEDIUM) {
            // Shift towards safer Aster Earn: 80/20
            return (8_000, 2_000);
        } else if (currentVolatility == VolatilityState.HIGH) {
            // Mostly in Aster Earn: 90/10
            return (9_000, 1_000);
        } else {
            // Extreme: all into Aster Earn (safest)
            return (10_000, 0);
        }
    }

    /// @notice Check if strategy execution is allowed
    function isExecutionAllowed() external view returns (bool) {
        if (circuitBreakerActive) return false;
        if (currentVolatility == VolatilityState.EXTREME) return false;
        return true;
    }

    // ─────────────────────────────────────────────────────────────
    //  Governance (via timelock only)
    // ─────────────────────────────────────────────────────────────

    /// @notice Update risk parameters — can only be called by the strategy engine (which is timelocked)
    function updateRiskParams(
        uint256 _maxDrawdownBps,
        uint256 _maxSlippageBps,
        uint256 _maxSingleProtocolBps,
        uint256 _oracleStalenessPeriod
    ) external onlyStrategyEngine {
        require(_maxDrawdownBps > 0 && _maxDrawdownBps <= 5_000, "Invalid drawdown");
        require(_maxSlippageBps > 0 && _maxSlippageBps <= 500, "Invalid slippage");
        require(_maxSingleProtocolBps >= 5_000 && _maxSingleProtocolBps <= 10_000, "Invalid allocation");

        maxDrawdownBps = _maxDrawdownBps;
        maxSlippageBps = _maxSlippageBps;
        maxSingleProtocolBps = _maxSingleProtocolBps;
        oracleStalenessPeriod = _oracleStalenessPeriod;
    }
}
