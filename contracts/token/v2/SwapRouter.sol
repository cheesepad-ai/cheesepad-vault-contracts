// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ISwapRouter} from "./ISwapRouter.sol";
import {ICheeseTaxTokenV2} from "./ICheeseTaxTokenV2.sol";
import {IUniswapV2Router02} from "../../interfaces/IUniswapV2Router02.sol";
import {LibNativeAsset} from "../../launchpad/libraries/LibNativeAsset.sol";

/// @title SwapRouter
/// @notice Shared, upgradeable swap/liquidity router for tax-token processors.
///         Each processor snapshots this proxy's address, so upgrading the
///         implementation (e.g. to add deeper routing) reaches already-deployed
///         tokens without redeploying them.
contract SwapRouter is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ISwapRouter
{
    using SafeERC20 for IERC20;

    uint256 private constant BPS_BASE = 10_000;
    uint256 private constant SLIPPAGE_BPS = 9_000;
    string private constant ERR_NO_TOKEN_IN = "Insufficient token input";

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Sets the upgrade authority.
    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);
    }

    receive() external payable {}

    /// @inheritdoc ISwapRouter
    function swapForQuoteFrom(address token, address to, uint256 amountToken)
        external
        override
        returns (uint256)
    {
        ICheeseTaxTokenV2 cfg = ICheeseTaxTokenV2(token);
        address quoteToken = cfg.QUOTE_TOKEN();
        IUniswapV2Router02 router = IUniswapV2Router02(cfg.ROUTER());

        uint256 amountIn = _pull(token, msg.sender, amountToken);
        IERC20(token).forceApprove(address(router), amountIn);

        address recipient = to.code.length > 0 ? address(this) : to;
        uint256 amountOut = _swapTokenForToken(
            router,
            token,
            quoteToken,
            recipient,
            amountIn
        );
        if (amountOut > 0 && recipient != to) {
            IERC20(quoteToken).safeTransfer(to, amountOut);
        }
        _sweepResidual(token, quoteToken, msg.sender);
        return amountOut;
    }

    /// @inheritdoc ISwapRouter
    function swapForETHFrom(address token, address to, uint256 amountToken)
        external
        override
        returns (uint256)
    {
        ICheeseTaxTokenV2 cfg = ICheeseTaxTokenV2(token);
        IUniswapV2Router02 router = IUniswapV2Router02(cfg.ROUTER());
        address weth = cfg.WETH();

        uint256 amountIn = _pull(token, msg.sender, amountToken);
        IERC20(token).forceApprove(address(router), amountIn);

        uint256 amountOut = _swapTokenForEth(router, token, weth, to, amountIn);
        _sweepResidual(token, weth, msg.sender);
        return amountOut;
    }

    /// @inheritdoc ISwapRouter
    function addLiquidityFrom(address token, uint256 amountToken)
        external
        override
    {
        ICheeseTaxTokenV2 cfg = ICheeseTaxTokenV2(token);
        address quoteToken = cfg.QUOTE_TOKEN();
        address weth = cfg.WETH();
        address fundManager = cfg.fundManager();
        IUniswapV2Router02 router = IUniswapV2Router02(cfg.ROUTER());

        uint256 amountIn = _pull(token, msg.sender, amountToken);
        IERC20(token).forceApprove(address(router), amountIn);

        uint256 amountToSwap = amountIn / 2;
        uint256 amountToLiquidity = amountIn - amountToSwap;

        // A native quote pairs against wrapped-native. In UsdcPrecompile mode that
        // wrapped-native IS a plain 6-decimal ERC20 (the precompile) with no
        // deposit/withdraw, so the ERC20 add-liquidity path — not the ETH one —
        // seeds it; the swap output and add-liquidity are already in pair units.
        if (quoteToken == weth && !LibNativeAsset.isPrecompile(weth)) {
            _addLiquidityWithEth(
                router,
                token,
                weth,
                fundManager,
                amountToSwap,
                amountToLiquidity
            );
        } else {
            _addLiquidityWithQuote(
                router,
                token,
                quoteToken,
                fundManager,
                amountToSwap,
                amountToLiquidity
            );
        }
        _sweepResidual(token, quoteToken, msg.sender);
    }

    // ─── Internals ─────────────────────────────────────────────────────────────

    function _pull(
        address token,
        address payer,
        uint256 amountToken
    ) private returns (uint256 amountIn) {
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(payer, address(this), amountToken);
        amountIn = IERC20(token).balanceOf(address(this)) - before;
        require(amountIn > 0, ERR_NO_TOKEN_IN);
    }

    function _swapTokenForToken(
        IUniswapV2Router02 router,
        address token,
        address outToken,
        address to,
        uint256 amountIn
    ) private returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = outToken;

        uint256 outBefore = IERC20(outToken).balanceOf(to);
        try
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amountIn,
                0,
                path,
                to,
                block.timestamp
            )
        {} catch {
            return 0;
        }
        return IERC20(outToken).balanceOf(to) - outBefore;
    }

    function _swapTokenForEth(
        IUniswapV2Router02 router,
        address token,
        address weth,
        address to,
        uint256 amountIn
    ) private returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = weth;

        // UsdcPrecompile: the router cannot unwrap (the precompile has no withdraw),
        // so swap to the precompile ERC20 here and hand it to `to` — a transfer of
        // the precompile ERC20 credits `to`'s native balance 1:1 with its 6-dec face.
        if (LibNativeAsset.isPrecompile(weth)) {
            uint256 pairBefore = IERC20(weth).balanceOf(address(this));
            try
                router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    amountIn,
                    0,
                    path,
                    address(this),
                    block.timestamp
                )
            {} catch {
                return 0;
            }
            uint256 pairOut = IERC20(weth).balanceOf(address(this)) - pairBefore;
            if (pairOut == 0) {
                return 0;
            }
            IERC20(weth).safeTransfer(to, pairOut);
            return LibNativeAsset.fromPairUnitsFor(weth, pairOut);
        }

        uint256 ethBefore = to.balance;
        try
            router.swapExactTokensForETHSupportingFeeOnTransferTokens(
                amountIn,
                0,
                path,
                to,
                block.timestamp
            )
        {} catch {
            return 0;
        }
        return to.balance - ethBefore;
    }

    function _addLiquidityWithEth(
        IUniswapV2Router02 router,
        address token,
        address weth,
        address fundManager,
        uint256 amountToSwap,
        uint256 amountToLiquidity
    ) private {
        if (amountToSwap == 0) {
            return;
        }
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = weth;

        uint256 ethBefore = address(this).balance;
        try
            router.swapExactTokensForETHSupportingFeeOnTransferTokens(
                amountToSwap,
                0,
                path,
                address(this),
                block.timestamp
            )
        {} catch {
            return;
        }

        uint256 amountETH = address(this).balance - ethBefore;
        if (amountETH == 0) {
            return;
        }

        try
            router.addLiquidityETH{value: amountETH}(
                token,
                amountToLiquidity,
                _minAmount(amountToLiquidity),
                _minAmount(amountETH),
                fundManager,
                block.timestamp
            )
        {} catch {}
    }

    function _addLiquidityWithQuote(
        IUniswapV2Router02 router,
        address token,
        address quoteToken,
        address fundManager,
        uint256 amountToSwap,
        uint256 amountToLiquidity
    ) private {
        if (amountToSwap == 0) {
            return;
        }
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = quoteToken;

        uint256 quoteBefore = IERC20(quoteToken).balanceOf(address(this));
        try
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amountToSwap,
                0,
                path,
                address(this),
                block.timestamp
            )
        {} catch {
            return;
        }

        uint256 amountQuote = IERC20(quoteToken).balanceOf(address(this)) -
            quoteBefore;
        if (amountQuote == 0) {
            return;
        }
        IERC20(quoteToken).forceApprove(address(router), amountQuote);

        try
            router.addLiquidity(
                token,
                quoteToken,
                amountToLiquidity,
                amountQuote,
                _minAmount(amountToLiquidity),
                _minAmount(amountQuote),
                fundManager,
                block.timestamp
            )
        {} catch {}
    }

    function _minAmount(uint256 amount) private pure returns (uint256) {
        return (amount * SLIPPAGE_BPS) / BPS_BASE;
    }

    function _sweepResidual(
        address token,
        address quoteToken,
        address caller
    ) private {
        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        if (tokenBalance > 0) {
            IERC20(token).safeTransfer(caller, tokenBalance);
        }
        if (quoteToken != token) {
            uint256 quoteBalance = IERC20(quoteToken).balanceOf(address(this));
            if (quoteBalance > 0) {
                IERC20(quoteToken).safeTransfer(caller, quoteBalance);
            }
        }
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            (bool success, ) = payable(caller).call{value: ethBalance}("");
            require(success, "ETH refund failed");
        }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
