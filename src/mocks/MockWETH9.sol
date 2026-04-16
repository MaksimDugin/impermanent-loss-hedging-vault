// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockWETH9 is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    receive() external payable {
        deposit();
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function deposit() public payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        require(balanceOf(msg.sender) >= amount, "BALANCE");
        _burn(msg.sender, amount);
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        require(ok, "ETH_SEND_FAILED");
    }
}