# SimplePool 测试全策略文档

> **合约**：SimplePool（恒定乘积 AMM + 0.3% 手续费 + ReentrancyGuard）
> **功能**：swap / addLiquidity / removeLiquidity / getAmountOut / getPrice
> **测试框架**：Foundry
> **测试文件**：`test/Pool.t.sol`

---

## 测试覆盖总览

```
31 个测试场景，6 个维度，0 失败

维度 1  功能测试      7 个  正常路径 + 事件验证 + 金额一致性
维度 2  边界值        7 个  最小输入、极大输入、空池、满额移除
维度 3  状态不变量    7 个  k 值、余额守恒、往返磨损、精度
维度 4  权限验证      2 个  公开访问（无权限限制）
维度 5  异常回滚      7 个  零输入、无效 token、空池、滑点、超额
维度 6  重入攻击      1 个  恶意 ERC20 回调重入 + nonReentrant 防护
```

---

## 合约概述

```
SimplePool
├── tokenA / tokenB          immutable ERC20 地址
├── reserveA / reserveB      链上储备量（实际余额可不同）
├── FEE_BPS = 30             0.3% = 30 基点
├── BASIS_POINTS = 10000     精度基数
├── swap(in, amt, minOut)    nonReentrant 保护
├── addLiquidity(amtA, amtB)  公开
├── removeLiquidity(amtA, amtB) 公开
├── getAmountOut(in, amt)    view
└── getPrice(in)             view
```

**恒定乘积公式**（含 0.3% 手续费）：

```
amountInWithFee = amountIn × 9970
amountOut = (amountInWithFee × reserveOut) / (reserveIn × 10000 + amountInWithFee)
```

手续费留在池中 → k = reserveA × reserveB 会略增。

---

## 维度 1：功能测试 — 正常路径 (1–7)

验证每个公开函数的基本行为和事件 emit。

| # | 测试函数 | 验证点 |
|---|---|---|
| 1 | `test_SwapAtoB()` | TokenA → TokenB，output > 0，`Swap` 事件 emit |
| 2 | `test_SwapBtoA()` | TokenB → TokenA，反向正确，事件验证 |
| 3 | `test_SwapReserveUpdate()` | swap 后 reserveA += amountIn, reserveB -= amountOut |
| 4 | `test_SwapFeeCalculation()` | actual 输出 = getAmountOut 预测；actual < 无手续费理论值 |
| 5 | `test_AddLiquidity()` | reserveA/B 增加，`LiquidityAdded` 事件 emit |
| 6 | `test_RemoveLiquidity()` | reserveA/B 减少，`LiquidityRemoved` 事件 emit，代币退回用户 |
| 7 | `test_GetAmountOutMatchesSwap()` | 3 种不同输入量的 getAmountOut 预测 = swap 实际输出 |

**关键设计**：
- `test_SwapFeeCalculation` 必须在 swap **之前**缓存 reserve 来计算无手续费理论值
- `test_GetAmountOutMatchesSwap` 需要给 alice mint 足够 token 覆盖 3 次 swap

---

## 维度 2：边界值 (8–14)

挑战输入空间的极值。

| # | 测试函数 | 验证点 |
|---|---|---|
| 8 | `test_SwapOneWei()` | 100 wei 最小有效输入（1 wei 因整数除法输出为 0 会 revert Zero output） |
| 9 | `test_SwapLargeInput()` | 90% 储备量的大额 swap，成功但滑点极大 |
| 10 | `test_SwapNoSlippageMin()` | `amountOutMin = 0`，无滑点保护也成功 |
| 11 | `test_SwapExactMinBoundary()` | `amountOutMin` 精确等于计算值 → 不触发 slippage |
| 12 | `test_AddLiquidityEmptyPool()` | 全新池子首次添加，reserve 从 0 跳到 amount |
| 13 | `test_AddLiquidityMultiple()` | 两次连续添加，储备量累加 |
| 14 | `test_RemoveAllLiquidity()` | 移除 100% 储备 → reserveA = reserveB = 0 |

**边界值设计思路**：
- 0 → 1 wei → 正常 → 极大（90%） — 覆盖输入域的全谱
- 空池添加 → 非空添加 → 全额移除 — 覆盖流动性生命周期

---

## 维度 3：状态不变量 (15–21)

A 操作前后，某属性永远成立。

| # | 测试函数 | 不变量 |
|---|---|---|
| 15 | `test_ConstantProductInvariant()` | swap 前后 k = reserveA × reserveB ≥ 原来（fee 留在池中） |
| 16 | `test_SwapBalanceConservation()` | 用户变化 + 池子变化 = 0（方向相反） |
| 17 | `test_BalanceEqualsReserveAfterAdd()` | addLiquidity 后 `tokenA.balanceOf(pool) == reserveA` |
| 18 | `test_BalanceEqualsReserveAfterRemove()` | removeLiquidity 后 `tokenA.balanceOf(pool) == reserveA` |
| 19 | `test_SwapOutputLeqGetAmountOut()` | swap 实际输出 ≤ getAmountOut 预测 |
| 20 | `test_RoundTripFeeLoss()` | A→B→A 往返后余额 < 初始（两次手续费磨损） |
| 21 | `test_GetAmountOutZero()` | `getAmountOut(any, 0) == 0` |

**不变量测试的关键**：
- #15: k 不减反增 → 证明了恒定乘积公式正确且手续费在池中
- #20: 往返亏损 → 证明手续费被正确扣除（非零和博弈）
- #16: 逐地址核算 → 用户和池子的变化精确对账

---

## 维度 4：权限验证 (22–23)

