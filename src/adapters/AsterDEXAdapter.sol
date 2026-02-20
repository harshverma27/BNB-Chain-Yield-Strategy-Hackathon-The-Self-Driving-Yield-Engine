// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAsBNBMinting, IAsUSDFMinting, IAsterALP, IAsterTreasury} from "../interfaces/IAsterDEXEarn.sol";
import {IWBNB} from "../interfaces/IPancakeSwap.sol";
import {Constants} from "../libraries/Constants.sol";
import {MathLib} from "../libraries/MathLib.sol";

/// @title AsterDEXAdapter - Integration layer for AsterDEX Earn protocol
/// @notice Manages deposits/withdrawals to asBNB, asUSDF, and ALP vaults
/// @dev All interactions are permissionless — called by StrategyEngine only
contract AsterDEXAdapter is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MathLib for uint256;

    // ─────────────────────────────────────────────────────────────
    //  Errors
    // ─────────────────────────────────────────────────────────────
    error NotStrategyEngine();
    error ZeroAmount();
    error InsufficientBalance();
    error WithdrawalPending();

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────
    event DepositedToAsBNB(uint256 bnbAmount, uint256 asBNBReceived);
    event WithdrawnFromAsBNB(uint256 asBNBAmount);
    event DepositedToAsUSDF(uint256 usdtAmount);
    event WithdrawnFromAsUSDF(uint256 asUSDFAmount);
    event DepositedToALP(address token, uint256 amount, uint256 alpReceived);
    event WithdrawnFromALP(address tokenOut, uint256 alpAmount, uint256 received);
    event RewardsClaimed(uint256 amount);

    // ─────────────────────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────────────────────
    address public immutable strategyEngine;

    IAsBNBMinting public immutable asBNBMinting;
    IAsUSDFMinting public immutable asUSDFMinting;
    IAsterALP public immutable asterALP;
    IAsterTreasury public immutable treasury;

    IERC20 public immutable asBNBToken;
    IERC20 public immutable asUSDFToken;
    IWBNB public immutable wbnb;

    // Accounting
    uint256 public totalBNBDeposited;
    uint256 public totalUSDFDeposited;
    uint256 public totalALPMinted;

    // Withdrawal tracking
    bool public bnbWithdrawalPending;
    bool public usdtWithdrawalPending;

    // ─────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────
    constructor(address _strategyEngine) {
        strategyEngine = _strategyEngine;

        asBNBMinting = IAsBNBMinting(Constants.ASBNB_MINTING);
        asUSDFMinting = IAsUSDFMinting(Constants.ASUSDF_MINTING);
        asterALP = IAsterALP(Constants.ASTER_TREASURY); // ALP is part of treasury
        treasury = IAsterTreasury(Constants.ASTER_TREASURY);

        asBNBToken = IERC20(Constants.ASBNB_TOKEN);
        asUSDFToken = IERC20(Constants.ASUSDF_TOKEN);
        wbnb = IWBNB(Constants.WBNB);
    }

    modifier onlyStrategyEngine() {
        if (msg.sender != strategyEngine) revert NotStrategyEngine();
        _;
    }

    // ─────────────────────────────────────────────────────────────
    //  asBNB Operations
    // ─────────────────────────────────────────────────────────────

    /// @notice Deposit BNB to AsterDEX Earn to receive asBNB
    /// @dev Unwraps WBNB and deposits native BNB to the minting contract
    function depositBNB(uint256 amount) external onlyStrategyEngine nonReentrant {
        if (amount == 0) revert ZeroAmount();

        // Unwrap WBNB to BNB
        wbnb.withdraw(amount);

        // Deposit BNB to get asBNB
        uint256 balBefore = asBNBToken.balanceOf(address(this));
        asBNBMinting.deposit{value: amount}();
        uint256 balAfter = asBNBToken.balanceOf(address(this));
        uint256 received = balAfter - balBefore;

        totalBNBDeposited += amount;

        emit DepositedToAsBNB(amount, received);
    }

    /// @notice Request withdrawal of asBNB back to slisBNB/BNB
    /// @param amount Amount of asBNB to withdraw
    function requestWithdrawBNB(uint256 amount) external onlyStrategyEngine nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 bal = asBNBToken.balanceOf(address(this));
        if (bal < amount) revert InsufficientBalance();
        if (bnbWithdrawalPending) revert WithdrawalPending();

        // Approve and request withdrawal
        asBNBToken.approve(address(asBNBMinting), amount);
        asBNBMinting.requestWithdraw(amount);
        bnbWithdrawalPending = true;

        emit WithdrawnFromAsBNB(amount);
    }

    /// @notice Claim completed BNB withdrawal
    function claimBNBWithdrawal() external onlyStrategyEngine nonReentrant {
        if (!bnbWithdrawalPending) return;

        asBNBMinting.claimWithdraw();
        bnbWithdrawalPending = false;

        // Wrap any received BNB back to WBNB for the strategy engine
        uint256 bnbBalance = address(this).balance;
        if (bnbBalance > 0) {
            wbnb.deposit{value: bnbBalance}();
            IERC20(address(wbnb)).safeTransfer(strategyEngine, bnbBalance);
        }
    }

    // ─────────────────────────────────────────────────────────────
    //  asUSDF Operations
    // ─────────────────────────────────────────────────────────────

    /// @notice Deposit USDT/USDF to AsterDEX Earn to receive asUSDF
    /// @param amount Amount of USDF to stake
    function depositUSDF(uint256 amount) external onlyStrategyEngine nonReentrant {
        if (amount == 0) revert ZeroAmount();

        // Approve USDF for staking
        IERC20(Constants.USDT).approve(address(asUSDFMinting), amount);
        asUSDFMinting.stake(amount);

        totalUSDFDeposited += amount;
        emit DepositedToAsUSDF(amount);
    }

    /// @notice Request unstake of asUSDF
    /// @param amount Amount of asUSDF to unstake
    function requestWithdrawUSDF(uint256 amount) external onlyStrategyEngine nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 bal = asUSDFToken.balanceOf(address(this));
        if (bal < amount) revert InsufficientBalance();
        if (usdtWithdrawalPending) revert WithdrawalPending();

        asUSDFToken.approve(address(asUSDFMinting), amount);
        asUSDFMinting.requestUnstake(amount);
        usdtWithdrawalPending = true;

        emit WithdrawnFromAsUSDF(amount);
    }

    /// @notice Claim completed USDF unstake
    function claimUSDFWithdrawal() external onlyStrategyEngine nonReentrant {
        if (!usdtWithdrawalPending) return;

        asUSDFMinting.claimUnstake();
        usdtWithdrawalPending = false;

        // Transfer USDT back to strategy engine
        uint256 usdtBal = IERC20(Constants.USDT).balanceOf(address(this));
        if (usdtBal > 0) {
            IERC20(Constants.USDT).safeTransfer(strategyEngine, usdtBal);
        }
    }

    // ─────────────────────────────────────────────────────────────
    //  ALP Operations
    // ─────────────────────────────────────────────────────────────

    /// @notice Mint ALP tokens by depositing assets
    function mintALP(address token, uint256 amount, uint256 minAlp)
        external
        onlyStrategyEngine
        nonReentrant
        returns (uint256)
    {
        if (amount == 0) revert ZeroAmount();

        IERC20(token).approve(address(asterALP), amount);
        uint256 alpReceived = asterALP.mintAlp(token, amount, minAlp);

        totalALPMinted += alpReceived;
        emit DepositedToALP(token, amount, alpReceived);
        return alpReceived;
    }

    /// @notice Burn ALP tokens to receive assets
    function burnALP(address tokenOut, uint256 alpAmount, uint256 minOut)
        external
        onlyStrategyEngine
        nonReentrant
        returns (uint256)
    {
        if (alpAmount == 0) revert ZeroAmount();

        uint256 received = asterALP.burnAlp(tokenOut, alpAmount, minOut);
        totalALPMinted -= alpAmount;

        // Transfer received tokens to strategy engine
        IERC20(tokenOut).safeTransfer(strategyEngine, received);

        emit WithdrawnFromALP(tokenOut, alpAmount, received);
        return received;
    }

    // ─────────────────────────────────────────────────────────────
    //  Rewards
    // ─────────────────────────────────────────────────────────────

    /// @notice Claim accumulated rewards from AsterDEX Treasury
    function claimRewards() external onlyStrategyEngine nonReentrant {
        uint256 pending = treasury.pendingRewards(address(this));
        if (pending > 0) {
            treasury.claimRewards();
            emit RewardsClaimed(pending);
        }
    }

    // ─────────────────────────────────────────────────────────────
    //  View Functions
    // ─────────────────────────────────────────────────────────────

    /// @notice Get total value of all AsterDEX positions in USD (18 decimals)
    function totalValue() external view returns (uint256) {
        uint256 asBNBBal = asBNBToken.balanceOf(address(this));
        uint256 asUSDFBal = asUSDFToken.balanceOf(address(this));
        uint256 alpBal = asterALP.balanceOf(address(this));

        // asBNB value = balance * exchange rate * BNB price
        uint256 asBNBValue = 0;
        if (asBNBBal > 0) {
            try asBNBMinting.exchangeRate() returns (uint256 rate) {
                // rate is in WAD, convert to USD value
                asBNBValue = asBNBBal.wadMul(rate);
            } catch {
                asBNBValue = asBNBBal; // Fallback: 1:1
            }
        }

        // asUSDF value = balance * exchange rate (already in USD terms)
        uint256 asUSDFValue = 0;
        if (asUSDFBal > 0) {
            try asUSDFMinting.exchangeRate() returns (uint256 rate) {
                asUSDFValue = asUSDFBal.wadMul(rate);
            } catch {
                asUSDFValue = asUSDFBal; // Fallback: 1:1
            }
        }

        // ALP value = balance * ALP price
        uint256 alpValue = 0;
        if (alpBal > 0) {
            try asterALP.getAlpPrice() returns (uint256 price) {
                alpValue = alpBal.wadMul(price);
            } catch {
                alpValue = alpBal;
            }
        }

        return asBNBValue + asUSDFValue + alpValue;
    }

    /// @notice Get asBNB balance
    function getAsBNBBalance() external view returns (uint256) {
        return asBNBToken.balanceOf(address(this));
    }

    /// @notice Get asUSDF balance
    function getAsUSDFBalance() external view returns (uint256) {
        return asUSDFToken.balanceOf(address(this));
    }

    /// @notice Get ALP balance
    function getALPBalance() external view returns (uint256) {
        return asterALP.balanceOf(address(this));
    }

    // ─────────────────────────────────────────────────────────────
    //  Receive BNB
    // ─────────────────────────────────────────────────────────────
    receive() external payable {}
}
