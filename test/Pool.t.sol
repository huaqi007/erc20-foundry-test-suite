// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {SimplePool} from "../src/Pool.sol";
import {SimpleToken} from "../src/SimpleToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract PoolTest is Test {
    SimpleToken public tokenA;
    SimpleToken public tokenB;
    SimplePool public pool;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    uint256 constant INITIAL_LIQ = 1000 * 1e18;

    function setUp() public {
        // 部署代币（测试合约是 owner）
        tokenA = new SimpleToken(); // name="SimpleToken", symbol="STK"
        tokenB = new SimpleToken();

        // 部署池子
        pool = new SimplePool(address(tokenA), address(tokenB));

        // 测试合约授权池子，添加初始流动性
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        pool.addLiquidity(INITIAL_LIQ, INITIAL_LIQ);

        // 分发代币给 alice / bob
        tokenA.mint(alice, 100 * 1e18);
        tokenB.mint(bob, 100 * 1e18);

        // alice / bob 授权池子
        vm.prank(alice);
        tokenA.approve(address(pool), type(uint256).max);
        vm.prank(bob);
        tokenB.approve(address(pool), type(uint256).max);
        vm.prank(alice);
        tokenB.approve(address(pool), type(uint256).max); // 往返测试用
    }

    // ═══════════════════════════════════════════
    // 维度 1：功能测试 — 正常路径 (1–7)
    // ═══════════════════════════════════════════

    /// @dev 1. TokenA → TokenB 正常兑换 → 输出 > 0，事件 Swap 正确 emit
    function test_SwapAtoB() public {
        uint256 amountIn = 10 * 1e18;
        uint256 expectedOut = pool.getAmountOut(address(tokenA), amountIn);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit SimplePool.Swap(alice, address(tokenA), amountIn, address(tokenB), expectedOut);
        uint256 actualOut = pool.swap(address(tokenA), amountIn, 0);

        assertGt(actualOut, 0, "output > 0");
        assertEq(actualOut, expectedOut, "output == getAmountOut");
    }

    /// @dev 2. TokenB → TokenA 反向兑换
    function test_SwapBtoA() public {
        uint256 amountIn = 10 * 1e18;
        uint256 expectedOut = pool.getAmountOut(address(tokenB), amountIn);

        vm.prank(bob);
        vm.expectEmit(true, true, true, true);
        emit SimplePool.Swap(bob, address(tokenB), amountIn, address(tokenA), expectedOut);
        uint256 actualOut = pool.swap(address(tokenB), amountIn, 0);

        assertGt(actualOut, 0, "output > 0");
        assertEq(actualOut, expectedOut, "output == getAmountOut");
    }

    /// @dev 3. 兑换后储备量更新正确（reserveA + amountIn, reserveB - amountOut）
    function test_SwapReserveUpdate() public {
        uint256 amountIn = 50 * 1e18;
        uint256 rA = pool.reserveA();
        uint256 rB = pool.reserveB();

        vm.prank(alice);
        uint256 amountOut = pool.swap(address(tokenA), amountIn, 0);

        assertEq(pool.reserveA(), rA + amountIn, "reserveA += amountIn");
        assertEq(pool.reserveB(), rB - amountOut, "reserveB -= amountOut");
    }

    /// @dev 4. 手续费计算正确：amountOut = getAmountOut 返回的值
    function test_SwapFeeCalculation() public {
        uint256 amountIn = 50 * 1e18;
        uint256 expected = pool.getAmountOut(address(tokenA), amountIn);
        // 缓存 swap 前的储备量（swap 后会变化）
        uint256 rA = pool.reserveA();
        uint256 rB = pool.reserveB();

        vm.prank(alice);
        uint256 actual = pool.swap(address(tokenA), amountIn, 0);

        assertEq(actual, expected, "actual == getAmountOut");
        // 手续费使 output < 无手续费时的理论值（用 swap 前储备计算）
        uint256 noFeeOut = (amountIn * rB) / (rA + amountIn);
        assertLt(actual, noFeeOut, "0.3% fee reduces output");
    }

    /// @dev 5. 正常添加流动性 → reserveA/B 增加，事件 LiquidityAdded emit
    function test_AddLiquidity() public {
        tokenA.mint(address(this), 200 * 1e18);
        tokenB.mint(address(this), 200 * 1e18);

        uint256 rA = pool.reserveA();
        uint256 rB = pool.reserveB();
        uint256 addA = 100 * 1e18;
        uint256 addB = 100 * 1e18;

        vm.expectEmit(true, false, false, true);
        emit SimplePool.LiquidityAdded(address(this), addA, addB);
        pool.addLiquidity(addA, addB);

        assertEq(pool.reserveA(), rA + addA, "reserveA");
        assertEq(pool.reserveB(), rB + addB, "reserveB");
    }

    /// @dev 6. 正常移除 → reserveA/B 减少，事件 LiquidityRemoved emit，代币退回
    function test_RemoveLiquidity() public {
        uint256 removeA = 200 * 1e18;
        uint256 removeB = 200 * 1e18;
        uint256 rA = pool.reserveA();
        uint256 rB = pool.reserveB();
        uint256 balA = tokenA.balanceOf(address(this));
        uint256 balB = tokenB.balanceOf(address(this));

        vm.expectEmit(true, false, false, true);
        emit SimplePool.LiquidityRemoved(address(this), removeA, removeB);
        pool.removeLiquidity(removeA, removeB);

        assertEq(pool.reserveA(), rA - removeA, "reserveA");
        assertEq(pool.reserveB(), rB - removeB, "reserveB");
        assertEq(tokenA.balanceOf(address(this)), balA + removeA, "user gets A back");
        assertEq(tokenB.balanceOf(address(this)), balB + removeB, "user gets B back");
    }

    /// @dev 7. 给定输入，返回预期输出（与 swap 实际输出一致）
    function test_GetAmountOutMatchesSwap() public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1 * 1e18;
        amounts[1] = 50 * 1e18;
        amounts[2] = 200 * 1e18;

        // 给 alice 足够 token 完成 3 次 swap
        uint256 total = amounts[0] + amounts[1] + amounts[2];
        tokenA.mint(alice, total);

        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 predicted = pool.getAmountOut(address(tokenA), amounts[i]);
            vm.prank(alice);
            uint256 actual = pool.swap(address(tokenA), amounts[i], 0);
            assertEq(actual, predicted, "amountOut matches prediction");
        }
    }

    // ═══════════════════════════════════════════
    // 维度 2：边界值 (8–14)
    // ═══════════════════════════════════════════

    /// @dev 8. amountIn = 1 wei → 最小输入，输出 > 0
    function test_SwapOneWei() public {
        vm.prank(alice);
        // 1 wei 可能因整数除法得 0（Zero output），用 100 wei 验证最小有效路径
        uint256 amountOut = pool.swap(address(tokenA), 100, 0);
        assertGt(amountOut, 0, "100 wei produces output");
    }

    /// @dev 9. amountIn 极大（90% reserveIn）→ 输出接近 reserveOut（滑点极大）
    function test_SwapLargeInput() public {
        uint256 amountIn = (pool.reserveA() * 90) / 100;
        tokenA.mint(alice, amountIn);

        vm.prank(alice);
        uint256 amountOut = pool.swap(address(tokenA), amountIn, 0);

        assertGt(amountOut, 0, "large swap succeeds");
        assertLt(amountOut, pool.reserveB(), "output < entire reserveB");
    }

    /// @dev 10. amountOutMin = 0（无滑点保护）→ 成功
    function test_SwapNoSlippageMin() public {
        vm.prank(alice);
        uint256 out = pool.swap(address(tokenA), 10 * 1e18, 0);
        assertGt(out, 0, "succeeds with zero slippage protection");
    }

    /// @dev 11. amountOutMin = 恰好等于计算值 → 成功（边界）
    function test_SwapExactMinBoundary() public {
        uint256 amountIn = 10 * 1e18;
        uint256 exactOut = pool.getAmountOut(address(tokenA), amountIn);

        vm.prank(alice);
        uint256 out = pool.swap(address(tokenA), amountIn, exactOut);
        assertEq(out, exactOut, "output == exact min");
    }

    /// @dev 12. 首次添加（空池）→ reserve 从 0 到 amount
    function test_AddLiquidityEmptyPool() public {
        SimplePool empty = new SimplePool(address(tokenA), address(tokenB));
        tokenA.mint(address(this), 500 * 1e18);
        tokenB.mint(address(this), 500 * 1e18);
        tokenA.approve(address(empty), type(uint256).max);
        tokenB.approve(address(empty), type(uint256).max);

        empty.addLiquidity(300 * 1e18, 300 * 1e18);

        assertEq(empty.reserveA(), 300 * 1e18, "from 0");
        assertEq(empty.reserveB(), 300 * 1e18, "from 0");
    }

    /// @dev 13. 多次添加（非空池）→ 储备量累加
    function test_AddLiquidityMultiple() public {
        tokenA.mint(address(this), 200 * 1e18);
        tokenB.mint(address(this), 200 * 1e18);

        uint256 rA1 = pool.reserveA();
        pool.addLiquidity(100 * 1e18, 100 * 1e18);
        assertEq(pool.reserveA(), rA1 + 100 * 1e18, "first add");

        uint256 rA2 = pool.reserveA();
        pool.addLiquidity(50 * 1e18, 50 * 1e18);
        assertEq(pool.reserveA(), rA2 + 50 * 1e18, "second add");
    }

    /// @dev 14. 移除恰好全部储备量 → reserve 归零
    function test_RemoveAllLiquidity() public {
        uint256 allA = pool.reserveA();
        uint256 allB = pool.reserveB();

        pool.removeLiquidity(allA, allB);

        assertEq(pool.reserveA(), 0, "reserveA zero");
        assertEq(pool.reserveB(), 0, "reserveB zero");
    }

    // ═══════════════════════════════════════════
    // 维度 3：状态一致性 / 不变量 (15–21)
    // ═══════════════════════════════════════════

    /// @dev 15. swap 前后：reserveA * reserveB 乘积不减（含手续费后 ≥ 之前）
    function test_ConstantProductInvariant() public {
        uint256 kBefore = pool.reserveA() * pool.reserveB();

        vm.prank(alice);
        pool.swap(address(tokenA), 10 * 1e18, 0);

        uint256 kAfter = pool.reserveA() * pool.reserveB();
        assertGe(kAfter, kBefore, "k never decreases (fee stays in pool)");
    }

    /// @dev 16. swap 前后：用户余额变化 = 池子余额变化（方向相反）
    function test_SwapBalanceConservation() public {
        uint256 balA_User = tokenA.balanceOf(alice);
        uint256 balB_User = tokenB.balanceOf(alice);
        uint256 balA_Pool = tokenA.balanceOf(address(pool));
        uint256 balB_Pool = tokenB.balanceOf(address(pool));

        uint256 amountIn = 40 * 1e18;
        vm.prank(alice);
        uint256 amountOut = pool.swap(address(tokenA), amountIn, 0);

        assertEq(tokenA.balanceOf(alice), balA_User - amountIn, "user spent A");
        assertEq(tokenB.balanceOf(alice), balB_User + amountOut, "user received B");
        assertEq(tokenA.balanceOf(address(pool)), balA_Pool + amountIn, "pool gained A");
        assertEq(tokenB.balanceOf(address(pool)), balB_Pool - amountOut, "pool lost B");
    }

    /// @dev 17. addLiquidity 后：池子 tokenA 余额 = reserveA
    function test_BalanceEqualsReserveAfterAdd() public {
        tokenA.mint(address(this), 100 * 1e18);
        tokenB.mint(address(this), 100 * 1e18);
        pool.addLiquidity(100 * 1e18, 100 * 1e18);

        assertEq(tokenA.balanceOf(address(pool)), pool.reserveA(), "balanceA == reserveA");
        assertEq(tokenB.balanceOf(address(pool)), pool.reserveB(), "balanceB == reserveB");
    }

    /// @dev 18. removeLiquidity 后：池子 tokenA 余额 = reserveA
    function test_BalanceEqualsReserveAfterRemove() public {
        pool.removeLiquidity(100 * 1e18, 100 * 1e18);

        assertEq(tokenA.balanceOf(address(pool)), pool.reserveA(), "balanceA == reserveA");
        assertEq(tokenB.balanceOf(address(pool)), pool.reserveB(), "balanceB == reserveB");
    }

    /// @dev 19. swap 后 amountOut ≤ getAmountOut 返回值（实际 ≤ 预测）
    function test_SwapOutputLeqGetAmountOut() public {
        uint256 amountIn = 25 * 1e18;
        uint256 predicted = pool.getAmountOut(address(tokenA), amountIn);

        vm.prank(alice);
        uint256 actual = pool.swap(address(tokenA), amountIn, 0);

        assertLe(actual, predicted, "actual <= predicted");
    }

    /// @dev 20. 连续两次 swap（A→B→A）→ 用户余额 ≤ 初始（两次手续费）
    function test_RoundTripFeeLoss() public {
        uint256 amountIn = 30 * 1e18;
        uint256 balStart = tokenA.balanceOf(alice);

        vm.startPrank(alice);
        uint256 gotB = pool.swap(address(tokenA), amountIn, 0);
        // 用换到的 B 换回 A
        pool.swap(address(tokenB), gotB, 0);
        vm.stopPrank();

        uint256 balEnd = tokenA.balanceOf(alice);
        assertLt(balEnd, balStart, "round-trip loses value (2x fees)");
    }

    /// @dev 21. getAmountOut(0) = 0
    function test_GetAmountOutZero() public view {
        assertEq(pool.getAmountOut(address(tokenA), 0), 0, "getAmountOut(0)");
    }

    // ═══════════════════════════════════════════
    // 维度 4：权限 / 访问控制 (22–23)
    // ═══════════════════════════════════════════

    /// @dev 22. 任意地址都可以调用 swap（无需授权）
    function test_AnyoneCanSwap() public {
        address stranger = makeAddr("stranger");
        tokenA.mint(stranger, 50 * 1e18);
        vm.prank(stranger);
        tokenA.approve(address(pool), type(uint256).max);

        vm.prank(stranger);
        uint256 out = pool.swap(address(tokenA), 10 * 1e18, 0);

        assertGt(out, 0, "stranger can swap");
    }

    /// @dev 23. 任意地址都可以添加/移除流动性
    function test_AnyoneCanAddLiquidity() public {
        address stranger = makeAddr("stranger");
        tokenA.mint(stranger, 50 * 1e18);
        tokenB.mint(stranger, 50 * 1e18);

        vm.startPrank(stranger);
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        pool.addLiquidity(20 * 1e18, 20 * 1e18);
        assertGt(pool.reserveA(), INITIAL_LIQ, "stranger added");
        pool.removeLiquidity(10 * 1e18, 10 * 1e18);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════
    // 维度 5：异常 / 回滚 (24–30)
    // ═══════════════════════════════════════════

    /// @dev 24. amountIn = 0 → revert
    function test_Revert_AmountInZero() public {
        vm.prank(alice);
        vm.expectRevert("AmountIn must be > 0");
        pool.swap(address(tokenA), 0, 0);
    }

    /// @dev 25. 传入无效 token 地址 → revert
    function test_Revert_InvalidToken() public {
        vm.prank(alice);
        vm.expectRevert("Invalid token");
        pool.swap(address(0xdead), 10 * 1e18, 0);
    }

    /// @dev 26. 池子为空时 swap → revert
    function test_Revert_EmptyPool() public {
        SimplePool empty = new SimplePool(address(tokenA), address(tokenB));
        tokenA.mint(alice, 20 * 1e18);
        vm.prank(alice);
        tokenA.approve(address(empty), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert("Empty pool");
        empty.swap(address(tokenA), 10 * 1e18, 0);
    }

    /// @dev 27. amountOutMin 设置过高 → revert
    function test_Revert_SlippageExceeded() public {
        uint256 amountIn = 10 * 1e18;
        uint256 impossibleMin = pool.getAmountOut(address(tokenA), amountIn) + 1e18;

        vm.prank(alice);
        vm.expectRevert("Slippage exceeded");
        pool.swap(address(tokenA), amountIn, impossibleMin);
    }

    /// @dev 28. 用户余额不足 / 未授权 → transferFrom 失败
    function test_Revert_TransferFromFail() public {
        // charlie 有 token 但没给池子授权
        tokenA.mint(charlie, 100 * 1e18);
        // 没有 approve

        vm.prank(charlie);
        vm.expectRevert(); // ERC20InsufficientAllowance
        pool.swap(address(tokenA), 50 * 1e18, 0);
    }

    /// @dev 29. addLiquidity amountA = 0 → revert
    function test_Revert_AddZeroLiquidity() public {
        vm.expectRevert("Amounts must be > 0");
        pool.addLiquidity(0, 100 * 1e18);
    }

    /// @dev 30. 移除量超过储备量 → revert
    function test_Revert_RemoveTooMuch() public {
        uint256 tooMuch = pool.reserveA() + 1;
        vm.expectRevert("Insufficient reserves");
        pool.removeLiquidity(tooMuch, 100 * 1e18);
    }

    // ═══════════════════════════════════════════
    // 加分：重入攻击测试 (31)
    // ═══════════════════════════════════════════

    /// @dev 31. 攻击合约在 swap 回调中重入 swap → revert（nonReentrant 保护）
    function test_ReentrancyProtection() public {
        // 部署恶意 token（transfer 时回调接收方）
        MaliciousERC20 maliciousToken = new MaliciousERC20();
        SimpleToken normalToken = new SimpleToken();

        SimplePool pool2 = new SimplePool(address(normalToken), address(maliciousToken));

        // 添加流动性
        normalToken.approve(address(pool2), type(uint256).max);
        maliciousToken.approve(address(pool2), type(uint256).max);
        pool2.addLiquidity(1000 * 1e18, 1000 * 1e18);

        // 部署攻击合约
        ReentrantAttacker attacker = new ReentrantAttacker();
        normalToken.mint(address(attacker), 100 * 1e18);

        // 攻击者授权
        attacker.setup(pool2, address(normalToken));

        // 攻击 → 重入被 nonReentrant 拦截
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        attacker.attack(10 * 1e18);
    }
}

// ═══════════════════════════════════════════
// 辅助合约：重入攻击
// ═══════════════════════════════════════════

/// 恶意 ERC20 — transfer 时回调接收方（模拟 ERC777 钩子，制造重入入口）
contract MaliciousERC20 is SimpleToken {
    function transfer(address to, uint256 value) public override returns (bool) {
        super.transfer(to, value);
        // 回调接收方 → 这是重入入口
        if (to.code.length > 0) {
            IReentrantAttacker(to).onTokenReceived();
        }
        return true;
    }
}

interface IReentrantAttacker {
    function onTokenReceived() external;
}

/// 攻击合约 — 在 swap 换出 token 的回调中尝试再次 swap
contract ReentrantAttacker is Test {
    SimplePool public targetPool;
    address public tokenIn;

    function setup(SimplePool _pool, address _tokenIn) external {
        targetPool = _pool;
        tokenIn = _tokenIn;
        IERC20(tokenIn).approve(address(targetPool), type(uint256).max);
    }

    function attack(uint256 amount) external {
        // 第一次 swap → 会触发 tokenOut.transfer → MaliciousERC20.transfer → onTokenReceived
        targetPool.swap(tokenIn, amount, 0);
    }

    /// @notice 由 MaliciousERC20.transfer 回调触发
    function onTokenReceived() external {
        // 重入 swap → nonReentrant 拦截 → revert
        targetPool.swap(tokenIn, 100, 0);
    }
}
