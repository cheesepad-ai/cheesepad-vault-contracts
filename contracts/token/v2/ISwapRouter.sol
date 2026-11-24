// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Shared, upgradeable swap/liquidity router used by tax-token processors.
///         Config (quote token, router, WETH, fund manager) is read from the passed
///         `token`; tax tokens are pulled from `msg.sender` (the processor), which
///         must pre-approve the router.
interface ISwapRouter {
    /// @notice Swaps `amountToken` of `token` to its quote token, delivering to `to`.
    function swapForQuoteFrom(address token, address to, uint256 amountToken)
        external
        returns (uint256 amountOut);

    /// @notice Swaps `amountToken` of `token` to native ETH, delivering to `to`.
    function swapForETHFrom(address token, address to, uint256 amountToken)
        external
        returns (uint256 amountOut);

    /// @notice Adds liquidity from `amountToken` of `token`; LP tokens go to the
    ///         token's fund manager.
    function addLiquidityFrom(address token, uint256 amountToken) external;
}
