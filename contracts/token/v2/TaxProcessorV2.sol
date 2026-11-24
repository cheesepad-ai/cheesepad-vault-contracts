// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ITaxProcessorV2} from "./ITaxProcessorV2.sol";
import {IDividendTrackerV2} from "./IDividendTrackerV2.sol";
import {ISwapRouter} from "./ISwapRouter.sol";
import {ICheeseTaxTokenV2} from "./ICheeseTaxTokenV2.sol";
import {IRevenueNotifiable} from "../../interfaces/IRevenueNotifiable.sol";
import {IUniswapV2Router02} from "../../interfaces/IUniswapV2Router02.sol";
import {IWETH} from "../../interfaces/IWETH.sol";
import {LibNativeAsset} from "../../launchpad/libraries/LibNativeAsset.sol";

/// @title TaxProcessorV2
/// @notice Per-token, ownerless revenue router. Immutable config; routes collected
///         tax across feeReceiver / holders / burn / liquidity slices, reallocating
///         the holder slice when there are no shares. Swaps go through the shared,
///         upgradeable SwapRouter.
contract TaxProcessorV2 is ITaxProcessorV2, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public immutable override token;
    address public immutable override router;
    address public immutable override swapRouter;
    address public immutable override quoteToken;
    address public immutable override weth;
    address public immutable override dividendTracker;
    address public immutable override feeReceiver;

    uint256 public immutable override feeReceiverBps;
    uint256 public immutable override holdersBps;
    uint256 public immutable override burnBps;
    uint256 public immutable override liquidityBps;

    /// @notice Reference quote output for a liquidation; drives the threshold signal.
    uint256 public immutable liqExpectedOutputAmount;

    /// @notice Platform cut (BPS) taken off the top of tax before the four slices.
    uint256 public immutable platformCutPostBps;
    /// @notice Platform cut (BPS) taken off the top of flushed curve-phase tax.
    uint256 public immutable platformCutPreBps;
    /// @notice Recipient of the platform cut (the platform treasury).
    address public immutable platformFeeReceiver;
    /// @notice The only caller of the curve-tax functions (the launchpad for a
    ///         bonding-curve launch); zero disables them (microsale launches).
    address public immutable curveConfigurator;
    /// @notice Set once the graduation cap is committed; permanently closes
    ///         `depositCurveTax` and `setDispatchSpendCap`.
    bool public curveTaxClosed;

    // ─── Curve-phase parked buckets (spent post-graduation) ────────────────────
    /// @notice Burn slice of curve tax, held as quote; spent via dispatchBurn.
    uint256 public parkedBurnQuote;
    /// @notice Liquidity slice of curve tax, held as quote; spent via dispatchLiquidity.
    uint256 public parkedLiquidityQuote;
    /// @notice Per-call spend ceiling for the parked buckets, set at graduation.
    uint256 public dispatchSpendCap;
    uint48 private _lastBurnSpendBlock;
    uint48 private _lastLiquiditySpendBlock;

    event Dispatched(
        uint256 totalDispatched,
        uint256 feeReceiverDelivered,
        uint256 holdersDelivered,
        uint256 burned
    );

    /// @notice Immutable construction config (struct avoids stack-too-deep at the
    ///         deploy site).
    struct InitConfig {
        address token;
        address router;
        address swapRouter;
        address quoteToken;
        address weth;
        address dividendTracker;
        address feeReceiver;
        uint256 feeReceiverBps;
        uint256 holdersBps;
        uint256 burnBps;
        uint256 liquidityBps;
        uint256 liqExpectedOutputAmount;
        uint256 platformCutPostBps;
        uint256 platformCutPreBps;
        address platformFeeReceiver;
        address curveConfigurator;
    }

    constructor(InitConfig memory c) {
        token = c.token;
        router = c.router;
        swapRouter = c.swapRouter;
        quoteToken = c.quoteToken;
        weth = c.weth;
        dividendTracker = c.dividendTracker;
        feeReceiver = c.feeReceiver;
        feeReceiverBps = c.feeReceiverBps;
        holdersBps = c.holdersBps;
        burnBps = c.burnBps;
        liquidityBps = c.liquidityBps;
        liqExpectedOutputAmount = c.liqExpectedOutputAmount;
        platformCutPostBps = c.platformCutPostBps;
        platformCutPreBps = c.platformCutPreBps;
        platformFeeReceiver = c.platformFeeReceiver;
        curveConfigurator = c.curveConfigurator;
    }

    /// @inheritdoc ITaxProcessorV2
    function processTaxTokens(uint256 amount)
        external
        override
        nonReentrant
        returns (int8)
    {
        require(msg.sender == token, "Not token");
        amount; // held balance is the source of truth
        uint256 valueOut = _flush();
        if (liqExpectedOutputAmount == 0) {
            return 0;
        }
        if (valueOut > liqExpectedOutputAmount) {
            return -1;
        }
        if (valueOut < liqExpectedOutputAmount) {
            return 1;
        }
        return 0;
    }

    /// @inheritdoc ITaxProcessorV2
    function dispatch() external override nonReentrant {
        _flush();
    }

    /// @dev Routes the full held balance through the four slices and returns the
    ///      quote delivered to the value slices (feeReceiver + holders).
    function _flush() private returns (uint256 valueOut) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) {
            return 0;
        }

        ICheeseTaxTokenV2(token).setSwapping(true);

        // Platform cut off the top — swapped to quote and HELD in the processor;
        // delivered to the platform only AFTER the swap window closes (below) so no
        // external recipient callback runs while tax is globally bypassed (W4).
        uint256 platformQuote;
        if (platformCutPostBps > 0 && platformFeeReceiver != address(0)) {
            uint256 platformCut = (balance * platformCutPostBps) / 10_000;
            if (platformCut > 0) {
                uint256 qb = IERC20(quoteToken).balanceOf(address(this));
                IERC20(token).forceApprove(swapRouter, platformCut);
                ISwapRouter(swapRouter).swapForQuoteFrom(
                    token,
                    address(this),
                    platformCut
                );
                platformQuote = IERC20(quoteToken).balanceOf(address(this)) - qb;
            }
        }

        // Remaining tax (after the platform cut) funds the creator's four slices.
        uint256 base = IERC20(token).balanceOf(address(this));
        bool holdersActive = dividendTracker != address(0) &&
            IDividendTrackerV2(dividendTracker).totalShares() > 0;
        uint256 rateTotal = feeReceiverBps +
            burnBps +
            liquidityBps +
            (holdersActive ? holdersBps : 0);
        // When every weighted slice is zero — an all-holders allocation whose holders
        // are momentarily ineligible (totalShares == 0) — rateTotal is 0. Each slice
        // guard below is then false, so nothing divides by it and the full balance
        // falls through to the liquidity remainder sweep. That explicit fallback keeps
        // the creator tax from being stranded (and re-charged the platform cut on
        // every later dispatch); once holders qualify, normal distribution resumes.
        if (base == 0) {
            ICheeseTaxTokenV2(token).setSwapping(false);
            if (platformQuote > 0) {
                _payQuoteOrNative(platformFeeReceiver, platformQuote);
            }
            return 0;
        }

        uint256 holdersDelivered;
        uint256 burned;

        // Holder slice — swapped to quote and deposited to the (trusted) tracker
        // inside the window; the tracker makes no external recipient callback.
        if (holdersActive && holdersBps > 0) {
            uint256 amount = (base * holdersBps) / rateTotal;
            if (amount > 0) {
                uint256 quoteBefore = IERC20(quoteToken).balanceOf(address(this));
                IERC20(token).forceApprove(swapRouter, amount);
                ISwapRouter(swapRouter).swapForQuoteFrom(
                    token,
                    address(this),
                    amount
                );
                uint256 out = IERC20(quoteToken).balanceOf(address(this)) -
                    quoteBefore;
                if (out > 0) {
                    IERC20(quoteToken).forceApprove(dividendTracker, out);
                    IDividendTrackerV2(dividendTracker).depositDividend(out);
                    holdersDelivered = out;
                }
            }
        }

        // Fee-receiver slice — swapped to quote and HELD; the (possibly untrusted)
        // recipient is paid and `onRevenue`-notified only after the window closes.
        uint256 feeReceiverQuote;
        if (feeReceiverBps > 0 && feeReceiver != address(0)) {
            uint256 amount = (base * feeReceiverBps) / rateTotal;
            if (amount > 0) {
                uint256 qb = IERC20(quoteToken).balanceOf(address(this));
                IERC20(token).forceApprove(swapRouter, amount);
                ISwapRouter(swapRouter).swapForQuoteFrom(
                    token,
                    address(this),
                    amount
                );
                feeReceiverQuote = IERC20(quoteToken).balanceOf(address(this)) - qb;
            }
        }

        if (burnBps > 0) {
            uint256 amount = (base * burnBps) / rateTotal;
            if (amount > 0) {
                IERC20(token).safeTransfer(DEAD, amount);
                burned = amount;
            }
        }

        uint256 remainder = IERC20(token).balanceOf(address(this));
        if (remainder > 0) {
            IERC20(token).forceApprove(swapRouter, remainder);
            ISwapRouter(swapRouter).addLiquidityFrom(token, remainder);
        }
        IERC20(token).forceApprove(swapRouter, 0);

        // ── Close the swap window BEFORE any external recipient interaction ──
        ICheeseTaxTokenV2(token).setSwapping(false);

        // Pay the platform + fee-receiver slices and fire onRevenue OUTSIDE the
        // window, so a contract recipient cannot reenter the router to sell
        // tax-free or retain a stale dividend share (W4).
        if (platformQuote > 0) {
            _payQuoteOrNative(platformFeeReceiver, platformQuote);
        }
        uint256 feeReceiverDelivered;
        if (feeReceiverQuote > 0) {
            _payQuoteOrNative(feeReceiver, feeReceiverQuote);
            feeReceiverDelivered = feeReceiverQuote;
            if (feeReceiver.code.length > 0) {
                try
                    IRevenueNotifiable(feeReceiver).onRevenue(feeReceiverQuote)
                {} catch {}
            }
        }

        // Distribute only the TRUE residual (swap/LP dust), reserving the parked
        // curve-phase buckets so dispatchBurn/dispatchLiquidity stay solvent (C1).
        uint256 parkedReserve = parkedBurnQuote + parkedLiquidityQuote;
        uint256 quoteHeld = IERC20(quoteToken).balanceOf(address(this));
        uint256 residualQuote = quoteHeld > parkedReserve
            ? quoteHeld - parkedReserve
            : 0;
        if (residualQuote > 0) {
            if (holdersActive) {
                IERC20(quoteToken).forceApprove(dividendTracker, residualQuote);
                IDividendTrackerV2(dividendTracker).depositDividend(residualQuote);
            } else if (feeReceiver != address(0)) {
                IERC20(quoteToken).safeTransfer(feeReceiver, residualQuote);
            }
        }

        // In UsdcPrecompile mode the native balance IS the quote (precompile ERC20)
        // the processor holds — including the reserved parked buckets — so sweeping
        // it here would double-spend them. The quote-residual sweep above already
        // returned the true residual in quote units; skip the native sweep.
        if (!LibNativeAsset.isPrecompile(weth)) {
            uint256 ethResidual = address(this).balance;
            if (ethResidual > 0 && feeReceiver != address(0)) {
                (bool ok, ) = payable(feeReceiver).call{value: ethResidual}("");
                ok;
            }
        }

        valueOut = feeReceiverDelivered + holdersDelivered;
        emit Dispatched(balance, feeReceiverDelivered, holdersDelivered, burned);
    }

    // ─── Curve-phase tax ───────────────────────────────────────────────────────

    event CurveTaxDeposited(
        uint256 grossQuote,
        uint256 platformCut,
        uint256 toFeeReceiver,
        uint256 toHolders,
        uint256 parkedBurn,
        uint256 parkedLiquidity
    );
    event BurnDispatched(uint256 quoteSpent, uint256 tokensBurned);
    event LiquidityDispatched(uint256 quoteSpent);

    modifier onlyOpenCurveConfigurator() {
        require(msg.sender == curveConfigurator, "Not configurator");
        require(!curveTaxClosed, "Curve tax closed");
        _;
    }

    /// @notice Allocates flushed curve-phase tax (already delivered here in quote):
    ///         platform cut off the top, feeReceiver + holders paid, burn + liquidity
    ///         parked for post-graduation dispatch. Callable only by the curve
    ///         configurator, until graduation closes it.
    function depositCurveTax(uint256 grossQuote)
        external
        nonReentrant
        onlyOpenCurveConfigurator
    {
        if (grossQuote == 0) return;

        uint256 platformCut = platformCutPreBps > 0
            ? (grossQuote * platformCutPreBps) / 10_000
            : 0;
        if (platformCut > 0 && platformFeeReceiver != address(0)) {
            _payQuoteOrNative(platformFeeReceiver, platformCut);
        }
        uint256 remaining = grossQuote - platformCut;

        uint256 rateTotal = feeReceiverBps + holdersBps + burnBps + liquidityBps;
        uint256 toFee = (remaining * feeReceiverBps) / rateTotal;
        uint256 toHolders = (remaining * holdersBps) / rateTotal;
        uint256 toBurn = (remaining * burnBps) / rateTotal;
        uint256 toLiquidity = remaining - toFee - toHolders - toBurn;

        bool holdersActive = dividendTracker != address(0) &&
            IDividendTrackerV2(dividendTracker).totalShares() > 0;

        if (toHolders > 0 && holdersActive) {
            IERC20(quoteToken).forceApprove(dividendTracker, toHolders);
            IDividendTrackerV2(dividendTracker).depositDividend(toHolders);
        } else if (toHolders > 0) {
            // No shares yet — fold the holder slice into the fee-receiver slice.
            toFee += toHolders;
        }

        if (toFee > 0 && feeReceiver != address(0)) {
            // Deliver as native ETH when the quote is WETH — the post-graduation
            // flush does the same, and a native-revenue vault only sees native
            // balance, so handing it WETH here would strand the funds.
            _payQuoteOrNative(feeReceiver, toFee);
            if (feeReceiver.code.length > 0) {
                try IRevenueNotifiable(feeReceiver).onRevenue(toFee) {} catch {}
            }
        }

        parkedBurnQuote += toBurn;
        parkedLiquidityQuote += toLiquidity;

        emit CurveTaxDeposited(
            grossQuote,
            platformCut,
            toFee,
            toHolders,
            toBurn,
            toLiquidity
        );
    }

    /// @notice Records the per-call spend ceiling for the parked buckets at
    ///         graduation and permanently closes both curve-tax functions.
    function setDispatchSpendCap(uint256 cap) external onlyOpenCurveConfigurator {
        dispatchSpendCap = cap;
        curveTaxClosed = true;
    }

    /// @notice Permissionless: spends one capped clip of the parked burn bucket by
    ///         buying tokens from the pair and burning them. One clip per block.
    function dispatchBurn()
        external
        nonReentrant
        returns (uint256 quoteSpent, uint256 tokensBurned)
    {
        if (block.number == _lastBurnSpendBlock) return (0, 0);
        uint256 clip = _clip(parkedBurnQuote);
        if (clip == 0) return (0, 0);
        _lastBurnSpendBlock = uint48(block.number);
        // Decrement by quote actually consumed: _buyBack swallows router reverts,
        // so charging the counter the full clip would strand the liability.
        uint256 quoteBefore = IERC20(quoteToken).balanceOf(address(this));
        tokensBurned = _buyBack(clip, DEAD);
        quoteSpent = quoteBefore - IERC20(quoteToken).balanceOf(address(this));
        parkedBurnQuote -= quoteSpent;
        emit BurnDispatched(quoteSpent, tokensBurned);
    }

    /// @notice Permissionless: spends one capped clip of the parked liquidity bucket
    ///         by buying tokens with half and adding liquidity. One clip per block.
    function dispatchLiquidity()
        external
        nonReentrant
        returns (uint256 quoteSpent)
    {
        if (block.number == _lastLiquiditySpendBlock) return 0;
        uint256 clip = _clip(parkedLiquidityQuote);
        if (clip == 0) return 0;
        _lastLiquiditySpendBlock = uint48(block.number);
        // Decrement by quote actually consumed: _addLiquidityFromQuote swallows
        // router reverts and refunds unpaired quote, so only what left the
        // processor should reduce the parked liability.
        uint256 quoteBefore = IERC20(quoteToken).balanceOf(address(this));
        _addLiquidityFromQuote(clip);
        quoteSpent = quoteBefore - IERC20(quoteToken).balanceOf(address(this));
        parkedLiquidityQuote -= quoteSpent;
        emit LiquidityDispatched(quoteSpent);
    }

    function _clip(uint256 parked) private view returns (uint256 clip) {
        // A zero cap is an unarmed dispatch window, not "unlimited": the cap is
        // set only at graduation, and a mid-curve flush can park buckets before
        // then. Treating an unarmed cap as dormant keeps those buckets unspendable
        // until graduation arms the cap, instead of relying on the pre-listing
        // pair being unfunded.
        if (dispatchSpendCap == 0) {
            return 0;
        }
        clip = parked;
        if (clip > dispatchSpendCap) {
            clip = dispatchSpendCap;
        }
    }

    /// @dev Buys `token` from the pair with `quoteAmount` and sends it to `to`.
    ///      Bypassed from tax via the swap window.
    function _buyBack(uint256 quoteAmount, address to)
        private
        returns (uint256 bought)
    {
        ICheeseTaxTokenV2(token).setSwapping(true);
        IERC20(quoteToken).forceApprove(router, quoteAmount);
        address[] memory path = new address[](2);
        path[0] = quoteToken;
        path[1] = token;
        uint256 before = IERC20(token).balanceOf(to);
        try
            IUniswapV2Router02(router)
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    quoteAmount,
                    0,
                    path,
                    to,
                    block.timestamp
                )
        {} catch {}
        bought = IERC20(token).balanceOf(to) - before;
        ICheeseTaxTokenV2(token).setSwapping(false);
    }

    /// @dev Buys `token` with half of `quoteAmount` and pairs it with the rest as LP
    ///      (LP burned to DEAD). Bypassed from tax via the swap window.
    function _addLiquidityFromQuote(uint256 quoteAmount) private {
        uint256 half = quoteAmount / 2;
        uint256 quoteLeft = quoteAmount - half;
        ICheeseTaxTokenV2(token).setSwapping(true);
        uint256 tokBefore = IERC20(token).balanceOf(address(this));
        IERC20(quoteToken).forceApprove(router, quoteAmount);
        address[] memory path = new address[](2);
        path[0] = quoteToken;
        path[1] = token;
        try
            IUniswapV2Router02(router)
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    half,
                    0,
                    path,
                    address(this),
                    block.timestamp
                )
        {} catch {
            ICheeseTaxTokenV2(token).setSwapping(false);
            return;
        }
        uint256 tokBought = IERC20(token).balanceOf(address(this)) - tokBefore;
        if (tokBought > 0 && quoteLeft > 0) {
            IERC20(token).forceApprove(router, tokBought);
            try
                IUniswapV2Router02(router).addLiquidity(
                    token,
                    quoteToken,
                    tokBought,
                    quoteLeft,
                    0,
                    0,
                    DEAD,
                    block.timestamp
                )
            {} catch {}
        }
        ICheeseTaxTokenV2(token).setSwapping(false);
    }

    /// @dev Pays `amount` of quote to `to` as native ETH when the quote is WETH
    ///      (unwrapping first), else as the ERC20 quote. If the native send fails
    ///      (recipient rejects ETH), the amount is re-wrapped and delivered to the
    ///      SAME recipient as WETH — never left as orphaned ETH that a later flush
    ///      would sweep to a different recipient (W9), and never reverting the
    ///      caller (so graduation / a flush can't be bricked).
    function _payQuoteOrNative(address to, uint256 amount) private {
        if (quoteToken == weth) {
            // UsdcPrecompile: the precompile ERC20 IS native (one shared balance),
            // so a plain transfer of `amount` (its 6-dec face) credits `to`'s native
            // balance 1:1 — no unwrap, and a transfer invokes no recipient code, so
            // the native-send fallback is unneeded.
            if (LibNativeAsset.isPrecompile(weth)) {
                IERC20(weth).safeTransfer(to, amount);
                return;
            }
            IWETH(weth).withdraw(amount);
            (bool ok, ) = payable(to).call{value: amount}("");
            if (!ok) {
                IWETH(weth).deposit{value: amount}();
                IERC20(weth).safeTransfer(to, amount);
            }
        } else {
            IERC20(quoteToken).safeTransfer(to, amount);
        }
    }

    receive() external payable {}
}
