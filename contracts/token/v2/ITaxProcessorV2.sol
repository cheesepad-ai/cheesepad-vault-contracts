// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Per-token, ownerless revenue router for CheeseTaxTokenV2. Routes
///         collected tax across feeReceiver / holders / burn / liquidity slices.
interface ITaxProcessorV2 {
    /// @notice Pulls and processes `amount` of accrued tax from the bound token and
    ///         returns the liquidation-threshold direction (>0 raise, <0 lower,
    ///         0 unchanged). Callable only by the bound token.
    function processTaxTokens(uint256 amount) external returns (int8 direction);

    /// @notice Permissionless flush of any pending accrued balances.
    function dispatch() external;

    /// @notice Allocates flushed curve-phase tax (delivered in quote). Curve-configurator
    ///         only, until graduation closes it.
    function depositCurveTax(uint256 grossQuote) external;

    /// @notice Records the per-call spend ceiling for parked buckets and permanently
    ///         closes the curve-tax functions. Curve-configurator only, once.
    function setDispatchSpendCap(uint256 cap) external;

    function curveConfigurator() external view returns (address);
    function curveTaxClosed() external view returns (bool);

    /// @notice Permissionless: spends one capped clip of the parked burn bucket.
    function dispatchBurn() external returns (uint256 quoteSpent, uint256 tokensBurned);

    /// @notice Permissionless: spends one capped clip of the parked liquidity bucket.
    function dispatchLiquidity() external returns (uint256 quoteSpent);

    function token() external view returns (address);
    function router() external view returns (address);
    function swapRouter() external view returns (address);
    function quoteToken() external view returns (address);
    function weth() external view returns (address);
    function dividendTracker() external view returns (address);
    function feeReceiver() external view returns (address);

    function feeReceiverBps() external view returns (uint256);
    function holdersBps() external view returns (uint256);
    function burnBps() external view returns (uint256);
    function liquidityBps() external view returns (uint256);
}
