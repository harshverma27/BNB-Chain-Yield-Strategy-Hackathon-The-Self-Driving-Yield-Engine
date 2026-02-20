// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAsterDEXEarn - Interfaces for AsterDEX Earn protocol on BNB Chain
/// @notice Covers asBNB minting/withdrawal, asUSDF minting/withdrawal, and ALP operations

/// @notice Interface for the asBNB minting contract
interface IAsBNBMinting {
    /// @notice Deposit BNB to receive asBNB (auto-converts to slisBNB internally)
    function deposit() external payable;

    /// @notice Deposit slisBNB to receive asBNB
    /// @param amount Amount of slisBNB to deposit
    function depositSlisBNB(uint256 amount) external;

    /// @notice Request withdrawal of asBNB back to slisBNB
    /// @param amount Amount of asBNB to withdraw
    function requestWithdraw(uint256 amount) external;

    /// @notice Claim completed withdrawal
    function claimWithdraw() external;

    /// @notice Get current exchange rate of asBNB to BNB
    function exchangeRate() external view returns (uint256);

    /// @notice Get pending withdrawal amount for an address
    function pendingWithdrawals(address user) external view returns (uint256);

    /// @notice Get the total deposited BNB
    function totalDeposited() external view returns (uint256);
}

/// @notice Interface for the asUSDF minting contract
interface IAsUSDFMinting {
    /// @notice Deposit USDF to mint asUSDF
    /// @param amount Amount of USDF to stake
    function stake(uint256 amount) external;

    /// @notice Request unstake of asUSDF back to USDF
    /// @param amount Amount of asUSDF to unstake
    function requestUnstake(uint256 amount) external;

    /// @notice Claim completed unstake
    function claimUnstake() external;

    /// @notice Get current exchange rate of asUSDF
    function exchangeRate() external view returns (uint256);

    /// @notice Get the current APY in basis points
    function currentAPY() external view returns (uint256);

    /// @notice Get pending unstake amount
    function pendingUnstakes(address user) external view returns (uint256);
}

/// @notice Interface for ALP (AsterDEX Liquidity Pool) operations
interface IAsterALP {
    /// @notice Mint ALP tokens by depositing assets
    /// @param token The token to deposit
    /// @param amount Amount to deposit
    /// @param minAlp Minimum ALP to receive
    function mintAlp(address token, uint256 amount, uint256 minAlp) external returns (uint256);

    /// @notice Burn ALP tokens to receive assets
    /// @param tokenOut Token to receive
    /// @param alpAmount Amount of ALP to burn
    /// @param minOut Minimum tokens to receive
    function burnAlp(address tokenOut, uint256 alpAmount, uint256 minOut) external returns (uint256);

    /// @notice Get the current ALP price
    function getAlpPrice() external view returns (uint256);

    /// @notice Get total ALP supply
    function totalSupply() external view returns (uint256);

    /// @notice Get ALP balance of address
    function balanceOf(address account) external view returns (uint256);

    /// @notice Approve spender
    function approve(address spender, uint256 amount) external returns (bool);

    /// @notice Transfer ALP tokens
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice Interface for AsterDEX Treasury
interface IAsterTreasury {
    /// @notice Get the current NAV of the treasury
    function getNetAssetValue() external view returns (uint256);

    /// @notice Get pending rewards for a user
    function pendingRewards(address user) external view returns (uint256);

    /// @notice Claim accumulated rewards
    function claimRewards() external;
}

/// @notice Interface for USDF stablecoin
interface IUSDF {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}
