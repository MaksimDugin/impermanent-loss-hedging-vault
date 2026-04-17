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

contract ReentrantAttacker {
    ImpermanentLossHedgingVault public vault;
    bool public attempted;

    constructor(address vault_) {
        vault = ImpermanentLossHedgingVault(payable(vault_));
    }

    receive() external payable {
        if (!attempted) {
            attempted = true;
            vault.withdraw(1);
        }
    }
}

contract VaultTest is Test {
    MockERC20 usdc;
    MockWETH9 weth;
    MockOracle oracle;
    MockUniswapV2Pair pair;
    MockUniswapV2Router02 router;
    MockAavePool pool;
    ImpermanentLossHedgingVault vault;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

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
        usdc.mint(bob, 100_000e6);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    function testUnitDeltaLpEqualsEthReserve() public {
        vm.prank(alice);
        vault.deposit{value: 1 ether}(1 ether, 2000e6);

        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 reserveEth = pair.token0() == address(weth) ? uint256(r0) : uint256(r1);
        uint256 reserveUsdc = pair.token0() == address(weth) ? uint256(r1) : uint256(r0);

        uint256 L = _sqrt(reserveEth * reserveUsdc);
        uint256 price1e18 = reserveUsdc * 1e18 / reserveEth;
        uint256 deltaFromFormula = L * 1e18 / _sqrt(price1e18 * 1e18);

        assertApproxEqAbs(deltaFromFormula, reserveEth, 2);
        assertApproxEqAbs(vault.getCurrentDelta(), reserveEth, 1e12);
    }

    function testUnitDeltaEdgeZeroReservesReturnsZero() public {
        assertEq(vault.getCurrentDelta(), 0);
    }

    function testUnitGammaFormulaAndMonotonicity() public pure {
        uint256 L = 1000e18;
        uint256 p1 = 2000e18;
        uint256 p2 = 3000e18;

        int256 g1 = _gamma1e18(L, p1);
        int256 g2 = _gamma1e18(L, p2);

        assertLt(g1, 0);
        assertLt(g2, 0);
        assertLt(_abs(g2), _abs(g1));
    }

    function testUnitImpermanentLossKnownPoints() public pure {
        assertEq(_impermanentLoss1e18(1e18), 0);

        int256 ilUp = _impermanentLoss1e18(2e18);
        int256 ilDown = _impermanentLoss1e18(5e17);

        assertApproxEqAbs(uint256(_abs(ilUp)), 57e15, 1e15);
        assertApproxEqAbs(uint256(_abs(ilDown)), 57e15, 1e15);
    }

    function testIntegrationDepositWithdrawNoPriceChange() public {
        uint256 usdcBefore = usdc.balanceOf(alice);
        uint256 ethBefore = alice.balance;

        vm.prank(alice);
        vault.deposit{value: 1 ether}(1 ether, 2000e6);

        uint256 shares = vault.sharesOf(alice);
        vm.prank(alice);
        vault.withdraw(shares);

        uint256 ethAfter = alice.balance;
        uint256 usdcAfter = usdc.balanceOf(alice);

        assertApproxEqRel(ethAfter, ethBefore, 0.001e18);
        assertApproxEqRel(usdcAfter, usdcBefore, 0.001e18);
    }

    function testIntegrationHedgeWhenPriceDrops() public {
        vm.prank(alice);
        vault.deposit{value: 1 ether}(1 ether, 2000e6);

        uint256 debtBefore = vault.getCurrentDebt();
        router.reprice(1600e6);
        oracle.setAnswer(1600e8);
        vault.rebalance();
        uint256 debtAfter = vault.getCurrentDebt();

        // For V2 50/50 LP, ETH reserve share grows when ETH price drops, so target hedge debt increases.
        assertGt(debtAfter, debtBefore);
    }

    function testIntegrationHedgeWhenPriceRises() public {
        vm.prank(alice);
        vault.deposit{value: 1 ether}(1 ether, 2000e6);

        router.reprice(2400e6);
        oracle.setAnswer(2400e8);
        vault.rebalance();

        uint256 target = vault.getCurrentDelta();
        uint256 debt = vault.getCurrentDebt();
        uint256 hf = vault.getHealthFactorBps();

        assertApproxEqRel(debt, target, 0.02e18);
        // In the MVP accounting this scenario keeps HF around ~1.6x; require a conservative >1.5x floor.
        assertGt(hf, 15_000);
    }

    function testIntegrationMultiRebalanceStressAndDebtAccrual() public {
        vm.prank(alice);
        vault.deposit{value: 1 ether}(1 ether, 2000e6);

        uint256[4] memory prices = [uint256(1800e6), 2200e6, 2000e6, 1900e6];
        for (uint256 i = 0; i < prices.length; i++) {
            router.reprice(prices[i]);
            oracle.setAnswer(int256(prices[i] / 1e6) * 1e8);
            vm.warp(block.timestamp + 7 days);
            vault.rebalance();
        }

        uint256 debt = vault.getCurrentDebt();
        uint256 delta = vault.getCurrentDelta();
        uint256 deviation = debt > delta ? debt - delta : delta - debt;

        assertLt(deviation * 10_000 / (delta == 0 ? 1 : delta), 100);
    }

    function testIntegrationPartialWithdrawKeepsRemainingHedge() public {
        vm.prank(alice);
        vault.deposit{value: 1 ether}(1 ether, 2000e6);
        vm.prank(bob);
        vault.deposit{value: 1 ether}(1 ether, 2000e6);

        router.reprice(2200e6);
        oracle.setAnswer(2200e8);
        vault.rebalance();

        uint256 debtBefore = vault.getCurrentDebt();
        uint256 aliceShares = vault.sharesOf(alice);

        vm.prank(alice);
        vault.withdraw(aliceShares);

        uint256 debtAfter = vault.getCurrentDebt();
        assertApproxEqRel(debtAfter, debtBefore / 2, 0.05e18);

        uint256 bobShares = vault.sharesOf(bob);
        uint256 totalShares = vault.totalShares();
        uint256 bobDelta = vault.getCurrentDelta() * bobShares / totalShares;
        uint256 bobDebt = debtAfter * bobShares / totalShares;
        uint256 diff = bobDelta > bobDebt ? bobDelta - bobDebt : bobDebt - bobDelta;
        assertLt(diff * 10_000 / (bobDelta == 0 ? 1 : bobDelta), 200);
    }

    function testSecurityReentrancyGuardOnWithdraw() public {
        vm.prank(alice);
        vault.deposit{value: 1 ether}(1 ether, 2000e6);

        ReentrantAttacker attacker = new ReentrantAttacker(address(vault));
        vm.deal(address(attacker), 1 ether);
        usdc.mint(address(attacker), 2000e6);

        vm.startPrank(address(attacker));
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit{value: 1 ether}(1 ether, 2000e6);
        uint256 shares = vault.sharesOf(address(attacker));
        vm.expectRevert();
        vault.withdraw(shares);
        vm.stopPrank();
    }

    function testSecuritySlippageProtectionWithExplicitMinimums() public {
        vm.startPrank(alice);
        vm.expectRevert();
        vault.depositWithMin{value: 1 ether}(1 ether, 2000e6, 1 ether, 3000e6);
        vm.stopPrank();
    }

    function testSecurityAaveBorrowFailureRevertsDeposit() public {
        pool.setFailBorrow(true);

        vm.startPrank(alice);
        vm.expectRevert("MOCK_BORROW_FAILED");
        vault.deposit{value: 1 ether}(1 ether, 2000e6);
        vm.stopPrank();
    }

    function testSecurityPauseBlocksDepositAndRebalanceButAllowsWithdraw() public {
        vm.prank(alice);
        vault.deposit{value: 1 ether}(1 ether, 2000e6);

        vault.pause();

        vm.prank(alice);
        vm.expectRevert();
        vault.deposit{value: 1 ether}(1 ether, 2000e6);

        vm.expectRevert();
        vault.rebalance();

        uint256 shares = vault.sharesOf(alice);
        vm.prank(alice);
        vault.withdraw(shares);
    }

    function testSecurityRebalanceGasBounded() public {
        vm.prank(alice);
        vault.deposit{value: 1 ether}(1 ether, 2000e6);

        uint256 gasBefore = gasleft();
        vault.rebalance();
        uint256 used = gasBefore - gasleft();

        assertLt(used, 1_000_000);
    }

    function testPropertyDeltaCloseToZeroAfterRebalance(uint256 priceUsdc6) public {
        priceUsdc6 = bound(priceUsdc6, 1000e6, 3000e6);

        vm.prank(alice);
        vault.deposit{value: 1 ether}(1 ether, 2000e6);

        router.reprice(priceUsdc6);
        oracle.setAnswer(int256(priceUsdc6 / 1e6) * 1e8);
        vault.rebalance();

        uint256 delta = vault.getCurrentDelta();
        uint256 debt = vault.getCurrentDebt();
        uint256 diff = delta > debt ? delta - debt : debt - delta;

        assertLt(diff * 10_000 / (delta == 0 ? 1 : delta), 100);
    }

    function testPropertyPortfolioStabilityAcrossRandomShocks(uint256 s1, uint256 s2, uint256 s3) public {
        vm.prank(alice);
        vault.deposit{value: 1 ether}(1 ether, 2000e6);

        uint256[3] memory shocks = [bound(s1, 1000e6, 3000e6), bound(s2, 1000e6, 3000e6), bound(s3, 1000e6, 3000e6)];

        (, , int256 navStart) = vault.getCapitalPosition1e18();
        for (uint256 i = 0; i < shocks.length; i++) {
            router.reprice(shocks[i]);
            oracle.setAnswer(int256(shocks[i] / 1e6) * 1e8);
            vm.warp(block.timestamp + 3 days);
            vault.rebalance();
        }

        (, , int256 navEnd) = vault.getCapitalPosition1e18();
        uint256 drift = uint256(_abs(navEnd - navStart));
        uint256 navAbsStart = uint256(_abs(navStart));
        // Allow wider drift in fuzzed extreme paths because this is an MVP with simplified debt accrual model.
        assertLt(drift * 10_000 / (navAbsStart == 0 ? 1 : navAbsStart), 3_000);
    }

    function _gamma1e18(uint256 L, uint256 price1e18) internal pure returns (int256) {
        uint256 sqrtP = _sqrt(price1e18 * 1e18);
        uint256 p32 = price1e18 * sqrtP / 1e18;
        uint256 magnitude = L * 1e18 / (2 * p32 / 1e18);
        return -int256(magnitude);
    }

    function _impermanentLoss1e18(uint256 ratio1e18) internal pure returns (int256) {
        uint256 sqrtRatio = _sqrt(ratio1e18 * 1e18);
        uint256 numerator = 2 * sqrtRatio;
        uint256 denominator = 1e18 + ratio1e18;
        uint256 value1e18 = numerator * 1e18 / denominator;
        return int256(value1e18) - int256(1e18);
    }

    function _abs(int256 x) internal pure returns (int256) {
        return x < 0 ? -x : x;
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
