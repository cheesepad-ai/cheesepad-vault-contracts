// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {VaultFactoryBase} from "./VaultFactoryBase.sol";
import {LaunchDataV1} from "./IVaultFactory.sol";
import {VaultDataSchema, Field, FieldType} from "./IVaultSchema.sol";
import {GiftVault} from "./GiftVault.sol";

contract GiftVaultFactory is VaultFactoryBase {
    address public immutable weth;

    uint256 private constant MIN_TIMEOUT = 1 days;
    uint256 private constant MAX_TIMEOUT = 365 days;

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
        if (d.holdersBps == 0) return (false, "Gift vault requires a holder dividend slice");
        return (true, "");
    }

    function createVault(address quoteToken, address creator, bytes calldata vaultData)
        external onlyDiamond returns (address vault)
    {
        (string memory xHandle, uint256 timeoutPeriod) =
            abi.decode(vaultData, (string, uint256));
        require(bytes(xHandle).length > 0, "Empty handle");
        require(
            timeoutPeriod >= MIN_TIMEOUT && timeoutPeriod <= MAX_TIMEOUT,
            "Bad timeout"
        );
        vault = address(
            new GiftVault(
                diamond,
                quoteToken,
                creator,
                quoteToken == weth,
                xHandle,
                timeoutPeriod
            )
        );
    }

    function vaultDataSchema() external pure returns (VaultDataSchema memory schema) {
        schema.description = "Gifts revenue to the wallet behind an X handle (relayer-attested, one-time bind)";
        schema.isArray = false;
        schema.fields = new Field[](2);
        schema.fields[0] = Field("xHandle", FieldType.String, false, 0, "X / Twitter handle to gift to");
        schema.fields[1] = Field("timeoutPeriod", FieldType.Uint256, false, 0, "Seconds until unclaimed funds route to token holders as dividends");
    }
}
