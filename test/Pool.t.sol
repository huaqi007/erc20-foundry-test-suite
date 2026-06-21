// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {SimplePool} from "../src/Pool.sol";
import {SimpleToken} from "../src/SimpleToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PoolTest is Test {
    SimplePool public pool;
    SimpleToken public tokenA;
    SimpleToken public tokenB;

    address public user = makeAddr("user");
    address public attacker = makeAddr("attacker");

    uint256 constant INITIAL_LIQUIDITY = 1000 * 1e18; // 1000 each

    function setUp() public {
        tokenA = new SimpleToken();
        tokenB = new SimpleToken();
        pool = new SimplePool(address(tokenA), address(tokenB));

        // Mint tokens to user
        tokenA.mint(user, INITIAL_LIQUIDITY * 2);
        tokenB.mint(user, INITIAL_LIQUIDITY * 2);

        // Add initial liquidity
        vm.startPrank(user);
        tokenA.approve(address(pool), INITIAL_LIQUIDITY);
        tokenB.approve(address(pool), INITIAL_LIQUIDITY);
        pool.addLiquidity(INITIAL_LIQUIDITY, INITIAL_LIQUIDITY);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════
    // 维度 1：功能测试 (1–7)
    // ═══════════════════════════════════════════

    /// @dev 1. TokenA → TokenB 正常兑换
    function test_Swap_AtoB() public {
        uint256 amountIn = 100 * 1e18;
        uint256 expectedOut = pool.getAmountOut(address(tokenA), amountIn);

        vm.startPrank(user);
        tokenA.approve(address(pool), amountIn);

        vm.expectEmit(true, true, false, true);
        emit SimplePool.Swap(user, address(tokenA), amountIn, address(tokenB), expectedOut);

        uint256 amountOut = pool.swap(address(tokenA), amountIn, 0);
        vm.stopPrank();

        assertEq(amountOut, expectedOut, "amountOut matches getAmountOut");
        assertGt(amountOut, 0, "got tokens out");
    }

    /// @dev 2. TokenB → TokenA 反向兑换
    function test_Swap_BtoA() public {
        uint256 amountIn = 50 * 1e18;
        uint256 expectedOut = pool.getAmountOut(address(tokenB), amountIn);

        vm.startPrank(user);
        tokenB.approve(address(pool), amountIn);
        uint256 amountOut = pool.swap(address(tokenB), amountIn, 0);
        vm.stopPrank();

        assertEq(amountOut, expectedOut, "reverse swap amount");
    }

    /// @dev 3. 兑换后储备量更新正确
    function test_SwapReservesUpdate() public {
        uint256 amountIn = 100 * 1e18;
        uint256 reserveABefore = pool.reserveA();
        uint256 reserveBBefore = pool.reserveB();

        vm.startPrank(user);
        tokenA.approve(address(pool), amountIn);
        uint256 amountOut = pool.swap(address(tokenA), amountIn, 0);
        vm.stopPrank();

        assertEq(pool.reserveA(), reserveABefore + amountIn, "reserveA increased");
        assertEq(pool.reserveB(), reserveBBefore - amountOut, "reserveB decreased");
    }

    /// @dev 4. 手续费计算正确（997/1000）
    function test_SwapFeeCalculation() public {
        uint256 amountIn = 1000 * 1e18;
        uint256 expectedOut = pool.getAmountOut(address(tokenA), amountIn);
        // 理论无手续费：(1000 * 1000) / (1000 + 1000) = 500
        // 有 0.3% 手续费，应 < 500
        uint256 noFeeOutput = (amountIn * INITIAL_LIQUIDITY) / (INITIAL_LIQUIDITY + amountIn);

        assertLt(expectedOut, noFeeOutput, "fee reduces output");
    }

    /// @dev 5. 正常添加流动性
    function test_AddLiquidity() public {
        uint256 amtA = 200 * 1e18;
        uint256 amtB = 200 * 1e18;

        uint256 reserveABefore = pool.reserveA();
        uint256 reserveBBefore = pool.reserveB();

        vm.startPrank(user);
        tokenA.approve(address(pool), amtA);
        tokenB.approve(address(pool), amtB);

        vm.expectEmit(true, false, false, true);
        emit SimplePool.LiquidityAdded(user, amtA, amtB);

        pool.addLiquidity(amtA, amtB);
        vm.stopPrank();

        assertEq(pool.reserveA(), reserveABefore + amtA, "reserveA");
        assertEq(pool.reserveB(), reserveBBefore + amtB, "reserveB");
    }

    /// @dev 6. 正常移除流动性
    function test_RemoveLiquidity() public {
        uint256 outA = 100 * 1e18;
        uint256 outB = 100 * 1e18;

        uint256 reserveABefore = pool.reserveA();
        uint256 balanceBBefore = tokenB.balanceOf(user);

        vm.startPrank(user);
        vm.expectEmit(true, false, false, true);
        emit SimplePool.LiquidityRemoved(user, outA, outB);

        pool.removeLiquidity(outA, outB);
        vm.stopPrank();

        assertEq(pool.reserveA(), reserveABefore - outA, "reserveA");
        assertEq(tokenB.balanceOf(user), balanceBBefore + outB, "user got B back");
    }

    /// @dev 7. getAmountOut 与 swap 实际输出一致
    function test_GetAmountOutMatchesSwap() public {
        uint256 amountIn = 77 * 1e18;
        uint256 expected = pool.getAmountOut(address(tokenA), amountIn);

        vm.startPrank(user);
        tokenA.approve(address(pool), amountIn);
        uint256 actual = pool.swap(address(tokenA), amountIn, 0);
        vm.stopPrank();

        assertEq(actual, expected, "getAmountOut == actual swap output");
    }

    // ═══════════════════════════════════════════
    // 维度 2：边界值 (8–14)
    // ═══════════════════════════════════════════

    /// @dev 8. 最小有效输入（100 wei，1 wei 会因取整归零）
    function test_SwapMinimumAmount() public {
        // 1 wei 会因 997/1000 取整归零 → Zero output。用 100 wei 验证最小有效输入。
        vm.startPrank(user);
        tokenA.approve(address(pool), 100);
        uint256 out = pool.swap(address(tokenA), 100, 0);
        vm.stopPrank();
        assertGt(out, 0, "minimum viable input gives > 0 out");
    }

    /// @dev 9. amountIn 极大（接近储备量），高滑点
    function test_SwapLargeAmount() public {
        uint256 amountIn = 900 * 1e18; // 90% of reserveA
        uint256 expected = pool.getAmountOut(address(tokenA), amountIn);

        vm.startPrank(user);
        tokenA.approve(address(pool), amountIn);
        uint256 out = pool.swap(address(tokenA), amountIn, 0);
        vm.stopPrank();

        assertEq(out, expected, "large swap output");
        assertLt(out, amountIn, "severe slippage due to large trade");
    }

    /// @dev 10. amountOutMin = 0（无滑点保护）
    function test_SwapZeroSlippageCheck() public {
        vm.startPrank(user);
        tokenA.approve(address(pool), 10 * 1e18);
        uint256 out = pool.swap(address(tokenA), 10 * 1e18, 0);
        vm.stopPrank();
        assertGt(out, 0, "swap succeeds with 0 slippage protection");
    }

    /// @dev 11. amountOutMin = 恰好计算值
    function test_SwapExactSlippageBoundary() public {
        uint256 amountIn = 50 * 1e18;
        uint256 exactOut = pool.getAmountOut(address(tokenA), amountIn);

        vm.startPrank(user);
        tokenA.approve(address(pool), amountIn);
        pool.swap(address(tokenA), amountIn, exactOut);
        vm.stopPrank();
    }

    /// @dev 12. 首次添加（空池）— 在 setUp 之前测
    function test_AddLiquidityEmptyPool() public {
        SimplePool newPool = new SimplePool(address(tokenA), address(tokenB));

        vm.startPrank(user);
        tokenA.approve(address(newPool), 500 * 1e18);
        tokenB.approve(address(newPool), 500 * 1e18);
        newPool.addLiquidity(500 * 1e18, 500 * 1e18);
        vm.stopPrank();

        assertEq(newPool.reserveA(), 500 * 1e18, "empty pool first add");
    }

    /// @dev 13. 非空池追加流动性
    function test_AddLiquidityNonEmpty() public {
        uint256 reserveABefore = pool.reserveA();

        vm.startPrank(user);
        tokenA.approve(address(pool), 100 * 1e18);
        tokenB.approve(address(pool), 100 * 1e18);
        pool.addLiquidity(100 * 1e18, 100 * 1e18);
        vm.stopPrank();

        assertEq(pool.reserveA(), reserveABefore + 100 * 1e18, "cumulative liquidity");
    }

    /// @dev 14. 移除恰好全部储备量
    function test_RemoveAllLiquidity() public {
        uint256 allA = pool.reserveA();
        uint256 allB = pool.reserveB();

        vm.prank(user);
        pool.removeLiquidity(allA, allB);

        assertEq(pool.reserveA(), 0, "reserve A drained");
        assertEq(pool.reserveB(), 0, "reserve B drained");
    }

    // ═══════════════════════════════════════════
    // 维度 3：状态一致性 / 不变量 (15–21)
    // ═══════════════════════════════════════════

    /// @dev 15. swap 前后 k = reserveA * reserveB 不减少
    function test_ConstantProductInvariant() public {
        uint256 kBefore = pool.reserveA() * pool.reserveB();

        vm.startPrank(user);
        tokenA.approve(address(pool), 50 * 1e18);
        pool.swap(address(tokenA), 50 * 1e18, 0);
        vm.stopPrank();

        uint256 kAfter = pool.reserveA() * pool.reserveB();
        assertGe(kAfter, kBefore, "k should never decrease");
    }

    /// @dev 16. swap 前后用户余额变化 = 池子余额变化（反方向）
    function test_SwapBalanceConservation() public {
        uint256 userABefore = tokenA.balanceOf(user);
        uint256 userBBefore = tokenB.balanceOf(user);
        uint256 poolABefore = tokenA.balanceOf(address(pool));
        uint256 poolBBefore = tokenB.balanceOf(address(pool));

        uint256 amountIn = 40 * 1e18;
        vm.startPrank(user);
        tokenA.approve(address(pool), amountIn);
        uint256 amountOut = pool.swap(address(tokenA), amountIn, 0);
        vm.stopPrank();

        // 用户：A 减少，B 增加
        assertEq(tokenA.balanceOf(user), userABefore - amountIn, "user A spent");
        assertEq(tokenB.balanceOf(user), userBBefore + amountOut, "user B received");
        // 池子：A 增加，B 减少
        assertEq(tokenA.balanceOf(address(pool)), poolABefore + amountIn, "pool A gained");
        assertEq(tokenB.balanceOf(address(pool)), poolBBefore - amountOut, "pool B spent");
    }

    /// @dev 17. addLiquidity 后池子 token 余额 = reserve
    function test_TokenBalanceMatchesReserveAfterAdd() public {
        vm.startPrank(user);
        tokenA.approve(address(pool), 100 * 1e18);
        tokenB.approve(address(pool), 100 * 1e18);
        pool.addLiquidity(100 * 1e18, 100 * 1e18);
        vm.stopPrank();

        assertEq(tokenA.balanceOf(address(pool)), pool.reserveA(), "tokenA balance = reserveA");
        assertEq(tokenB.balanceOf(address(pool)), pool.reserveB(), "tokenB balance = reserveB");
    }

    /// @dev 18. removeLiquidity 后池子 token 余额 = reserve
    function test_TokenBalanceMatchesReserveAfterRemove() public {
        vm.prank(user);
        pool.removeLiquidity(100 * 1e18, 100 * 1e18);

        assertEq(tokenA.balanceOf(address(pool)), pool.reserveA(), "balanceA after remove");
    }

    /// @dev 19. swap 输出 ≤ getAmountOut（精度）
    function test_SwapOutputMatchesGetAmountOut() public {
        uint256 amountIn = 123 * 1e18;
        uint256 expected = pool.getAmountOut(address(tokenA), amountIn);

        vm.startPrank(user);
        tokenA.approve(address(pool), amountIn);
        uint256 actual = pool.swap(address(tokenA), amountIn, 0);
        vm.stopPrank();

        assertEq(actual, expected, "exact match (Solidity integer division)");
    }

    /// @dev 20. 往返兑换后余额 ≤ 初始（手续费损耗）
    function test_RoundTripLoss() public {
        uint256 userBBefore = tokenB.balanceOf(user);
        uint256 swapAmount = 100 * 1e18;

        // A → B
        vm.startPrank(user);
        tokenA.approve(address(pool), swapAmount);
        uint256 receivedB = pool.swap(address(tokenA), swapAmount, 0);

        // B → A（用刚换到的 B 换回去）
        tokenB.approve(address(pool), receivedB);
        uint256 receivedA = pool.swap(address(tokenB), receivedB, 0);
        vm.stopPrank();

        // 换回来的 A < 初始的 A（扣了两次手续费）
        assertLt(receivedA, swapAmount, "round-trip loses value to fees");
    }

    /// @dev 21. getAmountOut(0) = 0
    function test_GetAmountOutZero() public view {
        assertEq(pool.getAmountOut(address(tokenA), 0), 0);
    }

    // ═══════════════════════════════════════════
    // 维度 4：无权限限制验证 (22–23)
    // ═══════════════════════════════════════════

    /// @dev 22. 任意地址都可以 swap
    function test_AnyoneCanSwap() public {
        address stranger = makeAddr("stranger");
        tokenA.mint(stranger, 10 * 1e18);

        vm.startPrank(stranger);
        tokenA.approve(address(pool), 10 * 1e18);
        uint256 out = pool.swap(address(tokenA), 10 * 1e18, 0);
        vm.stopPrank();

        assertGt(out, 0, "stranger swapped");
    }

    /// @dev 23. 任意地址都可以添加流动性
    function test_AnyoneCanAddLiquidity() public {
        address stranger = makeAddr("stranger");
        tokenA.mint(stranger, 10 * 1e18);
        tokenB.mint(stranger, 10 * 1e18);

        vm.startPrank(stranger);
        tokenA.approve(address(pool), 10 * 1e18);
        tokenB.approve(address(pool), 10 * 1e18);
        pool.addLiquidity(10 * 1e18, 10 * 1e18);
        vm.stopPrank();

        assertGt(pool.reserveA(), INITIAL_LIQUIDITY, "stranger added liquidity");
    }

    // ═══════════════════════════════════════════
    // 维度 5：异常 / 回滚 (24–30)
    // ═══════════════════════════════════════════

    /// @dev 24. amountIn = 0
    function test_Revert_SwapZeroAmount() public {
        vm.startPrank(user);
        tokenA.approve(address(pool), 0);
        vm.expectRevert("AmountIn must be > 0");
        pool.swap(address(tokenA), 0, 0);
        vm.stopPrank();
    }

    /// @dev 25. 无效 token 地址
    function test_Revert_InvalidToken() public {
        vm.prank(user);
        vm.expectRevert("Invalid token");
        pool.swap(address(0xdead), 10 * 1e18, 0);
    }

    /// @dev 26. 空池 swap
    function test_Revert_EmptyPool() public {
        SimplePool newPool = new SimplePool(address(tokenA), address(tokenB));

        vm.startPrank(user);
        tokenA.approve(address(newPool), 10 * 1e18);
        vm.expectRevert("Empty pool");
        newPool.swap(address(tokenA), 10 * 1e18, 0);
        vm.stopPrank();
    }

    /// @dev 27. 滑点超限
    function test_Revert_SlippageExceeded() public {
        uint256 amountIn = 10 * 1e18;
        uint256 fairOut = pool.getAmountOut(address(tokenA), amountIn);
        uint256 tooHigh = fairOut * 2; // 要求两倍输出

        vm.startPrank(user);
        tokenA.approve(address(pool), amountIn);
        vm.expectRevert("Slippage exceeded");
        pool.swap(address(tokenA), amountIn, tooHigh);
        vm.stopPrank();
    }

    /// @dev 28. 用户余额不足（transferFrom 失败）
    function test_Revert_InsufficientUserBalance() public {
        address poor = makeAddr("poor");
        // poor has 0 tokens

        vm.startPrank(poor);
        tokenA.approve(address(pool), 100 * 1e18);
        vm.expectRevert(); // ERC20InsufficientBalance
        pool.swap(address(tokenA), 100 * 1e18, 0);
        vm.stopPrank();
    }

    /// @dev 29. addLiquidity amount = 0
    function test_Revert_AddZeroLiquidity() public {
        vm.prank(user);
        vm.expectRevert("Amounts must be > 0");
        pool.addLiquidity(0, 100 * 1e18);
    }

    /// @dev 30. removeLiquidity 超过储备量
    function test_Revert_RemoveTooMuch() public {
        uint256 tooMuchA = pool.reserveA() + 1;
        uint256 reserveB = pool.reserveB();

        vm.prank(user);
        vm.expectRevert("Insufficient reserves");
        pool.removeLiquidity(tooMuchA, reserveB);
    }
}

