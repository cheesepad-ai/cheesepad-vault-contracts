// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice How the native gas asset relates to its DEX-pair ERC20. `Weth`: the
///         classic wrapped-native token (deposit/withdraw, 18-dec) — today's
///         behavior on every existing chain. `UsdcPrecompile`: a native asset with
///         an 18-dec native face and a 6-dec ERC20 face sharing one balance, so
///         amounts crossing to the pair scale by LibNativeAsset.PRECOMPILE_SCALE and
///         there is nothing to wrap/unwrap.
///
/// @dev In its own file so standalone token-side contracts (tax processor, vaults,
///      swap router, token helper) can share the enum via LibNativeAsset WITHOUT
///      importing LibAppStorage, whose full source would otherwise be pulled into a
///      launch token's Standard-JSON verification.
enum NativeAssetMode {
    Weth,
    UsdcPrecompile
}
