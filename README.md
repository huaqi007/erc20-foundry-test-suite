# ERC20 + AMM 全场景测试 & 安全审计套件

基于 Foundry 的 DeFi 智能合约完整测试与安全修复体系。

---

## 项目结构

```
src/
├── SimpleToken.sol          # ERC20 合约（OpenZeppelin）
├── Pool.sol                 # V1 — 恒定乘积 AMM（原始版）
└── PoolV2.sol               # V2 — 安全修复版（TWAP + SafeERC20 + nonReentrant）

test/
├── SimpleToken.t.sol        # 32 个 ERC20 测试
├── Pool.t.sol               # 49 个 Pool V1 测试（100% 分支覆盖）
├── PoolV2.t.sol             # 17 个 V2 回归测试
├── AttackPoC.t.sol          # Fee-on-transfer / USDT / Rebasing PoC
├── ReentrancyPoC.t.sol      # 跨函数重入 / 只读重入 PoC
├── FlashloanSandwichPoC.t.sol  # 闪电贷 / MEV / 精度损失 PoC
└── Counter.t.sol            # 示例测试

.claude/agents/
├── defi-attacker.md         # 漏洞发现 → 攻击建模 → PoC
├── reviewer.md              # 测试审查 → 覆盖率缺口分析
├── test-strategist.md       # 测试维度设计 → 矩阵输出
├── test-writer.md           # 规范测试用例编写
└── code-patcher.md          # 合约漏洞修复（6 大模式）

SECURITY_AUDIT.md            # 10 个漏洞完整审计报告
FIX_REPORT.md                # V-01 ~ V-08 修复报告（含 diff + 测试结果）
```

---

## 测试覆盖总览

| 测试套件 | 文件 | 用例数 | 类型 |
|----------|------|:--:|------|
| SimpleToken | `test/SimpleToken.t.sol` | 32 | 功能 / 边界 / 权限 / 异常 |
| Pool V1 | `test/Pool.t.sol` | 49 | **100% 行 + 分支覆盖** |
| Pool V2 回归 | `test/PoolV2.t.sol` | 17 | 8 个漏洞修复验证 |
| Attack PoC | `test/AttackPoC.t.sol` | 5 | FOT / USDT / Rebasing |
| Reentrancy PoC | `test/ReentrancyPoC.t.sol` | 6 | 跨函数 / 只读重入 |
| Flashloan PoC | `test/FlashloanSandwichPoC.t.sol` | 7 | 闪电贷 / 三明治 / 精度 |
| Counter | `test/Counter.t.sol` | 6 | 示例 |
| **总计** | | **122** | **0 failed** |

---

## 快速开始

```bash
git clone https://github.com/huaqi007/erc20-foundry-test-suite.git
cd erc20-foundry-test-suite

# 运行全部测试
forge test

# 只看 Pool 相关
forge test --match-path test/Pool.t.sol
forge test --match-path test/PoolV2.t.sol

# 覆盖率（Pool.sol）
forge coverage --match-path test/Pool.t.sol --report lcov
```

### 要求

- Foundry (forge)
- Solidity ^0.8.20

---

## Agent 协作流程

本项目使用 **5 个专职 AI Agent** 组成安全审计流水线：

```
                        ┌─────────────────┐
                        │  test-strategist │
                        │   测试策略设计    │
                        └────────┬────────┘
                                 │ 测试矩阵
                                 ▼
┌──────────────┐     ┌─────────────────┐     ┌──────────────┐
│ defi-attacker │     │   test-writer   │     │   reviewer   │
│  漏洞发现     │     │   测试用例编写   │     │  测试审查    │
│  PoC 编写    │     │  覆盖率补全     │     │  缺口分析    │
└──────┬───────┘     └────────┬────────┘     └──────┬───────┘
       │ 漏洞报告              │                     │
       ▼                      │                     │
┌──────────────┐              │ 审查意见             │
│ code-patcher │◄─────────────┘─────────────────────┘
│  合约修复    │
│  回归测试    │
└──────┬───────┘
       │ 修复后合约 + 回归测试
       ▼
┌──────────────┐
│  forge test  │
│  122 tests   │
│  0 failed ✅ │
└──────────────┘
```

### 各 Agent 职责

| Agent | 角色 | 输入 | 输出 |
|-------|------|------|------|
| **test-strategist** | 测试架构师 | 合约源码 | 测试维度矩阵 + 场景优先级 |
| **defi-attacker** | 白帽黑客 | 合约源码 | 漏洞报告 + 可运行 PoC 测试 |
| **test-writer** | QA 工程师 | 测试矩阵 + 覆盖率报告 | 完整 Foundry 测试文件 |
| **reviewer** | QA 审查者 | 测试文件 | 审查报告（缺口/质量/断言） |
| **code-patcher** | 安全工程师 | 漏洞报告 | 最小化修复 + 回归测试 |

### 典型工作流

```bash
# 1. defi-attacker 发现漏洞 → 输出 PoC
#    → test/ReentrancyPoC.t.sol (含 test_PoC_CrossFunctionReentrancy)

# 2. reviewer 审查现有测试 → 发现覆盖缺口
#    → 输出: "BRDA:59 未覆盖，需要 Zero output revert 测试"

# 3. test-writer 补齐测试
#    → test/Pool.t.sol (+4 覆盖率测试，100% 分支覆盖)

# 4. code-patcher 修复漏洞
#    → src/PoolV2.sol (TWAP + SafeERC20 + nonReentrant + CEI + deadline)
#    → test/PoolV2.t.sol (17 个回归测试)

# 5. 全量验证
forge test  # 122 tests, 0 failed ✅
```

### code-patcher 修复模式（6 大类）

| 漏洞类型 | 修复方案 |
|----------|---------|
| **Reentrancy** | CEI 重排序 / `nonReentrant` 修饰符 |
| **MEV / Slippage** | `deadline` 参数 / 强制 `amountOutMin > 0` |
| **ERC20 兼容性** | SafeERC20 / 余额快照法（FOT, Rebasing） |
| **精度损失** | 先乘后除 / 最小输出检查 |
| **访问控制** | `onlyOwner` / `external` 可见性 |
| **DoS / Gas** | 循环上限 / Pull-over-Push 模式 |

> **反模式警告**：注释、NatSpec、文档不属于修复。如果 PoC 仍然通过，就不算修复。详见 `.claude/agents/code-patcher.md` Anti-Patterns 章节。

---

## 安全审计清单（V-01 ~ V-10）

| ID | 严重性 | 漏洞 | V2 状态 |
|----|--------|------|:--:|
| V-01 | Critical | Fee-on-Transfer 导致 insolvency | ✅ 余额快照 |
| V-02 | Critical | Cross-Function Reentrancy | ✅ nonReentrant |
| V-03 | Critical | Spot Price Oracle 操纵 | ✅ TWAP Oracle |
| V-04 | High | USDT 返回值未检查 | ✅ SafeERC20 |
| V-05 | High | Rebasing Token 余额膨胀 | ✅ 余额快照 |
| V-06 | High | Sandwich MEV | ✅ deadline |
| V-07 | Medium | Read-only Reentrancy | ✅ CEI 顺序 |
| V-08 | Medium | No Deadline | ✅ deadline |
| V-09 | Medium | 极端精度损失 | ↔️ 保留检查 |
| V-10 | Low | 近单边移除 | ↔️ 文档说明 |

完整报告见 [`SECURITY_AUDIT.md`](./SECURITY_AUDIT.md)，修复 diff 见 [`FIX_REPORT.md`](./FIX_REPORT.md)。
