// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ImpermanentLossHedgingVault} from "../src/ImpermanentLossHedgingVault.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockWETH9} from "../src/mocks/MockWETH9.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";
import {MockUniswapV2Pair} from "../src/mocks/MockUniswapV2Pair.sol";
import {MockUniswapV2Router02} from "../src/mocks/MockUniswapV2Router02.sol";
import {MockAavePool} from "../src/mocks/MockAavePool.sol";

contract VaultTest is Test {
    MockERC20 usdc;
    MockWETH9 weth;
    MockOracle oracle;
    MockUniswapV2Pair pair;
    MockUniswapV2Router02 router;
    MockAavePool pool;
    ImpermanentLossHedgingVault vault;

    address alice = address(0xA11CE);

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockWETH9();
        router = new MockUniswapV2Router02(address(weth), address(usdc));
        pair = new MockUniswapV2Pair(address(weth), address(usdc), address(router));
        router.setPair(address(pair));
        oracle = new MockOracle(2000e8, 8, "ETH / USD");
        pool = new MockAavePool(address(weth));

        vault = new ImpermanentLossHedgingVault(
            address(this),
            address(router),
            address(pair),
            address(pool),
            address(oracle),
            address(usdc),
            address(weth),
            6
        );

        usdc.mint(alice, 100_000e6);
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    function testDepositAddsLiquidityAndDelta() public {
        vm.prank(alice);
        vault.deposit{value: 1 ether}(1 ether, 2000e6);

        assertGt(pair.balanceOf(address(vault)), 0);
        uint256 delta = vault.getCurrentDelta();
        assertApproxEqAbs(delta, 1 ether, 1e15);
        assertGt(vault.getCurrentDebt(), 0);
    }

    function testRebalanceUpAndDownWithPriceMoves() public {
        vm.prank(alice);
        vault.deposit{value: 1 ether}(1 ether, 2000e6);

        uint256 debt0 = vault.getCurrentDebt();
        assertGt(debt0, 0);

        router.reprice(2500e6);
        oracle.setAnswer(2500e8);
        vault.rebalance();
        uint256 debt1 = vault.getCurrentDebt();
        assertLt(debt1, debt0);

        router.reprice(1800e6);
        oracle.setAnswer(1800e8);
        vault.rebalance();
        uint256 debt2 = vault.getCurrentDebt();
        assertGt(debt2, debt1);
    }

    function testWithdrawApproximatesHoldForModerateMove() public {
        vm.prank(alice);
        vault.deposit{value: 1 ether}(1 ether, 2000e6);

        router.reprice(2100e6);
        oracle.setAnswer(2100e8);
        vault.rebalance();

        uint256 usdcBefore = usdc.balanceOf(alice);
        uint256 ethBefore = alice.balance;

        uint256 shares = vault.sharesOf(alice);
        vm.prank(alice);
        vault.withdraw(shares);

        uint256 receivedEth = alice.balance - ethBefore;
        uint256 receivedUsdc = usdc.balanceOf(alice) - usdcBefore;

        uint256 valueReceived = receivedEth * 2100 / 1e18 + receivedUsdc / 1e6;
        uint256 holdValue = 1 ether * 2100 / 1e18 + 2000e6 / 1e6;
        assertApproxEqRel(valueReceived, holdValue, 0.03e18);
    }
}
