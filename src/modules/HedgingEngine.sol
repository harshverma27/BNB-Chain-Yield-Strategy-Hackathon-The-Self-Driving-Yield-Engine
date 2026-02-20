// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Constants} from "../libraries/Constants.sol";
import {MathLib} from "../libraries/MathLib.sol";
import {RiskManager} from "../core/RiskManager.sol";

/// @title HedgingEngine - IL hedging using AsterDEX perpetual positions
/// @notice Calculates and maintains hedges against BNB exposure from LP positions
/// @dev Uses asUSDF as collateral (earning yield while hedging)
contract HedgingEngine is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MathLib for uint256;

    // ─────────────────────────────────────────────────────────────
    //  Errors
    // ─────────────────────────────────────────────────────────────
    error NotStrategyEngine();
    error HedgeTooLarge();
    error FundingRateTooExpensive();

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────
    event HedgeOpened(uint256 bnbExposure, uint256 hedgeSize, uint256 hedgeRatioBps);
    event HedgeAdjusted(uint256 oldSize, uint256 newSize);
    event HedgeClosed(uint256 hedgeSize, int256 pnl);
    event FundingRateChecked(int256 fundingRate, bool hedgeActive);

    // ─────────────────────────────────────────────────────────────
    //  Types
    // ─────────────────────────────────────────────────────────────
    struct HedgePosition {
        bool active;
        uint256 bnbExposure;       // Total BNB exposure from LPs
        uint256 hedgeSize;         // Size of short perp in BNB terms
        uint256 collateralUsed;    // asUSDF collateral used
        uint256 entryPrice;        // BNB price at hedge entry
        uint256 openTimestamp;
        uint256 hedgeRatioBps;     // Actual hedge ratio in bps
    }

    // ─────────────────────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────────────────────
    address public immutable strategyEngine;
    RiskManager public immutable riskManager;

    HedgePosition public currentHedge;

    // Configurable parameters (via timelock)
    uint256 public hedgeRatioBps;           // Target hedge ratio
    uint256 public maxFundingRateBps;       // Max acceptable funding rate
    uint256 public hedgeAdjustThresholdBps; // Min exposure change to trigger adjustment

    // Simulated PnL tracking (in production this reads from AsterDEX perp positions)
    int256 public cumulativePnL;

    // ─────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────
    constructor(address _strategyEngine, address _riskManager) {
        strategyEngine = _strategyEngine;
        riskManager = RiskManager(_riskManager);

        hedgeRatioBps = Constants.DEFAULT_HEDGE_RATIO_BPS;
        maxFundingRateBps = Constants.MAX_FUNDING_RATE_BPS;
        hedgeAdjustThresholdBps = 500; // Adjust when exposure changes by 5%
    }

    modifier onlyStrategyEngine() {
        if (msg.sender != strategyEngine) revert NotStrategyEngine();
        _;
    }

    // ─────────────────────────────────────────────────────────────
    //  Hedge Management
    // ─────────────────────────────────────────────────────────────

    /// @notice Open or adjust hedge based on current BNB exposure from LP positions
    /// @param bnbExposure Total BNB held in LP positions (in BNB, 18 decimals)
    /// @param availableCollateral Available asUSDF for collateral
    function updateHedge(
        uint256 bnbExposure,
        uint256 availableCollateral
    ) external onlyStrategyEngine nonReentrant {
        uint256 bnbPrice = riskManager.getBnbPrice();
        uint256 targetHedgeSize = bnbExposure.bpsMul(hedgeRatioBps);

        if (!currentHedge.active) {
            // Open new hedge
            if (targetHedgeSize > 0 && availableCollateral > 0) {
                _openHedge(targetHedgeSize, availableCollateral, bnbExposure, bnbPrice);
            }
        } else {
            // Check if adjustment needed
            uint256 exposureChange = MathLib.absDiff(bnbExposure, currentHedge.bnbExposure);
            uint256 changePercent = currentHedge.bnbExposure > 0
                ? (exposureChange * Constants.BASIS_POINTS) / currentHedge.bnbExposure
                : Constants.BASIS_POINTS;

            if (changePercent >= hedgeAdjustThresholdBps) {
                _adjustHedge(targetHedgeSize, bnbExposure, bnbPrice);
            }
        }
    }

    /// @notice Close the hedge entirely (when LP positions are removed)
    function closeHedge() external onlyStrategyEngine nonReentrant {
        if (!currentHedge.active) return;

        uint256 currentPrice = riskManager.getBnbPrice();
        int256 pnl = _calculateHedgePnL(currentPrice);
        cumulativePnL += pnl;

        emit HedgeClosed(currentHedge.hedgeSize, pnl);

        // Reset hedge
        delete currentHedge;
    }

    /// @notice Check funding rate and close hedge if too expensive
    /// @param currentFundingRateBps Current funding rate in bps (positive = longs pay shorts)
    function checkFundingRate(int256 currentFundingRateBps) external onlyStrategyEngine {
        // If funding is negative (shorts pay longs) and exceeds our threshold, close
        if (currentFundingRateBps < 0 && uint256(-currentFundingRateBps) > maxFundingRateBps) {
            if (currentHedge.active) {
                uint256 currentPrice = riskManager.getBnbPrice();
                int256 pnl = _calculateHedgePnL(currentPrice);
                cumulativePnL += pnl;

                emit HedgeClosed(currentHedge.hedgeSize, pnl);
                delete currentHedge;
            }
        }

        emit FundingRateChecked(currentFundingRateBps, currentHedge.active);
    }

    // ─────────────────────────────────────────────────────────────
    //  Internal Hedge Logic
    // ─────────────────────────────────────────────────────────────

    function _openHedge(
        uint256 hedgeSize,
        uint256 collateral,
        uint256 bnbExposure,
        uint256 entryPrice
    ) internal {
        currentHedge = HedgePosition({
            active: true,
            bnbExposure: bnbExposure,
            hedgeSize: hedgeSize,
            collateralUsed: collateral,
            entryPrice: entryPrice,
            openTimestamp: block.timestamp,
            hedgeRatioBps: hedgeRatioBps
        });

        emit HedgeOpened(bnbExposure, hedgeSize, hedgeRatioBps);
    }

    function _adjustHedge(
        uint256 newHedgeSize,
        uint256 newBnbExposure,
        uint256 currentPrice
    ) internal {
        uint256 oldSize = currentHedge.hedgeSize;

        // Settle PnL from old position
        int256 pnl = _calculateHedgePnL(currentPrice);
        cumulativePnL += pnl;

        // Update hedge
        currentHedge.hedgeSize = newHedgeSize;
        currentHedge.bnbExposure = newBnbExposure;
        currentHedge.entryPrice = currentPrice;

        emit HedgeAdjusted(oldSize, newHedgeSize);
    }

    /// @notice Calculate PnL of the short hedge
    /// @dev Short PnL = size * (entryPrice - currentPrice) / entryPrice
    function _calculateHedgePnL(uint256 currentPrice) internal view returns (int256) {
        if (!currentHedge.active || currentHedge.entryPrice == 0) return 0;

        if (currentPrice <= currentHedge.entryPrice) {
            // Price went down — short is profitable
            uint256 profit = (currentHedge.hedgeSize * (currentHedge.entryPrice - currentPrice))
                / currentHedge.entryPrice;
            return int256(profit);
        } else {
            // Price went up — short is at loss
            uint256 loss = (currentHedge.hedgeSize * (currentPrice - currentHedge.entryPrice))
                / currentHedge.entryPrice;
            return -int256(loss);
        }
    }

    // ─────────────────────────────────────────────────────────────
    //  View Functions
    // ─────────────────────────────────────────────────────────────

    /// @notice Get current hedge PnL
    function getCurrentPnL() external view returns (int256) {
        if (!currentHedge.active) return 0;
        return _calculateHedgePnL(riskManager.getBnbPrice());
    }

    /// @notice Get recommended hedge ratio based on volatility
    function getRecommendedHedgeRatio() external view returns (uint256) {
        RiskManager.VolatilityState vol = riskManager.currentVolatility();

        if (vol == RiskManager.VolatilityState.LOW) {
            return hedgeRatioBps / 2; // Light hedge in calm markets
        } else if (vol == RiskManager.VolatilityState.MEDIUM) {
            return hedgeRatioBps; // Standard hedge
        } else if (vol == RiskManager.VolatilityState.HIGH) {
            return MathLib.min(hedgeRatioBps * 3 / 2, Constants.BASIS_POINTS); // Enhanced hedge
        } else {
            return Constants.BASIS_POINTS; // Full hedge in extreme
        }
    }

    /// @notice Check if hedge is active
    function isHedgeActive() external view returns (bool) {
        return currentHedge.active;
    }

    /// @notice Get hedge details
    function getHedgeDetails() external view returns (HedgePosition memory) {
        return currentHedge;
    }

    // ─────────────────────────────────────────────────────────────
    //  Governance
    // ─────────────────────────────────────────────────────────────

    function updateHedgeParams(
        uint256 _hedgeRatioBps,
        uint256 _maxFundingRateBps,
        uint256 _adjustThresholdBps
    ) external onlyStrategyEngine {
        require(_hedgeRatioBps <= Constants.BASIS_POINTS, "Hedge ratio too high");
        hedgeRatioBps = _hedgeRatioBps;
        maxFundingRateBps = _maxFundingRateBps;
        hedgeAdjustThresholdBps = _adjustThresholdBps;
    }
}
