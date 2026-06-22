# Foundry Fuzz 测试逻辑说明

> **测试框架**：Foundry
> **版本**：forge 0.8+

---

## 什么是 Fuzz 测试？

Fuzz 测试（模糊测试）是 Foundry 的**内置能力**：测试函数声明一个或多个参数，Forge 在运行时自动生成大量**随机值**传入，验证函数在所有随机输入下行为是否正确。

```solidity
// 普通测试 — 固定参数
function test_Transfer() public {
    token.transfer(alice, 100 * 1e18);  // 只测 100
}

// Fuzz 测试 — 随机参数，Forge 自动跑 256 次
function testFuzz_TransferBalanceSumInvariant(uint256 amount) public {
    token.transfer(alice, amount);       // 测 256 个不同的 amount
}
```

### 命名规则

Foundry 识别 `testFuzz_` 前缀（或 `test_Fuzz_`）的函数为 Fuzz 测试，或配置 `fuzz` 选项。

---

## Fuzz 测试的两种模式

### 1. 独立 Fuzz 测试

每次用随机参数独立运行，状态**不跨轮共享**（每轮从 `setUp()` 重新开始）：

```solidity
function testFuzz_SetNumber(uint256 x) public {
    counter.setNumber(x);
    assertEq(counter.number(), x);  // 任意 x 都应该存储成功
}
```

### 2. 不变性测试（Invariant）

检查状态在调用序列后某属性是否始终成立，状态**跨调用持续**：

```
// 不在本项目范围内，简要说明：
// - invariant_Xxx() 函数 → Forge 随机调合约函数，每次调用后检查不变量
```

---

## 本项目 Fuzz 测试清单

### Counter — 1 个

| 函数 | 参数 | 逻辑 |
|---|---|---|
| `testFuzz_SetNumber(uint256 x)` | 任意 `uint256` | `setNumber(x)` 后 `number() == x` |

### SimpleToken — 4 个

| 函数 | 参数 | 逻辑 |
|---|---|---|
| `testFuzz_TransferBalanceSumInvariant(uint256 amount)` | `amount` 缩放到 `[0, INITIAL_SUPPLY]` | transfer 前后发送者+接收者余额之和不变 |
| `testFuzz_ApproveDoesNotChangeBalance(uint256 approveAmount)` | 任意 `uint256` | approve 不会改变授权者余额 |
| `testFuzz_MintThenBurnTotalSupply(uint256, uint256)` | `mintAmount ∈ [1, 1M]`, `burnAmount ∈ [0, mintAmount]` | mint 增 totalSupply，burn 减 totalSupply |
| `testFuzz_TransferFromAllowance(uint256, uint256)` | `approve ∈ [1, 1M]`, `transfer ∈ [0, approve]` | transferFrom 后 allowance 正确扣减 |

---

## 关键技巧

### `bound()` — 限制随机范围

Fuzz 输入是全 `uint256` 范围，很多值会导致 revert（如转账超过余额）。用 `bound(x, min, max)` 把输入限制到**合法区间**：

```solidity
function testFuzz_TransferBalanceSumInvariant(uint256 amount) public {
    amount = bound(amount, 0, INITIAL_SUPPLY);  // 超过总供应量会 revert，限制到合法范围
    // ...
}
```

**不用 bound 会怎样？** — Forge 生成的很多随机值会触发 ERC20 的 `ERC20InsufficientBalance` revert，测试函数整体 revert，浪费大量 fuzz 轮次。

### `runs` 配置

默认 fuzz runs = 256。在 `foundry.toml` 中可调：

```toml
[fuzz]
runs = 1000          # 更多轮次
max_test_rejects = 65536  # 最多拒绝次数（找到合法区间的尝试上限）
```

### Fuzz 轮次的输出解读

```
[PASS] testFuzz_SetNumber(uint256) (runs: 256, μ: 28511, ~: 29289)
```

| 字段 | 含义 |
|---|---|
| `runs: 256` | 执行了 256 轮 |
| `μ: 28511` | 平均 gas 消耗 |
| `~: 29289` | 中位数 gas 消耗 |

---

## Fuzz vs 普通测试：什么时候用？

| 场景 | 用哪种 |
|---|---|
| 已知的具体输入（如 transfer 100 token） | 普通 `test_Xxx()` |
| "对于任意合法输入，属性 X 永远成立" | Fuzz `testFuzz_Xxx()` |
| "对于任意金额的转账，余额和不变" | Fuzz（本项目 4 个） |
| "amountIn = 0 时 revert" | 普通（单一确定输入） |
| "任意大于 0 的 amountIn 不 revert" | Fuzz（随机大量合法值） |

---

## 最佳实践

1. **用 `bound()` 缩小输入空间** — 避免大量无效 revert 轮次
2. **Fuzz 测试应覆盖不变量** — "任何时候 X 都成立" 是 Fuzz 的天然用武之地
3. **Fuzz 不能替代边界测试** — 边界值（0, max, 1 wei）仍需单独测试
4. **`runs: 256` 是默认值，CI 中够用** — 开发阶段可临时调高做深度检查
