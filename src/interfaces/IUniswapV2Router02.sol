// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
// forge-lint: disable-file(mixed-case-function)

interface IUniswapV2Router02 {
    function WETH() external view returns (address);

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountEthMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountEth, uint256 liquidity);

    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountEthMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountToken, uint256 amountEth);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
}
