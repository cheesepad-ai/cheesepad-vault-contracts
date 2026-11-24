// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {VaultDataSchema} from "./IVaultSchema.sol";

/// @notice Revision 1 launch data — the tax-token fee shape (new CheeseTaxToken,
/// TOKEN_TYPE 3). Frozen after launch; pre-launch may be edited in place.
/// A future token generation gets a new struct + new revision constant; existing
/// revisions are never modified (no field additions, reorders, or type changes).
struct LaunchDataV1 {
    uint256 configId;
    address quoteToken;
    uint256 buyTaxBps;
    uint256 sellTaxBps;
    uint256 taxDuration;
    uint16 feeReceiverBps;
    uint16 holdersBps;
    uint16 burnBps;
    uint16 liquidityBps;
    uint256 minDispatch;
    uint256 minHolderShare;
    address creator;
}

interface IVaultFactory {
    /// @notice The LaunchpadDiamond this factory serves. The diamond verifies
    ///         this matches itself before any other interaction.
    function diamond() external view returns (address);

    /// @notice Deploy a vault instance for one launch. MUST be diamond-only.
    ///         How the factory deploys is its own business (plain `new` suffices).
    /// @dev The deployed vault's isNativeRevenue MUST equal (quoteToken == weth): the
    ///      diamond asserts this at create (CreateMicroSaleTaxTokenWithVaultFacet) and a
    ///      mismatch reverts the launch. Native-quote tokens push ETH; ERC20-quote tokens
    ///      push the quote token.
    /// @param vaultData ABI-encoded per-instance params, shaped per vaultDataSchema().
    function createVault(
        address quoteToken,
        address creator,
        bytes calldata vaultData
    ) external returns (address vault);

    /// @notice Declares which launch-data revisions this factory can review.
    ///         Checked by the diamond BEFORE reviewLaunch — fail-closed: a factory
    ///         that does not understand a revision is never asked to review it.
    function supportsLaunchRevision(uint16 revision) external view returns (bool);

    /// @notice Launch veto hook. launchData = abi.encode(uint16 revision, bytes body)
    ///         where body = abi.encode(LaunchDataV{revision}). See LibLaunchData.
    ///         Deliberately does NOT receive vaultData: cross-validation between
    ///         launch params and per-instance vault params is unsupported by design.
    function reviewLaunch(bytes calldata launchData)
        external view returns (bool ok, string memory reason);

    /// @notice Whether this factory's vaults can handle revenue in the given quote
    ///         token. Checked fail-closed by the diamond before launch.
    function supportsQuoteToken(address quoteToken) external view returns (bool);

    /// @notice Machine-readable description of the vaultData encoding, used by the
    ///         frontend to render the vault-creation form.
    function vaultDataSchema() external view returns (VaultDataSchema memory);
}
