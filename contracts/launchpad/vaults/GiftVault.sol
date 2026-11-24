// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {VaultBase} from "./VaultBase.sol";
import {VaultUISchema, Method, Field, FieldType} from "./IVaultSchema.sol";
import {IConfigView} from "../../interfaces/IConfigView.sol";
import {LibVaultSig} from "./LibVaultSig.sol";
import {ICheeseTaxToken} from "../../interfaces/ICheeseTaxToken.sol";
import {IDividendTracker} from "../../interfaces/IDividendTracker.sol";
import {IWETH} from "../../interfaces/IWETH.sol";
import {LibNativeAsset} from "../libraries/LibNativeAsset.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/// @title GiftVault
/// @notice Gifts a token's accrued tax revenue to the wallet behind an X handle.
///         CheesePad's relayer signs a ONE-TIME, EXPIRING EIP-712 proof binding
///         handle -> wallet; after binding the beneficiary withdraws permissionlessly
///         forever (the backend is never in the claim path). If no one binds before
///         the timeout, anyone may route accrued funds to token holders as dividends.
///         Immutable.
contract GiftVault is VaultBase, EIP712 {
    using SafeERC20 for IERC20;
    // keccak256("GiftBind(bytes32 xHandleHash,address taxToken,address beneficiary,uint256 nonce,uint256 validUntil)")
    bytes32 private constant BIND_TYPEHASH =
        keccak256("GiftBind(bytes32 xHandleHash,address taxToken,address beneficiary,uint256 nonce,uint256 validUntil)");

    // Raw handle is the single source of truth (kept on-chain, not just a hash, so
    // indexers/FE can enumerate "which vault gifts to @handle"). The EIP-712 binding
    // key is derived from it via xHandleHash() — no separate stored hash to desync.
    string public xHandle;
    uint256 public immutable timeoutAt;

    address public beneficiary;
    uint256 public lastNonce;
    bool public locked;
    bool public dividendMode;

    mapping(address => uint256) public owed;
    // Sum of all outstanding owed[] entries. _settle credits only revenue beyond what
    // is already owed (balance - totalOwed), so funds already credited to ANY address are
    // never re-credited to the current beneficiary. Earned balances stay with whoever
    // earned them; a binding change redirects only not-yet-credited (future) revenue.
    uint256 public totalOwed;

    error NotBeneficiary();
    error AlreadyLocked();
    error BadProof();
    error ProofExpired();
    error StaleNonce();
    error ZeroBeneficiary();
    error BeneficiaryAlreadySet();
    error NotBound();
    error TimeoutNotReached();
    error BindingClosed();

    event BeneficiaryBound(address indexed beneficiary, uint256 nonce, bool viaRelayer);
    event Distributed(uint256 amount);
    event Paid(address indexed to, uint256 amount);
    event PayFailed(address indexed to, uint256 amount);
    event Claimed(address indexed to, uint256 amount);
    event Locked();
    event DividendDistributed(uint256 amount);

    constructor(
        address _diamond,
        address _quoteToken,
        address _creator,
        bool _isNativeRevenue,
        string memory _xHandle,
        uint256 _timeoutPeriod
    ) VaultBase(_diamond, _quoteToken, _creator, _isNativeRevenue) EIP712("CheesePadGiftVault", "1") {
        xHandle = _xHandle;
        timeoutAt = block.timestamp + _timeoutPeriod;
    }

    /// @notice EIP-712 binding key, derived from the raw handle (single source of truth).
    function xHandleHash() public view returns (bytes32) {
        return keccak256(bytes(xHandle));
    }

    /// @dev Both binding paths require the timeout not to have passed and dividendMode
    ///      not to be active. Once either condition is violated, control is forfeited
    ///      permanently — dividendMode acts as an implicit lock for all binding paths.
    modifier bindingOpen() {
        if (block.timestamp > timeoutAt || dividendMode) revert BindingClosed();
        _;
    }

    function bindBeneficiary(address newBeneficiary, uint256 nonce, uint256 validUntil, bytes calldata signature)
        external
        nonReentrant
        bindingOpen
    {
        if (locked) revert AlreadyLocked();
        if (newBeneficiary == address(0)) revert ZeroBeneficiary();
        if (nonce <= lastNonce) revert StaleNonce();
        if (block.timestamp > validUntil) revert ProofExpired();

        bytes32 structHash =
            keccak256(abi.encode(BIND_TYPEHASH, xHandleHash(), token, newBeneficiary, nonce, validUntil));
        address signer = IConfigView(diamond).getGiftRelayerSigner();
        if (!LibVaultSig.verify(_domainSeparatorV4(), structHash, signature, signer)) revert BadProof();

        // Only future revenue is redirected; any owed[] already credited to the prior
        // beneficiary stays claimable by them (see claim()).
        lastNonce = nonce;
        beneficiary = newBeneficiary;
        emit BeneficiaryBound(newBeneficiary, nonce, true);
    }

    function lock() external {
        if (msg.sender != beneficiary) revert NotBeneficiary();
        locked = true;
        emit Locked();
    }

    /// @notice Corrects a wrongly- or maliciously-bound beneficiary while the vault is still
    ///         unlocked, by redirecting FUTURE revenue to `newBeneficiary`. It deliberately does
    ///         NOT touch any `owed[]` already credited to the previous beneficiary — those funds
    ///         remain claimable by whoever earned them, so a compromised platform key cannot seize
    ///         a correctly-bound user's earned balance, only redirect not-yet-credited revenue.
    ///
    ///         `lastNonce` is intentionally NOT advanced: bumping it by 1 provides no security
    ///         against a compromised relayer key (an attacker holding the key can sign any nonce
    ///         they like). The correct mitigations are:
    ///           (a) rotate `giftRelayerSigner` via `ConfigFacet.setGiftRelayerSigner`, which
    ///               invalidates every proof the compromised key ever issued; and
    ///           (b) have the rescued beneficiary call `lock()` immediately after rescue to make
    ///               the correction permanent and remove both the relayer and the platform from
    ///               any future binding path.
    function platformRescue(address newBeneficiary) external onlyPlatform bindingOpen {
        if (locked) revert AlreadyLocked();
        if (newBeneficiary == address(0)) revert ZeroBeneficiary();
        beneficiary = newBeneficiary;
        emit BeneficiaryBound(newBeneficiary, lastNonce, false);
    }

    /// @dev Credits revenue not yet booked to the ledger (`balance - totalOwed`) to the current
    ///      beneficiary. Using `totalOwed` rather than `owed[beneficiary]` keeps settlement
    ///      correct even when other addresses still hold unclaimed owed[] from a prior binding —
    ///      their backing funds are excluded, never double-credited to the new beneficiary.
    function _settle() internal {
        if (beneficiary == address(0)) return;
        uint256 balance = _revenueBalance();
        uint256 uncredited = balance > totalOwed ? balance - totalOwed : 0;
        if (uncredited > 0) {
            owed[beneficiary] += uncredited;
            totalOwed += uncredited;
            emit Distributed(uncredited);
        }
    }

    function distribute() external nonReentrant {
        address beneficiaryAddress = beneficiary;
        if (beneficiaryAddress == address(0)) revert NotBound();
        _settle();
        uint256 amount = owed[beneficiaryAddress];
        if (amount == 0) return;
        owed[beneficiaryAddress] = 0;
        if (!_pay(beneficiaryAddress, amount)) {
            owed[beneficiaryAddress] = amount;
            emit PayFailed(beneficiaryAddress, amount);
        } else {
            totalOwed -= amount;
            emit Paid(beneficiaryAddress, amount);
        }
    }

    /// @notice Pull any balance owed to the caller. NOT gated on the current beneficiary: an
    ///         address that earned a balance under a prior binding can always recover it, even
    ///         after the beneficiary has been rebound or rescued.
    function claim() external nonReentrant {
        _settle();
        uint256 amount = owed[msg.sender];
        require(amount > 0, "nothing owed");
        owed[msg.sender] = 0;
        totalOwed -= amount;
        require(_pay(msg.sender, amount), "send failed");
        emit Claimed(msg.sender, amount);
    }

    /// @notice Permissionless terminal fallback: routes accrued revenue to token holders
    ///         as dividends via the DividendTracker. Only callable after the timeout when
    ///         the vault was never bound. Setting dividendMode is permanent and idempotent —
    ///         subsequent calls continue to push newly-accrued revenue to holders.
    ///         The flag is set ONLY when revenue is actually routed (amount > 0 and
    ///         totalShares > 0), preventing a vacuous call from permanently closing the
    ///         binding path without distributing anything.
    function distributeDividend() external nonReentrant {
        require(block.timestamp > timeoutAt, "Timeout not reached");
        require(beneficiary == address(0), "Already bound");
        address tracker = ICheeseTaxToken(token).dividendTracker();
        require(tracker != address(0), "No dividend tracker");
        if (IDividendTracker(tracker).totalShares() == 0) return; // no holders yet — no-op
        uint256 amount = _revenueBalance();
        if (amount == 0) return; // nothing to route — do not flip dividendMode
        dividendMode = true; // terminal; idempotent on repeat
        // On a native-USDC precompile there is nothing to wrap: the accrued 18-dec
        // native is the same balance the 6-dec tracker sees, so deposit the ÷1e12
        // pair-unit amount and report the 18-dec native routed.
        if (isNativeRevenue && LibNativeAsset.isPrecompile(quoteToken)) {
            uint256 pairAmount = LibNativeAsset.toPairUnitsFor(quoteToken, amount);
            IERC20(quoteToken).forceApprove(tracker, pairAmount);
            IDividendTracker(tracker).depositDividend(pairAmount);
            emit DividendDistributed(amount);
            return;
        }
        if (isNativeRevenue) IWETH(quoteToken).deposit{value: amount}();
        IERC20(quoteToken).forceApprove(tracker, amount);
        IDividendTracker(tracker).depositDividend(amount);
        emit DividendDistributed(amount);
    }

    function description() external view returns (string memory) {
        if (dividendMode) return "Gift vault: unclaimed revenue routed to token holders as dividends";
        return beneficiary == address(0)
            ? "Gift vault: awaiting the X-handle owner to bind their wallet"
            : "Gift vault: revenue streams to the bound beneficiary";
    }

    function vaultUISchema() external pure returns (VaultUISchema memory s) {
        s.vaultType = "Gift";
        s.description = "Streams token revenue to the wallet behind an X handle";
        s.methods = new Method[](11);

        // ── Write actions ────────────────────────────────────────────────────
        s.methods[0].name = "bindBeneficiary";
        s.methods[0].selector = bytes4(keccak256("bindBeneficiary(address,uint256,uint256,bytes)"));
        s.methods[0].isWrite = true;
        s.methods[0].hint = "Bind your wallet with a relayer-signed proof";
        s.methods[1].name = "distribute";
        s.methods[1].selector = bytes4(keccak256("distribute()"));
        s.methods[1].isWrite = true;
        s.methods[1].hint = "Push accrued revenue to the beneficiary";
        s.methods[2].name = "claim";
        s.methods[2].selector = bytes4(keccak256("claim()"));
        s.methods[2].isWrite = true;
        s.methods[2].hint = "Beneficiary pulls owed balance";
        s.methods[3].name = "lock";
        s.methods[3].selector = bytes4(keccak256("lock()"));
        s.methods[3].isWrite = true;
        s.methods[3].hint = "Permanently lock the beneficiary (cuts the relayer/platform out)";
        s.methods[4].name = "distributeDividend";
        s.methods[4].selector = bytes4(keccak256("distributeDividend()"));
        s.methods[4].isWrite = true;
        s.methods[4].hint = "After timeout with no beneficiary, route funds to token holders";

        // ── Read fields (isWrite=false: FE calls and renders the typed outputs) ─
        s.methods[5].name = "xHandle";
        s.methods[5].selector = bytes4(keccak256("xHandle()"));
        s.methods[5].isWrite = false;
        s.methods[5].outputs = new Field[](1);
        s.methods[5].outputs[0] = Field("xHandle", FieldType.String, false, 0, "X / Twitter handle this vault gifts to");
        s.methods[5].hint = "Target X handle";

        s.methods[6].name = "beneficiary";
        s.methods[6].selector = bytes4(keccak256("beneficiary()"));
        s.methods[6].isWrite = false;
        s.methods[6].outputs = new Field[](1);
        s.methods[6].outputs[0] = Field("beneficiary", FieldType.Address, false, 0, "Bound wallet (zero until claimed)");
        s.methods[6].hint = "Currently bound beneficiary";

        s.methods[7].name = "timeoutAt";
        s.methods[7].selector = bytes4(keccak256("timeoutAt()"));
        s.methods[7].isWrite = false;
        s.methods[7].outputs = new Field[](1);
        s.methods[7].outputs[0] = Field("timeoutAt", FieldType.Time, false, 0, "Deadline to bind before dividend fallback opens");
        s.methods[7].hint = "Binding deadline";

        s.methods[8].name = "dividendMode";
        s.methods[8].selector = bytes4(keccak256("dividendMode()"));
        s.methods[8].isWrite = false;
        s.methods[8].outputs = new Field[](1);
        s.methods[8].outputs[0] = Field("dividendMode", FieldType.Bool, false, 0, "True once unclaimed revenue routes to holders");
        s.methods[8].hint = "Dividend-fallback state";

        s.methods[9].name = "locked";
        s.methods[9].selector = bytes4(keccak256("locked()"));
        s.methods[9].isWrite = false;
        s.methods[9].outputs = new Field[](1);
        s.methods[9].outputs[0] = Field("locked", FieldType.Bool, false, 0, "True if the beneficiary locked the binding");
        s.methods[9].hint = "Binding lock state";

        s.methods[10].name = "owed";
        s.methods[10].selector = bytes4(keccak256("owed(address)"));
        s.methods[10].isWrite = false;
        s.methods[10].inputs = new Field[](1);
        s.methods[10].inputs[0] = Field("account", FieldType.Address, false, 0, "Address to query");
        s.methods[10].outputs = new Field[](1);
        s.methods[10].outputs[0] = Field("owed", FieldType.Uint256, false, 18, "Pending balance for the account");
        s.methods[10].hint = "Pending balance owed to an address";
    }
}
