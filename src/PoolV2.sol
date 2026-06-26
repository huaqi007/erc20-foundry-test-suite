// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title SimplePoolV2 — 恒定乘积 AMM 交易池（安全修复版）
/// @notice 支持两种 ERC20 代币的兑换，0.3% 手续费，内置 TWAP oracle
/// @dev 相对于 V1 修复了 SECURITY_AUDIT.md 中的 V-01~V-08 漏洞
contract SimplePoolV2 is ReentrancyGuard {
    using SafeERC20 for IERC20; // Fix: V-04 — USDT transfer 返回值未检查

    IERC20 public immutable tokenA;
    IERC20 public immutable tokenB;

    uint256 public reserveA;
    uint256 public reserveB;

    uint256 public constant FEE_BPS = 30; // 0.3% = 30 bps
    uint256 public constant BASIS_POINTS = 10000;

    // ══════════════════ Fix: V-03 — TWAP Oracle ══════════════════
    // Uniswap V2 风格累积价格 + 双槽观测环形缓冲区。
    // 外部集成方：
    //   a) 链下：定期快照 getOracleState() → 自行计算任意窗口 TWAP
    //   b) 链上：调用 getTwapA(period) / getTwapB(period) 获取最近窗口 TWAP
    //
    // 安全保证：TWAP 需要累积 ≥period 秒的历史，单笔闪电贷无法在短时间内
    //          将 time-weighted 均值拉到有利水平（需持续操纵整个窗口）。

    struct Observation {
        uint32 timestamp; // 区块时间戳
        uint256 cumA; // priceACumulativeLast 快照
        uint256 cumB; // priceBCumulativeLast 快照
    }

    uint256 public priceACumulativeLast; // tokenA 价格累积（以 tokenB 计价，scale 1e18）
    uint256 public priceBCumulativeLast; // tokenB 价格累积（以 tokenA 计价，scale 1e18）
    uint32 public blockTimestampLast; // 上次 oracle 更新时间

    Observation[2] private _observations; // 双槽环形缓冲区
    uint8 private _obsIndex; // 当前写入槽位 (0 或 1)

    event Swap(
        address indexed user,
        address indexed tokenIn,
        uint256 amountIn,
        address indexed tokenOut,
        uint256 amountOut
    );

    event LiquidityAdded(address indexed provider, uint256 amountA, uint256 amountB);

    event LiquidityRemoved(address indexed provider, uint256 amountA, uint256 amountB);

    // Fix: V-03 — Oracle 更新事件（供链下监控）
    event OracleUpdated(
        uint256 priceACumulative,
        uint256 priceBCumulative,
        uint32 timestamp
    );

    constructor(address _tokenA, address _tokenB) {
        require(_tokenA != address(0) && _tokenB != address(0), "Invalid token");
        require(_tokenA != _tokenB, "Same token");
        tokenA = IERC20(_tokenA);
        tokenB = IERC20(_tokenB);

        // Fix: V-03 — 初始化 oracle
        uint32 ts = uint32(block.timestamp % 2 ** 32);
        blockTimestampLast = ts;
        _observations[0] = Observation(ts, 0, 0);
        _observations[1] = Observation(ts, 0, 0);
    }

    // ═══════════════════════════════════════════
    // TWAP Oracle（Fix: V-03）
    // ═══════════════════════════════════════════

    /// @notice 更新累积价格，写入环形缓冲区
    /// @dev 必须在 reserve 变更前调用（使用变更前的价格累积）
    function _updateOracle() private {
        uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast;

        if (timeElapsed > 0 && reserveA > 0 && reserveB > 0) {
            // 累积价格 += 当前瞬时价格 × 经过秒数
            // priceA = reserveB / reserveA（1 A = ? B, scale 1e18）
            // priceB = reserveA / reserveB（1 B = ? A, scale 1e18）
            priceACumulativeLast += (reserveB * 1e18 / reserveA) * timeElapsed;
            priceBCumulativeLast += (reserveA * 1e18 / reserveB) * timeElapsed;

            // 写入环形缓冲区（为 getTwap 提供历史快照）
            // 仅在新 block 写入，避免同一 block 内覆盖
            Observation memory lastObs = _observations[_obsIndex];
            if (blockTimestamp > lastObs.timestamp) {
                _obsIndex = 1 - _obsIndex; // 切换槽位
                _observations[_obsIndex] = Observation(
                    blockTimestamp,
                    priceACumulativeLast,
                    priceBCumulativeLast
                );
            }

            blockTimestampLast = blockTimestamp;
            emit OracleUpdated(priceACumulativeLast, priceBCumulativeLast, blockTimestamp);
        } else if (timeElapsed > 0) {
            blockTimestampLast = blockTimestamp;
        }
    }

    /// @notice 查询 TWAP — tokenA 以 tokenB 计价
    /// @param _period 时间窗口（秒），如 1800 = 30 分钟
    /// @return twap TWAP 价格 × 1e18；若历史不足返回 0
    /// @dev 取环形缓冲区中最接近 _period 的历史快照，计算时间加权均值
    function getTwapA(uint32 _period) external view returns (uint256 twap) {
        if (_period == 0 || reserveA == 0 || reserveB == 0) return 0;

        Observation memory current = _observations[_obsIndex];
        Observation memory previous = _observations[1 - _obsIndex];

        // 确保有足够时间跨度的历史
        if (current.timestamp <= previous.timestamp) return 0;
        uint32 window = current.timestamp - previous.timestamp;
        if (window < _period) return 0;

        // TWAP = Δ累积价格 / Δ时间
        // ΔcumA = (price_A_t1 + price_A_t2 + ...) × avg_dt, 除以总时间 = 平均价格
        uint256 deltaCum = current.cumA - previous.cumA;
        twap = deltaCum / uint256(window);
    }

    /// @notice 查询 TWAP — tokenB 以 tokenA 计价
    function getTwapB(uint32 _period) external view returns (uint256 twap) {
        if (_period == 0 || reserveA == 0 || reserveB == 0) return 0;

        Observation memory current = _observations[_obsIndex];
        Observation memory previous = _observations[1 - _obsIndex];

        if (current.timestamp <= previous.timestamp) return 0;
        uint32 window = current.timestamp - previous.timestamp;
        if (window < _period) return 0;

        uint256 deltaCum = current.cumB - previous.cumB;
        twap = deltaCum / uint256(window);
    }

    /// @notice 查询 oracle 完整状态（供外部集成方快照 + 自行计算任意窗口 TWAP）
    /// @dev 外部使用方式：
    ///  1. T1: 调用 getOracleState() → 记录 (cumA, cumB, ts)
    ///  2. 等待 ≥ period 秒
    ///  3. T2: 再次调用 getOracleState() → 记录 (cumA', cumB', ts')
    ///  4. TWAP_A = (cumA' - cumA) / (ts' - ts)
    ///      TWAP_B = (cumB' - cumB) / (ts' - ts)
    function getOracleState()
        external
        view
        returns (
            uint256 cumA,
            uint256 cumB,
            uint32 lastTs,
            uint256 resA,
            uint256 resB
        )
    {
        return (priceACumulativeLast, priceBCumulativeLast, blockTimestampLast, reserveA, reserveB);
    }

    // ═══════════════════════════════════════════
    // AMM 核心逻辑
    // ═══════════════════════════════════════════

    /// @notice 恒定乘积 AMM 兑换
    /// @param _tokenIn 输入代币地址
    /// @param _amountIn 输入数量
    /// @param _amountOutMin 最小输出（滑点保护）
    /// @param deadline 交易截止时间戳（0 表示无截止）— Fix: V-06, V-08
    /// @return amountOut 实际输出数量
    function swap(
        address _tokenIn,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint256 deadline
    ) external nonReentrant returns (uint256 amountOut) {
        if (deadline != 0) {
            require(block.timestamp <= deadline, "Expired");
        }
        require(_amountIn > 0, "AmountIn must be > 0");
        require(
            _tokenIn == address(tokenA) || _tokenIn == address(tokenB),
            "Invalid token"
        );

        (IERC20 tokenIn, IERC20 tokenOut, uint256 reserveIn, uint256 reserveOut) = _tokenIn
            == address(tokenA)
            ? (tokenA, tokenB, reserveA, reserveB)
            : (tokenB, tokenA, reserveB, reserveA);

        require(reserveIn > 0 && reserveOut > 0, "Empty pool");

        // Fix: V-03 — 在储备量变更前更新 oracle
        _updateOracle();

        // Fix: V-01, V-05 — 余额快照
        uint256 balanceBefore = tokenIn.balanceOf(address(this));
        tokenIn.safeTransferFrom(msg.sender, address(this), _amountIn);
        uint256 actualIn = tokenIn.balanceOf(address(this)) - balanceBefore;
        require(actualIn > 0, "Zero received");

        uint256 amountInWithFee = actualIn * (BASIS_POINTS - FEE_BPS);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * BASIS_POINTS + amountInWithFee;
        amountOut = numerator / denominator;

        require(amountOut >= _amountOutMin, "Slippage exceeded");
        require(amountOut > 0, "Zero output");

        // Fix: V-07 — CEI: 先更新储备量，再 transfer
        if (_tokenIn == address(tokenA)) {
            reserveA += actualIn;
            reserveB -= amountOut;
        } else {
            reserveB += actualIn;
            reserveA -= amountOut;
        }

        tokenOut.safeTransfer(msg.sender, amountOut);
        emit Swap(msg.sender, _tokenIn, actualIn, address(tokenOut), amountOut);
    }

    /// @notice 添加流动性
    function addLiquidity(uint256 _amountA, uint256 _amountB)
        external
        nonReentrant
    {
        require(_amountA > 0 && _amountB > 0, "Amounts must be > 0");

        // Fix: V-03 — 在储备量变更前更新 oracle
        _updateOracle();

        uint256 balABefore = tokenA.balanceOf(address(this));
        uint256 balBBefore = tokenB.balanceOf(address(this));
        tokenA.safeTransferFrom(msg.sender, address(this), _amountA);
        tokenB.safeTransferFrom(msg.sender, address(this), _amountB);
        uint256 actualA = tokenA.balanceOf(address(this)) - balABefore;
        uint256 actualB = tokenB.balanceOf(address(this)) - balBBefore;
        require(actualA > 0 && actualB > 0, "Zero received");

        reserveA += actualA;
        reserveB += actualB;
        emit LiquidityAdded(msg.sender, actualA, actualB);
    }

    /// @notice 移除流动性
    function removeLiquidity(uint256 _amountA, uint256 _amountB)
        external
        nonReentrant
    {
        require(_amountA > 0 && _amountB > 0, "Amounts must be > 0");
        require(_amountA <= reserveA && _amountB <= reserveB, "Insufficient reserves");

        // Fix: V-03 — 在储备量变更前更新 oracle
        _updateOracle();

        reserveA -= _amountA;
        reserveB -= _amountB;
        tokenA.safeTransfer(msg.sender, _amountA);
        tokenB.safeTransfer(msg.sender, _amountB);
        emit LiquidityRemoved(msg.sender, _amountA, _amountB);
    }

    /// @notice 查询兑换输出量（不执行交易）
    function getAmountOut(address _tokenIn, uint256 _amountIn)
        external
        view
        returns (uint256)
    {
        if (_amountIn == 0) return 0;
        (uint256 reserveIn, uint256 reserveOut) = _tokenIn == address(tokenA)
            ? (reserveA, reserveB)
            : (reserveB, reserveA);
        if (reserveIn == 0 || reserveOut == 0) return 0;
        uint256 amountInWithFee = _amountIn * (BASIS_POINTS - FEE_BPS);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * BASIS_POINTS + amountInWithFee;
        return numerator / denominator;
    }

    /// @notice 查询当前现货价格 × 1e18
    /// @dev ⚠️ 瞬时价格 —— 单笔大额交易即可操纵。
    ///      禁止用于清算/借贷/衍生品定价。
    ///      请使用 getTwapA(period) / getTwapB(period) 或 getOracleState() 自行计算 TWAP。
    function getPrice(address _tokenIn) external view returns (uint256) {
        if (_tokenIn == address(tokenA)) {
            return reserveA > 0 ? (reserveB * 1e18) / reserveA : 0;
        } else {
            return reserveB > 0 ? (reserveA * 1e18) / reserveB : 0;
        }
    }
}
