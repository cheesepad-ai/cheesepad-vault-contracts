// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {VaultUISchema} from "./IVaultSchema.sol";

interface IVault {
    function bind(address token) external;            // diamond-only, one-time
    function distribute() external;                   // permissionless poke
    function token() external view returns (address);
    function quoteToken() external view returns (address);
    function creator() external view returns (address);
    function diamond() external view returns (address);
    function isNativeRevenue() external view returns (bool);
    function description() external view returns (string memory);
    function vaultUISchema() external view returns (VaultUISchema memory);
    receive() external payable;
}
