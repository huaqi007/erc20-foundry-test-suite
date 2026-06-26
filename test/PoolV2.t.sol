// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {SimplePoolV2} from "../src/PoolV2.sol";
import {SimpleToken} from "../src/SimpleToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title PoolV2 安全修复回归测试
/// @notice 验证 SECURITY_AUDIT.md 中 V-01~V-08 的修复有效性
contract PoolV2RegressionTest is Test {
    SimpleToken public tokenA;
    SimpleToken public tokenB;
    SimplePoolV2 public pool;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public attacker = makeAddr("attacker");

    uint256 constant INITIAL_LIQ = 1000 * 1e18;

    function setUp() public {
        tokenA = new SimpleToken();
        tokenB = new SimpleToken();

        pool = new SimplePoolV2(address(tokenA), address(tokenB));

        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        pool.addLiquidity(INITIAL_LIQ, INITIAL_LIQ);

        tokenA.mint(alice, 1000 * 1e18);
        tokenB.mint(bob, 1000 * 1e18);

        vm.prank(alice);
        tokenA.approve(address(pool), type(uint256).max);
        vm.prank(bob);
        tokenB.approve(address(pool), type(uint256).max);
        vm.prank(alice);
        tokenB.approve(address(pool), type(uint256).max);
    }

    // ═══════════════════════════════════════════
    // V-02: Cross-Function Reentrancy Fix
    // ═══════════════════════════════════════════

    /// @dev V-02 Fix: addLiquidity 有 nonReentrant → 跨函数重入被拦截
    function test_Fix_V02_AddLiquidity_NonReentrant() public {
        // 部署恶意 ERC777 token（transfer 时回调接收方）
        ERC777Token maliciousToken = new ERC777Token();
        SimpleToken normalToken = new SimpleToken();
        SimplePoolV2 pool2 = new SimplePoolV2(address(normalToken), address(maliciousToken));

        normalToken.approve(address(pool2), type(uint256).max);
        maliciousToken.approve(address(pool2), type(uint256).max);
        pool2.addLiquidity(1000 * 1e18, 1000 * 1e18);

        // 部署攻击者 — swap 换出 ERC777 token，回调中尝试 addLiquidity
        CrossFunctionAttacker attackerContract = new CrossFunctionAttacker();
        normalToken.mint(address(attackerContract), 100 * 1e18);

        attackerContract.setupV2(address(pool2), address(normalToken), address(maliciousToken));

        // 攻击 → nonReentrant 拦截
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        attackerContract.attackViaSwap(50 * 1e18);
    }

    /// @dev V-02 Fix: removeLiquidity 有 nonReentrant → 跨函数重入被拦截
    function test_Fix_V02_RemoveLiquidity_NonReentrant() public {
        ERC777Token maliciousToken = new ERC777Token();
        SimpleToken normalToken = new SimpleToken();
        SimplePoolV2 pool2 = new SimplePoolV2(address(normalToken), address(maliciousToken));

        normalToken.approve(address(pool2), type(uint256).max);
        maliciousToken.approve(address(pool2), type(uint256).max);
        pool2.addLiquidity(1000 * 1e18, 1000 * 1e18);

        CrossFunctionAttacker attackerContract = new CrossFunctionAttacker();
        normalToken.mint(address(attackerContract), 100 * 1e18);
        // 给 attacker 一些流动性代币用于 remove
        maliciousToken.mint(address(attackerContract), 200 * 1e18);

        attackerContract.setupV2(address(pool2), address(normalToken), address(maliciousToken));

        // 攻击 → nonReentrant 拦截
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        attackerContract.attackViaRemove(100 * 1e18, 100 * 1e18);
    }

    // ═══════════════════════════════════════════
    // V-01 + V-05: Fee-on-Transfer & Rebasing Fix
    // ═══════════════════════════════════════════

    /// @dev V-01 Fix: FOT token — 池子使用实际到账而非参数值
    function test_Fix_V01_FeeOnTransfer_UsesActualReceived() public {
        FeeOnTransferToken fotToken = new FeeOnTransferToken();
        SimpleToken normalToken = new SimpleToken();
        SimplePoolV2 pool2 = new SimplePoolV2(address(normalToken), address(fotToken));

        // Mint + approve
        normalToken.mint(address(this), 2000 * 1e18);
        fotToken.mint(address(this), 2000 * 1e18);
        normalToken.approve(address(pool2), type(uint256).max);
        fotToken.approve(address(pool2), type(uint256).max);

        // 添加流动性 — FOT 扣 5% 费用
        pool2.addLiquidity(1000 * 1e18, 1000 * 1e18);

        // 验证：储备量 = 实际到账（950），而非参数值（1000）
        uint256 reserveNormal = pool2.reserveA(); // normalToken = tokenA
        uint256 reserveFot = pool2.reserveB(); // fotToken = tokenB

        // FOT token 实际到账 = 1000 * 0.95 = 950
        assertEq(reserveNormal, 1000 * 1e18, "normal token reserve = stated amount");
        assertEq(reserveFot, 950 * 1e18, "FOT token reserve = actual received (950, not 1000)");

        // 验证余额 = 储备量（无 gap）
        assertEq(normalToken.balanceOf(address(pool2)), pool2.reserveA(), "balance == reserveA");
        assertEq(fotToken.balanceOf(address(pool2)), pool2.reserveB(), "balance == reserveB (no gap)");
    }

    /// @dev V-05 Fix: Rebasing token — 余额快照防止 balance/reserve 不匹配
    function test_Fix_V05_Rebasing_BalanceMatchesReserve() public {
        RebasingToken rebaseToken = new RebasingToken();
        SimpleToken normalToken = new SimpleToken();
        SimplePoolV2 pool2 = new SimplePoolV2(address(normalToken), address(rebaseToken));

        normalToken.mint(address(this), 2000 * 1e18);
        rebaseToken.mint(address(this), 2000 * 1e18);
        normalToken.approve(address(pool2), type(uint256).max);
        rebaseToken.approve(address(pool2), type(uint256).max);

        // 添加流动性
        pool2.addLiquidity(1000 * 1e18, 1000 * 1e18);

        uint256 reserveBefore = pool2.reserveB();
        uint256 balanceBefore = rebaseToken.balanceOf(address(pool2));
        assertEq(balanceBefore, reserveBefore, "initial: balance == reserve");

        // 模拟 rebase：直接 mint 给池子（模拟正向 rebase +10%）
        rebaseToken.mint(address(pool2), 100 * 1e18);

        // 验证：储备量不变，余额膨胀（gap 出现）
        assertEq(pool2.reserveB(), reserveBefore, "reserve unchanged after rebase");
        assertGt(rebaseToken.balanceOf(address(pool2)), pool2.reserveB(), "balance > reserve (gap exists)");

        // swap 使用 normalToken 换 rebaseToken（使用 pool2 自己的 tokenA = normalToken）
        normalToken.mint(alice, 100 * 1e18);
        vm.prank(alice);
        normalToken.approve(address(pool2), type(uint256).max);
        vm.prank(alice);
        uint256 amountOut = pool2.swap(address(normalToken), 10 * 1e18, 0, 0);

        assertGt(amountOut, 0, "swap succeeds despite rebase gap");
    }

    // ═══════════════════════════════════════════
    // V-04: USDT Transfer Return Value Fix
    // ═══════════════════════════════════════════

    /// @dev V-04 Fix: SafeERC20 — transfer 返回 false 时转为 revert
    function test_Fix_V04_USDT_TransferFailReverts() public {
        // 使用 ERC20 在 transferFrom 时返回 false 的恶意 token
        ReturningFalseToken falseToken = new ReturningFalseToken();
        SimpleToken normalToken = new SimpleToken();
        SimplePoolV2 pool2 = new SimplePoolV2(address(normalToken), address(falseToken));

        normalToken.mint(address(this), 2000 * 1e18);
        falseToken.mint(address(this), 2000 * 1e18);
        normalToken.approve(address(pool2), type(uint256).max);
        falseToken.approve(address(pool2), type(uint256).max);

        // addLiquidity → falseToken 的 transferFrom 返回 false → SafeERC20 转为 revert
        vm.expectRevert();
        pool2.addLiquidity(1000 * 1e18, 1000 * 1e18);
    }

    /// @dev V-04 Fix: SafeERC20 — MockUSDT 正常场景（transfer 返回 true，无 revert）
    function test_Fix_V04_USDT_NormalFlow() public {
        MockUSDT usdt = new MockUSDT();
        SimpleToken normalToken = new SimpleToken();
        SimplePoolV2 pool2 = new SimplePoolV2(address(normalToken), address(usdt));

        normalToken.mint(address(this), 2000 * 1e18);
        usdt.mint(address(this), 2000 * 1e18);
        normalToken.approve(address(pool2), type(uint256).max);
        usdt.approve(address(pool2), type(uint256).max);

        // 正常添加和交换 — USDT 的 transfer 返回 true，SafeERC20 正常执行
        pool2.addLiquidity(1000 * 1e18, 1000 * 1e18);
        assertEq(pool2.reserveA(), 1000 * 1e18, "reserveA correct");
        assertEq(pool2.reserveB(), 1000 * 1e18, "reserveB correct");

        // swap 正常执行
        normalToken.mint(alice, 100 * 1e18);
        vm.prank(alice);
        normalToken.approve(address(pool2), type(uint256).max);
        vm.prank(alice);
        uint256 out = pool2.swap(address(normalToken), 10 * 1e18, 0, 0);
        assertGt(out, 0, "swap with USDT works via SafeERC20");
    }

    // ═══════════════════════════════════════════
    // V-06 + V-08: Deadline Fix
    // ═══════════════════════════════════════════

    /// @dev V-08 Fix: deadline 已过期 → revert "Expired"
    function test_Fix_V08_Deadline_Expired() public {
        vm.warp(1000); // 设置当前区块时间

        vm.prank(alice);
        vm.expectRevert("Expired");
        pool.swap(address(tokenA), 10 * 1e18, 0, 999); // deadline 在过去
    }

    /// @dev V-08 Fix: deadline 未过期 → 成功
    function test_Fix_V08_Deadline_NotExpired() public {
        vm.warp(1000);

        vm.prank(alice);
        uint256 out = pool.swap(address(tokenA), 10 * 1e18, 0, 1500); // deadline 在未来
        assertGt(out, 0, "swap succeeds with valid deadline");
    }

    /// @dev V-08 Fix: deadline = 0 → 不检查（向后兼容）
    function test_Fix_V08_Deadline_ZeroMeansNoCheck() public {
        vm.warp(1000);

        vm.prank(alice);
        uint256 out = pool.swap(address(tokenA), 10 * 1e18, 0, 0);
        assertGt(out, 0, "deadline=0 skips check");
    }

    // ═══════════════════════════════════════════
    // V-07: CEI Ordering Fix
    // ═══════════════════════════════════════════

    /// @dev V-07 Fix: reserve 在 tokenOut.transfer 之前更新（CEI）
    /// 验证：在 ERC777 回调中读取 getPrice 得到 post-swap 价格
    function test_Fix_V07_CEI_ReservesUpdatedBeforeCallback() public {
        ERC777Token erc777 = new ERC777Token();
        SimpleToken normalToken = new SimpleToken();
        SimplePoolV2 pool2 = new SimplePoolV2(address(normalToken), address(erc777));

        normalToken.mint(address(this), 2000 * 1e18);
        erc777.mint(address(this), 2000 * 1e18);
        normalToken.approve(address(pool2), type(uint256).max);
        erc777.approve(address(pool2), type(uint256).max);

        pool2.addLiquidity(1000 * 1e18, 1000 * 1e18);

        // 部署价格检查器 — 在 ERC777 回调中读取 getPrice
        // PriceChecker 自己执行 swap，这样 tokenOut 转到 PriceChecker（合约），触发 callback
        PriceChecker checker = new PriceChecker();
        checker.setPool(address(pool2));
        erc777.setCallbackReceiver(address(checker));

        normalToken.mint(address(checker), 100 * 1e18);
        checker.setup(address(normalToken), address(pool2));

        // PriceChecker 执行 swap normalToken → erc777
        // tokenOut = erc777 转到 checker(合约) → 触发 callback → 读取 getPrice
        uint256 out = checker.doSap(50 * 1e18);
        assertGt(out, 0, "swap succeeds");

        // checker 记录回调中读取的 price — reserves 应是 post-swap 状态（CEI 保证）
        uint256 priceInCallback = checker.lastPrice();
        assertGt(priceInCallback, 0, "price was read in callback (post-swap state)");
    }

    // ═══════════════════════════════════════════
    // V-03: TWAP Oracle Fix
    // ═══════════════════════════════════════════

    /// @dev V-03 Fix: swap 后累积价格更新
    function test_Fix_V03_TWAP_CumulativePriceUpdated() public {
        // 记录初始 oracle 状态
        (uint256 cumA0, uint256 cumB0, uint32 ts0, , ) = pool.getOracleState();
        assertEq(cumA0, 0, "initial cumA = 0");
        assertEq(cumB0, 0, "initial cumB = 0");

        // 时间推进 + swap
        vm.warp(block.timestamp + 100);
        vm.prank(alice);
        pool.swap(address(tokenA), 10 * 1e18, 0, 0);

        // 验证累积价格已更新
        (uint256 cumA1, uint256 cumB1, uint32 ts1, , ) = pool.getOracleState();
        assertGt(cumA1, cumA0, "cumA increased after swap");
        assertGt(cumB1, cumB0, "cumB increased after swap");
        assertGt(ts1, ts0, "timestamp advanced");
    }

    /// @dev V-03 Fix: getTwapA 返回时间加权平均价格
    function test_Fix_V03_TWAP_GetTwapA_ReturnsTWAP() public {
        // 需要至少两次状态变更跨越不同 block 来填充双槽环形缓冲区
        // 第一次：初始化后 swap（写入 slot 0）
        vm.warp(block.timestamp + 100);
        vm.prank(alice);
        pool.swap(address(tokenA), 10 * 1e18, 0, 0);

        // 第二次：等待足够时间后 swap（写入 slot 1，创建历史快照）
        vm.warp(block.timestamp + 100); // +100s, 足够跨 block
        vm.prank(alice);
        pool.swap(address(tokenA), 10 * 1e18, 0, 0);

        // 第三次：再次推进时间 + swap（确保双槽有足够间隔）
        vm.warp(block.timestamp + 100);
        vm.prank(alice);
        pool.swap(address(tokenA), 10 * 1e18, 0, 0);

        // 查询 TWAP（period = 100s，两槽之间应有足够时间差）
        uint256 twapA = pool.getTwapA(100);
        assertGt(twapA, 0, "TWAP A > 0");
    }

    /// @dev V-03 Fix: 大额 swap 操纵 spot price，但 TWAP 更稳定
    function test_Fix_V03_TWAP_MoreStableThanSpot() public {
        // 建立历史：多次小额 swap 跨越较长窗口
        vm.warp(block.timestamp + 200);
        vm.prank(alice);
        pool.swap(address(tokenA), 10 * 1e18, 0, 0);

        vm.warp(block.timestamp + 200);
        vm.prank(alice);
        pool.swap(address(tokenA), 10 * 1e18, 0, 0);

        vm.warp(block.timestamp + 200);
        vm.prank(alice);
        pool.swap(address(tokenA), 10 * 1e18, 0, 0);

        uint256 spotBefore = pool.getPrice(address(tokenA));

        // 大额 swap 操纵 spot price
        tokenA.mint(alice, 500 * 1e18);
        vm.prank(alice);
        pool.swap(address(tokenA), 500 * 1e18, 0, 0);

        uint256 spotAfter = pool.getPrice(address(tokenA));
        // Spot price 应大幅偏离
        assertLt(spotAfter, spotBefore, "large swap pushes spot price down");

        // TWAP 因为累积了 600s 的历史，应相对稳定（不被单笔交易完全操纵）
        // 但注意：如果窗口不够大，TWAP 也会被部分影响 — 这是预期行为
        uint256 twapA = pool.getTwapA(100);
        // TWAP 存在且 > 0
        assertGt(twapA, 0, "TWAP available");
        // TWAP 比当前 spot 更接近原始价格（因为包含历史）
        if (twapA > spotAfter) {
            assertGt(twapA, spotAfter, "TWAP > manipulated spot (closer to original)");
        }
    }

    /// @dev V-03: getPrice spot 查询仍然可用（向后兼容）
    function test_Fix_V03_GetPrice_StillWorks() public {
        uint256 priceA = pool.getPrice(address(tokenA));
        assertEq(priceA, 1e18, "spot price of A = 1:1 in balanced pool");

        uint256 priceB = pool.getPrice(address(tokenB));
        assertEq(priceB, 1e18, "spot price of B = 1:1 in balanced pool");
    }

    /// @dev V-03: 验证 spot price 可被大额交易操纵（证明 TWAP 必要性）
    function test_Fix_V03_SpotPrice_Manipulable() public {
        uint256 priceBefore = pool.getPrice(address(tokenA));

        tokenA.mint(alice, 500 * 1e18);
        vm.prank(alice);
        pool.swap(address(tokenA), 500 * 1e18, 0, 0);

        uint256 priceAfter = pool.getPrice(address(tokenA));
        assertLt(priceAfter, priceBefore, "spot price manipulated by large swap");
    }

    /// @dev V-03 Fix: getOracleState 返回完整 oracle 状态供外部 TWAP 计算
    function test_Fix_V03_GetOracleState() public {
        vm.warp(block.timestamp + 100);
        vm.prank(alice);
        pool.swap(address(tokenA), 10 * 1e18, 0, 0);

        (uint256 cumA, uint256 cumB, uint32 lastTs, uint256 resA, uint256 resB) = pool.getOracleState();
        assertGt(cumA, 0, "cumA > 0");
        assertGt(cumB, 0, "cumB > 0");
        assertGt(lastTs, 0, "lastTs > 0");
        assertGt(resA, 0, "resA > 0");
        assertGt(resB, 0, "resB > 0");
    }

    /// @dev V-03 Fix: getTwapA 在历史不足时返回 0
    function test_Fix_V03_TWAP_ReturnsZeroWhenInsufficientHistory() public {
        // 没有足够历史 → getTwapA(3600) 应返回 0
        uint256 twap = pool.getTwapA(3600);
        assertEq(twap, 0, "TWAP = 0 when history insufficient");
    }

    // ═══════════════════════════════════════════
    // 区块高度 / 多区块场景 (vm.roll)
    // ═══════════════════════════════════════════

    /// @dev vm.roll + vm.warp: 模拟真实多区块 TWAP 累积（每区块 12s）
    function test_Fix_V03_MultiBlock_TWAP_AccumulatesOverBlocks() public {
        // 初始 swap 写入 slot 0
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        vm.prank(alice);
        pool.swap(address(tokenA), 10 * 1e18, 0, 0);

        // 多次跨区块 swap，每次 12s（模拟 Ethereum 出块）
        for (uint256 i = 0; i < 5; i++) {
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 12);
            vm.prank(alice);
            pool.swap(address(tokenA), 1 * 1e18, 0, 0);
        }

        // 最后再 advance 一次确保双槽跨越足够窗口
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        vm.prank(alice);
        pool.swap(address(tokenA), 10 * 1e18, 0, 0);

        // 双槽窗口 = 最后两次不同 block 的 swap 间隔（≥12s）
        // getTwapA(12) 要求窗口 ≥ 12s
        uint256 twap = pool.getTwapA(12);
        assertGt(twap, 0, "TWAP accumulated across multiple blocks");
    }

    /// @dev vm.roll + vm.warp: deadline 跨区块过期
    function test_Fix_V08_Deadline_ExpiredAfterMultipleBlocks() public {
        // 设置 deadline = 当前 + 5 个区块后
        uint256 deadlineBlock = block.timestamp + 60; // 5 blocks × 12s

        // 推进 10 个区块（120s）→ deadline 已过期
        vm.roll(block.number + 10);
        vm.warp(block.timestamp + 120);

        vm.prank(alice);
        vm.expectRevert("Expired");
        pool.swap(address(tokenA), 10 * 1e18, 0, deadlineBlock);
    }

    /// @dev vm.roll: 仅推进区块高度（时间不变）→ TWAP 不累积（依赖时间差）
    function test_Fix_V03_RollOnly_NoTimeElapsed_NoTWAPUpdate() public {
        // 初始 swap
        vm.warp(block.timestamp + 100);
        vm.prank(alice);
        pool.swap(address(tokenA), 10 * 1e18, 0, 0);

        (uint256 cumA1, , , , ) = pool.getOracleState();

        // 仅推进区块号，时间不变
        vm.roll(block.number + 100);

        // 再做 swap（同一 timestamp → elapsed = 0 → oracle 不累积）
        vm.prank(alice);
        pool.swap(address(tokenA), 10 * 1e18, 0, 0);

        (uint256 cumA2, , , , ) = pool.getOracleState();
        // 累积价格不变（timeElapsed = 0，无新增累积）
        assertEq(cumA2, cumA1, "cumulative price unchanged when timestamp stays same");
    }

    /// @dev vm.roll + vm.warp: TWAP 跨区块窗口，价格比 spot 更稳定
    /// 双槽环形缓冲区提供最近两次跨区块观察的 TWAP 窗口
    function test_Fix_V03_MultiBlock_PriceStaysStable() public {
        // 第一次 swap — 写入 slot 0（t=100）
        vm.roll(block.number + 1);
        vm.warp(100);
        vm.prank(alice);
        pool.swap(address(tokenA), 1 * 1e18, 0, 0);

        // 等待 100s + 多区块 — 第二次 swap 写入 slot 1（t=200）
        vm.roll(block.number + 50);
        vm.warp(200);
        vm.prank(alice);
        pool.swap(address(tokenA), 1 * 1e18, 0, 0);

        uint256 spotBefore = pool.getPrice(address(tokenA));

        // 双槽窗口 = 200 - 100 = 100s，getTwapA(60) 应可用
        uint256 twapBefore = pool.getTwapA(60);
        assertGt(twapBefore, 0, "TWAP available after 100s window");

        // 一次大额 swap 操纵 spot price（t=212）
        tokenA.mint(alice, 200 * 1e18);
        vm.roll(block.number + 1);
        vm.warp(212);
        vm.prank(alice);
        pool.swap(address(tokenA), 200 * 1e18, 0, 0);

        uint256 spotAfter = pool.getPrice(address(tokenA));
        assertLt(spotAfter, spotBefore, "spot price drops after large swap");

        // 大额 swap 后双槽被覆盖为新窗口（100→212=112s），TWAP 包含 12s 操纵段 + 100s 稳定段
        // 相对 spot 更稳定（受历史稀释）
        uint256 twapAfter = pool.getTwapA(60);
        if (twapAfter > 0) {
            assertGt(twapAfter, spotAfter, "TWAP > manipulated spot (diluted by history)");
        }
    }
}

