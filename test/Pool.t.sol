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

        // alice 额外 token 用于 fuzz 测试（多次迭代需要大量余额）
        tokenA.mint(alice, 1_000_000 * 1e18);
        tokenB.mint(alice, 1_000_000 * 1e18);
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

    // ═══════════════════════════════════════════
    // 补充：swap 边界 & 并发场景 (32–35)
    // ═══════════════════════════════════════════

    /// @dev 32. swap 后 reserve 归零检查：多次大额 swap 后某一 reserve 接近 0 → 行为验证
    /// 恒定乘积保证 reserve 不会精确归零；但 reserveOut 极小时输出也极小 → 仍可产出 > 0
    function test_Swap_ReserveNearZero_AfterDraining() public {
        // 创建小规模池子 + 巨量 token 供排空用
        SimplePool smallPool = new SimplePool(address(tokenA), address(tokenB));
        uint256 hugeMint = 1_000_000 * 1e18;
        tokenA.mint(address(this), hugeMint);
        tokenB.mint(address(this), hugeMint);
        tokenA.approve(address(smallPool), type(uint256).max);
        tokenB.approve(address(smallPool), type(uint256).max);
        smallPool.addLiquidity(1000 * 1e18, 1000 * 1e18);

        uint256 kBaseline = smallPool.reserveA() * smallPool.reserveB();

        // 多轮大额 A→B swap 排空 reserveB
        // 每轮输入当前 reserveA 的 40%，排空力度随 A 储备增长而递增
        for (uint256 i = 0; i < 15; i++) {
            uint256 rB = smallPool.reserveB();
            if (rB < 1 * 1e18) break; // B 已接近 0，停止排空

            uint256 swapAmt = (smallPool.reserveA() * 40) / 100;
            vm.prank(address(this));
            smallPool.swap(address(tokenA), swapAmt, 0);

            uint256 kCurrent = smallPool.reserveA() * smallPool.reserveB();
            assertGe(kCurrent, kBaseline, "k never decreases during draining");
            kBaseline = kCurrent;
        }

        // 验证 reserveB 已被大幅排空但 > 0（恒定乘积不可能精确归零）
        assertLt(smallPool.reserveB(), (INITIAL_LIQ * 5) / 100, "reserveB drained to < 5% of initial");
        assertGt(smallPool.reserveB(), 0, "reserveB never reaches exactly zero");

        // 极小输入 swap 仍可产出 > 0 的输出
        vm.prank(address(this));
        uint256 tinyOut = smallPool.swap(address(tokenA), 1e15, 0); // 0.001 token
        assertGt(tinyOut, 0, "tiny swap after draining still produces output");
    }

    /// @dev 33. 并发 swap 价格冲击：两个用户先后 swap 同一方向 → 后者成交价劣于前者
    function test_Swap_ConcurrentPriceWorsens() public {
        uint256 amountIn = 30 * 1e18;
        tokenA.mint(bob, amountIn);
        vm.prank(bob);
        tokenA.approve(address(pool), type(uint256).max);

        // 记录 swap 前 A 的价格
        uint256 priceBefore = pool.getPrice(address(tokenA));

        // Alice 先 swap A→B（推高 A 的供给 → A 贬值）
        vm.prank(alice);
        uint256 aliceOut = pool.swap(address(tokenA), amountIn, 0);

        // Bob 用相同金额 swap A→B（在 Alice 之后，价格已被推高）
        vm.prank(bob);
        uint256 bobOut = pool.swap(address(tokenA), amountIn, 0);

        // 验证：相同输入下，Bob 的输出 < Alice 的输出（滑点叠加）
        assertLt(bobOut, aliceOut, "second swapper gets worse price (price impact stacks)");

        // 验证：A 相对于 B 的价格下降（A 供给增加 → 1 A 换更少 B）
        uint256 priceAfter = pool.getPrice(address(tokenA));
        assertLt(priceAfter, priceBefore, "price of A dropped after two swaps");
    }

    /// @dev 34. amountOutMin = type(uint256).max → revert "Slippage exceeded"
    function test_Revert_SlippageExceeded_MaxUint256() public {
        vm.prank(alice);
        vm.expectRevert("Slippage exceeded");
        pool.swap(address(tokenA), 10 * 1e18, type(uint256).max);
    }

    /// @dev 35. constructor 禁止相同 token 地址（已验证，P2 明确覆盖）
    function test_Revert_Constructor_SameToken() public {
        vm.expectRevert("Same token");
        new SimplePool(address(tokenA), address(tokenA));
    }

    // ═══════════════════════════════════════════
    // 补充：addLiquidity 场景 (36–37)
    // ═══════════════════════════════════════════

    /// @dev 36. 非等比例添加流动性 → 产生套利机会
    /// 池子 1000:1000 → 用户以 100:200 添加 → reserve 1100:1200（比例 ≠ 1:1）
    /// → 套利者 swap B→A 将比例拉回，从中获利
    function test_AddLiquidity_NonProportional_CreatesArbitrage() public {
        // 非等比例添加
        tokenA.mint(address(this), 100 * 1e18);
        tokenB.mint(address(this), 200 * 1e18);
        pool.addLiquidity(100 * 1e18, 200 * 1e18);

        assertEq(pool.reserveA(), 1100 * 1e18, "reserveA = 1100");
        assertEq(pool.reserveB(), 1200 * 1e18, "reserveB = 1200");

        // 此时价格偏离 1:1：getPrice(A) = 1200/1100 ≈ 1.09（A 相对 B 更便宜）
        // 套利者 swap B→A：用 B 买便宜的 A，从中获利
        uint256 arbAmountIn = 100 * 1e18;
        tokenB.mint(charlie, arbAmountIn);
        vm.prank(charlie);
        tokenB.approve(address(pool), type(uint256).max);

        uint256 balA_Before = tokenA.balanceOf(charlie);
        vm.prank(charlie);
        uint256 arbOut = pool.swap(address(tokenB), arbAmountIn, 0);

        // 套利者获得 A（利润 = A 的市场价值 - B 的投入）
        assertGt(arbOut, 0, "arbitrageur gets A tokens out");
        assertEq(tokenA.balanceOf(charlie), balA_Before + arbOut, "arbitrageur profits A");

        // 套利后价格向 1:1 回归：B→A swap 增加 B 储备、减少 A 储备 → A 价格上涨
        uint256 priceAfter = pool.getPrice(address(tokenA));
        // getPrice(A) = reserveB / reserveA * 1e18
        // 套利前: 1200/1100 ≈ 1.09e18；套利后: reserveB↑, reserveA↓ → 比例趋近 1e18
        assertGt(priceAfter, 1e18, "price moved back toward original 1:1 equilibrium");
    }

    /// @dev 37. addLiquidity 的 K 不变量验证
    /// K_new = (rA + a) * (rB + b) = rA*rB + rA*b + rB*a + a*b
    /// ≥ K_old + a*b（因为 rA、rB、a、b 均为正）
    function test_AddLiquidity_KInvariantIncrease() public {
        tokenA.mint(address(this), 200 * 1e18);
        tokenB.mint(address(this), 200 * 1e18);

        uint256 rA = pool.reserveA();
        uint256 rB = pool.reserveB();
        uint256 kBefore = rA * rB;
        uint256 addA = 100 * 1e18;
        uint256 addB = 150 * 1e18;

        pool.addLiquidity(addA, addB);

        uint256 kAfter = pool.reserveA() * pool.reserveB();
        // K_new = K_old + rA*b + rB*a + a*b
        uint256 kExpected = kBefore + rA * addB + rB * addA + addA * addB;

        assertEq(kAfter, kExpected, "K_new = K_old + rA*b + rB*a + a*b");
        // 下界约束：至少比 K_old + a*b 大
        assertGe(kAfter, kBefore + addA * addB, "K_new >= K_old + a*b (lower bound)");
    }

    // ═══════════════════════════════════════════
    // 补充：removeLiquidity 场景 (38–41)
    // ═══════════════════════════════════════════

    /// @dev 38. 近似单边移除：removeLiquidity(500e18, 1 wei)
    /// 当前 require 要求两参数均 > 0，但 attacker 可用 1 wei 近似单边移除
    function test_RemoveLiquidity_NearSingleSided() public {
        uint256 removeA = 500 * 1e18;
        uint256 removeB = 1; // 1 wei, 近似单边移除 tokenA

        uint256 rA = pool.reserveA();
        uint256 rB = pool.reserveB();
        uint256 balA = tokenA.balanceOf(address(this));
        uint256 balB = tokenB.balanceOf(address(this));

        pool.removeLiquidity(removeA, removeB);

        assertEq(pool.reserveA(), rA - removeA, "reserveA decreased by 500 tokens");
        assertEq(pool.reserveB(), rB - removeB, "reserveB decreased by only 1 wei");
        assertEq(tokenA.balanceOf(address(this)), balA + removeA, "got A back");
        assertEq(tokenB.balanceOf(address(this)), balB + removeB, "got 1 wei B back");
    }

    /// @dev 39. 单边移除 amountB=0 → revert（require 要求两参数均 > 0）
    function test_Revert_RemoveLiquidity_SingleSidedZero() public {
        vm.expectRevert("Amounts must be > 0");
        pool.removeLiquidity(500 * 1e18, 0);
    }

    /// @dev 40. 全量移除后 K=0 → swap revert "Empty pool"，addLiquidity 成功恢复
    function test_RemoveAllLiquidity_EmptyPoolBehaviors() public {
        uint256 allA = pool.reserveA();
        uint256 allB = pool.reserveB();
        pool.removeLiquidity(allA, allB);

        // 验证 K = 0
        assertEq(pool.reserveA(), 0, "reserveA = 0");
        assertEq(pool.reserveB(), 0, "reserveB = 0");
        assertEq(pool.reserveA() * pool.reserveB(), 0, "K = 0 after full removal");

        // swap → revert "Empty pool"
        tokenA.mint(alice, 100 * 1e18);
        vm.prank(alice);
        vm.expectRevert("Empty pool");
        pool.swap(address(tokenA), 10 * 1e18, 0);

        // addLiquidity → 成功恢复
        // removeLiquidity 已将 token 退回测试合约，无需额外 mint
        pool.addLiquidity(300 * 1e18, 300 * 1e18);
        assertEq(pool.reserveA(), 300 * 1e18, "pool A restored");
        assertEq(pool.reserveB(), 300 * 1e18, "pool B restored");

        // 恢复后 swap 正常
        vm.prank(alice);
        uint256 out = pool.swap(address(tokenA), 10 * 1e18, 0);
        assertGt(out, 0, "swap works after pool restored");
    }

    /// @dev 41. removeLiquidity 后 K 减少验证：K_after = K_old - rA*b - rB*a + a*b
    function test_RemoveLiquidity_KDecreaseVerification() public {
        uint256 rA = pool.reserveA();
        uint256 rB = pool.reserveB();
        uint256 kBefore = rA * rB;
        uint256 removeA = 300 * 1e18;
        uint256 removeB = 200 * 1e18;

        pool.removeLiquidity(removeA, removeB);

        uint256 kAfter = pool.reserveA() * pool.reserveB();
        // K_after = (rA - a) * (rB - b) = rA*rB - rA*b - rB*a + a*b
        uint256 kExpected = kBefore - rA * removeB - rB * removeA + removeA * removeB;

        assertLt(kAfter, kBefore, "K decreases after removal");
        assertEq(kAfter, kExpected, "K_after = K_old - rA*b - rB*a + a*b");
    }

    // ═══════════════════════════════════════════
    // 补充：Fuzz 不变量测试 (42–43)
    // ═══════════════════════════════════════════

    /// @dev 42. Fuzz: 任意合法 swap 参数下 K 不减（P0 — 资金安全核心不变量）
    /// 随机 amountIn ∈ [1, 50e18]，验证每次 swap 后 k 不减反增（手续费留在池中）
    function testFuzz_Swap_KNeverDecreases(uint256 amountIn) public {
        amountIn = bound(amountIn, 1, 50 * 1e18);
        // 跳过余额不足或输出为 0 的 fuzz 迭代（多轮后状态漂移导致）
        vm.assume(tokenA.balanceOf(alice) >= amountIn);
        vm.assume(pool.getAmountOut(address(tokenA), amountIn) > 0);

        uint256 kBefore = pool.reserveA() * pool.reserveB();

        vm.prank(alice);
        pool.swap(address(tokenA), amountIn, 0);

        uint256 kAfter = pool.reserveA() * pool.reserveB();
        assertGe(kAfter, kBefore, "fuzz: k never decreases after swap (fees stay in pool)");
    }

    /// @dev 43. Fuzz: 任意合法 swap 下 amountOut = getAmountOut 预测（P2 — 预测一致性）
    function testFuzz_Swap_AmountOutEqualsGetAmountOut(uint256 amountIn) public {
        amountIn = bound(amountIn, 1, 50 * 1e18);
        vm.assume(tokenA.balanceOf(alice) >= amountIn);
        vm.assume(pool.getAmountOut(address(tokenA), amountIn) > 0);

        uint256 predicted = pool.getAmountOut(address(tokenA), amountIn);

        vm.prank(alice);
        uint256 actual = pool.swap(address(tokenA), amountIn, 0);

        // 单次 swap：getAmountOut 与实际输出使用同一储备 → 应完全一致
        assertEq(actual, predicted, "fuzz: amountOut == getAmountOut prediction");
    }

    // ═══════════════════════════════════════════
    // 补充：余额 vs 储备一致性 & 极端边界 (44–45)
    // ═══════════════════════════════════════════

    /// @dev 44. 手续费模型验证：balanceOf(pool) == reserve 恒成立
    /// 本合约不同于 Uniswap V2（余额 ≥ 储备差值 = 累计手续费），
    /// 本合约中 swap 将全额 amountIn 计入 reserve，手续费体现为 K 的增长（#15, #42）
    function test_BalanceAlwaysEqualsReserve() public {
        // 初始
        assertEq(tokenA.balanceOf(address(pool)), pool.reserveA(), "init: balanceA == reserveA");
        assertEq(tokenB.balanceOf(address(pool)), pool.reserveB(), "init: balanceB == reserveB");

        // swap 后
        vm.prank(alice);
        pool.swap(address(tokenA), 20 * 1e18, 0);
        assertEq(tokenA.balanceOf(address(pool)), pool.reserveA(), "after swap: balanceA == reserveA");
        assertEq(tokenB.balanceOf(address(pool)), pool.reserveB(), "after swap: balanceB == reserveB");

        // addLiquidity 后
        tokenA.mint(address(this), 50 * 1e18);
        tokenB.mint(address(this), 50 * 1e18);
        pool.addLiquidity(50 * 1e18, 50 * 1e18);
        assertEq(tokenA.balanceOf(address(pool)), pool.reserveA(), "after add: balanceA == reserveA");
        assertEq(tokenB.balanceOf(address(pool)), pool.reserveB(), "after add: balanceB == reserveB");

        // removeLiquidity 后
        pool.removeLiquidity(30 * 1e18, 30 * 1e18);
        assertEq(tokenA.balanceOf(address(pool)), pool.reserveA(), "after remove: balanceA == reserveA");
        assertEq(tokenB.balanceOf(address(pool)), pool.reserveB(), "after remove: balanceB == reserveB");

        // 结论：本合约 balance ≡ reserve；手续费累积等效于 K 的增加
    }

    /// @dev 45. reserve 接近 uint256.max 时的 swap 行为：验证 Solidity 0.8 checked math 不溢出
    function test_Swap_ReserveNearUint256Max_NoOverflow() public {
        // 使用 type(uint128).max >> 1 ≈ 1.7e38 — 远大于实际 DeFi 规模，但乘法不溢出 uint256
        uint256 hugeAmount = uint256(type(uint128).max) >> 1;

        SimpleToken hugeTokenA = new SimpleToken();
        SimpleToken hugeTokenB = new SimpleToken();
        SimplePool hugePool = new SimplePool(address(hugeTokenA), address(hugeTokenB));

        // Mint 巨量 token
        hugeTokenA.mint(address(this), hugeAmount * 2);
        hugeTokenB.mint(address(this), hugeAmount * 2);
        hugeTokenA.approve(address(hugePool), type(uint256).max);
        hugeTokenB.approve(address(hugePool), type(uint256).max);

        // 添加 hugeAmount : hugeAmount 流动性
        hugePool.addLiquidity(hugeAmount, hugeAmount);

        // 验证小额 swap 无溢出
        hugeTokenA.mint(alice, 10 * 1e18);
        vm.prank(alice);
        hugeTokenA.approve(address(hugePool), type(uint256).max);
        vm.prank(alice);
        uint256 out1 = hugePool.swap(address(hugeTokenA), 1 * 1e18, 0);
        assertGt(out1, 0, "small swap with huge reserves works");

        // 验证 K 不变量在极端储备下仍成立
        uint256 kBefore = hugePool.reserveA() * hugePool.reserveB();
        hugeTokenA.mint(alice, 10 * 1e18);
        vm.prank(alice);
        hugePool.swap(address(hugeTokenA), 1 * 1e18, 0);
        uint256 kAfter = hugePool.reserveA() * hugePool.reserveB();
        assertGe(kAfter, kBefore, "k invariant holds at extreme reserves");
    }

    // ═══════════════════════════════════════════
    // 补充：覆盖率补充 (覆盖 lcov 未命中分支 46–49)
    // ═══════════════════════════════════════════

    /// @dev 46. constructor _tokenA == address(0) → revert "Invalid token"
    /// 覆盖 BRDA:28,0,0（_tokenA != address(0) 为 false 的路径）
    function test_Revert_Constructor_ZeroAddress() public {
        vm.expectRevert("Invalid token");
        new SimplePool(address(0), address(tokenB));
    }

    /// @dev 47. 极度不平衡池 + 1 wei 极小输入 → amountOut 向下取整为 0 → revert "Zero output"
    /// 覆盖 BRDA:59,6,0（amountOut > 0 为 false 的 revert 路径）
    /// 构造：reserveA = 1 wei, reserveB = 1000e18，swap B→A 用 1 wei
    /// 公式：amountOut = (1 * 9970 * 1) / (1000e18 * 10000 + 9970) = 0
    function test_Revert_Swap_ZeroOutput() public {
        SimplePool skewed = new SimplePool(address(tokenA), address(tokenB));

        // Mint 所需 token：A = 1 wei, B = 1000e18（加一点额外用于 swap）
        tokenA.mint(address(this), 1);
        tokenB.mint(address(this), 1001 * 1e18);

        tokenA.approve(address(skewed), type(uint256).max);
        tokenB.approve(address(skewed), type(uint256).max);

        // 极度不平衡添加：A 只有 1 wei，B 有 1000 token
        skewed.addLiquidity(1, 1000 * 1e18);

        // 用 1 wei tokenB 换 tokenA：reserveOut(A) = 1 wei，整数除法向下取整 → 0
        vm.expectRevert("Zero output");
        skewed.swap(address(tokenB), 1, 0);
    }

    /// @dev 48. getAmountOut 空池（reserve = 0）→ 返回 0
    /// 覆盖 BRDA:111,12,0（reserveIn == 0 || reserveOut == 0 为 true 的 return 0 路径）
    function test_GetAmountOut_EmptyPool() public {
        SimplePool empty = new SimplePool(address(tokenA), address(tokenB));
        assertEq(empty.getAmountOut(address(tokenA), 100 * 1e18), 0, "empty pool getAmountOut = 0");
        // 也覆盖反向 token
        assertEq(empty.getAmountOut(address(tokenB), 100 * 1e18), 0, "empty pool getAmountOut(tokenB) = 0");
    }

    /// @dev 49. getPrice(tokenB) → else 分支（反向价格查询）
    /// 覆盖 BRDA:121,13,1（_tokenIn == address(tokenA) 为 false 的 else 路径）
    /// 同时覆盖 line 124（reserveB > 0 ? ... : 0 的 true 子路径）
    function test_GetPrice_TokenB() public {
        // 池子 1:1 → priceB = reserveA / reserveB * 1e18 = 1e18
        uint256 priceB = pool.getPrice(address(tokenB));
        assertEq(priceB, 1e18, "price of B in A terms = 1:1");

        // 非对称场景：再做一次 swap A→B 破坏 1:1 比例，验证价格变化
        vm.prank(alice);
        pool.swap(address(tokenA), 100 * 1e18, 0);

        uint256 priceBAfter = pool.getPrice(address(tokenB));
        // swap A→B 后：reserveA↑, reserveB↓ → priceB = reserveA/reserveB > 1e18
        assertGt(priceBAfter, 1e18, "B price in A terms increases after A->B swap");
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
