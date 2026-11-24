// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice The two launchpad settings the vaults read.
interface IConfigView {
    /// @notice The platform address a vault may opt in to as an emergency backstop.
    function getPlatformRole() external view returns (address);

    /// @notice The signer GiftVault checks when a beneficiary binds an X handle.
    function getGiftRelayerSigner() external view returns (address);
}
