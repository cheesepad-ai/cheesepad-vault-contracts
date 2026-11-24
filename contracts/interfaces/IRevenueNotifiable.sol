// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IRevenueNotifiable {
    /// @notice Best-effort signal that the fee-receiver slice was just delivered.
    ///         Fired by the bound token AFTER funds have moved (native push or
    ///         ERC20 credit). Implementations MUST be cheap (bookkeeping/events
    ///         only), MUST NOT call back into the token, and MUST tolerate never
    ///         being called (balance-diff remains the source of truth).
    /// @param amount The delivered quantity — quote-token units, or wei when the
    ///        quote is WETH (native push). Treat as a hint; reconcile with balances.
    function onRevenue(uint256 amount) external;
}
