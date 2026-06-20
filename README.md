# ERC20 全场景测试套件

基于 Foundry 的 ERC20 代币完整测试体系，覆盖 5 个维度 32 个场景。

## 项目结构

```
src/SimpleToken.sol       # ERC20 合约（基于 OpenZeppelin）
test/SimpleToken.t.sol    # 32 个测试用例
TESTCASES.md              # 完整测试用例文档
```

## 测试覆盖

| 维度 | 场景数 | 说明 |
|------|--------|------|
| 功能测试 | 5 | 正常路径 + 事件验证 |
| 边界值 | 9 | 0 值、最大值、归零 |
| 状态一致性 | 8 | totalSupply 不变量 |
| 权限控制 | 3 | onlyOwner 守卫 |
| 异常回滚 | 7 | address(0)、超余额 |

## 快速开始

```bash
git clone https://github.com/huaqi007/erc20-foundry-test-suite.git
cd erc20-foundry-test-suite
forge test -vvv
```

## 要求

- Foundry (forge)
- Solidity ^0.8.20
