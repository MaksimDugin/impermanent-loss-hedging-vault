// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPool} from "../interfaces/IPool.sol";
import {MockWETH9} from "./MockWETH9.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockAavePool is IPool {
    using SafeERC20 for IERC20;

    MockWETH9 public immutable weth;

    constructor(address weth_) {
        weth = MockWETH9(payable(weth_));
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external override {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
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
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        if (onBehalfOf != msg.sender) {
            // no-op in the mock
        }
        return amount;
    }
}
