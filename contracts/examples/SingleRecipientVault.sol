// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {VaultBase} from "../launchpad/vaults/VaultBase.sol";
import {VaultFactoryBase} from "../launchpad/vaults/VaultFactoryBase.sol";
import {LaunchDataV1} from "../launchpad/vaults/IVaultFactory.sol";
import {VaultUISchema, VaultDataSchema, Method, Field, FieldType} from "../launchpad/vaults/IVaultSchema.sol";

contract SingleRecipientVault is VaultBase {
    address public recipient;

    constructor(address _diamond, address _quote, address _creator, bool _native, address _recipient)
        VaultBase(_diamond, _quote, _creator, _native)
    {
        require(_recipient != address(0), "bad recipient");
        recipient = _recipient;
    }

    // Permissionless: push the whole balance to the recipient.
    function distribute() external nonReentrant {
        uint256 bal = _revenueBalance();
        if (bal == 0) return;
        // Reverts on a failed send so nothing is lost. A multi-payee vault should instead keep
        // a failed payee's share as owed[] for a later claim(); see the checklist.
        require(_pay(recipient, bal), "pay failed");
    }

    function description() external pure returns (string memory) {
        return "Streams all revenue to a single recipient";
    }

    function vaultUISchema() external pure returns (VaultUISchema memory s) {
        s.vaultType = "SingleRecipient";
        s.description = "Streams all revenue to a single recipient";
        s.methods = new Method[](2);
        s.methods[0].name = "distribute";
        s.methods[0].selector = bytes4(keccak256("distribute()"));
        s.methods[0].isWrite = true;
        s.methods[0].hint = "Send accrued revenue to the recipient";
        s.methods[1].name = "recipient";
        s.methods[1].selector = bytes4(keccak256("recipient()"));
        s.methods[1].isWrite = false;
        s.methods[1].outputs = new Field[](1);
        s.methods[1].outputs[0] = Field("recipient", FieldType.Address, false, 0, "Who receives the revenue");
        s.methods[1].hint = "Revenue recipient";
    }
}

contract SingleRecipientVaultFactory is VaultFactoryBase {
    address public immutable weth;

    constructor(address _diamond, address _weth) VaultFactoryBase(_diamond) { weth = _weth; }

    function supportsQuoteToken(address) external pure returns (bool) { return true; }

    // Veto launches that would never fund the vault.
    function _reviewV1(LaunchDataV1 memory d) internal pure override returns (bool, string memory) {
        if (d.feeReceiverBps == 0) return (false, "feeReceiver bps must be > 0");
        if (d.buyTaxBps == 0 && d.sellTaxBps == 0) return (false, "tax must be > 0");
        return (true, "");
    }

    function createVault(address quoteToken, address creator, bytes calldata vaultData)
        external onlyDiamond returns (address vault)
    {
        address recipient = abi.decode(vaultData, (address));
        // isNativeRevenue MUST be (quoteToken == weth); the launchpad enforces this.
        vault = address(new SingleRecipientVault(diamond, quoteToken, creator, quoteToken == weth, recipient));
    }

    function vaultDataSchema() external pure returns (VaultDataSchema memory s) {
        s.description = "The single address that receives all revenue";
        s.isArray = false;
        s.fields = new Field[](1);
        s.fields[0] = Field("recipient", FieldType.Address, false, 0, "Revenue recipient");
    }
}
