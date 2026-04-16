// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IPool.sol";
import "./MockERC20.sol";
import "./MockWETH9.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockAavePool is IPool {
    MockWETH9 public immutable weth;

    constructor(address weth_) {
        weth = MockWETH9(payable(weth_));
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external override {
        require(IERC20(asset).transferFrom(msg.sender, address(this), amount), "SUPPLY");
        if (onBehalfOf != msg.sender) {
            // no-op in the mock
        }
    }

    function borrow(address asset, uint256 amount, uint256, uint16, address onBehalfOf) external override {
        require(asset == address(weth), "ASSET");
        weth.mint(onBehalfOf, amount);
    }

    function repay(address asset, uint256 amount, uint256, address onBehalfOf) external override returns (uint256) {
        require(asset == address(weth), "ASSET");
        uint256 balance = IERC20(asset).balanceOf(msg.sender);
        if (balance < amount) {
            amount = balance;
        }
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        if (onBehalfOf != msg.sender) {
            // no-op in the mock
        }
        return amount;
    }
}
