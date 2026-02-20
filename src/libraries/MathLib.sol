// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MathLib - Fixed-point math utilities for yield and IL calculations
/// @notice Provides safe fixed-point arithmetic for precise financial calculations
library MathLib {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant HALF_WAD = 5e17;
    uint256 internal constant HALF_RAY = 5e26;

    /// @notice Multiply two WAD values
    function wadMul(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b + HALF_WAD) / WAD;
    }

    /// @notice Divide two WAD values
    function wadDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b > 0, "MathLib: division by zero");
        return (a * WAD + b / 2) / b;
    }

    /// @notice Calculate percentage in basis points
    function bpsMul(uint256 value, uint256 bps) internal pure returns (uint256) {
        return (value * bps) / 10_000;
    }

    /// @notice Calculate impermanent loss ratio given price ratio
    /// @param priceRatio Current price / initial price (in WAD)
    /// @return ilLoss The IL as a fraction of initial value (in WAD)
    /// @dev IL = 2 * sqrt(priceRatio) / (1 + priceRatio) - 1
    ///      Uses Babylonian method for sqrt approximation
    function calculateIL(uint256 priceRatio) internal pure returns (uint256 ilLoss) {
        if (priceRatio == WAD) return 0;

        // sqrt(priceRatio) using Babylonian method
        uint256 sqrtRatio = sqrt(priceRatio * WAD);

        // 2 * sqrt(r) / (1 + r)
        uint256 numerator = 2 * sqrtRatio;
        uint256 denominator = WAD + priceRatio;

        uint256 ratio = wadDiv(numerator, denominator);

        // IL = 1 - ratio (always positive since IL is a loss)
        if (ratio >= WAD) return 0;
        ilLoss = WAD - ratio;
    }

    /// @notice Babylonian square root for uint256
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /// @notice Safe subtraction that returns 0 instead of reverting
    function safeSub(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a - b : 0;
    }

    /// @notice Returns the minimum of two values
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @notice Returns the maximum of two values
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    /// @notice Calculates absolute difference
    function absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a - b : b - a;
    }
}