SimplePool 没有 `onlyOwner`，所有函数对外公开。

| # | 测试函数 | 验证点 |
|---|---|---|
| 22 | `test_AnyoneCanSwap()` | 陌生人（无任何特殊权限）调用 swap → 成功 |
| 23 | `test_AnyoneCanAddLiquidity()` | 陌生人添加 + 移除流动性 → 成功 |

**与其他合约的对比**：
- SimpleToken 有 `onlyOwner` 守卫 → 权限维度需要测 revert
- SimplePool 无权限守卫 → 权限维度验证"应该能做的事确实能做"

---

## 维度 5：异常回滚 (24–30)

输入不合法时 revert 并给出正确错误信息。

| # | 测试函数 | 触发条件 | 期望 revert |
|---|---|---|---|
| 24 | `test_Revert_AmountInZero()` | `amountIn = 0` | `"AmountIn must be > 0"` |
| 25 | `test_Revert_InvalidToken()` | 传入 `0xdead`（非池中 token） | `"Invalid token"` |
| 26 | `test_Revert_EmptyPool()` | 空池 swap | `"Empty pool"` |
| 27 | `test_Revert_SlippageExceeded()` | `amountOutMin` 设为预测值的 2 倍 | `"Slippage exceeded"` |
| 28 | `test_Revert_TransferFromFail()` | charlie 有余额但没授权池子 | ERC20 层 `ERC20InsufficientAllowance` |
| 29 | `test_Revert_AddZeroLiquidity()` | `addLiquidity(0, x)` | `"Amounts must be > 0"` |
| 30 | `test_Revert_RemoveTooMuch()` | 移除量 > 储备量 | `"Insufficient reserves"` |

**回滚测试设计原则**：
- 每个 `require` 语句 → 至少一个 revert 测试
- 回滚来自合约层（#24-27, #29-30）→ 精确匹配 revert message
- 回滚来自 ERC20 层（#28）→ 用 `vm.expectRevert()` 无参数匹配任意 revert

---

## 维度 6：重入攻击 (31)

这是面试加分项：AMM swap 函数的 `nonReentrant` 保护。

| # | 测试函数 | 攻击方式 | 防护 |
|---|---|---|---|
| 31 | `test_ReentrancyProtection()` | 恶意 ERC20 在 `transfer()` 中回调攻击者 → 攻击者重入 `swap()` | `ReentrancyGuard` 拦截 → `ReentrancyGuardReentrantCall` |

**攻击流程**：

```
用户调用 swap(tokenA, amt)
  └─ tokenA.transferFrom(user, pool, amt)     ← 正常 ERC20，无回调
  └─ tokenB.transfer(user, output)             ← 恶意 ERC20！
       └─ MaliciousERC20 覆盖 transfer()
            └─ 回调 user.onTokenReceived()
                 └─ AttackContract 调用 swap()  ← 重入！
                      └─ nonReentrant 拦截 ✋
                           ReentrancyGuardReentrantCall revert
```

**为什么需要 MaliciousERC20？** — 标准 ERC20 的 `transfer` 不触发接收方回调。真实世界中有 ERC777（带 `tokensReceived` 钩子），攻击者用 ERC777 作为输出 token 即可发动重入。本测试用 `MaliciousERC20` 模拟 ERC777 行为来验证 `nonReentrant` 有效。

**辅助合约**：
- `MaliciousERC20` — 继承 SimpleToken，覆盖 `transfer()` 添加接收方回调
- `ReentrantAttacker` — 接收回调后尝试再次调用 `swap()`

---

## 测试环境设计

```
setUp() 初始化：
├── tokenA = new SimpleToken()          // 测试合约获得 1000 TKA（构造 mint）
├── tokenB = new SimpleToken()          // 测试合约获得 1000 TKB
├── pool = new SimplePool(A, B)
├── pool.addLiquidity(1000, 1000)       // 1:1 初始比例
├── alice 获得 100 TKA + 授权
└── bob 获得 100 TKB + 授权
```

| 角色 | TKA | TKB | 用途 |
|---|---|---|---|
| 测试合约 | 0（全入池）+ 无限 mint 权 | 0 + 无限 mint 权 | 添加/移除流动性测试 |
| alice | 100 | 0 | TKA→TKB swap、往返测试 |
| bob | 0 | 100 | TKB→TKA swap |
| charlie | 按需 mint | 按需 mint | 权限和回滚测试 |
| stranger | 按需 mint | 按需 mint | 权限测试 |

---

## 扩展方向

以下测试可在未来加入（目前未覆盖）：

| 话题 | 说明 |
|---|---|
| **Fuzz swap** | 随机金额的 swap 验证 k 始终不减、输出 ≤ 预测 |
| **Fuzz 往返** | 随机金额 A→B→A 始终亏损 |
| **三明治攻击** | 构造 front-run + back-run 场景，验证滑点保护 |
| **价格操纵** | 大额 swap 导致价格偏移，验证 getPrice 更新 |
| **精度损失** | 极小储备 + 极小输入的组合，验证输出归零处理 |
| **Gas 基准** | 已通过 `forge snapshot --check` 在 CI 中执行 |

---

## 运行命令

```bash
# 运行全部 Pool 测试
forge test --match-path test/Pool.t.sol -vvv

# 只运行回滚测试
forge test --match-path test/Pool.t.sol --match-test test_Revert -vvv

# 只运行不变量测试
forge test --match-path test/Pool.t.sol --match-test test_Swap --match-test test_Constant --match-test test_Balance --match-test test_Round --match-test test_GetAmount -vvv

# 生成 gas 基准
forge snapshot --match-path test/Pool.t.sol
```
