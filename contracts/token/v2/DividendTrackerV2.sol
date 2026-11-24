// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IDividendTrackerV2} from "./IDividendTrackerV2.sol";

interface ITokenFundManager {
    function fundManager() external view returns (address);
}

/// @title DividendTrackerV2
/// @notice Ownerless holder-dividend accounting paid in the quote token. `setShare`
///         is token-only; deposits, claims and pushes are permissionless. Holders
///         may redirect their payout address.
contract DividendTrackerV2 is IDividendTrackerV2, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant MAGNITUDE = 2 ** 128;
    address public immutable override token;
    address public immutable override quoteToken;
    uint256 public immutable minHolderShare;

    uint256 public override totalShares;
    uint256 public feePerShare;

    struct UserInfo {
        uint256 share;
        uint256 rewardDebt;
        uint256 claimable;
        uint256 claimed;
    }
    mapping(address => UserInfo) public userInfo;
    mapping(address => address) public dividendReceiver;

    error NotToken();
    error NoShares();

    event ShareUpdated(address indexed account, uint256 share);
    event DividendDeposited(uint256 amount);
    event Claimed(address indexed account, address indexed receiver, uint256 amount);
    event DividendReceiverSet(address indexed account, address indexed receiver);

    constructor(address _token, address _quoteToken, uint256 _minHolderShare) {
        token = _token;
        quoteToken = _quoteToken;
        minHolderShare = _minHolderShare;
    }

    modifier onlyToken() {
        if (msg.sender != token) revert NotToken();
        _;
    }

    function shareOf(address account) external view override returns (uint256) {
        return userInfo[account].share;
    }

    function _isExcluded(address account) internal view returns (bool) {
        return
            account == address(0) ||
            account == token ||
            account == address(this) ||
            account == ITokenFundManager(token).fundManager();
    }

    /// @inheritdoc IDividendTrackerV2
    function setShare(address account, uint256 balance)
        external
        override
        onlyToken
    {
        if (_isExcluded(account)) return;
        uint256 newShare = balance < minHolderShare ? 0 : balance;
        UserInfo storage record = userInfo[account];
        uint256 currentShare = record.share;
        if (newShare == currentShare) return;
        if (currentShare > 0) {
            uint256 accruedFee = (currentShare * feePerShare) / MAGNITUDE;
            if (accruedFee > record.rewardDebt) {
                record.claimable += accruedFee - record.rewardDebt;
            }
        }
        record.share = newShare;
        record.rewardDebt = (newShare * feePerShare) / MAGNITUDE;
        if (newShare > currentShare) {
            totalShares += (newShare - currentShare);
        } else {
            totalShares -= (currentShare - newShare);
        }
        emit ShareUpdated(account, newShare);
    }

    /// @inheritdoc IDividendTrackerV2
    function depositDividend(uint256 amount) external override nonReentrant {
        if (totalShares == 0) revert NoShares();
        // Credit the ACTUAL amount received, not the nominal request, so a
        // fee-on-transfer quote cannot inflate feePerShare beyond assets held.
        uint256 before = IERC20(quoteToken).balanceOf(address(this));
        IERC20(quoteToken).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(quoteToken).balanceOf(address(this)) - before;
        feePerShare += (received * MAGNITUDE) / totalShares;
        emit DividendDeposited(received);
    }

    function claimableFee(address account)
        public
        view
        override
        returns (uint256)
    {
        UserInfo storage record = userInfo[account];
        uint256 amount = record.claimable;
        uint256 accruedFee = (record.share * feePerShare) / MAGNITUDE;
        if (accruedFee > record.rewardDebt) {
            amount += accruedFee - record.rewardDebt;
        }
        return amount;
    }

    /// @inheritdoc IDividendTrackerV2
    function claim() external override nonReentrant {
        _claim(msg.sender);
    }

    /// @inheritdoc IDividendTrackerV2
    function claim(address[] calldata accounts) external override nonReentrant {
        for (uint256 i = 0; i < accounts.length; i++) {
            _claim(accounts[i]);
        }
    }

    /// @inheritdoc IDividendTrackerV2
    function withdrawDividendsFor(address account)
        external
        override
        nonReentrant
    {
        _claim(account);
    }

    /// @inheritdoc IDividendTrackerV2
    function setDividendReceiver(address receiver) external override {
        dividendReceiver[msg.sender] = receiver;
        emit DividendReceiverSet(msg.sender, receiver);
    }

    function _claim(address account) internal {
        uint256 amount = claimableFee(account);
        if (amount == 0) return;
        UserInfo storage record = userInfo[account];
        record.rewardDebt = (record.share * feePerShare) / MAGNITUDE;
        record.claimable = 0;
        record.claimed += amount;
        address to = dividendReceiver[account];
        if (to == address(0)) {
            to = account;
        }
        IERC20(quoteToken).safeTransfer(to, amount);
        emit Claimed(account, to, amount);
    }
}
