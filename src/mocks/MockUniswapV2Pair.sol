// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "./MockERC20.sol";

contract MockUniswapV2Pair is MockERC20 {
    address public immutable token0;
    address public immutable token1;
    address public router;

    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;

    modifier onlyRouter() {
        require(msg.sender == router, "NOT_ROUTER");
        _;
    }

    constructor(address token0_, address token1_, address router_) MockERC20("Uniswap V2 LP", "UNI-V2", 18) {
        token0 = token0_;
        token1 = token1_;
        router = router_;
    }

    function setRouter(address router_) external onlyRouter {
        router = router_;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    function mint(address to, uint256 amount) external override onlyRouter {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external override onlyRouter {
        require(balanceOf[from] >= amount, "BALANCE");
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function setReserves(uint256 newReserve0, uint256 newReserve1) external onlyRouter {
        require(newReserve0 <= type(uint112).max && newReserve1 <= type(uint112).max, "OVERFLOW");
        // forge-lint: disable-next-line(unsafe-typecast)
        reserve0 = uint112(newReserve0);
        // forge-lint: disable-next-line(unsafe-typecast)
        reserve1 = uint112(newReserve1);
        blockTimestampLast = uint32(block.timestamp);
    }

    function reprice(uint256 newPriceUsdcPerEth6) external onlyRouter {
        require(newPriceUsdcPerEth6 > 0, "PRICE");
        uint256 k = uint256(reserve0) * uint256(reserve1);
        if (k == 0) {
            return;
        }
        uint256 newReserveEth;
        uint256 newReserveUsdc;
        if (token0 == address(0)) revert("TOKEN0");
        // token0 is expected to be WETH in the tests
        newReserveEth = _sqrt((k * 1e18) / newPriceUsdcPerEth6);
        newReserveUsdc = k / newReserveEth;
        // forge-lint: disable-next-line(unsafe-typecast)
        reserve0 = uint112(newReserveEth);
        // forge-lint: disable-next-line(unsafe-typecast)
        reserve1 = uint112(newReserveUsdc);
        blockTimestampLast = uint32(block.timestamp);
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
