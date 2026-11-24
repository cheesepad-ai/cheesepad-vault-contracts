// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IVaultFactory, LaunchDataV1} from "./IVaultFactory.sol";
import {LibLaunchData} from "./LibLaunchData.sol";

/// @notice Optional convenience base for factory authors. Handles the revision-tag
///         convention so authors only override typed hooks. Implementing
///         IVaultFactory directly (without this base) is equally valid.
///         supportsLaunchRevision is the single source of truth: reviewLaunch gates
///         on it before dispatching, and this base only dispatches the revisions it
///         was shipped with (reviewLaunch is deliberately non-virtual). When a new
///         token generation mints revision N, the platform ships an updated base
///         carrying a _reviewVN hook and its dispatch branch; adopting N then means
///         recompiling against that base, overriding _reviewVN, extending
///         supportsLaunchRevision, and redeploying (factories are stateless and
///         non-upgradeable; a new version is a new address). Extending
///         supportsLaunchRevision beyond what the compiled-in base dispatches just
///         vetoes those launches with "Unsupported launch revision" — fail-closed.
abstract contract VaultFactoryBase is IVaultFactory {
    address public immutable diamond;

    error NotDiamond();

    constructor(address _diamond) {
        diamond = _diamond;
    }

    modifier onlyDiamond() {
        if (msg.sender != diamond) revert NotDiamond();
        _;
    }

    function supportsLaunchRevision(uint16 revision) public view virtual returns (bool) {
        return revision == LibLaunchData.REVISION_1;
    }

    function reviewLaunch(bytes calldata launchData)
        external view returns (bool ok, string memory reason)
    {
        (uint16 revision, bytes memory body) = LibLaunchData.unwrap(launchData);
        if (!supportsLaunchRevision(revision)) {
            return (false, "Unsupported launch revision");
        }
        if (revision == LibLaunchData.REVISION_1) {
            return _reviewV1(abi.decode(body, (LaunchDataV1)));
        }
        // Reached only when a subclass advertises a revision this base version
        // cannot dispatch — a safe veto rather than a silent mis-route.
        return (false, "Unsupported launch revision");
    }

    /// @notice Author hook for revision-1 (tax-token fee shape) launches. Typed; no bytes.
    /// @param data The decoded LaunchDataV1 — the launch's tax/fee configuration plus
    ///        configId and creator. Return (false, reason) to veto the launch.
    function _reviewV1(LaunchDataV1 memory data)
        internal view virtual returns (bool ok, string memory reason);
}
