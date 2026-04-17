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

contract BacktestVaultScenarios is Test {
    struct StrategyMetrics {
        uint256 holdUsd1e18;
        uint256 lpUsd1e18;
        uint256 hedgedUsd1e18;
        int256 lpImpermanentLossUsd1e18;
        int256 hedgedImpermanentLossUsd1e18;
        uint256 hedgeCostUsd1e18;
        uint256 lpTrackingErrorBps;
        uint256 hedgedTrackingErrorBps;
    }

    MockERC20 internal usdc;
    MockWETH9 internal weth;
    MockOracle internal oracle;
    MockUniswapV2Pair internal pair;
    MockUniswapV2Router02 internal router;
    MockAavePool internal pool;
    ImpermanentLossHedgingVault internal vault;

    address internal constant HOLD_USER = address(0x1001);
    address internal constant LP_USER = address(0x1002);
    address internal constant HEDGE_USER = address(0x1003);

    uint256 internal constant INITIAL_ETH = 1 ether;
    uint256 internal constant INITIAL_USDC = 2_000e6;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockWETH9();
        router = new MockUniswapV2Router02(address(weth), address(usdc));
        pair = new MockUniswapV2Pair(address(weth), address(usdc), address(router));
        router.setPair(address(pair));
        oracle = new MockOracle(2_000e8, 8, "ETH / USD");
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

        _seedStartBalances(HOLD_USER);
        _seedStartBalances(LP_USER);
        _seedStartBalances(HEDGE_USER);

        // Seed router balances so mock swaps can always pay tokenOut on both legs.
        deal(address(usdc), address(router), 10_000_000e6);
        deal(address(weth), address(router), 10_000 ether);

        vm.prank(LP_USER);
        usdc.approve(address(router), type(uint256).max);

        vm.prank(HEDGE_USER);
        usdc.approve(address(vault), type(uint256).max);
    }

    /// @dev Launch command example:
    /// forge test --match-test testBacktestScenario_DowntrendThenRecovery --fork-url $RPC_URL --fork-block-number 20_000_000 -vv
    function testBacktestScenario_DowntrendThenRecovery() external {
        uint256[] memory path = new uint256[](4);
        path[0] = 1_700e6;
        path[1] = 1_450e6;
        path[2] = 1_850e6;
        path[3] = 2_050e6;

        StrategyMetrics memory m = _runBacktest(path, 3 days, 100);
        _assertBacktestSanity(m);

        // In this path hedge should track hold at least as tight as plain LP (allow tiny noise).
        assertLe(m.hedgedTrackingErrorBps, m.lpTrackingErrorBps + 50);
    }

    function testBacktestScenario_UpOnlyTrend() external {
        uint256[] memory path = new uint256[](4);
        path[0] = 2_250e6;
        path[1] = 2_500e6;
        path[2] = 2_900e6;
        path[3] = 3_200e6;

        StrategyMetrics memory m = _runBacktest(path, 5 days, 120);
        _assertBacktestSanity(m);

        // LP usually underperforms hold on strong trend due to IL; hedged strategy should be more stable.
        assertLe(m.hedgedTrackingErrorBps, m.lpTrackingErrorBps + 200);
    }

    function testBacktestScenario_HighVolatilityChop() external {
        uint256[] memory path = new uint256[](6);
        path[0] = 2_350e6;
        path[1] = 1_650e6;
        path[2] = 2_450e6;
        path[3] = 1_550e6;
        path[4] = 2_300e6;
        path[5] = 2_000e6;

        StrategyMetrics memory m = _runBacktest(path, 2 days, 80);
        _assertBacktestSanity(m);

        // Choppy market should still keep hedge strategy close to benchmark hold.
        assertLe(m.hedgedTrackingErrorBps, 2_500);
    }

    function _runBacktest(uint256[] memory shocksUsd6, uint256 stepTime, uint256 stepBlocks)
        internal
        returns (StrategyMetrics memory m)
    {
        emit log_named_uint("HOLD before", _walletValueUsd1e18(HOLD_USER, _priceTo1e18(shocksUsd6[0])));
        emit log_named_uint("LP before", _walletValueUsd1e18(LP_USER, _priceTo1e18(shocksUsd6[0])));
        emit log_named_uint("HEDGE before", _walletValueUsd1e18(HEDGE_USER, _priceTo1e18(shocksUsd6[0])));

        _runHoldStrategy(shocksUsd6);
        _runPlainLpStrategy(shocksUsd6);
        _runHedgedVaultStrategy(shocksUsd6, stepTime, stepBlocks);

        uint256 finalPrice1e18 = _priceTo1e18(shocksUsd6[shocksUsd6.length - 1]);

        emit log_named_uint("HOLD after", _walletValueUsd1e18(HOLD_USER, finalPrice1e18));
        emit log_named_uint("LP after", _walletValueUsd1e18(LP_USER, finalPrice1e18));
        emit log_named_uint("HEDGE after", _walletValueUsd1e18(HEDGE_USER, finalPrice1e18));

        m.holdUsd1e18 = _walletValueUsd1e18(HOLD_USER, finalPrice1e18);
        m.lpUsd1e18 = _walletValueUsd1e18(LP_USER, finalPrice1e18);
        m.hedgedUsd1e18 = _walletValueUsd1e18(HEDGE_USER, finalPrice1e18);

        m.lpImpermanentLossUsd1e18 = int256(m.lpUsd1e18) - int256(m.holdUsd1e18);
        m.hedgedImpermanentLossUsd1e18 = int256(m.hedgedUsd1e18) - int256(m.holdUsd1e18);

        // Cost of hedge as residual liability in USD at scenario end.
        m.hedgeCostUsd1e18 = vault.getCurrentDebt() * finalPrice1e18 / 1e18;

        m.lpTrackingErrorBps = _trackingErrorBps(m.lpUsd1e18, m.holdUsd1e18);
        m.hedgedTrackingErrorBps = _trackingErrorBps(m.hedgedUsd1e18, m.holdUsd1e18);

        emit log_named_uint("holdUsd1e18", m.holdUsd1e18);
        emit log_named_uint("lpUsd1e18", m.lpUsd1e18);
        emit log_named_uint("hedgedUsd1e18", m.hedgedUsd1e18);
        emit log_named_int("lpImpermanentLossUsd1e18", m.lpImpermanentLossUsd1e18);
        emit log_named_int("hedgedImpermanentLossUsd1e18", m.hedgedImpermanentLossUsd1e18);
        emit log_named_uint("hedgeCostUsd1e18", m.hedgeCostUsd1e18);
        emit log_named_uint("lpTrackingErrorBps", m.lpTrackingErrorBps);
        emit log_named_uint("hedgedTrackingErrorBps", m.hedgedTrackingErrorBps);
    }

    function _runHoldStrategy(uint256[] memory shocksUsd6) internal {
        for (uint256 i = 0; i < shocksUsd6.length; i++) {
            vm.warp(block.timestamp + 1 days);
            vm.roll(block.number + 25);
            router.reprice(shocksUsd6[i]);
            oracle.setAnswer(int256(shocksUsd6[i] / 1e6) * 1e8);
        }
    }

    function _runPlainLpStrategy(uint256[] memory shocksUsd6) internal {
        vm.prank(LP_USER);
        router.addLiquidityETH{value: INITIAL_ETH}(
            address(usdc), INITIAL_USDC, INITIAL_USDC, INITIAL_ETH, LP_USER, block.timestamp + 30 minutes
        );

        uint256 lpBalance = pair.balanceOf(LP_USER);

        for (uint256 i = 0; i < shocksUsd6.length; i++) {
            vm.warp(block.timestamp + 1 days);
            vm.roll(block.number + 30);
            router.reprice(shocksUsd6[i]);
            oracle.setAnswer(int256(shocksUsd6[i] / 1e6) * 1e8);
        }

        vm.prank(LP_USER);
        router.removeLiquidityETH(address(usdc), lpBalance, 0, 0, LP_USER, block.timestamp + 30 minutes);
    }

    function _runHedgedVaultStrategy(uint256[] memory shocksUsd6, uint256 stepTime, uint256 stepBlocks) internal {
        vm.prank(HEDGE_USER);
        vault.deposit{value: INITIAL_ETH}(INITIAL_ETH, INITIAL_USDC);

        for (uint256 i = 0; i < shocksUsd6.length; i++) {
            vm.warp(block.timestamp + stepTime);
            vm.roll(block.number + stepBlocks);
            router.reprice(shocksUsd6[i]);
            oracle.setAnswer(int256(shocksUsd6[i] / 1e6) * 1e8);
            vault.rebalance();
        }

        uint256 shares = vault.sharesOf(HEDGE_USER);
        vm.prank(HEDGE_USER);
        vault.withdraw(shares);
    }

    function _seedStartBalances(address user) internal {
        deal(user, INITIAL_ETH);
        deal(address(usdc), user, INITIAL_USDC);

        emit log_named_uint("seed ETH", user.balance);
        emit log_named_uint("seed USDC", usdc.balanceOf(user));
    }

    function _walletValueUsd1e18(address user, uint256 ethPrice1e18) internal returns (uint256) {
        uint256 ethBal = user.balance;
        uint256 usdcBal = usdc.balanceOf(user);

        emit log_named_uint("wallet ETH", ethBal);
        emit log_named_uint("wallet USDC", usdcBal);

        uint256 ethUsd = ethBal * ethPrice1e18 / 1e18;
        uint256 usdcUsd = usdcBal * 1e12;

        emit log_named_uint("wallet ETH USD", ethUsd);
        emit log_named_uint("wallet USDC USD", usdcUsd);

        return ethUsd + usdcUsd;
    }

    function _priceTo1e18(uint256 priceUsd6) internal pure returns (uint256) {
        return priceUsd6 * 1e12;
    }

    function _trackingErrorBps(uint256 strategyUsd1e18, uint256 benchmarkUsd1e18) internal pure returns (uint256) {
        if (benchmarkUsd1e18 == 0) return 0;
        uint256 diff = strategyUsd1e18 > benchmarkUsd1e18
            ? strategyUsd1e18 - benchmarkUsd1e18
            : benchmarkUsd1e18 - strategyUsd1e18;
        return diff * 10_000 / benchmarkUsd1e18;
    }

    function _assertBacktestSanity(StrategyMetrics memory m) internal pure {
        assertGt(m.holdUsd1e18, 0);
        assertGt(m.lpUsd1e18, 0);
        assertGt(m.hedgedUsd1e18, 0);
        assertLe(m.hedgedTrackingErrorBps, 10_000);
        assertLe(m.lpTrackingErrorBps, 10_000);
    }
}
