// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ITaxProcessor {
    /// @notice Flush all held tax tokens through the four-slice routing.
    ///
    /// Cross-layer invariant: the bound token's `setSwapping(true)` suppresses
    /// `setShare`/share-accounting in `_update` for the duration of the swap
    /// window, guaranteeing that `totalShares` cannot change after the
    /// `holdersActive` check inside `dispatch()`.  The token calls `dispatch()`
    /// best-effort (via try/catch), so a mid-dispatch revert rolls back
    /// atomically — there is no persistent "stuck-swapping" state.
    function dispatch() external;

    function token() external view returns (address);
    function router() external view returns (address);
    function helper() external view returns (address);
    function quoteToken() external view returns (address);
    function weth() external view returns (address);
    function dividendTracker() external view returns (address);
    function feeReceiver() external view returns (address);

    function feeReceiverBps() external view returns (uint256);
    function holdersBps() external view returns (uint256);
    function burnBps() external view returns (uint256);
    function liquidityBps() external view returns (uint256);
}
