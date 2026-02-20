// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Constants} from "../libraries/Constants.sol";
import {MathLib} from "../libraries/MathLib.sol";
import {StrategyEngine} from "./StrategyEngine.sol";
import {IWBNB} from "../interfaces/IPancakeSwap.sol";

/// @title YieldVault - ERC-4626 compliant vault for the Self-Driving Yield Engine
/// @notice Users deposit WBNB to receive vault shares. Capital is autonomously
///         deployed, compounded, hedged, and rebalanced by the StrategyEngine.
/// @dev Fully non-custodial: only depositors can withdraw their proportional share.
///      No admin can access user funds. Share pricing reflects real-time strategy performance.
contract YieldVault is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MathLib for uint256;

    // ─────────────────────────────────────────────────────────────
    //  Errors
    // ─────────────────────────────────────────────────────────────
    error ZeroDeposit();
    error ZeroWithdraw();
    error InsufficientShares();
    error DepositExceedsLimit();
    error WithdrawExceedsBalance();
    error VaultPaused();

    // ─────────────────────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────────────────────
    event Deposited(address indexed user, uint256 assets, uint256 shares);
    event Withdrawn(address indexed user, uint256 assets, uint256 shares);
    event StrategyEngineUpdated(address indexed engine);

    // ─────────────────────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────────────────────
    IWBNB public immutable wbnb;
    StrategyEngine public strategyEngine;

    // Vault parameters
    uint256 public maxDepositPerUser;     // Max deposit per user (0 = unlimited)
    uint256 public totalDepositCap;       // Total vault deposit cap (0 = unlimited)
    uint256 public depositFee;            // Deposit fee in bps (0 default)
    uint256 public withdrawFee;           // Withdrawal fee in bps (0 default)

    // Tracking
    mapping(address => uint256) public userDeposits;
    uint256 public totalUserDeposits;

    // ─────────────────────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────────────────────
    constructor()
        ERC20("Self-Driving Yield Engine", "sdYIELD")
    {
        wbnb = IWBNB(Constants.WBNB);
        maxDepositPerUser = 0; // Unlimited by default
        totalDepositCap = 0;   // Unlimited by default
    }

    /// @notice Set the strategy engine address (called once after deployment)
    function setStrategyEngine(address _engine) external {
        require(address(strategyEngine) == address(0), "Already set");
        require(_engine != address(0), "Zero address");
        strategyEngine = StrategyEngine(payable(_engine));
        emit StrategyEngineUpdated(_engine);
    }

    // ─────────────────────────────────────────────────────────────
    //  ERC-4626 Core: Deposit/Withdraw
    // ─────────────────────────────────────────────────────────────

    /// @notice Deposit WBNB into the vault and receive shares
    /// @param assets Amount of WBNB to deposit
    /// @return shares Amount of vault shares received
    function deposit(uint256 assets) external nonReentrant returns (uint256 shares) {
        if (assets == 0) revert ZeroDeposit();
        if (strategyEngine.paused()) revert VaultPaused();

        // Check deposit limits
        if (maxDepositPerUser > 0) {
            if (userDeposits[msg.sender] + assets > maxDepositPerUser) {
                revert DepositExceedsLimit();
            }
        }
        if (totalDepositCap > 0) {
            if (totalUserDeposits + assets > totalDepositCap) {
                revert DepositExceedsLimit();
            }
        }

        // Calculate shares using current exchange rate
        shares = _convertToShares(assets);

        // Apply deposit fee if any
        if (depositFee > 0) {
            uint256 fee = assets.bpsMul(depositFee);
            assets -= fee;
            shares = _convertToShares(assets);
        }

        // Transfer WBNB from user
        IERC20(address(wbnb)).safeTransferFrom(msg.sender, address(this), assets);

        // Mint shares to user
        _mint(msg.sender, shares);

        // Update tracking
        userDeposits[msg.sender] += assets;
        totalUserDeposits += assets;

        // Deploy capital to strategy
        IERC20(address(wbnb)).approve(address(strategyEngine), assets);
        strategyEngine.deployFromVault(assets);

        emit Deposited(msg.sender, assets, shares);
    }

    /// @notice Deposit native BNB (auto-wraps to WBNB)
    /// @return shares Amount of vault shares received
    function depositBNB() external payable nonReentrant returns (uint256 shares) {
        uint256 assets = msg.value;
        if (assets == 0) revert ZeroDeposit();
        if (strategyEngine.paused()) revert VaultPaused();

        // Check limits
        if (maxDepositPerUser > 0 && userDeposits[msg.sender] + assets > maxDepositPerUser) {
            revert DepositExceedsLimit();
        }
        if (totalDepositCap > 0 && totalUserDeposits + assets > totalDepositCap) {
            revert DepositExceedsLimit();
        }

        // Wrap BNB to WBNB
        wbnb.deposit{value: assets}();

        // Calculate shares
        shares = _convertToShares(assets);

        // Mint shares
        _mint(msg.sender, shares);

        // Track
        userDeposits[msg.sender] += assets;
        totalUserDeposits += assets;

        // Deploy to strategy
        IERC20(address(wbnb)).approve(address(strategyEngine), assets);
        strategyEngine.deployFromVault(assets);

        emit Deposited(msg.sender, assets, shares);
    }

    /// @notice Withdraw assets by burning shares
    /// @param shares Amount of shares to burn
    /// @return assets Amount of WBNB received
    function withdraw(uint256 shares) external nonReentrant returns (uint256 assets) {
        if (shares == 0) revert ZeroWithdraw();
        if (balanceOf(msg.sender) < shares) revert InsufficientShares();

        // Calculate assets for these shares
        assets = _convertToAssets(shares);

        // Apply withdrawal fee if any
        if (withdrawFee > 0) {
            uint256 fee = assets.bpsMul(withdrawFee);
            assets -= fee;
        }

        // Burn shares
        _burn(msg.sender, shares);

        // Withdraw from strategy
        strategyEngine.withdrawToVault(assets);

        // Transfer WBNB to user
        uint256 wbnbBal = IERC20(address(wbnb)).balanceOf(address(this));
        uint256 toTransfer = MathLib.min(assets, wbnbBal);

        if (toTransfer > 0) {
            IERC20(address(wbnb)).safeTransfer(msg.sender, toTransfer);
        }

        // Update tracking
        userDeposits[msg.sender] = MathLib.safeSub(userDeposits[msg.sender], assets);
        totalUserDeposits = MathLib.safeSub(totalUserDeposits, assets);

        emit Withdrawn(msg.sender, toTransfer, shares);
    }

    /// @notice Withdraw as native BNB
    /// @param shares Amount of shares to burn
    /// @return assets Amount of BNB received
    function withdrawBNB(uint256 shares) external nonReentrant returns (uint256 assets) {
        if (shares == 0) revert ZeroWithdraw();
        if (balanceOf(msg.sender) < shares) revert InsufficientShares();

        assets = _convertToAssets(shares);

        if (withdrawFee > 0) {
            uint256 fee = assets.bpsMul(withdrawFee);
            assets -= fee;
        }

        _burn(msg.sender, shares);

        // Withdraw from strategy
        strategyEngine.withdrawToVault(assets);

        // Unwrap WBNB to BNB
        uint256 wbnbBal = IERC20(address(wbnb)).balanceOf(address(this));
        uint256 toUnwrap = MathLib.min(assets, wbnbBal);

        if (toUnwrap > 0) {
            wbnb.withdraw(toUnwrap);
            (bool success,) = msg.sender.call{value: toUnwrap}("");
            require(success, "BNB transfer failed");
        }

        userDeposits[msg.sender] = MathLib.safeSub(userDeposits[msg.sender], assets);
        totalUserDeposits = MathLib.safeSub(totalUserDeposits, assets);

        emit Withdrawn(msg.sender, toUnwrap, shares);
    }

    // ─────────────────────────────────────────────────────────────
    //  ERC-4626 View Functions
    // ─────────────────────────────────────────────────────────────

    /// @notice Get the underlying asset (WBNB)
    function asset() external view returns (address) {
        return address(wbnb);
    }

    /// @notice Get total assets under management
    function totalAssets() public view returns (uint256) {
        if (address(strategyEngine) == address(0)) return 0;

        uint256 engineValue = strategyEngine.getTotalValue();
        uint256 idleInVault = IERC20(address(wbnb)).balanceOf(address(this));
        return engineValue + idleInVault;
    }

    /// @notice Convert assets to shares
    function convertToShares(uint256 assets) external view returns (uint256) {
        return _convertToShares(assets);
    }

    /// @notice Convert shares to assets
    function convertToAssets(uint256 shares) external view returns (uint256) {
        return _convertToAssets(shares);
    }

    /// @notice Get share price (assets per share, in WAD)
    function sharePrice() external view returns (uint256) {
        if (totalSupply() == 0) return MathLib.WAD;
        return MathLib.wadDiv(totalAssets(), totalSupply());
    }

    /// @notice Get the max deposit for a user
    function maxDeposit(address user) external view returns (uint256) {
        if (strategyEngine.paused()) return 0;
        if (maxDepositPerUser == 0) return type(uint256).max;
        return MathLib.safeSub(maxDepositPerUser, userDeposits[user]);
    }

    /// @notice Get the max withdrawal for a user
    function maxWithdraw(address user) external view returns (uint256) {
        return _convertToAssets(balanceOf(user));
    }

    // ─────────────────────────────────────────────────────────────
    //  Internal Share Math
    // ─────────────────────────────────────────────────────────────

    function _convertToShares(uint256 assets) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return assets; // 1:1 for first deposit
        }
        return Math.mulDiv(assets, supply, totalAssets());
    }

    function _convertToAssets(uint256 shares) internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return shares; // 1:1 fallback
        }
        return Math.mulDiv(shares, totalAssets(), supply);
    }

    // ─────────────────────────────────────────────────────────────
    //  Receive BNB
    // ─────────────────────────────────────────────────────────────
    receive() external payable {}
}
