# 🏎️ The Self-Driving Yield Engine

> A fully autonomous, non-custodial yield protocol on BNB Chain that programmatically deploys, compounds, hedges, and rebalances capital across AsterDEX Earn and PancakeSwap — with zero human intervention.

[![Solidity](https://img.shields.io/badge/Solidity-0.8.24-blue)](https://soliditylang.org/)
[![BNB Chain](https://img.shields.io/badge/BNB%20Chain-Mainnet-yellow)](https://www.bnbchain.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)

---

## 📐 Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         USER DEPOSITS                              │
│                    (BNB / WBNB → sdYIELD shares)                   │
└─────────────────────┬───────────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────────────┐
│                   YIELD VAULT (ERC-4626)                           │
│         Non-custodial • Share-based accounting • BNB/WBNB          │
└─────────────────────┬───────────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    STRATEGY ENGINE                                  │
│    Central orchestrator — fully permissionless executeStrategy()    │
│                                                                     │
│    ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐          │
│    │ HARVEST  │→ │ COMPOUND │→ │REBALANCE │→ │  HEDGE   │          │
│    └──────────┘  └──────────┘  └──────────┘  └──────────┘          │
└─────────┬───────────────┬───────────────┬───────────────────────────┘
          │               │               │
          ▼               ▼               ▼
┌─────────────────┐ ┌─────────────┐ ┌──────────────────┐
│  AsterDEX Earn  │ │ PancakeSwap │ │  Hedging Engine   │
│  ═════════════  │ │ ═══════════ │ │  ══════════════   │
│  • asBNB vault  │ │ • WBNB/USDT │ │  • Short BNB perp │
│  • asUSDF vault │ │   V2 LPs    │ │  • Dynamic ratio  │
│  • ALP vault    │ │ • Farming   │ │  • Funding rate   │
│                 │ │ • CAKE      │ │    monitoring     │
│   (70% capital) │ │ (30% capital)│ │                   │
└─────────────────┘ └─────────────┘ └──────────────────┘
```

---

## 🧠 Philosophy of Design

### Why Self-Driving?

Human fund managers are slow, emotional, and sleep 8 hours a day. During that sleep, markets move, opportunities compound (or don't), and volatility strikes without mercy. Every hour of inaction is yield left on the table.

This protocol replaces the human with a deterministic, always-on smart contract engine that executes a precise cycle: **Harvest → Compound → Rebalance → Hedge** — triggered by anyone, rewarded with a gas bounty, and governed by math, not opinions.

### Core Strategy

We treat AsterDEX Earn as the **bedrock** — a reliable, yield-bearing anchor — and PancakeSwap LP positions as **growth accelerators** that stack additional yield on top. The engine automatically balances between safety and growth based on real-time market volatility:

| Volatility | AsterDEX Earn | PancakeSwap LP | Hedge Ratio |
|------------|:------------:|:--------------:|:-----------:|
| 🟢 Low    | 70%          | 30%            | 25%         |
| 🟡 Medium | 80%          | 20%            | 50%         |
| 🔴 High   | 90%          | 10%            | 75%         |
| ⚫ Extreme| 100%         | 0%             | 100%        |

### Key Assumptions We Challenged

1. **"You need keepers/bots for automation"** — No. We use a gas bounty model where *anyone* can call `executeStrategy()` and earn 0.5% of harvested yield. This is self-incentivizing and fully decentralized.

2. **"Hedging kills yields"** — Not when your collateral is yield-bearing asUSDF. We earn yield on the hedge collateral itself, making hedging nearly free in calm markets.

3. **"You need an admin to handle emergencies"** — Our circuit breaker triggers automatically when drawdown exceeds 10% from high-water mark. No manual button needed.

4. **"Governance means DAO votes"** — We use a transparent timelock. All parameter changes are queued with a 48-hour delay and visible on-chain. No surprise rug pulls, no governance theater.

---

## 🏗️ Contract Architecture

### Core Contracts
| Contract | Purpose |
|----------|---------|
| `YieldVault.sol` | ERC-4626 vault — users deposit BNB/WBNB, receive sdYIELD shares |
| `StrategyEngine.sol` | Central orchestrator — coordinates all strategy operations |
| `RiskManager.sol` | Circuit breakers, oracle validation, volatility tracking |

### Adapters
| Contract | Purpose |
|----------|---------|
| `AsterDEXAdapter.sol` | asBNB/asUSDF/ALP deposit, withdrawal, rewards |
| `PancakeSwapAdapter.sol` | LP provision, farming, CAKE harvesting, IL tracking |

### Modules
| Contract | Purpose |
|----------|---------|
| `HedgingEngine.sol` | IL hedging via AsterDEX perp shorts |
| `RebalanceModule.sol` | Drift detection and portfolio rebalancing |
| `AutoCompounder.sol` | Permissionless compounding with keeper bounties |

### Governance
| Contract | Purpose |
|----------|---------|
| `TimelockGovernor.sol` | 48-hour timelock on all parameter changes |

---

## 🔒 Security Architecture

### Non-Custodial Guarantees
- **No admin keys**: All parameters are governed by timelock — no instant changes possible
- **No privileged operators**: `executeStrategy()` is permissionless — anyone can call it
- **No off-chain triggers**: All logic executes on-chain, deterministically
- **Proportional withdrawals only**: Users can only withdraw their share — no admin drain

### Risk Mitigation
- **Circuit Breakers**: Auto-pause if drawdown exceeds 10% from high-water mark
- **Oracle Validation**: Staleness checks, deviation bounds, round completeness via Chainlink
- **Slippage Protection**: Max 1% slippage enforced on all swaps
- **Volatility Shield**: Automatic defensive rotation during market stress
- **Multi-Protocol Exposure Limits**: Max 80% in any single protocol

### Attack Vector Mitigation
| Attack | Mitigation |
|--------|-----------|
| Flash loan price manipulation | Multi-block TWAP + Chainlink oracle validation |
| Sandwich attacks | Max slippage enforcement (100 bps) |
| Reentrancy | OpenZeppelin ReentrancyGuard on all external calls |
| Admin rug pull | No admin keys — 48hr timelock on all changes |
| Oracle manipulation | Staleness checks + deviation bounds + round completeness |

---

## 🚀 Deployment

### Prerequisites
- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- BNB Chain RPC endpoint

### Build
```bash
forge build
```

### Test
```bash
# Unit tests (no fork required)
forge test -vvv

# Fork tests against BNB Chain
forge test --fork-url https://bsc-dataseed1.binance.org -vvv
```

### Deploy
```bash
# Set environment variables
export PRIVATE_KEY=your_private_key
export BSCSCAN_API_KEY=your_api_key

# Deploy to BNB Chain
forge script script/Deploy.s.sol --rpc-url https://bsc-dataseed1.binance.org --broadcast --verify
```

---

## 📊 The Four Pillars

### 1. Integrate (The Core)
AsterDEX Earn is the **primary yield source**. All capital begins in AsterDEX Earn vaults (asBNB, asUSDF, ALP), and returns to AsterDEX during market stress. This is our capital anchor.

### 2. Stack (The Growth)
Yield from AsterDEX Earn is **re-deployed** into PancakeSwap WBNB/USDT liquidity pools and farms. CAKE rewards are harvested, swapped, and compounded back into the strategy — creating a yield-on-yield flywheel.

### 3. Automate (The Speed)
Every strategy cycle is **fully programmatic**:
- No manual buttons
- No multisig execution
- No privileged operators
- No off-chain triggers or keepers

Anyone can call `executeStrategy()` and earn a gas bounty.

### 4. Protect (The Trust)
100% non-custodial:
- Smart contracts are the sole source of truth
- No admin keys or entities control user funds
- All governance changes go through 48-hour timelock
- Circuit breakers trigger automatically based on on-chain conditions

---

## 🔗 External Contract Addresses (BNB Chain Mainnet)

### AsterDEX Earn
| Contract | Address |
|----------|---------|
| asBNB Token | `0x77734e70b6E88b4d82fE632a168EDf6e700912b6` |
| asBNB Minting | `0x2F31ab8950c50080E77999fa456372f276952fD8` |
| asUSDF Token | `0x917AF46B3C3c6e1Bb7286B9F59637Fb7C65851Fb` |
| asUSDF Minting | `0xdB57a53C428a9faFcbFefFB6dd80d0f427543695` |
| Treasury | `0x128463A60784c4D3f46c23Af3f65Ed859Ba87974` |

### PancakeSwap
| Contract | Address |
|----------|---------|
| V2 Router | `0x10ED43C718714eb63d5aA57B78B54704E256024E` |
| MasterChef V3 | `0x556B9306565093C855AEA9AE92A594704c2Cd59e` |

### Chainlink Oracles
| Feed | Address |
|------|---------|
| BNB/USD | `0x0567F2323251f0Aab15c8dFb1967E4e8A7D42aeE` |
| USDT/USD | `0xB97Ad0E74fa7d920791E90258A6E2085088b4320` |

---

## 📈 Economic Design

### Yield Sources
1. **AsterDEX asBNB**: BNB staking rewards + Binance Launchpool/Megadrop rewards
2. **AsterDEX asUSDF**: Delta-neutral strategy yield + funding fee collection
3. **AsterDEX ALP**: Trading fee share from Simple mode volume
4. **PancakeSwap LP**: Trading fees from WBNB/USDT pool
5. **PancakeSwap Farm**: CAKE emission rewards

### Fee Structure
- **Deposit fee**: 0% (configurable via timelock)
- **Withdrawal fee**: 0% (configurable via timelock)
- **Keeper bounty**: 0.5% of harvested yield (incentivizes automation)
- **Protocol fee**: 0% — fully accrues to vault share holders

### Sustainability
Yield is derived primarily from:
- Trading fees (ALP vault, PancakeSwap LP fees) — sustainable, volume-based
- Staking rewards (asBNB) — sustainable, network-level
- Delta-neutral strategies (asUSDF) — sustainable, market-neutral

We explicitly avoid emission-dependent yields that decay over time.

---

## 📜 License

MIT License — see [LICENSE](LICENSE) for details.

---

*Built for the BNB Chain Yield Strategy Hackathon: The Self-Driving Yield Engine*
