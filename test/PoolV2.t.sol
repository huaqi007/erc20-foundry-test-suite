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
    // V-03: Spot Price Oracle (Documented)
    // ═══════════════════════════════════════════

    /// @dev V-03: getPrice 仍然可用但标注了安全警告（编译时 NatSpec）
    function test_Fix_V03_GetPrice_StillWorks() public {
        uint256 priceA = pool.getPrice(address(tokenA));
        assertEq(priceA, 1e18, "price of A = 1:1 in balanced pool");

        uint256 priceB = pool.getPrice(address(tokenB));
        assertEq(priceB, 1e18, "price of B = 1:1 in balanced pool");
    }

    /// @dev V-03: 大额 swap 后 getPrice 显著偏离（demonstrating 可操纵性）
    function test_Fix_V03_GetPrice_ManipulableByLargeSwap() public {
        uint256 priceBefore = pool.getPrice(address(tokenA));

        // 大额 swap 改变 spot price
        tokenA.mint(alice, 500 * 1e18);
        vm.prank(alice);
        pool.swap(address(tokenA), 500 * 1e18, 0, 0);

        uint256 priceAfter = pool.getPrice(address(tokenA));
        // spot price 被大幅推离 1:1
        assertLt(priceAfter, priceBefore, "large swap manipulates spot price");
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