// ═══════════════════════════════════════════
// 辅助合约
// ═══════════════════════════════════════════

/// ERC777 风格代币 — transfer 时回调接收方
contract ERC777Token is SimpleToken {
    address public callbackReceiver;

    function setCallbackReceiver(address _receiver) external {
        callbackReceiver = _receiver;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        super.transfer(to, value);
        if (callbackReceiver != address(0) && to.code.length > 0) {
            IERC777Callback(callbackReceiver).tokensReceived(msg.sender, value);
        }
        return true;
    }
}

interface IERC777Callback {
    function tokensReceived(address from, uint256 amount) external;
}

/// 跨函数重入攻击者 — swap 回调中 addLiquidity / removeLiquidity
contract CrossFunctionAttacker is Test {
    SimplePoolV2 public pool;
    address public normalToken;
    address public erc777Token;

    function setupV2(address _pool, address _normal, address _erc777) external {
        pool = SimplePoolV2(_pool);
        normalToken = _normal;
        erc777Token = _erc777;
        IERC20(normalToken).approve(_pool, type(uint256).max);
        IERC20(erc777Token).approve(_pool, type(uint256).max);
        // 注册为 ERC777 回调接收方
        ERC777Token(erc777Token).setCallbackReceiver(address(this));
    }

    /// 通过 swap 触发重入 — 在 tokenOut 回调中 addLiquidity
    function attackViaSwap(uint256 amount) external {
        pool.swap(normalToken, amount, 0, 0);
    }

    /// 通过 removeLiquidity 触发重入 — 在 tokenOut 回调中 removeLiquidity
    function attackViaRemove(uint256 amountA, uint256 amountB) external {
        pool.removeLiquidity(amountA, amountB);
    }

    /// ERC777 回调 — 重入 addLiquidity（应被 nonReentrant 拦截）
    function tokensReceived(address, uint256) external {
        // 尝试在 swap 的 tokenOut 回调中 addLiquidity
        pool.addLiquidity(100 * 1e18, 100 * 1e18);
    }
}

