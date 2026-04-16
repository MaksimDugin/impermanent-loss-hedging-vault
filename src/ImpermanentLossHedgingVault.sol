// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IUniswapV2Router02} from "./interfaces/IUniswapV2Router02.sol";
import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {IPool} from "./interfaces/IPool.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


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

    event Deposited(address indexed user, uint256 amountEth, uint256 amountUsdc, uint256 lpMinted, uint256 debtOpened);
    event Withdrawn(address indexed user, uint256 lpBurned, uint256 ethOut, uint256 usdcOut, uint256 debtRepaid);
    event Rebalanced(uint256 targetDebt, uint256 currentDebt, uint256 deltaAbs, bool increased);
    event ParamsUpdated(uint256 rebalanceThresholdBps, uint256 slippageBps, uint256 rebalanceIntervalBlocks);
    event PausedVault();
    event UnpausedVault();

    IUniswapV2Router02 public immutable ROUTER;
    IUniswapV2Pair public immutable PAIR;
    IPool public immutable POOL;
    AggregatorV3Interface public immutable ETH_USD_ORACLE;
    IERC20 public immutable USDC;
    IWETH9 public immutable WETH;

    uint8 public immutable USDC_DECIMALS;
    uint8 public immutable ORACLE_DECIMALS;

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
        ROUTER = IUniswapV2Router02(router_);
        PAIR = IUniswapV2Pair(pair_);
        POOL = IPool(pool_);
        ETH_USD_ORACLE = AggregatorV3Interface(oracle_);
        USDC = IERC20(usdc_);
        WETH = IWETH9(weth_);
        USDC_DECIMALS = usdcDecimals_;
        ORACLE_DECIMALS = ETH_USD_ORACLE.decimals();

        _validatePair();
        _approveInfinite();
    }

    /// @notice Deposit ETH + USDC, add liquidity to Uniswap V2, then open/adjust the short hedge on Aave.
    /// @dev Slippage and fee assumptions matter here: the router quote is used only as a minimum bound.
    function deposit(uint256 amountEth, uint256 amountUsdc) external payable nonReentrant whenNotPaused {
        if (amountEth == 0 || amountUsdc == 0) revert ZeroAmount();
        if (msg.value != amountEth) revert ZeroAmount();

        uint256 balanceBeforeUsdc = USDC.balanceOf(address(this));
        uint256 ethBalanceBefore = address(this).balance - amountEth;

        USDC.safeTransferFrom(msg.sender, address(this), amountUsdc);
        USDC.forceApprove(address(ROUTER), 0);
        USDC.forceApprove(address(ROUTER), amountUsdc);

        uint256 minToken = _applyBps(amountUsdc, 10_000 - slippageBps);
        uint256 minEth = _applyBps(amountEth, 10_000 - slippageBps);

        (, , uint256 liquidity) = ROUTER.addLiquidityETH{value: amountEth}(
            address(USDC),
            amountUsdc,
            minToken,
            minEth,
            address(this),
            block.timestamp + 15 minutes
        );

        uint256 usdcUsed = balanceBeforeUsdc + amountUsdc - USDC.balanceOf(address(this));
        uint256 ethUsed = ethBalanceBefore + amountEth - address(this).balance;
        uint256 ethRefund = amountEth - ethUsed;

        if (ethRefund > 0) {
            (bool ok,) = msg.sender.call{value: ethRefund}("");
            require(ok, "ETH_REFUND_FAILED");
        }

        uint256 usdcRefund = amountUsdc - usdcUsed;
        if (usdcRefund > 0) {
            USDC.safeTransfer(msg.sender, usdcRefund);
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
        uint256 usdcBefore = USDC.balanceOf(address(this));
        uint256 wethBefore = IERC20(address(WETH)).balanceOf(address(this));

        USDC.forceApprove(address(ROUTER), 0);

        uint256 ethOut;
        uint256 usdcOut;
        (usdcOut, ethOut) = ROUTER.removeLiquidityETH(
            address(USDC),
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
                uint256 usdcBal = USDC.balanceOf(address(this));
                if (usdcBal > 0) {
                    _swapExact(address(USDC), address(WETH), usdcBal);
                }

                uint256 wethBal = IERC20(address(WETH)).balanceOf(address(this));
                uint256 repayAmount = wethBal < debtRemaining ? wethBal : debtRemaining;
                if (repayAmount > 0) {
                    IERC20(address(WETH)).forceApprove(address(POOL), 0);
                    IERC20(address(WETH)).forceApprove(address(POOL), repayAmount);
                    POOL.repay(address(WETH), repayAmount, 2, address(this));
                    borrowedWeth -= repayAmount;
                }
                if (borrowedWeth > 0) revert NotEnoughLiquidity();
            }

            uint256 remainingWeth = IERC20(address(WETH)).balanceOf(address(this));
            if (remainingWeth > 0) {
                WETH.withdraw(remainingWeth);
            }

            uint256 finalEth = address(this).balance;
            if (finalEth > 0) {
                (bool ok,) = msg.sender.call{value: finalEth}("");
                require(ok, "ETH_SEND_FAILED");
            }

            uint256 finalUsdc = USDC.balanceOf(address(this));
            if (finalUsdc > 0) {
                USDC.safeTransfer(msg.sender, finalUsdc);
            }
        } else {
            // Proportional LP exit proceeds are already held here; only the withdrawn LP share leaves the vault.
            uint256 deltaEth = address(this).balance - ethBefore;
            uint256 currentUsdc = USDC.balanceOf(address(this));
            uint256 deltaUsdc = currentUsdc > usdcBefore ? currentUsdc - usdcBefore : 0;
            if (deltaEth > 0) {
                (bool ok,) = msg.sender.call{value: deltaEth}("");
                require(ok, "ETH_SEND_FAILED");
            }
            if (deltaUsdc > 0) {
                USDC.safeTransfer(msg.sender, deltaUsdc);
            }
            uint256 deltaWeth = IERC20(address(WETH)).balanceOf(address(this)) - wethBefore;
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
        (uint112 reserve0, uint112 reserve1,) = PAIR.getReserves();
        address token0 = PAIR.token0();
        uint256 reserveEth = token0 == address(WETH) ? uint256(reserve0) : uint256(reserve1);
        uint256 supply = PAIR.totalSupply();
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
        // casting to 'int256' is safe because lpValue and hodlValue represent bounded vault accounting values
        // and their ratio scaled by 1e18 remains well below int256 max in this MVP.
        // forge-lint: disable-next-line(unsafe-typecast)
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
        POOL.borrow(address(WETH), amountWeth, 2, 0, address(this));
    }

    function _buyWethAndRepay(uint256 amountWeth) internal returns (uint256 repaid) {
        uint256 wethBal = IERC20(address(WETH)).balanceOf(address(this));
        if (wethBal < amountWeth) {
            uint256 missingWeth = amountWeth - wethBal;
            uint256 ethBalance = address(this).balance;
            if (ethBalance > 0) {
                uint256 ethToWrap = missingWeth < ethBalance ? missingWeth : ethBalance;
                WETH.deposit{value: ethToWrap}();
                wethBal += ethToWrap;
            }
        }
        if (wethBal < amountWeth) {
            uint256 missingWeth = amountWeth - wethBal;
            uint256 usdcNeeded = _quoteExactOut(address(USDC), address(WETH), missingWeth);
            uint256 usdcBalance = USDC.balanceOf(address(this));
            if (usdcNeeded > usdcBalance) {
                usdcNeeded = usdcBalance;
            }
            if (usdcNeeded > 0) {
                _swapExact(address(USDC), address(WETH), usdcNeeded);
            }
        }
        wethBal = IERC20(address(WETH)).balanceOf(address(this));
        repaid = amountWeth;
        if (wethBal < repaid) {
            repaid = wethBal;
        }
        if (repaid == 0) return 0;

        IERC20(address(WETH)).forceApprove(address(POOL), 0);
        IERC20(address(WETH)).forceApprove(address(POOL), repaid);
        POOL.repay(address(WETH), repaid, 2, address(this));
        return repaid;
    }

    function _repayDebtWithAvailableBalances(uint256 amountWeth) internal returns (uint256 debtClosed) {
        uint256 wethBal = IERC20(address(WETH)).balanceOf(address(this));
        if (wethBal < amountWeth) {
            uint256 missingWeth = amountWeth - wethBal;
            uint256 ethBalance = address(this).balance;
            if (ethBalance > 0) {
                uint256 ethToWrap = missingWeth < ethBalance ? missingWeth : ethBalance;
                WETH.deposit{value: ethToWrap}();
                wethBal += ethToWrap;
            }
        }
        if (wethBal < amountWeth) {
            uint256 missingWeth = amountWeth - wethBal;
            uint256 usdcNeeded = _quoteExactOut(address(USDC), address(WETH), missingWeth);
            uint256 usdcBalance = USDC.balanceOf(address(this));
            if (usdcNeeded > usdcBalance) {
                usdcNeeded = usdcBalance;
            }
            if (usdcNeeded > 0) {
                _swapExact(address(USDC), address(WETH), usdcNeeded);
            }
        }

        wethBal = IERC20(address(WETH)).balanceOf(address(this));
        debtClosed = amountWeth;
        if (wethBal < debtClosed) {
            debtClosed = wethBal;
        }

        if (debtClosed > 0) {
            IERC20(address(WETH)).forceApprove(address(POOL), 0);
            IERC20(address(WETH)).forceApprove(address(POOL), debtClosed);
            POOL.repay(address(WETH), debtClosed, 2, address(this));
            borrowedWeth -= debtClosed;
        }
    }

    function _swapExact(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256 amountOut) {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        uint256 expectedOut = ROUTER.getAmountsOut(amountIn, path)[1];
        uint256 minOut = _applyBps(expectedOut, 10_000 - slippageBps);

        IERC20(tokenIn).forceApprove(address(ROUTER), 0);
        IERC20(tokenIn).forceApprove(address(ROUTER), amountIn);

        uint256[] memory amounts = ROUTER.swapExactTokensForTokens(
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

        uint256[] memory amounts = ROUTER.getAmountsOut(1e18, path);
        if (amounts[1] == 0) return 0;

        // approximate inverse quote, sufficient for MVP + keeper control loop
        uint256 price = amounts[1];
        if (tokenIn == address(USDC) && tokenOut == address(WETH)) {
            // price is WETH out for 1e18 USDC input; invert.
            return amountOutDesired * 1e18 / price;
        }
        return amountOutDesired * 1e18 / price;
    }

    function _priceEthUsd1e18() internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = ETH_USD_ORACLE.latestRoundData();
        if (answer <= 0) revert PriceFeedStale();
        if (block.timestamp - updatedAt > minOracleStaleness) revert PriceFeedStale();
        // casting to 'uint256' is safe because answer <= 0 is already rejected above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 raw = uint256(answer);
        if (ORACLE_DECIMALS >= 18) {
            return raw / (10 ** (ORACLE_DECIMALS - 18));
        }
        return raw * (10 ** (18 - ORACLE_DECIMALS));
    }

    function _currentLpValue1e18(uint256 priceEthUsd1e18) internal view returns (uint256) {
        uint256 lpShare = PAIR.balanceOf(address(this));
        uint256 supply = PAIR.totalSupply();
        if (supply == 0 || lpShare == 0) return 0;

        (uint112 reserve0, uint112 reserve1,) = PAIR.getReserves();
        uint256 reserveEth = PAIR.token0() == address(WETH) ? uint256(reserve0) : uint256(reserve1);
        uint256 reserveUsdc = PAIR.token0() == address(WETH) ? uint256(reserve1) : uint256(reserve0);

        uint256 userEth = reserveEth * lpShare / supply;
        uint256 userUsdc = reserveUsdc * lpShare / supply;

        uint256 ethValue = userEth * priceEthUsd1e18 / 1e18;
        uint256 usdcScale = 10 ** (18 - USDC_DECIMALS);
        uint256 usdcValue = userUsdc * usdcScale;
        return ethValue + usdcValue;
    }

    function _hodlValue1e18(uint256 priceEthUsd1e18) internal view returns (uint256) {
        uint256 ethValue = totalPrincipalEth * priceEthUsd1e18 / 1e18;
        uint256 usdcScale = 10 ** (18 - USDC_DECIMALS);
        uint256 usdcValue = totalPrincipalUsdc * usdcScale;
        return ethValue + usdcValue;
    }

    function _applyBps(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return amount * bps / 10_000;
    }

    function _validatePair() internal view {
        address token0 = PAIR.token0();
        address token1 = PAIR.token1();
        bool ok = (token0 == address(WETH) && token1 == address(USDC)) || (token0 == address(USDC) && token1 == address(WETH));
        if (!ok) revert InvalidPair();
    }

    function _approveInfinite() internal {
        USDC.forceApprove(address(ROUTER), type(uint256).max);
        USDC.forceApprove(address(POOL), type(uint256).max);
        IERC20(address(WETH)).forceApprove(address(ROUTER), type(uint256).max);
        IERC20(address(WETH)).forceApprove(address(POOL), type(uint256).max);
    }
}
