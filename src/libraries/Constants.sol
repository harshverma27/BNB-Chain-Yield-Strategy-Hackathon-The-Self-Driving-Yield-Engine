// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Constants - All external contract addresses and protocol parameters
/// @notice Central registry of immutable addresses and configuration for BNB Chain
library Constants {
    // ─────────────────────────────────────────────────────────────
    //  AsterDEX Earn — BNB Chain Mainnet
    // ─────────────────────────────────────────────────────────────
    address internal constant ASBNB_TOKEN = 0x77734e70b6E88b4d82fE632a168EDf6e700912b6;
    address internal constant ASBNB_MINTING = 0x2F31ab8950c50080E77999fa456372f276952fD8;
    address internal constant ASUSDF_TOKEN = 0x917AF46B3C3c6e1Bb7286B9F59637Fb7C65851Fb;
    address internal constant ASUSDF_MINTING = 0xdB57a53C428a9faFcbFefFB6dd80d0f427543695;
    address internal constant ASTER_TREASURY = 0x128463A60784c4D3f46c23Af3f65Ed859Ba87974;

    // ─────────────────────────────────────────────────────────────
    //  PancakeSwap — BNB Chain Mainnet
    // ─────────────────────────────────────────────────────────────
    address internal constant PANCAKE_V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address internal constant PANCAKE_V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address internal constant PANCAKE_V3_SWAP_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address internal constant PANCAKE_MASTERCHEF_V3 = 0x556B9306565093C855AEA9AE92A594704c2Cd59e;

    // ─────────────────────────────────────────────────────────────
    //  Tokens — BNB Chain Mainnet
    // ─────────────────────────────────────────────────────────────
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;

    // ─────────────────────────────────────────────────────────────
    //  Chainlink Price Feeds — BNB Chain Mainnet
    // ─────────────────────────────────────────────────────────────
    address internal constant CHAINLINK_BNB_USD = 0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE;
    address internal constant CHAINLINK_USDT_USD = 0xB97Ad0E74fa7d920791E90258A6E2085088b4320;
    address internal constant CHAINLINK_CAKE_USD = 0xB6064eD41d4f67e353768aA239cA86f4F73665a1;

    // ─────────────────────────────────────────────────────────────
    //  Protocol Parameters
    // ─────────────────────────────────────────────────────────────
    uint256 internal constant BASIS_POINTS = 10_000;

    /// @notice Default allocation: 70% to AsterDEX Earn, 30% to PancakeSwap
    uint256 internal constant DEFAULT_ASTER_ALLOCATION_BPS = 7_000;
    uint256 internal constant DEFAULT_PANCAKE_ALLOCATION_BPS = 3_000;

    /// @notice Rebalance triggers
    uint256 internal constant DEFAULT_REBALANCE_THRESHOLD_BPS = 500; // 5% drift
    uint256 internal constant MIN_REBALANCE_INTERVAL = 1 hours;
    uint256 internal constant MAX_REBALANCE_INTERVAL = 24 hours;

    /// @notice Compounding parameters
    uint256 internal constant MIN_COMPOUND_INTERVAL = 30 minutes;
    uint256 internal constant KEEPER_BOUNTY_BPS = 50; // 0.5% of harvested yield

    /// @notice Risk parameters
    uint256 internal constant MAX_DRAWDOWN_BPS = 1_000; // 10% circuit breaker
    uint256 internal constant MAX_SLIPPAGE_BPS = 100; // 1% max slippage
    uint256 internal constant ORACLE_STALENESS_THRESHOLD = 1 hours;

    /// @notice Governance timelocks
    uint256 internal constant TIMELOCK_DELAY = 48 hours;
    uint256 internal constant EMERGENCY_TIMELOCK_DELAY = 1 hours;

    /// @notice Hedge parameters
    uint256 internal constant DEFAULT_HEDGE_RATIO_BPS = 5_000; // 50% of LP BNB exposure
    uint256 internal constant MAX_FUNDING_RATE_BPS = 100; // Close hedge if funding > 1%
}
