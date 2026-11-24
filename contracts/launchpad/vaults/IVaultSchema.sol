// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Leaf type for a parameter or return value in a vault/launch schema.
enum FieldType {
    String, Address, Uint16, Uint256, Uint128, Bool, Bytes, Bytes32, Time, MsgValue
}
// Time = absolute unix seconds (a duration is just a Uint256 of seconds).
// MsgValue = native BNB sent as msg.value with the write call (NOT an ABI arg).
// `decimals` does not apply to Time / MsgValue.

struct Field {
    string name;
    FieldType fieldType;
    bool isArray;
    uint8 decimals;   // UI multiplies input / divides output by 10^decimals
    string hint;
}

/// @notice Describes how to ABI-encode `vaultData` for IVaultFactory.createVault.
struct VaultDataSchema {
    string description; // what these params configure, for the FE creation form
    bool isArray;       // true => vaultData = abi.encode(tuple[]); false => single tuple
    Field[] fields;
}

/// @notice Tells the FE an ERC20 approval must precede a write method.
/// tokenRef: "token" (the bound sale token), "quoteToken", or a 0x-hex literal address.
/// amountField: name of the input Field whose value is the approval amount.
/// The approval spender is always the vault address.
/// Unlimited (max) approval requires the explicit sentinel amountField = "*".
/// Empty amountField, or a tokenRef the FE cannot resolve => the FE must refuse to
/// render the method (untrusted schemas never get dangerous defaults).
struct ApprovalHint {
    string tokenRef;
    string amountField;
}

/// @notice One callable surface on a vault.
struct Method {
    string name;
    bytes4 selector;
    bool isWrite;
    Field[] inputs;
    Field[] outputs;
    ApprovalHint[] approvals;
    string hint;
}

/// @notice Ordered set of vault methods the frontend renders.
struct VaultUISchema {
    string vaultType;    // short label, e.g. "Splitter"
    string description;  // one-line type description for listings
    Method[] methods;
}
