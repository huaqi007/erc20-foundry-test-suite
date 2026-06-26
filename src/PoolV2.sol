// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title SimplePoolV2 — 恒定乘积 AMM 交易池（安全修复版）
/// @notice 支持两种 ERC20 代币的兑换，0.3% 手续费
/// @dev 相对于 V1 修复了 SECURITY_AUDIT.md 中的 V-01~V-08 漏洞
contract SimplePoolV2 is ReentrancyGuard {
    using SafeERC20 for IERC20; // Fix: V-04 — USDT transfer 返回值未检查

    IERC20 public immutable tokenA;
    IERC20 public immutable tokenB;

    uint256 public reserveA;
    uint256 public reserveB;

    uint256 public constant FEE_BPS = 30; // 0.3% = 30 bps
    uint256 public constant BASIS_POINTS = 10000;

    event Swap(
        address indexed user,
        address indexed tokenIn,
        uint256 amountIn,
        address indexed tokenOut,
        uint256 amountOut
    );

    event LiquidityAdded(address indexed provider, uint256 amountA, uint256 amountB);

    event LiquidityRemoved(address indexed provider, uint256 amountA, uint256 amountB);

    constructor(address _tokenA, address _tokenB) {
        require(_tokenA != address(0) && _tokenB != address(0), "Invalid token");
        require(_tokenA != _tokenB, "Same token");
        tokenA = IERC20(_tokenA);
        tokenB = IERC20(_tokenB);
    }

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
    )
        external
        nonReentrant // Fix: V-02 — 跨函数重入保护（保持）
        returns (uint256 amountOut)
    {
        // Fix: V-06, V-08 — deadline 检查防止过期交易
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

        // Fix: V-01, V-05 — 余额快照法：记录实际到账，防止 FOT/rebasing token
        uint256 balanceBefore = tokenIn.balanceOf(address(this));
        tokenIn.safeTransferFrom(msg.sender, address(this), _amountIn); // Fix: V-04 — SafeERC20
        uint256 actualIn = tokenIn.balanceOf(address(this)) - balanceBefore;
        require(actualIn > 0, "Zero received");

        // 恒定乘积公式：amountOut = (amountIn * 9970 * reserveOut) / (reserveIn * 10000 + amountIn * 9970)
        uint256 amountInWithFee = actualIn * (BASIS_POINTS - FEE_BPS);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * BASIS_POINTS + amountInWithFee;
        amountOut = numerator / denominator;

        require(amountOut >= _amountOutMin, "Slippage exceeded");
        require(amountOut > 0, "Zero output"); // Fix: V-09 — 精度损失保护（保持）

        // Fix: V-07 — CEI：先更新储备量，再执行外部调用
        if (_tokenIn == address(tokenA)) {
            reserveA += actualIn;
            reserveB -= amountOut;
        } else {
            reserveB += actualIn;
            reserveA -= amountOut;
        }

        // 外部调用放在状态更新之后（CEI — Interactions phase）
        tokenOut.safeTransfer(msg.sender, amountOut); // Fix: V-04 — SafeERC20

        emit Swap(msg.sender, _tokenIn, actualIn, address(tokenOut), amountOut);
    }

    /// @notice 添加流动性
    function addLiquidity(uint256 _amountA, uint256 _amountB)
        external
        nonReentrant // Fix: V-02 — 跨函数重入保护
    {
        require(_amountA > 0 && _amountB > 0, "Amounts must be > 0");

        // Fix: V-01, V-05 — 余额快照：防御 FOT 和 rebasing token
        uint256 balABefore = tokenA.balanceOf(address(this));
        uint256 balBBefore = tokenB.balanceOf(address(this));

        tokenA.safeTransferFrom(msg.sender, address(this), _amountA); // Fix: V-04
        tokenB.safeTransferFrom(msg.sender, address(this), _amountB); // Fix: V-04

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
        nonReentrant // Fix: V-02 — 跨函数重入保护
    {
        require(_amountA > 0 && _amountB > 0, "Amounts must be > 0");
        require(_amountA <= reserveA && _amountB <= reserveB, "Insufficient reserves");

        // CEI: 先更新储备量（原版已正确）
        reserveA -= _amountA;
        reserveB -= _amountB;

        tokenA.safeTransfer(msg.sender, _amountA); // Fix: V-04 — SafeERC20
        tokenB.safeTransfer(msg.sender, _amountB); // Fix: V-04 — SafeERC20

        emit LiquidityRemoved(msg.sender, _amountA, _amountB);
    }

    /// @notice 查询兑换输出量（不执行交易）
    /// @dev 返回值假设标准 ERC20（无 FOT 费用），实际 swap 使用余额快照法保证安全
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

    /// @notice 查询当前现货价格（输出/输入）
    /// @dev ⚠️ 安全警告：此函数返回瞬时现货价格，极易被闪电贷/大额交易操纵。
    ///      禁止将此价格作为清算、借贷、衍生品结算等关键业务的 oracle。
    ///      如需可信价格，请集成 TWAP（时间加权平均价格）或 Chainlink oracle。
    ///      Fix: V-03 — Spot price oracle 使用警告
    function getPrice(address _tokenIn) external view returns (uint256) {
        if (_tokenIn == address(tokenA)) {
            return reserveA > 0 ? (reserveB * 1e18) / reserveA : 0;
        } else {
            return reserveB > 0 ? (reserveA * 1e18) / reserveB : 0;
        }
    }
}
