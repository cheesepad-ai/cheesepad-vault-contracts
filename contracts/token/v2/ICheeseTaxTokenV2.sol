// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Surface of the decomposed CheeseTaxTokenV2 that its collaborators
///         (SwapRouter, TaxProcessorV2, DividendTrackerV2, vaults) call back into.
interface ICheeseTaxTokenV2 {
    // ─── Config getters (router reads these) ───────────────────────────────────
    function QUOTE_TOKEN() external view returns (address);
    function ROUTER() external view returns (address);
    function WETH() external view returns (address);
    function PAIR() external view returns (address);
    function fundManager() external view returns (address);

    // ─── Collaborator / receiver getters ───────────────────────────────────────
    function FEE_RECEIVER() external view returns (address);
    function taxProcessor() external view returns (address);
    function dividendTracker() external view returns (address);
    function configurator() external view returns (address);

    /// @notice Opens/closes the swap window so router→pair transfers are not
    ///         re-taxed. Callable only by the bound tax processor.
    function setSwapping(bool v) external;

    /// @notice One-way pre-listing transfer lock. Callable only by the configurator.
    function lockTransfersUntilListing() external;
    function transfersLockedUntilListing() external view returns (bool);

    // ─── State views ────────────────────────────────────────────────────────────
    function state() external view returns (uint8);
    function mainPool() external view returns (address);
    function isPool(address account) external view returns (bool);
    function tradingStarted() external view returns (bool);
    function tradingStartedAt() external view returns (uint256);
    function liquidationThreshold() external view returns (uint256);

    function TOKEN_TYPE() external view returns (uint8);
    function TAX_BPS() external view returns (uint256);
    function BUY_TAX_BPS() external view returns (uint256);
    function SELL_TAX_BPS() external view returns (uint256);
    function TAX_DURATION() external view returns (uint256);
    function antiFarmerDuration() external view returns (uint256);
}
