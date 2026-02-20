// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {YieldVault} from "../src/core/YieldVault.sol";
import {StrategyEngine} from "../src/core/StrategyEngine.sol";
import {RiskManager} from "../src/core/RiskManager.sol";
import {AsterDEXAdapter} from "../src/adapters/AsterDEXAdapter.sol";
import {PancakeSwapAdapter} from "../src/adapters/PancakeSwapAdapter.sol";
import {HedgingEngine} from "../src/modules/HedgingEngine.sol";
import {RebalanceModule} from "../src/modules/RebalanceModule.sol";
import {AutoCompounder} from "../src/modules/AutoCompounder.sol";
import {TimelockGovernor} from "../src/governance/TimelockGovernor.sol";
import {Constants} from "../src/libraries/Constants.sol";

/// @title Deploy - Full deployment script for the Self-Driving Yield Engine
/// @notice Deploys all contracts, sets up permissions, and initializes the strategy
contract Deploy is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast(deployerPrivateKey);

        // ─────────────────────────────────────────────────────────
        //  Step 1: Deploy Governance
        // ─────────────────────────────────────────────────────────
        TimelockGovernor governance = new TimelockGovernor(deployer, Constants.TIMELOCK_DELAY);
        console.log("TimelockGovernor:", address(governance));

        // ─────────────────────────────────────────────────────────
        //  Step 2: Deploy Vault
        // ─────────────────────────────────────────────────────────
        YieldVault vault = new YieldVault();
        console.log("YieldVault:", address(vault));

        // ─────────────────────────────────────────────────────────
        //  Step 3: Deploy Strategy Engine
        // ─────────────────────────────────────────────────────────
        StrategyEngine engine = new StrategyEngine(address(vault), address(governance));
        console.log("StrategyEngine:", address(engine));

        // ─────────────────────────────────────────────────────────
        //  Step 4: Deploy Risk Manager
        // ─────────────────────────────────────────────────────────
        RiskManager riskManager = new RiskManager(address(engine));
        console.log("RiskManager:", address(riskManager));

        // ─────────────────────────────────────────────────────────
        //  Step 5: Deploy Adapters
        // ─────────────────────────────────────────────────────────
        AsterDEXAdapter asterAdapter = new AsterDEXAdapter(address(engine));
        console.log("AsterDEXAdapter:", address(asterAdapter));

        PancakeSwapAdapter pancakeAdapter = new PancakeSwapAdapter(address(engine));
        console.log("PancakeSwapAdapter:", address(pancakeAdapter));

        // ─────────────────────────────────────────────────────────
        //  Step 6: Deploy Modules
        // ─────────────────────────────────────────────────────────
        HedgingEngine hedgingEngine = new HedgingEngine(address(engine), address(riskManager));
        console.log("HedgingEngine:", address(hedgingEngine));

        RebalanceModule rebalanceModule = new RebalanceModule(address(engine), address(riskManager));
        console.log("RebalanceModule:", address(rebalanceModule));

        AutoCompounder autoCompounder = new AutoCompounder(address(engine));
        console.log("AutoCompounder:", address(autoCompounder));

        // ─────────────────────────────────────────────────────────
        //  Step 7: Initialize Strategy Engine
        // ─────────────────────────────────────────────────────────
        engine.initialize(
            address(riskManager),
            address(asterAdapter),
            address(pancakeAdapter),
            address(hedgingEngine),
            address(rebalanceModule),
            address(autoCompounder)
        );
        console.log("StrategyEngine initialized");

        // ─────────────────────────────────────────────────────────
        //  Step 8: Connect Vault to Engine
        // ─────────────────────────────────────────────────────────
        vault.setStrategyEngine(address(engine));
        console.log("Vault connected to engine");

        vm.stopBroadcast();

        // ─────────────────────────────────────────────────────────
        //  Summary
        // ─────────────────────────────────────────────────────────
        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("Vault (deposit here):    ", address(vault));
        console.log("Strategy Engine:         ", address(engine));
        console.log("Risk Manager:            ", address(riskManager));
        console.log("AsterDEX Adapter:        ", address(asterAdapter));
        console.log("PancakeSwap Adapter:     ", address(pancakeAdapter));
        console.log("Hedging Engine:          ", address(hedgingEngine));
        console.log("Rebalance Module:        ", address(rebalanceModule));
        console.log("Auto Compounder:         ", address(autoCompounder));
        console.log("Timelock Governor:       ", address(governance));
    }
}
