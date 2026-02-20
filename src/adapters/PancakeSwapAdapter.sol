// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPancakeRouterV2, IPancakeFactoryV2, IPancakePairV2, IWBNB} from "../interfaces/IPancakeSwap.sol";
import {Constants} from "../libraries/Constants.sol";
import {MathLib} from "../libraries/MathLib.sol";

/// @title PancakeSwapAdapter - Integration layer for PancakeSwap V2 LP and farming
/// @notice Manages LP positions, liquidity provision, and reward harvesting
/// @dev Permissionless execution, called only by StrategyEngine
contract PancakeSwapAdapter is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MathLib for uint256;

    // ─────────────────────────────────────────────────────────────
    //  Errors
    // ─────────────────────────────────────────────────────────────
    error NotStrategyEngine();
    error ZeroAmount();
    error PairNotFound();
    error InsufficientLiquidity();

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────
    event LiquidityAdded(address tokenA, address tokenB, uint256 amountA, uint256 amountB, uint256 lpReceived);
    event LiquidityRemoved(address tokenA, address tokenB, uint256 lpAmount, uint256 amountA, uint256 amountB);
    event TokensSwapped(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);

    // ─────────────────────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────────────────────
    address public immutable strategyEngine;
    IPancakeRouterV2 public immutable router;
    IPancakeFactoryV2 public immutable factory;
    IWBNB public immutable wbnb;

    // Track LP positions
    struct LPPosition {
        address pair;
        address tokenA;
        address tokenB;
        uint256 lpBalance;
        uint256 initialPriceRatio; // tokenA/tokenB at entry (WAD)
        uint256 entryTimestamp;
    }

    mapping(address => LPPosition) public lpPositions; // pair => position
    address[] public activePairs;

    // ─────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────
    constructor(address _strategyEngine) {
        strategyEngine = _strategyEngine;
        router = IPancakeRouterV2(Constants.PANCAKE_V2_ROUTER);
        factory = IPancakeFactoryV2(Constants.PANCAKE_V2_FACTORY);
        wbnb = IWBNB(Constants.WBNB);
    }

    modifier onlyStrategyEngine() {
        if (msg.sender != strategyEngine) revert NotStrategyEngine();
        _;
    }

    // ─────────────────────────────────────────────────────────────
    //  Liquidity Operations
    // ─────────────────────────────────────────────────────────────

    /// @notice Add liquidity to a PancakeSwap V2 pair
    /// @param tokenA First token address
    /// @param tokenB Second token address
    /// @param amountA Desired amount of tokenA
    /// @param amountB Desired amount of tokenB
    /// @param slippageBps Slippage tolerance in basis points
    /// @return lpReceived Amount of LP tokens received
    function addLiquidity(address tokenA, address tokenB, uint256 amountA, uint256 amountB, uint256 slippageBps)
        external
        onlyStrategyEngine
        nonReentrant
        returns (uint256 lpReceived)
    {
        if (amountA == 0 || amountB == 0) revert ZeroAmount();

        address pair = factory.getPair(tokenA, tokenB);
        if (pair == address(0)) revert PairNotFound();

        // Calculate minimums with slippage
        uint256 amountAMin = amountA - amountA.bpsMul(slippageBps);
        uint256 amountBMin = amountB - amountB.bpsMul(slippageBps);

        // Approve tokens
        IERC20(tokenA).approve(address(router), amountA);
        IERC20(tokenB).approve(address(router), amountB);

        // Add liquidity
        (uint256 actualA, uint256 actualB, uint256 liquidity) = router.addLiquidity(
            tokenA, tokenB, amountA, amountB, amountAMin, amountBMin, address(this), block.timestamp + 300
        );

        // Track position
        if (lpPositions[pair].lpBalance == 0) {
            activePairs.push(pair);
        }

        lpPositions[pair] = LPPosition({
            pair: pair,
            tokenA: tokenA,
            tokenB: tokenB,
            lpBalance: lpPositions[pair].lpBalance + liquidity,
            initialPriceRatio: _getCurrentPriceRatio(pair),
            entryTimestamp: block.timestamp
        });

        // Return any unused tokens
        uint256 unusedA = amountA - actualA;
        uint256 unusedB = amountB - actualB;
        if (unusedA > 0) IERC20(tokenA).safeTransfer(strategyEngine, unusedA);
        if (unusedB > 0) IERC20(tokenB).safeTransfer(strategyEngine, unusedB);

        emit LiquidityAdded(tokenA, tokenB, actualA, actualB, liquidity);
        return liquidity;
    }

    /// @notice Remove liquidity from a PancakeSwap V2 pair
    /// @param pair LP pair address
    /// @param lpAmount Amount of LP to remove
    /// @param slippageBps Slippage tolerance in bps
    function removeLiquidity(address pair, uint256 lpAmount, uint256 slippageBps)
        external
        onlyStrategyEngine
        nonReentrant
        returns (uint256 amountA, uint256 amountB)
    {
        LPPosition storage pos = lpPositions[pair];
        if (pos.lpBalance < lpAmount) revert InsufficientLiquidity();

        // Get expected amounts
        (uint112 reserveA, uint112 reserveB,) = IPancakePairV2(pair).getReserves();
        uint256 totalSupply = IPancakePairV2(pair).totalSupply();
        uint256 expectedA = (uint256(reserveA) * lpAmount) / totalSupply;
        uint256 expectedB = (uint256(reserveB) * lpAmount) / totalSupply;

        uint256 minA = expectedA - expectedA.bpsMul(slippageBps);
        uint256 minB = expectedB - expectedB.bpsMul(slippageBps);

        // Approve LP tokens
        IPancakePairV2(pair).approve(address(router), lpAmount);

        // Remove liquidity
        (amountA, amountB) =
            router.removeLiquidity(pos.tokenA, pos.tokenB, lpAmount, minA, minB, address(this), block.timestamp + 300);

        // Update position
        pos.lpBalance -= lpAmount;

        // Remove from active pairs if fully withdrawn
        if (pos.lpBalance == 0) {
            _removeActivePair(pair);
        }

        // Transfer tokens to strategy engine
        IERC20(pos.tokenA).safeTransfer(strategyEngine, amountA);
        IERC20(pos.tokenB).safeTransfer(strategyEngine, amountB);

        emit LiquidityRemoved(pos.tokenA, pos.tokenB, lpAmount, amountA, amountB);
    }

    // ─────────────────────────────────────────────────────────────
    //  Swap Operations
    // ─────────────────────────────────────────────────────────────

    /// @notice Swap tokens via PancakeSwap V2 with slippage protection
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 slippageBps)
        external
        onlyStrategyEngine
        nonReentrant
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert ZeroAmount();

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        // Get expected output
        uint256[] memory amountsOut = router.getAmountsOut(amountIn, path);
        uint256 expectedOut = amountsOut[amountsOut.length - 1];
        uint256 minOut = expectedOut - expectedOut.bpsMul(slippageBps);

        // Approve and swap
        IERC20(tokenIn).approve(address(router), amountIn);
        uint256[] memory amounts =
            router.swapExactTokensForTokens(amountIn, minOut, path, strategyEngine, block.timestamp + 300);

        amountOut = amounts[amounts.length - 1];
        emit TokensSwapped(tokenIn, tokenOut, amountIn, amountOut);
    }

    // ─────────────────────────────────────────────────────────────
    //  IL Calculation
    // ─────────────────────────────────────────────────────────────

    /// @notice Calculate current impermanent loss for a position
    /// @param pair LP pair address
    /// @return ilBps IL in basis points
    function calculateIL(address pair) external view returns (uint256 ilBps) {
        LPPosition memory pos = lpPositions[pair];
        if (pos.lpBalance == 0) return 0;

        uint256 currentRatio = _getCurrentPriceRatio(pair);
        if (pos.initialPriceRatio == 0) return 0;

        // Price ratio change
        uint256 priceRatio = MathLib.wadDiv(currentRatio, pos.initialPriceRatio);

        // Calculate IL using the formula
        uint256 ilWad = MathLib.calculateIL(priceRatio);

        // Convert to bps
        ilBps = (ilWad * Constants.BASIS_POINTS) / MathLib.WAD;
    }

    // ─────────────────────────────────────────────────────────────
    //  View Functions
    // ─────────────────────────────────────────────────────────────

    /// @notice Get total value of all LP positions (in token terms)
    function totalValue() external view returns (uint256 totalTokenA, uint256 totalTokenB) {
        for (uint256 i = 0; i < activePairs.length; i++) {
            address pair = activePairs[i];
            LPPosition memory pos = lpPositions[pair];
            if (pos.lpBalance == 0) continue;

            (uint112 reserveA, uint112 reserveB,) = IPancakePairV2(pair).getReserves();
            uint256 totalSupply = IPancakePairV2(pair).totalSupply();

            totalTokenA += (uint256(reserveA) * pos.lpBalance) / totalSupply;
            totalTokenB += (uint256(reserveB) * pos.lpBalance) / totalSupply;
        }
    }

    /// @notice Get number of active LP positions
    function getActivePairsCount() external view returns (uint256) {
        return activePairs.length;
    }

    /// @notice Get LP position details
    function getLPPosition(address pair) external view returns (LPPosition memory) {
        return lpPositions[pair];
    }

    // ─────────────────────────────────────────────────────────────
    //  Internal Helpers
    // ─────────────────────────────────────────────────────────────

    function _getCurrentPriceRatio(address pair) internal view returns (uint256) {
        (uint112 reserveA, uint112 reserveB,) = IPancakePairV2(pair).getReserves();
        if (reserveB == 0) return MathLib.WAD;
        return MathLib.wadDiv(uint256(reserveA), uint256(reserveB));
    }

    function _removeActivePair(address pair) internal {
        for (uint256 i = 0; i < activePairs.length; i++) {
            if (activePairs[i] == pair) {
                activePairs[i] = activePairs[activePairs.length - 1];
                activePairs.pop();
                break;
            }
        }
    }

    receive() external payable {}
}
