// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Constants} from "../libraries/Constants.sol";
import {MathLib} from "../libraries/MathLib.sol";

/// @title AutoCompounder - Permissionless reward harvesting and compounding
/// @notice Harvests rewards from all sources and re-deploys into optimal strategies
/// @dev Anyone can call compound() and earn a gas bounty — no keeper infrastructure needed
contract AutoCompounder is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MathLib for uint256;

    // ─────────────────────────────────────────────────────────────
    //  Errors
    // ─────────────────────────────────────────────────────────────
    error NotStrategyEngine();
    error CompoundTooSoon();
    error NothingToCompound();

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────
    event Compounded(
        address indexed caller,
        uint256 totalHarvested,
        uint256 keeperBounty,
        uint256 compoundedAmount,
        uint256 timestamp
    );
    event CompoundIntervalUpdated(uint256 newInterval);

    // ─────────────────────────────────────────────────────────────
    //  Types
    // ─────────────────────────────────────────────────────────────
    struct CompoundRecord {
        uint256 timestamp;
        uint256 harvested;
        uint256 compounded;
        uint256 bountyPaid;
        address caller;
    }

    // ─────────────────────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────────────────────
    address public immutable strategyEngine;

    // Compounding parameters
    uint256 public compoundInterval;
    uint256 public keeperBountyBps;
    uint256 public lastCompoundTimestamp;

    // Statistics
    uint256 public totalCompounded;
    uint256 public totalBountyPaid;
    uint256 public compoundCount;

    // History (ring buffer of last 100 compounds)
    CompoundRecord[100] public compoundHistory;
    uint256 public historyIndex;

    // ─────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────
    constructor(address _strategyEngine) {
        strategyEngine = _strategyEngine;
        compoundInterval = Constants.MIN_COMPOUND_INTERVAL;
        keeperBountyBps = Constants.KEEPER_BOUNTY_BPS;
    }

    modifier onlyStrategyEngine() {
        if (msg.sender != strategyEngine) revert NotStrategyEngine();
        _;
    }

    // ─────────────────────────────────────────────────────────────
    //  Compounding Logic
    // ─────────────────────────────────────────────────────────────

    /// @notice Check if compounding can be executed
    /// @return canCompound_ Whether the interval requirement is met
    /// @return timeSinceLastCompound Seconds since last compound
    function canCompound() external view returns (bool canCompound_, uint256 timeSinceLastCompound) {
        timeSinceLastCompound = block.timestamp - lastCompoundTimestamp;
        canCompound_ = timeSinceLastCompound >= compoundInterval;
    }

    /// @notice Record a compound event (called by strategy engine after execution)
    /// @param caller The address that triggered the compound
    /// @param harvested Total rewards harvested (in base asset terms)
    /// @param bounty Bounty paid to the caller
    function recordCompound(
        address caller,
        uint256 harvested,
        uint256 bounty
    ) external onlyStrategyEngine {
        if (block.timestamp < lastCompoundTimestamp + compoundInterval) {
            revert CompoundTooSoon();
        }

        lastCompoundTimestamp = block.timestamp;
        uint256 compounded = harvested - bounty;

        totalCompounded += compounded;
        totalBountyPaid += bounty;
        compoundCount++;

        // Store in history
        compoundHistory[historyIndex] = CompoundRecord({
            timestamp: block.timestamp,
            harvested: harvested,
            compounded: compounded,
            bountyPaid: bounty,
            caller: caller
        });
        historyIndex = (historyIndex + 1) % 100;

        emit Compounded(caller, harvested, bounty, compounded, block.timestamp);
    }

    /// @notice Calculate the bounty for a given harvest amount
    function calculateBounty(uint256 harvestedAmount) external view returns (uint256) {
        return harvestedAmount.bpsMul(keeperBountyBps);
    }

    // ─────────────────────────────────────────────────────────────
    //  View Functions
    // ─────────────────────────────────────────────────────────────

    /// @notice Get the effective APY from compounding (annualized)
    function getCompoundingAPY() external view returns (uint256) {
        if (compoundCount < 2) return 0;

        // Use recent compound history to estimate
        uint256 recentIndex = historyIndex > 0 ? historyIndex - 1 : 99;
        CompoundRecord memory recent = compoundHistory[recentIndex];
        if (recent.timestamp == 0) return 0;

        // Extrapolate annual based on recent compound rate
        // This is a simplified calculation
        uint256 periodsPerYear = 365 days / compoundInterval;
        return recent.compounded * periodsPerYear;
    }

    /// @notice Get recent compound history
    function getRecentCompounds(uint256 count) external view returns (CompoundRecord[] memory) {
        uint256 actualCount = MathLib.min(count, compoundCount);
        actualCount = MathLib.min(actualCount, 100);

        CompoundRecord[] memory records = new CompoundRecord[](actualCount);
        for (uint256 i = 0; i < actualCount; i++) {
            uint256 idx = historyIndex > i ? historyIndex - 1 - i : 100 - 1 - (i - historyIndex);
            records[i] = compoundHistory[idx % 100];
        }
        return records;
    }

    // ─────────────────────────────────────────────────────────────
    //  Governance
    // ─────────────────────────────────────────────────────────────

    function updateCompoundParams(
        uint256 _interval,
        uint256 _bountyBps
    ) external onlyStrategyEngine {
        require(_interval >= 10 minutes, "Interval too short");
        require(_bountyBps <= 500, "Bounty too high"); // Max 5%
        compoundInterval = _interval;
        keeperBountyBps = _bountyBps;

        emit CompoundIntervalUpdated(_interval);
    }
}
