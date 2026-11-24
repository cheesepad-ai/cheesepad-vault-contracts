// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IDividendTracker {
    function setShare(address account, uint256 balance) external;
    function depositDividend(uint256 amount) external;
    function claim() external;
    function claim(address[] calldata accounts) external;
    function totalShares() external view returns (uint256);
    function shareOf(address account) external view returns (uint256);
    function claimableFee(address account) external view returns (uint256);
    function token() external view returns (address);
    function quoteToken() external view returns (address);
}
