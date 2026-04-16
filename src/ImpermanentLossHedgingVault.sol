// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IUniswapV2Router02.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./interfaces/IPool.sol";
import "./interfaces/AggregatorV3Interface.sol";
import "./interfaces/IWETH9.sol";

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


/// @title Delta-Neutral Liquidity Vault
/// @notice MVP vault for ETH/USDC LP deposits with an Aave V3 borrow-side hedge.
contract ImpermanentLossHedgingVault is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAmount();
    error InvalidPair();
    error SlippageExceeded();
    error InsufficientShares();
    error RebalanceNoOp();
    error PriceFeedStale();
    error DeadlineExpired();
    error NotEnoughLiquidity();

    event Deposited(address indexed user, uint256 amountETH, uint256 amountUSDC, uint256 lpMinted, uint256 debtOpened);
    event Withdrawn(address indexed user, uint256 lpBurned, uint256 ethOut, uint256 usdcOut, uint256 debtRepaid);
    event Rebalanced(uint256 targetDebt, uint256 currentDebt, uint256 deltaAbs, bool increased);
    event ParamsUpdated(uint256 rebalanceThresholdBps, uint256 slippageBps, uint256 rebalanceIntervalBlocks);
    event PausedVault();
    event UnpausedVault();

    IUniswapV2Router02 public immutable router;
    IUniswapV2Pair public immutable pair;
    IPool public immutable pool;
    AggregatorV3Interface public immutable ethUsdOracle;
    IERC20 public immutable usdc;
    IWETH9 public immutable weth;

    uint8 public immutable usdcDecimals;
    uint8 public immutable oracleDecimals;

    uint256 public rebalanceThresholdBps = 100; // 1%
    uint256 public slippageBps = 100; // 1%
    uint256 public rebalanceIntervalBlocks = 20;

    uint256 public lastRebalanceBlock;
    uint256 public totalShares;
    uint256 public totalPrincipalEth;
    uint256 public totalPrincipalUsdc;

    uint256 public borrowedWeth; // debt in WETH units (18 decimals)
    uint256 public minOracleStaleness = 2 hours;

    mapping(address => uint256) public sharesOf;

    constructor(
        address initialOwner,
        address router_,
        address pair_,
        address pool_,
        address oracle_,
        address usdc_,
        address weth_,
        uint8 usdcDecimals_
    ) Ownable(initialOwner) {
        router = IUniswapV2Router02(router_);
        pair = IUniswapV2Pair(pair_);
        pool = IPool(pool_);
        ethUsdOracle = AggregatorV3Interface(oracle_);
        usdc = IERC20(usdc_);
        weth = IWETH9(weth_);
        usdcDecimals = usdcDecimals_;
        oracleDecimals = ethUsdOracle.decimals();

        _validatePair();
        _approveInfinite();
    }

    /// @notice Deposit ETH + USDC, add liquidity to Uniswap V2, then open/adjust the short hedge on Aave.
    /// @dev Slippage and fee assumptions matter here: the router quote is used only as a minimum bound.
    function deposit(uint256 amountETH, uint256 amountUSDC) external payable nonReentrant whenNotPaused {
        if (amountETH == 0 || amountUSDC == 0) revert ZeroAmount();
        if (msg.value != amountETH) revert ZeroAmount();

        uint256 balanceBeforeUSDC = usdc.balanceOf(address(this));
        uint256 ethBalanceBefore = address(this).balance - amountETH;

        usdc.safeTransferFrom(msg.sender, address(this), amountUSDC);
        usdc.forceApprove(address(router), 0);
        usdc.forceApprove(address(router), amountUSDC);

        uint256 minToken = _applyBps(amountUSDC, 10_000 - slippageBps);
        uint256 minEth = _applyBps(amountETH, 10_000 - slippageBps);

        (, , uint256 liquidity) = router.addLiquidityETH{value: amountETH}(
            address(usdc),
            amountUSDC,
            minToken,
            minEth,
            address(this),
            block.timestamp + 15 minutes
        );

        uint256 usdcUsed = balanceBeforeUSDC + amountUSDC - usdc.balanceOf(address(this));
        uint256 ethUsed = ethBalanceBefore + amountETH - address(this).balance;
        uint256 ethRefund = amountETH - ethUsed;

        if (ethRefund > 0) {
            (bool ok,) = msg.sender.call{value: ethRefund}("");
            require(ok, "ETH_REFUND_FAILED");
        }

        uint256 usdcRefund = amountUSDC - usdcUsed;
        if (usdcRefund > 0) {
            usdc.safeTransfer(msg.sender, usdcRefund);
        }

        sharesOf[msg.sender] += liquidity;
        totalShares += liquidity;
        totalPrincipalEth += ethUsed;
        totalPrincipalUsdc += usdcUsed;

        uint256 debtOpened = _rebalanceToTarget();

        emit Deposited(msg.sender, ethUsed, usdcUsed, liquidity, debtOpened);
    }

    /// @notice Withdraw a proportional share of vault LP and unwind the matching debt.
    /// @dev For production, consider adding explicit accounting of swap fees and price-impact on exit.
    function withdraw(uint256 lpAmount) external nonReentrant whenNotPaused {
        if (lpAmount == 0) revert ZeroAmount();
        if (sharesOf[msg.sender] < lpAmount) revert InsufficientShares();
        if (totalShares == 0) revert NotEnoughLiquidity();

        uint256 totalSharesBefore = totalShares;
        uint256 principalEthBefore = totalPrincipalEth;
        uint256 principalUsdcBefore = totalPrincipalUsdc;
        uint256 debtBefore = borrowedWeth;

        uint256 userEthPrincipal = principalEthBefore * lpAmount / totalSharesBefore;
        uint256 userUsdcPrincipal = principalUsdcBefore * lpAmount / totalSharesBefore;
        uint256 debtToRepay = debtBefore * lpAmount / totalSharesBefore;

        sharesOf[msg.sender] -= lpAmount;
        totalShares = totalSharesBefore - lpAmount;
        totalPrincipalEth = principalEthBefore - userEthPrincipal;
        totalPrincipalUsdc = principalUsdcBefore - userUsdcPrincipal;

        uint256 ethBefore = address(this).balance;
        uint256 usdcBefore = usdc.balanceOf(address(this));
        uint256 wethBefore = IERC20(address(weth)).balanceOf(address(this));

        usdc.forceApprove(address(router), 0);

        uint256 ethOut;
        uint256 usdcOut;
        (usdcOut, ethOut) = router.removeLiquidityETH(
            address(usdc),
            lpAmount,
            0,
            0,
            address(this),
            block.timestamp + 15 minutes
        );

        if (debtToRepay > 0) {
            uint256 debtClosed = _repayDebtWithAvailableBalances(debtToRepay);
            emit Withdrawn(msg.sender, lpAmount, ethOut, usdcOut, debtClosed);
        } else {
            emit Withdrawn(msg.sender, lpAmount, ethOut, usdcOut, 0);
        }

        if (totalShares == 0) {
            uint256 debtRemaining = borrowedWeth;
            if (debtRemaining > 0) {
                uint256 usdcBal = usdc.balanceOf(address(this));
                if (usdcBal > 0) {
                    _swapExact(address(usdc), address(weth), usdcBal);
                }

                uint256 wethBal = IERC20(address(weth)).balanceOf(address(this));
                uint256 repayAmount = wethBal < debtRemaining ? wethBal : debtRemaining;
                if (repayAmount > 0) {
                    IERC20(address(weth)).forceApprove(address(pool), 0);
                    IERC20(address(weth)).forceApprove(address(pool), repayAmount);
                    pool.repay(address(weth), repayAmount, 2, address(this));
                    borrowedWeth -= repayAmount;
                }
                if (borrowedWeth > 0) revert NotEnoughLiquidity();
            }

            uint256 remainingWeth = IERC20(address(weth)).balanceOf(address(this));
            if (remainingWeth > 0) {
                weth.withdraw(remainingWeth);
            }

            uint256 finalEth = address(this).balance;
            if (finalEth > 0) {
                (bool ok,) = msg.sender.call{value: finalEth}("");
                require(ok, "ETH_SEND_FAILED");
            }

            uint256 finalUsdc = usdc.balanceOf(address(this));
            if (finalUsdc > 0) {
                usdc.safeTransfer(msg.sender, finalUsdc);
            }
        } else {
            // Proportional LP exit proceeds are already held here; only the withdrawn LP share leaves the vault.
            uint256 deltaEth = address(this).balance - ethBefore;
            uint256 currentUsdc = usdc.balanceOf(address(this));
            uint256 deltaUsdc = currentUsdc > usdcBefore ? currentUsdc - usdcBefore : 0;
            if (deltaEth > 0) {
                (bool ok,) = msg.sender.call{value: deltaEth}("");
                require(ok, "ETH_SEND_FAILED");
            }
            if (deltaUsdc > 0) {
                usdc.safeTransfer(msg.sender, deltaUsdc);
            }
            uint256 deltaWeth = IERC20(address(weth)).balanceOf(address(this)) - wethBefore;
            if (deltaWeth > 0) {
                // Keep WETH inside the vault for remaining shares in the partial-withdraw case.
            }
        }
    }

    /// @notice Public keeper-style rebalance entrypoint.
    /// @dev The amount of ETH to borrow/repay is estimated from current LP delta and the Uniswap V2 reserves.
    function rebalance() public nonReentrant whenNotPaused returns (uint256 debtChange) {
        debtChange = _rebalanceToTarget();
    }

    /// @notice Return the current LP delta of the whole vault, in WETH units.
    /// @dev For a Uniswap V2 ETH/USDC pool this equals the vault's proportional ETH reserve exposure.
    function getCurrentDelta() public view returns (uint256) {
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        address token0 = pair.token0();
        uint256 reserveEth = token0 == address(weth) ? uint256(reserve0) : uint256(reserve1);
        uint256 supply = pair.totalSupply();
        if (supply == 0 || reserveEth == 0 || totalShares == 0) {
            return 0;
        }
        return reserveEth * totalShares / supply;
    }

    /// @notice Approximate impermanent loss of the unhedged LP leg versus simple hodl, in 1e18 precision.
    function getImpermanentLoss() public view returns (int256) {
        uint256 price = _priceEthUsd1e18();
        uint256 lpValue = _currentLpValue1e18(price);
        uint256 hodlValue = _hodlValue1e18(price);
        if (hodlValue == 0) return 0;
        int256 ratio = int256((lpValue * 1e18) / hodlValue);
        return ratio - int256(1e18);
    }

    /// @notice Return current hedge debt in WETH units.
    function getCurrentDebt() external view returns (uint256) {
        return borrowedWeth;
    }

    function pause() external onlyOwner {
        _pause();
        emit PausedVault();
    }

    function unpause() external onlyOwner {
        _unpause();
        emit UnpausedVault();
    }

    function setRiskParams(uint256 thresholdBps, uint256 slippageBps_, uint256 intervalBlocks) external onlyOwner {
        require(thresholdBps <= 5_000, "THRESHOLD_TOO_HIGH");
        require(slippageBps_ <= 2_000, "SLIPPAGE_TOO_HIGH");
        rebalanceThresholdBps = thresholdBps;
        slippageBps = slippageBps_;
        rebalanceIntervalBlocks = intervalBlocks;
        emit ParamsUpdated(thresholdBps, slippageBps_, intervalBlocks);
    }

    function setOracleStaleness(uint256 maxAge) external onlyOwner {
        minOracleStaleness = maxAge;
    }

    receive() external payable {}

    function _rebalanceToTarget() internal returns (uint256 debtChange) {
        uint256 targetDebt = getCurrentDelta();
        uint256 currentDebt = borrowedWeth;

        uint256 threshold = targetDebt * rebalanceThresholdBps / 10_000;
        uint256 deltaAbs = targetDebt > currentDebt ? targetDebt - currentDebt : currentDebt - targetDebt;

        if (deltaAbs <= threshold) {
            emit Rebalanced(targetDebt, currentDebt, deltaAbs, false);
            return 0;
        }

        if (block.number < lastRebalanceBlock + rebalanceIntervalBlocks) {
            // Keeper can still call; interval is informational in the MVP.
        }

        lastRebalanceBlock = block.number;

        if (targetDebt > currentDebt) {
            debtChange = targetDebt - currentDebt;
            _borrowAndSellWeth(debtChange);
            borrowedWeth = targetDebt;
            emit Rebalanced(targetDebt, currentDebt, debtChange, true);
        } else {
            debtChange = currentDebt - targetDebt;
            uint256 repaid = _buyWethAndRepay(debtChange);
            borrowedWeth = currentDebt - repaid;
            debtChange = repaid;
            emit Rebalanced(targetDebt, currentDebt, debtChange, false);
        }
    }

    function _borrowAndSellWeth(uint256 amountWeth) internal {
        pool.borrow(address(weth), amountWeth, 2, 0, address(this));
        _swapExact(address(weth), address(usdc), amountWeth);
    }

    function _buyWethAndRepay(uint256 amountWeth) internal returns (uint256 repaid) {
        uint256 usdcNeeded = _quoteExactOut(address(usdc), address(weth), amountWeth);
        uint256 usdcBalance = usdc.balanceOf(address(this));
        if (usdcNeeded > usdcBalance) {
            usdcNeeded = usdcBalance;
        }
        if (usdcNeeded > 0) {
            _swapExact(address(usdc), address(weth), usdcNeeded);
        }

        uint256 wethBal = IERC20(address(weth)).balanceOf(address(this));
        repaid = amountWeth;
        if (wethBal < repaid) {
            repaid = wethBal;
        }
        if (repaid == 0) return 0;

        IERC20(address(weth)).forceApprove(address(pool), 0);
        IERC20(address(weth)).forceApprove(address(pool), repaid);
        pool.repay(address(weth), repaid, 2, address(this));
        return repaid;
    }

    function _repayDebtWithAvailableBalances(uint256 amountWeth) internal returns (uint256 debtClosed) {
        uint256 usdcNeeded = _quoteExactOut(address(usdc), address(weth), amountWeth);
        uint256 usdcBalance = usdc.balanceOf(address(this));
        if (usdcNeeded > usdcBalance) {
            usdcNeeded = usdcBalance;
        }

        if (usdcNeeded > 0) {
            _swapExact(address(usdc), address(weth), usdcNeeded);
        }

        uint256 wethBal = IERC20(address(weth)).balanceOf(address(this));
        debtClosed = amountWeth;
        if (wethBal < debtClosed) {
            debtClosed = wethBal;
        }

        if (debtClosed > 0) {
            IERC20(address(weth)).forceApprove(address(pool), 0);
            IERC20(address(weth)).forceApprove(address(pool), debtClosed);
            pool.repay(address(weth), debtClosed, 2, address(this));
            borrowedWeth -= debtClosed;
        }
    }

    function _swapExact(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256 amountOut) {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        uint256 expectedOut = router.getAmountsOut(amountIn, path)[1];
        uint256 minOut = _applyBps(expectedOut, 10_000 - slippageBps);

        IERC20(tokenIn).forceApprove(address(router), 0);
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        uint256[] memory amounts = router.swapExactTokensForTokens(
            amountIn,
            minOut,
            path,
            address(this),
            block.timestamp + 15 minutes
        );
        amountOut = amounts[amounts.length - 1];
    }

    function _quoteExactOut(address tokenIn, address tokenOut, uint256 amountOutDesired) internal view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        uint256[] memory amounts = router.getAmountsOut(1e18, path);
        if (amounts[1] == 0) return 0;

        // approximate inverse quote, sufficient for MVP + keeper control loop
        uint256 price = amounts[1];
        if (tokenIn == address(usdc) && tokenOut == address(weth)) {
            // price is WETH out for 1e18 USDC input; invert.
            return amountOutDesired * 1e18 / price;
        }
        return amountOutDesired * 1e18 / price;
    }

    function _priceEthUsd1e18() internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = ethUsdOracle.latestRoundData();
        if (answer <= 0) revert PriceFeedStale();
        if (block.timestamp - updatedAt > minOracleStaleness) revert PriceFeedStale();
        uint256 raw = uint256(answer);
        if (oracleDecimals >= 18) {
            return raw / (10 ** (oracleDecimals - 18));
        }
        return raw * (10 ** (18 - oracleDecimals));
    }

    function _currentLpValue1e18(uint256 priceEthUsd1e18) internal view returns (uint256) {
        uint256 lpShare = pair.balanceOf(address(this));
        uint256 supply = pair.totalSupply();
        if (supply == 0 || lpShare == 0) return 0;

        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        uint256 reserveEth = pair.token0() == address(weth) ? uint256(reserve0) : uint256(reserve1);
        uint256 reserveUsdc = pair.token0() == address(weth) ? uint256(reserve1) : uint256(reserve0);

        uint256 userEth = reserveEth * lpShare / supply;
        uint256 userUsdc = reserveUsdc * lpShare / supply;

        uint256 ethValue = userEth * priceEthUsd1e18 / 1e18;
        uint256 usdcScale = 10 ** (18 - usdcDecimals);
        uint256 usdcValue = userUsdc * usdcScale;
        return ethValue + usdcValue;
    }

    function _hodlValue1e18(uint256 priceEthUsd1e18) internal view returns (uint256) {
        uint256 ethValue = totalPrincipalEth * priceEthUsd1e18 / 1e18;
        uint256 usdcScale = 10 ** (18 - usdcDecimals);
        uint256 usdcValue = totalPrincipalUsdc * usdcScale;
        return ethValue + usdcValue;
    }

    function _applyBps(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return amount * bps / 10_000;
    }

    function _validatePair() internal view {
        address token0 = pair.token0();
        address token1 = pair.token1();
        bool ok = (token0 == address(weth) && token1 == address(usdc)) || (token0 == address(usdc) && token1 == address(weth));
        if (!ok) revert InvalidPair();
    }

    function _approveInfinite() internal {
        usdc.forceApprove(address(router), type(uint256).max);
        usdc.forceApprove(address(pool), type(uint256).max);
        IERC20(address(weth)).forceApprove(address(router), type(uint256).max);
        IERC20(address(weth)).forceApprove(address(pool), type(uint256).max);
    }
}
