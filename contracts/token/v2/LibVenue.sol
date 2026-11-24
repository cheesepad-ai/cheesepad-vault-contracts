// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title LibVenue
/// @notice CREATE2-predicts the DEX pools a launched token also taxes alongside its
///         main pair, across every registered DEX (e.g. PancakeSwap + Uniswap) and
///         every quote token (main quote, WETH, and the per-chain stables). Keying tax
///         on one pair can't be dodged by opening a second venue — a TOKEN/WETH V2
///         pair, a V3 pool at any fee tier, a TOKEN/<stable> pair, or the same pair on
///         another DEX. Every address is predicted, so it is gated whether or not
///         liquidity is ever deployed there. Pools on an unregistered factory can't be
///         predicted and stay out of scope.
library LibVenue {
    /// @notice One DEX's CREATE2 config: V2 factory + pair init hash, V3 factory + pool
    ///         init hash, and the DEX's fee tiers (Pancake `[100,500,2500,10000]`,
    ///         Uniswap `[100,500,3000,10000]`). `v3Factory == 0` marks a V2-only DEX.
    struct Dex {
        address v2Factory;
        bytes32 v2InitCodeHash;
        address v3Factory;
        bytes32 v3PoolInitCodeHash;
        uint24[] v3FeeTiers;
    }

    /// @notice Per-launch venue inputs beyond the launch DEX: extra quote tokens, the
    ///         other anti-farmer DEXes, and venues blocked until listing.
    struct LaunchVenues {
        address[] extraQuoteTokens;
        Dex[] extraDexes;
        address[] guardedVenues;
    }

    /// @notice CREATE2 address of a V2 pair for `(a, b)`.
    function pairFor(address factory, bytes32 initCodeHash, address a, address b)
        internal
        pure
        returns (address)
    {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                hex"ff",
                                factory,
                                keccak256(abi.encodePacked(t0, t1)),
                                initCodeHash
                            )
                        )
                    )
                )
            );
    }

    /// @notice CREATE2 address of a V3 pool for `(a, b)` at `fee`. The salt hashes
    ///         the ABI-encoded (padded) `(token0, token1, fee)` — the fee tier is
    ///         what turns one token/quote pair into several pool addresses.
    function poolV3For(
        address factory,
        bytes32 initCodeHash,
        address a,
        address b,
        uint24 fee
    ) internal pure returns (address) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return
            address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                hex"ff",
                                factory,
                                keccak256(abi.encode(t0, t1, fee)),
                                initCodeHash
                            )
                        )
                    )
                )
            );
    }

    /// @notice Marks the main pair, then the full venue set for the launch DEX and each
    ///         extra DEX: per DEX, the TOKEN/quote V2 pair, the TOKEN/WETH V2 pair (when
    ///         the quote is an ERC20 other than WETH), the TOKEN/quote V3 pools per fee
    ///         tier, and per extra quote its V2 pair + V3 pools. Extra quotes equal to
    ///         the token, the main quote, or zero are skipped; the set dedups the rest
    ///         (the launch DEX's TOKEN/quote V2 coincides with `mainPair`).
    function register(
        mapping(address => bool) storage venues,
        address mainPair,
        address token,
        address pairAsset,
        address weth,
        Dex memory launchDex,
        Dex[] memory extraDexes,
        address[] memory extraQuoteTokens
    ) internal {
        venues[mainPair] = true;
        _registerDexVenues(venues, token, pairAsset, weth, launchDex, extraQuoteTokens);
        for (uint256 i = 0; i < extraDexes.length; i++) {
            _registerDexVenues(venues, token, pairAsset, weth, extraDexes[i], extraQuoteTokens);
        }
    }

    /// @notice Like `register` but takes one combined DEX list.
    function registerVenues(
        mapping(address => bool) storage venues,
        address mainPair,
        address token,
        address pairAsset,
        address weth,
        Dex[] memory dexes,
        address[] memory extraQuoteTokens
    ) internal {
        venues[mainPair] = true;
        for (uint256 i = 0; i < dexes.length; i++) {
            _registerDexVenues(venues, token, pairAsset, weth, dexes[i], extraQuoteTokens);
        }
    }

    /// @notice Registers the full venue set for ONE dex. Split out to keep the stack
    ///         under the EVM limit.
    function _registerDexVenues(
        mapping(address => bool) storage venues,
        address token,
        address pairAsset,
        address weth,
        Dex memory dex,
        address[] memory extraQuoteTokens
    ) private {
        if (dex.v2InitCodeHash != bytes32(0)) {
            venues[pairFor(dex.v2Factory, dex.v2InitCodeHash, token, pairAsset)] = true;
            if (weth != pairAsset && weth != address(0)) {
                venues[pairFor(dex.v2Factory, dex.v2InitCodeHash, token, weth)] = true;
            }
        }
        _registerV3(venues, token, pairAsset, dex);

        for (uint256 i = 0; i < extraQuoteTokens.length; i++) {
            address q = extraQuoteTokens[i];
            if (q == address(0) || q == token || q == pairAsset) {
                continue;
            }
            if (dex.v2InitCodeHash != bytes32(0)) {
                venues[pairFor(dex.v2Factory, dex.v2InitCodeHash, token, q)] = true;
            }
            _registerV3(venues, token, q, dex);
        }
    }

    /// @notice Registers one V3 pool per fee tier for TOKEN/`quote`; no-op when the DEX
    ///         has no V3 factory.
    function _registerV3(
        mapping(address => bool) storage venues,
        address token,
        address quote,
        Dex memory dex
    ) private {
        if (dex.v3Factory == address(0)) {
            return;
        }
        for (uint256 i = 0; i < dex.v3FeeTiers.length; i++) {
            venues[
                poolV3For(dex.v3Factory, dex.v3PoolInitCodeHash, token, quote, dex.v3FeeTiers[i])
            ] = true;
        }
    }
}
