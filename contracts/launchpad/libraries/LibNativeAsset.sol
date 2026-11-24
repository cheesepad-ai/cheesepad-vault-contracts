// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IWETH} from "../../interfaces/IWETH.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IUniswapV2Router02} from "../../interfaces/IUniswapV2Router02.sol";
import {NativeAssetMode} from "./NativeAssetMode.sol";

/// @notice Centralizes every native<->DEX-pair conversion behind a runtime mode.
///         In `Weth` mode each primitive is exactly today's behavior (real
///         wrap/unwrap, no scaling), so existing chains are byte-identical. In
///         `UsdcPrecompile` mode the native asset carries an 18-dec native face and
///         a 6-dec ERC20 face over one balance: amounts crossing to the pair's ERC20
///         face scale by PRECOMPILE_SCALE, and there is nothing to wrap or unwrap.
library LibNativeAsset {
    /// @notice 1e12 == 10**(18-6): bridges the precompile's 18-dec native and 6-dec
    ///         ERC20 faces.
    uint256 internal constant PRECOMPILE_SCALE = 1e12;

    /// @notice The ERC20 a pair actually holds for a given quote: wrapped-native when
    ///         the quote is native (address(0)), else the quote token itself.
    function pairAsset(address quote, address wrappedNative)
        internal
        pure
        returns (address)
    {
        return quote == address(0) ? wrappedNative : quote;
    }

    /// @notice The wrapped-native ERC20 the native listing/trade legs pair against:
    ///         the operator-configured `weth` when set, else `router.WETH()`. Zero
    ///         `configuredWeth` (every weth-model chain) is byte-identical to reading
    ///         the router directly. On a usdcPrecompile chain whose router exposes a
    ///         revert-stub WETH() (Arc), `configuredWeth` is the USDC precompile.
    function resolveWrappedNative(address configuredWeth, address router)
        internal
        view
        returns (address)
    {
        return configuredWeth != address(0)
            ? configuredWeth
            : IUniswapV2Router02(router).WETH();
    }

    /// @notice Wraps native into the pair ERC20. Real IWETH.deposit in `Weth` mode;
    ///         a no-op in `UsdcPrecompile` mode (native already is the pair ERC20).
    function wrapNative(
        NativeAssetMode mode,
        address wrappedNative,
        uint256 amount
    ) internal {
        if (mode == NativeAssetMode.Weth) {
            IWETH(wrappedNative).deposit{value: amount}();
        }
    }

    /// @notice Unwraps the pair ERC20 back to native. Real IWETH.withdraw in `Weth`
    ///         mode; a no-op in `UsdcPrecompile` mode.
    function unwrapNative(
        NativeAssetMode mode,
        address wrappedNative,
        uint256 amount
    ) internal {
        if (mode == NativeAssetMode.Weth) {
            IWETH(wrappedNative).withdraw(amount);
        }
    }

    /// @notice Scales a native (18-dec) amount into the pair's ERC20 units: /1e12 in
    ///         `UsdcPrecompile`, identity in `Weth`.
    function toPairUnits(NativeAssetMode mode, uint256 nativeAmount)
        internal
        pure
        returns (uint256)
    {
        return
            mode == NativeAssetMode.UsdcPrecompile
                ? nativeAmount / PRECOMPILE_SCALE
                : nativeAmount;
    }

    /// @notice Scales a pair-ERC20 amount back into native (18-dec) units: *1e12 in
    ///         `UsdcPrecompile`, identity in `Weth`.
    function fromPairUnits(NativeAssetMode mode, uint256 pairAmount)
        internal
        pure
        returns (uint256)
    {
        return
            mode == NativeAssetMode.UsdcPrecompile
                ? pairAmount * PRECOMPILE_SCALE
                : pairAmount;
    }

    /// @notice Derives the mode for a standalone contract (one that cannot read
    ///         the launchpad's stored mode) from its resolved wrapped-native: a 6-decimal ERC20
    ///         face names the precompile unambiguously, anything else is a real
    ///         18-decimal wrapper.
    function modeFor(address wrappedNative)
        internal
        view
        returns (NativeAssetMode)
    {
        return
            IERC20Metadata(wrappedNative).decimals() == 6
                ? NativeAssetMode.UsdcPrecompile
                : NativeAssetMode.Weth;
    }

    /// @notice True when the resolved wrapped-native is the 6-decimal precompile —
    ///         the boolean form of {modeFor} for standalone contracts that only need
    ///         to branch, never the enum.
    function isPrecompile(address wrappedNative) internal view returns (bool) {
        return IERC20Metadata(wrappedNative).decimals() == 6;
    }

    /// @notice {toPairUnits} for a standalone contract, deriving the mode from the
    ///         wrapped-native's decimals.
    function toPairUnitsFor(address wrappedNative, uint256 nativeAmount)
        internal
        view
        returns (uint256)
    {
        return toPairUnits(modeFor(wrappedNative), nativeAmount);
    }

    /// @notice {fromPairUnits} for a standalone contract, deriving the mode from the
    ///         wrapped-native's decimals.
    function fromPairUnitsFor(address wrappedNative, uint256 pairAmount)
        internal
        view
        returns (uint256)
    {
        return fromPairUnits(modeFor(wrappedNative), pairAmount);
    }
}
