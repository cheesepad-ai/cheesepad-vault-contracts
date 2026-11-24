// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Holder-dividend accounting for CheeseTaxTokenV2, paid in the quote token.
///         Ownerless: `setShare` is token-only, everything else is permissionless.
interface IDividendTrackerV2 {
    /// @notice Token-only: updates an account's share to its current balance.
    function setShare(address account, uint256 balance) external;

    /// @notice Permissionless: deposits `amount` of quote token as dividends.
    function depositDividend(uint256 amount) external;

    /// @notice Claims the caller's accrued dividends.
    function claim() external;

    /// @notice Claims accrued dividends for each listed account (permissionless push).
    function claim(address[] calldata accounts) external;

    /// @notice Pushes accrued dividends to a single account (permissionless).
    function withdrawDividendsFor(address account) external;

    /// @notice Redirects the caller's future payouts to `receiver` (accounting stays
    ///         keyed on the caller).
    function setDividendReceiver(address receiver) external;

    function totalShares() external view returns (uint256);
    function shareOf(address account) external view returns (uint256);
    function claimableFee(address account) external view returns (uint256);
    function token() external view returns (address);
    function quoteToken() external view returns (address);
}