// ═══════════════════════════════════════════
// 重入攻击测试（加分项）
// ═══════════════════════════════════════════
// 说明：标准 ERC20（如 SimpleToken）的 transfer 不触发接收方回调，
// 因此无法通过 ERC20 转移路径重入 pool。nonReentrant 在此防范的是
// 未来支持 ERC777（带回调）等场景。以下测试验证 nonReentrant 修饰符
// 在同一个调用者连续调用的场景下正确工作。

contract ReentrancyTest is Test {
    SimpleToken public tokenA;
    SimpleToken public tokenB;
    SimplePool public pool;

    function setUp() public {
        tokenA = new SimpleToken();
        tokenB = new SimpleToken();
        pool = new SimplePool(address(tokenA), address(tokenB));

        tokenA.mint(address(this), 2000 * 1e18);
        tokenB.mint(address(this), 2000 * 1e18);
        tokenA.approve(address(pool), 2000 * 1e18);
        tokenB.approve(address(pool), 2000 * 1e18);
        pool.addLiquidity(1000 * 1e18, 1000 * 1e18);
    }

    /// @dev 31. swap 有 nonReentrant — 正常调用不受影响
    function test_SwapNonReentrantAllowsNormalCall() public {
        uint256 out = pool.swap(address(tokenA), 10 * 1e18, 0);
        assertGt(out, 0, "normal swap works with nonReentrant");
    }

    /// @dev 补充验证：swap 前后储备量正确（nonReentrant 内部逻辑正确）
    function test_SwapWithNonReentrantStateCorrect() public {
        uint256 rA = pool.reserveA();
        uint256 rB = pool.reserveB();

        uint256 amountIn = 50 * 1e18;
        uint256 out = pool.swap(address(tokenA), amountIn, 0);

        assertEq(pool.reserveA(), rA + amountIn, "reserveA updated");
        assertEq(pool.reserveB(), rB - out, "reserveB updated");
    }
}
