// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev DEPRECATED (TYPE 2): superseded by ICheeseTaxTokenV2. Retained for existing
///      on-chain pools.
interface ICheeseTaxToken2 {
    function HELPER() external view returns (address);

    function QUOTE_TOKEN() external view returns (address);

    function ROUTER() external view returns (address);

    function PAIR() external view returns (address);

    function fundManager() external view returns (address);

    function WETH() external view returns (address);
}
