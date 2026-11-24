// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Thin surface of the decomposed CheeseTaxToken that collaborators
///         (TaxProcessor, DividendTracker, GiftVault) need to call back into.
///         The ICheeseTaxToken2 getter names are kept so the parameterised
///         CheeseTokenHelper can read config from the token via either cast.
interface ICheeseTaxToken {
    // ─── ICheeseTaxToken2-compatible getters (helper reads these) ──────────────
    function HELPER() external view returns (address);
    function QUOTE_TOKEN() external view returns (address);
    function ROUTER() external view returns (address);
    function PAIR() external view returns (address);
    function WETH() external view returns (address);
    function fundManager() external view returns (address);

    // ─── Fee-receiver / collaborator getters ────────────────────────────────────
    function FEE_RECEIVER() external view returns (address);
    function taxProcessor() external view returns (address);
    function dividendTracker() external view returns (address);
    function configurator() external view returns (address);

    // ─── One-time bind setters (configurator-only) ──────────────────────────────
    function setFundManager(address fundManager_) external;
    function setFeeReceiver(address feeReceiver_) external;
    function setTaxProcessor(address taxProcessor_) external;
    function setDividendTracker(address dividendTracker_) external;

    // ─── Processor-driven swap-window flag ──────────────────────────────────────
    /// @notice Set by the TaxProcessor before/after its router calls so the
    ///         router→pair transfers are not re-taxed. Only callable by the
    ///         bound taxProcessor.
    function setSwapping(bool v) external;

    // ─── State views ────────────────────────────────────────────────────────────
    function tradingStarted() external view returns (bool);
    function TOKEN_TYPE() external view returns (uint8);
    function TAX_BPS() external view returns (uint256);
    function BUY_TAX_BPS() external view returns (uint256);
    function SELL_TAX_BPS() external view returns (uint256);
    function TAX_DURATION() external view returns (uint256);
    function tradingStartedAt() external view returns (uint256);
    function MIN_DISPATCH() external view returns (uint256);
    function MIN_HOLDER_SHARE() external view returns (uint256);
}
