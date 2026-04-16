// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
// forge-lint: disable-file(mixed-case-function)

import {MockUniswapV2Pair} from "./MockUniswapV2Pair.sol";
import {IUniswapV2Router02} from "../interfaces/IUniswapV2Router02.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockUniswapV2Router02 is IUniswapV2Router02 {
    using SafeERC20 for IERC20;

    address public immutable override WETH;
    MockUniswapV2Pair public pair;
    IERC20 public usdc;

    constructor(address weth_, address usdc_) {
        WETH = weth_;
        usdc = IERC20(usdc_);
    }

    function setPair(address pair_) external {
        pair = MockUniswapV2Pair(pair_);
    }

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountEthMin,
        address to,
        uint256 deadline
    ) external payable override returns (uint256 amountToken, uint256 amountEth, uint256 liquidity) {
        require(block.timestamp <= deadline, "DEADLINE");
        require(token == address(usdc), "TOKEN");
        require(msg.value >= amountEthMin, "ETH_MIN");

        amountToken = amountTokenDesired;
        amountEth = msg.value;

        if (amountToken < amountTokenMin || amountEth < amountEthMin) revert("SLIPPAGE");

        usdc.safeTransferFrom(msg.sender, address(this), amountToken);
        uint256 beforeLp = pair.balanceOf(to);
        liquidity = _liquidity(amountEth, amountToken);
        pair.mint(to, liquidity);
        _syncAfterAdd(amountEth, amountToken);
        liquidity = pair.balanceOf(to) - beforeLp;
    }

    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountEthMin,
        address to,
        uint256 deadline
    ) external override returns (uint256 amountToken, uint256 amountEth) {
        require(block.timestamp <= deadline, "DEADLINE");
        require(token == address(usdc), "TOKEN");
        uint256 supply = pair.totalSupply();
        require(supply > 0, "NO_LP");
        require(liquidity <= pair.balanceOf(msg.sender), "LP_BALANCE");

        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 reserveEth = pair.token0() == WETH ? uint256(r0) : uint256(r1);
        uint256 reserveUsdc = pair.token0() == WETH ? uint256(r1) : uint256(r0);
        uint256 shareNum = liquidity;
        uint256 shareDen = supply;

        amountEth = reserveEth * shareNum / shareDen;
        amountToken = reserveUsdc * shareNum / shareDen;
        if (amountEth < amountEthMin || amountToken < amountTokenMin) revert("SLIPPAGE");

        pair.burn(msg.sender, liquidity);
        if (pair.token0() == WETH) {
            pair.setReserves(reserveEth - amountEth, reserveUsdc - amountToken);
        } else {
            pair.setReserves(reserveUsdc - amountToken, reserveEth - amountEth);
        }

        (bool ok,) = payable(to).call{value: amountEth}("");
        require(ok, "ETH_SEND");
        usdc.safeTransfer(to, amountToken);
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external override returns (uint256[] memory amounts) {
        require(block.timestamp <= deadline, "DEADLINE");
        require(path.length == 2, "PATH");
        address tokenIn = path[0];
        address tokenOut = path[1];
        require((tokenIn == address(usdc) && tokenOut == WETH) || (tokenIn == WETH && tokenOut == address(usdc)), "PAIR");

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 amountOut = getAmountsOut(amountIn, path)[1];
        require(amountOut >= amountOutMin, "MIN_OUT");

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;

        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 reserveIn = tokenIn == WETH ? uint256(r0) : uint256(r1);
        uint256 reserveOut = tokenIn == WETH ? uint256(r1) : uint256(r0);
        uint256 amountInWithFee = amountIn * 997 / 1000;
        uint256 amountOutCheck = reserveOut * amountInWithFee / (reserveIn + amountInWithFee);
        require(amountOutCheck >= amountOutMin, "CHECK");

        if (tokenIn == WETH) {
            pair.setReserves(reserveIn + amountIn, reserveOut - amountOutCheck);
        } else {
            pair.setReserves(reserveOut - amountOutCheck, reserveIn + amountIn);
        }

        IERC20(tokenOut).safeTransfer(to, amountOutCheck);
        amounts[1] = amountOutCheck;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) public view override returns (uint256[] memory amounts) {
        require(path.length == 2, "PATH");
        address tokenIn = path[0];
        address tokenOut = path[1];
        require((tokenIn == address(usdc) && tokenOut == WETH) || (tokenIn == WETH && tokenOut == address(usdc)), "PAIR");

        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 reserveIn = tokenIn == WETH ? uint256(r0) : uint256(r1);
        uint256 reserveOut = tokenIn == WETH ? uint256(r1) : uint256(r0);

        uint256 amountInWithFee = amountIn * 997 / 1000;
        uint256 amountOut = reserveOut * amountInWithFee / (reserveIn + amountInWithFee);

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;
    }

    function reprice(uint256 newPriceUsdcPerEth6) external {
        pair.reprice(newPriceUsdcPerEth6);
    }

    function _liquidity(uint256 amountEth, uint256 amountUsdc) internal pure returns (uint256) {
        uint256 normalizedUsdc = amountUsdc * 1e12;
        return _sqrt(amountEth * normalizedUsdc);
    }

    function _syncAfterAdd(uint256 amountEth, uint256 amountUsdc) internal {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        if (pair.token0() == WETH) {
            pair.setReserves(uint256(r0) + amountEth, uint256(r1) + amountUsdc);
        } else {
            pair.setReserves(uint256(r0) + amountUsdc, uint256(r1) + amountEth);
        }
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y == 0) return 0;
        uint256 x = y / 2 + 1;
        z = y;
        while (x < z) {
            z = x;
            x = (y / x + x) / 2;
        }
    }
}
