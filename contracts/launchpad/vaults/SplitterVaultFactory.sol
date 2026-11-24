// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {VaultFactoryBase} from "./VaultFactoryBase.sol";
import {LaunchDataV1} from "./IVaultFactory.sol";
import {VaultDataSchema, Field, FieldType} from "./IVaultSchema.sol";
import {SplitterVault} from "./SplitterVault.sol";

contract SplitterVaultFactory is VaultFactoryBase {
    address public immutable weth;

    constructor(address _diamond, address weth_) VaultFactoryBase(_diamond) {
        weth = weth_;
    }

    function supportsQuoteToken(address) external pure returns (bool) {
        return true;
    }

    function _reviewV1(LaunchDataV1 memory d)
        internal pure override returns (bool, string memory)
    {
        if (d.feeReceiverBps == 0) return (false, "feeReceiver bps must be > 0");
        if (d.buyTaxBps == 0 && d.sellTaxBps == 0) return (false, "tax must be > 0");
        return (true, "");
    }

    function createVault(address quoteToken, address creator, bytes calldata vaultData)
        external onlyDiamond returns (address vault)
    {
        (address[] memory payees, uint16[] memory bps) =
            abi.decode(vaultData, (address[], uint16[]));
        vault = address(new SplitterVault(diamond, quoteToken, creator, quoteToken == weth, payees, bps));
    }

    function vaultDataSchema() external pure returns (VaultDataSchema memory schema) {
        schema.description = "Fixed payee list; each launch's revenue splits by bps";
        schema.isArray = false;
        schema.fields = new Field[](2);
        schema.fields[0] = Field("payees", FieldType.Address, true, 0, "Recipient addresses");
        schema.fields[1] = Field("bps", FieldType.Uint16, true, 0, "Basis points per payee (sum 10000)");
    }
}
