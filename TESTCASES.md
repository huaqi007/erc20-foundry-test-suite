# ERC20 全场景测试用例文档

> **合约**：SimpleToken（基于 OpenZeppelin ERC20 + Ownable）
> **功能**：mint(onlyOwner) / transfer / approve / transferFrom / burnFrom(onlyOwner)
> **测试框架**：Foundry
> **测试文件**：`test/SimpleToken.t.sol`

---

## 测试覆盖总览

```
32 个测试场景，5 个维度，0 失败

维度 1  功能测试    5 个  正常路径验证 + 事件验证
维度 2  边界值      9 个  0 值、最大值、全部余额、归零
维度 3  状态一致性  8 个  totalSupply 不变量、余额守恒
维度 4  权限控制    3 个  onlyOwner 守卫
维度 5  异常回滚    7 个  address(0)、超余额、超授权
```

---

## 维度 1：功能测试（正常路径）

验证每个函数的基本行为是否符合 ERC20 规范。

### 1. test_MintToAlice — 铸造代币

```
前置条件：owner 部署合约，初始供应量 1000 STK
操作：owner 调用 mint(alice, 500 STK)
验证：
  ├── alice 余额 = 500 STK
  ├── totalSupply = 初始 + 500 STK
  └── 事件 Transfer(address(0), alice, 500 STK) 已 emit
逻辑：_mint 从零地址铸造，增加目标地址余额和总供应量
```

### 2. test_Transfer — 普通转账

```
前置条件：alice 有 200 STK
操作：alice 调用 transfer(bob, 200 STK)
验证：
  ├── alice 余额 = 0
  ├── bob 余额 = 200 STK
  └── 事件 Transfer(alice, bob, 200 STK) 已 emit
逻辑：标准转账，发送者减少，接收者增加
```

### 3. test_Approve — 授权

```
前置条件：alice 有 300 STK
操作：alice 调用 approve(bob, 300 STK)
验证：
  ├── allowance(alice, bob) = 300 STK
  └── 事件 Approval(alice, bob, 300 STK) 已 emit
逻辑：授权不会改变任何人的余额
```

### 4. test_TransferFrom — 代理转账

```
前置条件：alice 有 300 STK，alice 授权 bob 300 STK
操作：bob 调用 transferFrom(alice, charlie, 100 STK)
验证：
  ├── alice 余额 = 200 STK  （-100）
  ├── charlie 余额 = 100 STK （+100）
  ├── allowance(alice, bob) = 200 STK （-100）
  └── 事件 Transfer(alice, charlie, 100 STK) 已 emit
逻辑：被授权方从授权方账户转出代币，同时扣减授权额度
```

### 5. test_BurnFrom — 销毁代币

```
前置条件：alice 有 200 STK
操作：owner 调用 burnFrom(alice, 50 STK)
验证：
  ├── alice 余额 = 150 STK
  ├── totalSupply = 操作前 - 50 STK
  └── 事件 Transfer(alice, address(0), 50 STK) 已 emit
逻辑：_burn 将代币发送到零地址，等同于销毁
```

---

## 维度 2：边界值测试

验证函数在极限值和特殊值下的行为。

### 6. test_MintZero — mint(0)

```
操作：owner mint(alice, 0)
验证：alice 余额不变，totalSupply 不变
逻辑：铸造 0 个代币是合法操作，不应改变任何状态
```

### 7. test_MintOneWei — mint(1)

```
操作：owner mint(alice, 1 wei)
验证：alice 余额 = 1 wei，totalSupply += 1
逻辑：最小有效铸造量，验证精度边界
```

### 8. test_TransferZero — transfer(0)

```
操作：owner transfer(alice, 0)
验证：双方余额不变
逻辑：转账 0 个代币是合法操作
```

### 9. test_TransferFullBalance — 转出全部余额

```
前置条件：alice 有 300 STK
操作：alice transfer(bob, 300 STK)
验证：alice 余额 = 0，bob 余额 = 300 STK
逻辑：余额清零是合法的边界操作
```

### 10. test_ApproveMax — 最大授权

```
操作：owner approve(alice, type(uint256).max)
验证：allowance = 2^256 - 1
逻辑：授权最大值是 DeFi 常见操作（避免重复授权）
```

### 11. test_ApproveZeroToCancel — 授权归零

```
前置条件：owner 已授权 alice 500 STK
操作：owner approve(alice, 0)
验证：allowance = 0
逻辑：授权 0 是取消授权的标准方式
```

### 12. test_TransferFromExactAllowance — 恰好等于授权额度

```
前置条件：alice 授权 bob 100 STK
操作：bob transferFrom(alice, charlie, 100 STK)
验证：转账成功，剩余 allowance = 0
逻辑：授权额度恰好用完是边界情况，不应 revert
```

### 13. test_BurnZero — burn(0)

```
前置条件：alice 有 100 STK
操作：owner burnFrom(alice, 0)
验证：alice 余额不变，totalSupply 不变
逻辑：销毁 0 个代币是合法操作
```

### 14. test_BurnFullBalance — 销毁全部余额

```
前置条件：alice 有 200 STK
操作：owner burnFrom(alice, 200 STK)
验证：alice 余额 = 0，totalSupply -= 200 STK
逻辑：销毁全部余额是合法的边界操作
```

---

## 维度 3：状态一致性（不变量）

验证函数执行前后，系统级不变量是否始终成立。

