// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title SimplePool — 恒定乘积 AMM 交易池
/// @notice 支持两种 ERC20 代币的兑换，0.3% 手续费
contract SimplePool is ReentrancyGuard {
    IERC20 public immutable tokenA;
    IERC20 public immutable tokenB;

    uint256 public reserveA;
    uint256 public reserveB;

    uint256 public constant FEE_BPS = 30; // 0.3% = 30 bps
    uint256 public constant BASIS_POINTS = 10000;

    event Swap(
        address indexed user, address indexed tokenIn, uint256 amountIn, address indexed tokenOut, uint256 amountOut
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
    /// @return amountOut 实际输出数量
    function swap(address _tokenIn, uint256 _amountIn, uint256 _amountOutMin)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        require(_amountIn > 0, "AmountIn must be > 0");
        require(_tokenIn == address(tokenA) || _tokenIn == address(tokenB), "Invalid token");

        (IERC20 tokenIn, IERC20 tokenOut, uint256 reserveIn, uint256 reserveOut) =
            _tokenIn == address(tokenA) ? (tokenA, tokenB, reserveA, reserveB) : (tokenB, tokenA, reserveB, reserveA);

        require(reserveIn > 0 && reserveOut > 0, "Empty pool");

        // 恒定乘积公式：amountOut = (amountIn * 997 * reserveOut) / (reserveIn * 1000 + amountIn * 997)
        uint256 amountInWithFee = _amountIn * (BASIS_POINTS - FEE_BPS);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * BASIS_POINTS + amountInWithFee;
        amountOut = numerator / denominator;

        require(amountOut >= _amountOutMin, "Slippage exceeded");
        require(amountOut > 0, "Zero output");

        // 转移代币
        tokenIn.transferFrom(msg.sender, address(this), _amountIn);
        tokenOut.transfer(msg.sender, amountOut);

        // 更新储备量
        if (_tokenIn == address(tokenA)) {
            reserveA += _amountIn;
            reserveB -= amountOut;
        } else {
            reserveB += _amountIn;
            reserveA -= amountOut;
        }

        emit Swap(msg.sender, _tokenIn, _amountIn, address(tokenOut), amountOut);
    }

    /// @notice 添加流动性
    function addLiquidity(uint256 _amountA, uint256 _amountB) external {
        require(_amountA > 0 && _amountB > 0, "Amounts must be > 0");

        tokenA.transferFrom(msg.sender, address(this), _amountA);
        tokenB.transferFrom(msg.sender, address(this), _amountB);

        reserveA += _amountA;
        reserveB += _amountB;

        emit LiquidityAdded(msg.sender, _amountA, _amountB);
    }

    /// @notice 移除流动性
    function removeLiquidity(uint256 _amountA, uint256 _amountB) external {
        require(_amountA > 0 && _amountB > 0, "Amounts must be > 0");
        require(_amountA <= reserveA && _amountB <= reserveB, "Insufficient reserves");

        reserveA -= _amountA;
        reserveB -= _amountB;

        tokenA.transfer(msg.sender, _amountA);
        tokenB.transfer(msg.sender, _amountB);

        emit LiquidityRemoved(msg.sender, _amountA, _amountB);
    }

    /// @notice 查询兑换输出量（不执行交易）
    function getAmountOut(address _tokenIn, uint256 _amountIn) external view returns (uint256) {
        if (_amountIn == 0) return 0;

        (uint256 reserveIn, uint256 reserveOut) =
            _tokenIn == address(tokenA) ? (reserveA, reserveB) : (reserveB, reserveA);

        if (reserveIn == 0 || reserveOut == 0) return 0;

        uint256 amountInWithFee = _amountIn * (BASIS_POINTS - FEE_BPS);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * BASIS_POINTS + amountInWithFee;
        return numerator / denominator;
    }

    /// @notice 查询当前价格（输出/输入）
    function getPrice(address _tokenIn) external view returns (uint256) {
        if (_tokenIn == address(tokenA)) {
            return reserveA > 0 ? (reserveB * 1e18) / reserveA : 0;
        } else {
            return reserveB > 0 ? (reserveA * 1e18) / reserveB : 0;
        }
    }
}
