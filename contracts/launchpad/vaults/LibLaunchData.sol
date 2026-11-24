// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {LaunchDataV1} from "./IVaultFactory.sol";

/// @notice Canonical encode/decode for the revision-tagged launch-validation payload.
/// Envelope: abi.encode(uint16 revision, bytes body); body = abi.encode(LaunchDataV{rev}).
/// Evolution rules: a revision's struct is frozen after launch (may be edited in place
/// pre-launch); a new fee shape is a new struct + new constant appended here; the
/// revision tag — checked before any body decode — is the authoritative defense against
/// cross-revision misreads, since same-word-count static structs decode without reverting.
library LibLaunchData {
    uint16 internal constant REVISION_1 = 1; // tax-token fee shape (CheeseTaxToken / CheeseTaxToken2)

    function encodeV1(LaunchDataV1 memory d) internal pure returns (bytes memory) {
        return abi.encode(REVISION_1, abi.encode(d));
    }

    /// Single canonical envelope decode — every consumer goes through this.
    function unwrap(bytes memory launchData)
        internal pure returns (uint16 revision, bytes memory body)
    {
        (revision, body) = abi.decode(launchData, (uint16, bytes));
    }

    function decodeV1(bytes memory launchData) internal pure returns (LaunchDataV1 memory) {
        (uint16 revision, bytes memory body) = unwrap(launchData);
        require(revision == REVISION_1, "LibLaunchData: not revision 1");
        return abi.decode(body, (LaunchDataV1));
    }
}