### 15. test_TransferTotalSupplyInvariant — transfer 不改变 totalSupply

```
操作前：totalSupply = S
操作：alice transfer(bob, 100 STK)
操作后：totalSupply = S
逻辑：转账只在账户间移动代币，不创造也不销毁
```

### 16. test_MintTotalSupplyIncreases — mint 增加 totalSupply

```
操作前：totalSupply = S
操作：mint(alice, 500 STK)
操作后：totalSupply = S + 500 STK
逻辑：铸造是创造新代币，总供应量必增
```

### 17. test_BurnTotalSupplyDecreases — burn 减少 totalSupply

```
操作前：totalSupply = S
操作：burnFrom(alice, 100 STK)
操作后：totalSupply = S - 100 STK
逻辑：销毁是移除代币，总供应量必减
```

### 18. test_ApproveDoesNotChangeBalance — approve 不改变余额

```
操作前：owner 余额 = B
操作：approve(alice, 500 STK)
操作后：owner 余额 = B
逻辑：授权只改变 allowance 映射，不影响余额
```

### 19. test_ApproveDoesNotChangeSpenderBalance — approve 不改变被授权方余额

```
操作前：alice 余额 = B
操作：owner approve(alice, 500 STK)
操作后：alice 余额 = B
逻辑：被授权只是获得了"可以转"的权限，不是获得了代币
```

### 20. test_ApproveDoesNotChangeTotalSupply — approve 不改变总供应量

```
操作前：totalSupply = S
操作：owner approve(alice, 500 STK)
操作后：totalSupply = S
逻辑：授权不创造也不销毁代币
```

### 21. test_TransferFromBalances — 中间人余额不变

```
前置条件：bob(中间人) 余额 = B
操作：bob transferFrom(alice, charlie, 100 STK)
操作后：bob 余额 = B（不变）
逻辑：transferFrom 中调用者只是执行方，自己的余额不受影响
```

### 22. test_SumOfBalancesEqualsTotalSupply — 全账户余额之和 = 总供应量

```
操作：向多个地址 mint 不同数量
验证：owner + alice + bob + charlie 的余额之和 = totalSupply
逻辑：这是 ERC20 系统最核心的不变量
```

---

## 维度 4：权限控制

验证 onlyOwner 修饰的函数是否被正确守卫。

### 23. test_MintOnlyOwner — 非 owner 不能 mint

```
操作：alice（非 owner）调用 mint(bob, 100 STK)
期望：revert
逻辑：mint 创造新代币，只应由合约 owner 执行
```

### 24. test_BurnFromOnlyOwner — 非 owner 不能 burn

```
操作：bob（非 owner）调用 burnFrom(alice, 50 STK)
期望：revert
逻辑：销毁他人代币是高危操作，只应由 owner 执行
```

### 25. test_TransferFromWithoutApproval — 未授权不能 transferFrom

```
操作：bob（未获得 alice 授权）调用 transferFrom(alice, charlie, 50 STK)
期望：revert
逻辑：transferFrom 必须先获得授权，这是 ERC20 规范要求
```

---

## 维度 5：异常 / 回滚测试

验证非法操作是否被正确拒绝。

### 26. test_TransferToZeroAddress — 不能转账到零地址

```
操作：owner transfer(address(0), 100 STK)
期望：revert
逻辑：零地址转账 = 永久丢失，ERC20 规范禁止
```

### 27. test_TransferExceedsBalance — 不能转账超过余额

```
操作：owner transfer(alice, 余额+1)
期望：revert
逻辑：余额不足时必须拒绝交易
```

### 28. test_ApproveZeroAddress — 不能授权给零地址

```
操作：owner approve(address(0), 500 STK)
期望：revert
逻辑：授权给零地址没有意义且危险
```

### 29. test_TransferFromToZeroAddress — transferFrom 不能转入零地址

```
前置条件：alice 授权 bob 100 STK
操作：bob transferFrom(alice, address(0), 100 STK)
期望：revert
逻辑：与 transfer 到零地址同理，ERC20 规范禁止
```

### 30. test_TransferFromExceedsAllowance — transferFrom 不能超过授权额度

```
前置条件：alice 授权 bob 100 STK
操作：bob transferFrom(alice, charlie, 200 STK)
期望：revert
逻辑：代理转账不能超出授权方设定的额度
```

### 31. test_BurnExceedsBalance — 不能销毁超过余额的代币

```
前置条件：alice 有 50 STK
操作：owner burnFrom(alice, 100 STK)
期望：revert
逻辑：销毁量不能超过持有量
```

### 32. test_TransferFromZeroSender — 不能从零地址 transferFrom

```
操作：bob transferFrom(address(0), charlie, 100 STK)
期望：revert
逻辑：零地址没有代币，也没有授权
```

---

## 统计

```
维度 1  功能测试     5 / 5  passed   含事件验证
维度 2  边界值       9 / 9  passed
维度 3  状态一致性   8 / 8  passed
维度 4  权限控制     3 / 3  passed
维度 5  异常回滚     7 / 7  passed
──────────────────────────────────
总计               32 / 32 passed  (0 failed)
```

---

## 运行测试

```bash
cd foundry-parctice
forge test -vvv --match-path test/SimpleToken.t.sol
```

## 生成 Gas 快照

```bash
forge snapshot --match-path test/SimpleToken.t.sol
```