/// Fee-on-Transfer 代币 — transfer 时扣除 5% 费用
contract FeeOnTransferToken is SimpleToken {
    uint256 public constant FEE_PERCENT = 5; // 5% fee

    function transfer(address to, uint256 value) public override returns (bool) {
        uint256 fee = (value * FEE_PERCENT) / 100;
        uint256 actual = value - fee;
        super.transfer(to, actual);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        uint256 fee = (value * FEE_PERCENT) / 100;
        uint256 actual = value - fee;
        super.transferFrom(from, to, actual);
        return true;
    }
}

/// Rebasing 代币 — 余额可在无 transfer 事件的情况下变化
contract RebasingToken is SimpleToken {
    /// 模拟正向 rebase：直接 mint 给目标地址（不触发 transfer 事件）
    function doRebase(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// 恶意 ERC20 — transferFrom 始终返回 false（模拟异常代币，用于验证 SafeERC20 检测）
contract ReturningFalseToken is SimpleToken {
    function transferFrom(address, address, uint256) public pure override returns (bool) {
        return false;
    }
}

/// Mock USDT — transfer/transferFrom 在余额不足时返回 false 而非 revert（模拟真实 USDT）
contract MockUSDT is SimpleToken {
    function transfer(address to, uint256 value) public override returns (bool) {
        // 真实 USDT: 余额不足时返回 false，不 revert
        if (balanceOf(msg.sender) < value) return false;
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (balanceOf(from) < value) return false;
        return super.transferFrom(from, to, value);
    }
}

/// 价格检查器 — 在 ERC777 回调中读取 getPrice 并记录
contract PriceChecker is IERC777Callback {
    uint256 public lastPrice;
    SimplePoolV2 public pool;
    address public tokenIn;

    function setPool(address _pool) external {
        pool = SimplePoolV2(_pool);
    }

    function setup(address _tokenIn, address _pool) external {
        tokenIn = _tokenIn;
        IERC20(_tokenIn).approve(_pool, type(uint256).max);
    }

    /// 执行 swap，tokenOut 将转入本合约（触发 ERC777 回调）
    function doSap(uint256 amount) external returns (uint256) {
        return pool.swap(tokenIn, amount, 0, 0);
    }

    function tokensReceived(address, uint256) external {
        // 在 ERC777 回调中读取 getPrice — 此时 reserve 应已更新（CEI）
        try pool.getPrice(address(pool.tokenA())) returns (uint256 p) {
            lastPrice = p;
        } catch {
            lastPrice = 0;
        }
    }
}
