// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @notice Shared EIP-712 verification for identity-bound vaults. The caller passes
///         its OWN domain separator (built with verifyingContract = address(this)),
///         so a proof is bound to one vault — replay across vaults/chains is
///         impossible by construction. This is a pure library, NOT a shared singleton:
///         there is no central oracle whose signer is blindly trusted by every vault.
library LibVaultSig {
    /// @return ok True iff `sig` is a valid signature by `signer` over the EIP-712
    ///         digest of (`domainSeparator`, `structHash`). False (never revert) on a
    ///         zero signer or a malformed signature, so callers branch cleanly.
    function verify(
        bytes32 domainSeparator,
        bytes32 structHash,
        bytes memory sig,
        address signer
    ) internal pure returns (bool ok) {
        if (signer == address(0)) return false;
        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
        (address recovered, ECDSA.RecoverError err, ) = ECDSA.tryRecover(digest, sig);
        return err == ECDSA.RecoverError.NoError && recovered == signer;
    }
}
