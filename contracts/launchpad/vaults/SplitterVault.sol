// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {VaultBase} from "./VaultBase.sol";
import {VaultUISchema, Method, Field, FieldType, ApprovalHint} from "./IVaultSchema.sol";

contract SplitterVault is VaultBase {
    uint16 private constant BPS = 10_000;
    // distribute() iterates all payees; an oversized list would exceed block gas
    // while the vault is un-sweepable, permanently locking funds.
    uint256 private constant MAX_PAYEES = 50;

    address[] public payees;
    uint16[] public bps;
    mapping(address => uint256) public owed;
    uint256 public credited; // total revenue already credited into owed[]

    error BadConfig();

    event Distributed(uint256 amount);
    event Paid(address indexed payee, uint256 amount);
    event PayFailed(address indexed payee, uint256 amount);
    event Claimed(address indexed payee, uint256 amount);

    constructor(
        address _diamond,
        address _quoteToken,
        address _creator,
        bool _isNativeRevenue,
        address[] memory _payees,
        uint16[] memory _bps
    ) VaultBase(_diamond, _quoteToken, _creator, _isNativeRevenue) {
        if (_payees.length == 0 || _payees.length != _bps.length) revert BadConfig();
        if (_payees.length > MAX_PAYEES) revert BadConfig();
        uint256 sum;
        for (uint256 i = 0; i < _bps.length; i++) {
            if (_payees[i] == address(0)) revert BadConfig();
            // A 0-bps payee would be a permanent no-op: its share computes to 0
            // in distribute() and, because the payee list is immutable and the
            // vault un-sweepable, the slot can never be corrected post-deploy.
            if (_bps[i] == 0) revert BadConfig();
            for (uint256 j = 0; j < i; j++) {
                if (_payees[j] == _payees[i]) revert BadConfig();
            }
            sum += _bps[i];
        }
        if (sum != BPS) revert BadConfig();
        payees = _payees;
        bps = _bps;
    }

    function distribute() external nonReentrant {
        uint256 bal = _revenueBalance();
        // Clamp instead of subtracting unconditionally: a quote token with
        // clawback/blocklist/rebasing behaviour could drop the vault balance
        // below what is already owed, which would otherwise underflow-revert
        // and permanently brick distribute() (per-payee claim() still works).
        uint256 owedTotal = _outstandingOwed();
        uint256 uncredited = bal > owedTotal ? bal - owedTotal : 0;
        if (uncredited > 0) {
            uint256 totalCredited;
            for (uint256 i = 0; i < payees.length; i++) {
                uint256 share = (uncredited * bps[i]) / BPS;
                owed[payees[i]] += share;
                totalCredited += share;
            }
            if (totalCredited > 0) {
                credited += totalCredited;
                emit Distributed(totalCredited);
            }
        }
        for (uint256 i = 0; i < payees.length; i++) {
            address p = payees[i];
            uint256 amt = owed[p];
            if (amt == 0) continue;
            owed[p] = 0;
            if (!_pay(p, amt)) { owed[p] = amt; emit PayFailed(p, amt); } else { emit Paid(p, amt); }
        }
    }

    function claim() external nonReentrant {
        uint256 amt = owed[msg.sender];
        require(amt > 0, "nothing owed");
        owed[msg.sender] = 0;
        require(_pay(msg.sender, amt), "send failed");
        emit Claimed(msg.sender, amt);
    }

    function _outstandingOwed() internal view returns (uint256 total) {
        for (uint256 i = 0; i < payees.length; i++) {
            total += owed[payees[i]];
        }
    }

    function payeesLength() external view returns (uint256) { return payees.length; }

    /// @notice Full split config as a single call (handy for generic FE rendering).
    function splitConfig() external view returns (address[] memory, uint16[] memory) {
        return (payees, bps);
    }

    function description() external pure returns (string memory) {
        return "Splits revenue among fixed payees by bps";
    }

    function vaultUISchema() external pure returns (VaultUISchema memory s) {
        s.vaultType = "Splitter";
        s.description = "Splits revenue among fixed payees by bps";
        s.methods = new Method[](5);

        // ── Write actions ────────────────────────────────────────────────────
        s.methods[0].name = "distribute";
        s.methods[0].selector = bytes4(keccak256("distribute()"));
        s.methods[0].isWrite = true;
        s.methods[0].hint = "Settle accrued revenue to payees";

        s.methods[1].name = "claim";
        s.methods[1].selector = bytes4(keccak256("claim()"));
        s.methods[1].isWrite = true;
        s.methods[1].hint = "Pull your owed balance";

        // ── Read fields (isWrite=false: FE calls and renders the typed outputs) ─
        s.methods[2].name = "splitConfig";
        s.methods[2].selector = bytes4(keccak256("splitConfig()"));
        s.methods[2].isWrite = false;
        s.methods[2].outputs = new Field[](2);
        s.methods[2].outputs[0] = Field("payees", FieldType.Address, true, 0, "Recipient addresses");
        s.methods[2].outputs[1] = Field("bps", FieldType.Uint16, true, 0, "Basis points per payee");
        s.methods[2].hint = "Payees and their split (bps)";

        s.methods[3].name = "credited";
        s.methods[3].selector = bytes4(keccak256("credited()"));
        s.methods[3].isWrite = false;
        s.methods[3].outputs = new Field[](1);
        s.methods[3].outputs[0] = Field("credited", FieldType.Uint256, false, 18, "Total revenue settled to date");
        s.methods[3].hint = "Total revenue distributed so far";

        s.methods[4].name = "owed";
        s.methods[4].selector = bytes4(keccak256("owed(address)"));
        s.methods[4].isWrite = false;
        s.methods[4].inputs = new Field[](1);
        s.methods[4].inputs[0] = Field("account", FieldType.Address, false, 0, "Payee address");
        s.methods[4].outputs = new Field[](1);
        s.methods[4].outputs[0] = Field("owed", FieldType.Uint256, false, 18, "Pending balance for the account");
        s.methods[4].hint = "Pending balance owed to an address";
    }
}
