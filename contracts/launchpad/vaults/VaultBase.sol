// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVault} from "./IVault.sol";
import {IConfigView} from "../../interfaces/IConfigView.sol";
import {IRevenueNotifiable} from "../../interfaces/IRevenueNotifiable.sol";
import {ICheeseTaxToken} from "../../interfaces/ICheeseTaxToken.sol";

abstract contract VaultBase is IVault, IRevenueNotifiable, ReentrancyGuard {
    address public immutable diamond;
    address public immutable quoteToken;
    address public immutable creator;
    bool public immutable isNativeRevenue;

    address public token;        // set once by bind()
    bool public bound;

    error NotDiamond();
    error AlreadyBound();
    error NotPlatform();

    event Bound(address indexed token);
    event RevenueReceived(uint256 amount);

    constructor(address _diamond, address _quoteToken, address _creator, bool _isNativeRevenue) {
        diamond = _diamond;
        quoteToken = _quoteToken;
        creator = _creator;
        isNativeRevenue = _isNativeRevenue;
    }

    function bind(address _token) external {
        if (msg.sender != diamond) revert NotDiamond();
        if (bound) revert AlreadyBound();
        bound = true;
        token = _token;
        emit Bound(_token);
    }

    function platform() public view returns (address) {
        return IConfigView(diamond).getPlatformRole();
    }

    /// @dev Reserved for vaults that opt IN to a platform backstop (e.g. the planned
    ///      GiftVault rescue path). SplitterVault is deliberately sovereign — no
    ///      platform method — per the vault design spec (§6.1): un-sweepability is
    ///      the trust property buyers verify.
    modifier onlyPlatform() {
        if (msg.sender != platform()) revert NotPlatform();
        _;
    }

    function _revenueBalance() internal view returns (uint256) {
        return isNativeRevenue
            ? address(this).balance
            : IERC20(quoteToken).balanceOf(address(this));
    }

    /// @dev Pays revenue in the vault's mode. Reports failure instead of bubbling —
    ///      callers MUST check `ok` and keep the payee's ledger entry on failure.
    ///      Tolerates no-return-value tokens (USDT). A zero amount is a no-op send.
    function _pay(address payee, uint256 amount) internal returns (bool ok) {
        if (isNativeRevenue) {
            (ok, ) = payee.call{value: amount}("");
        } else {
            (bool success, bytes memory ret) = quoteToken.call(
                abi.encodeWithSelector(IERC20.transfer.selector, payee, amount)
            );
            ok = success && (ret.length == 0 || abi.decode(ret, (bool)));
        }
    }

    /// @notice Best-effort revenue signal from the bound token or its TaxProcessor
    ///         (see {IRevenueNotifiable}). Cheap by rule: bookkeeping/events only,
    ///         never call back into the token.
    ///
    ///         In the decomposed architecture the TaxProcessor — not the token — makes
    ///         this call after delivering revenue. We accept both callers so legacy
    ///         and decomposed paths remain compatible.
    function onRevenue(uint256 amount) external {
        address _token = token;
        bool isToken = (msg.sender == _token);
        bool isProcessor = false;
        if (!isToken && _token != address(0) && _token.code.length > 0) {
            try ICheeseTaxToken(_token).taxProcessor() returns (address proc) {
                isProcessor = (proc != address(0) && msg.sender == proc);
            } catch {}
        }
        require(isToken || isProcessor, "Not token");
        emit RevenueReceived(amount);
    }

    /// @dev REVENUE CONTRACT for vault authors: receive() and onRevenue() execute
    ///      INSIDE the token's _swapping window (tax/share accounting is bypassed) and
    ///      the token wraps delivery in try/catch. They MUST be accrue-only / cheap and
    ///      MUST NOT call back into the token. All distribution happens in a separate,
    ///      permissionless poke (distribute()) or a beneficiary pull (claim()).
    ///      Concrete vaults implement distribute(), description(), vaultUISchema()
    ///      (the latter two are mandated by IVault, so every vault is FE-renderable).

    // Accrue-only in the mode that receives revenue; rejects the foreign asset:
    // an ERC20-mode vault is un-sweepable, so silently accepted ETH would be
    // stranded forever — bouncing it is the safe failure.
    receive() external payable virtual {
        require(isNativeRevenue, "Native not accepted");
    }
}
