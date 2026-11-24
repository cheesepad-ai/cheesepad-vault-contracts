// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICheeseTaxToken2} from "../interfaces/ICheeseTaxToken2.sol";
import {ICheeseTaxToken} from "../interfaces/ICheeseTaxToken.sol";
import {IDividendTracker} from "../interfaces/IDividendTracker.sol";
import {ITaxProcessor} from "../interfaces/ITaxProcessor.sol";
import {IUniswapV2Router02} from "../interfaces/IUniswapV2Router02.sol";
import {IUniswapV2Factory} from "../interfaces/IUniswapV2Factory.sol";

/// @title CheeseTaxToken
/// @notice Thin ERC20 tax token (TYPE 3). Handles transfer-path logic only:
///         tax collect, buy/sell detect, trading-start, a processor-driven
///         `_swapping` flag, and `setShare` notification. Revenue routing and
///         holder-dividend accounting are fully delegated to the bound
///         `TaxProcessor` and `DividendTracker` collaborators.
///
///         Ownership is renounced in the constructor, so the token has no owner
///         after deployment (`owner()` returns the zero address). The immutable
///         `configurator` (= msg.sender at deploy) may call the one-time bind
///         setters; after binding the collaborators the configurator has no
///         further power.
contract CheeseTaxToken is ERC20, ICheeseTaxToken2, ICheeseTaxToken, Ownable {
    // ─── Constants ───────────────────────────────────────────────────────────
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 public constant BPS_BASE = 10_000;
    /// @notice Token-type discriminant (CheeseToken = 0, CheeseTaxToken2 = 2, this token = 3).
    uint8 public constant TOKEN_TYPE = 3;
    uint256 public constant MAX_TAX_BPS = 1_000; // 10 %
    address public constant DEAD = address(0xdEaD);

    // ─── Config structs ──────────────────────────────────────────────────────

    /// @notice Per-bucket allocation of collected tax, in BPS. Must sum to 10 000.
    struct TaxAllocation {
        uint16 feeReceiver;
        uint16 holders;
        uint16 burn;
        uint16 liquidity;
    }

    /// @notice Full tax configuration supplied at construction time.
    struct TaxConfig {
        uint256 buyTaxBps;
        uint256 sellTaxBps;
        uint256 taxDuration; // 0 = permanent
        TaxAllocation allocation;
        address feeReceiver;
        address quoteToken;
        uint256 minDispatch;
        uint256 minHolderShare;
    }

    // ─── Config state (written once by initialize) ───────────────────────────
    // Deployed via a per-kind blueprint (arg-free CREATE2) so the address is a
    // pure function of {diamond, blueprint, salt}; everything the constructor used
    // to fix as an immutable is set once by `initialize`, guarded single-shot.
    address public override(ICheeseTaxToken, ICheeseTaxToken2) HELPER;
    address public override(ICheeseTaxToken, ICheeseTaxToken2) QUOTE_TOKEN;
    address public override(ICheeseTaxToken, ICheeseTaxToken2) ROUTER;
    address public override(ICheeseTaxToken, ICheeseTaxToken2) PAIR;
    address public override(ICheeseTaxToken, ICheeseTaxToken2) WETH;

    /// @notice The address that deployed and configured this token set.
    ///         Set once at initialize; it may call the one-time bind setters and
    ///         then has no further power over the token.
    address public override configurator;

    uint256 public override BUY_TAX_BPS;
    uint256 public override SELL_TAX_BPS;
    uint256 public override TAX_DURATION;
    TaxAllocation public allocation;
    uint256 public override MIN_DISPATCH;
    uint256 public override MIN_HOLDER_SHARE;

    /// @notice Name/symbol backing storage: the empty-constructor ERC20 stores
    ///         "" so `initialize` records them here and name()/symbol() read these.
    string private _tokenName;
    string private _tokenSymbol;

    /// @notice Single-shot initialize guard.
    bool private _initialized;

    // ─── Mutable state — one-time bindable collaborator refs ─────────────────
    /// @notice Fund-manager for this sale. Zero until bound via setFundManager.
    address public override(ICheeseTaxToken, ICheeseTaxToken2) fundManager;

    /// @notice Fee-receiver (vault or EOA). Zero at construction for
    ///         vault-paired launches (vanity-salt independence).
    address public override FEE_RECEIVER;

    /// @notice Bound TaxProcessor. Set once via setTaxProcessor.
    address public override taxProcessor;

    /// @notice Bound DividendTracker. Set once via setDividendTracker.
    ///         Remains zero for launches with allocation.holders == 0.
    address public override dividendTracker;

    // ─── Transfer-path mutable state ─────────────────────────────────────────
    bool public override tradingStarted;

    /// @notice Unix time when trading started (the official listing). Zero until
    ///         tradingStarted flips true. Anchors the tax-expiration window.
    uint256 public override tradingStartedAt;

    /// @notice Set by the TaxProcessor around its swap/liquidity calls so the
    ///         router→pair transfers are not re-taxed. Writable only by the
    ///         bound taxProcessor via setSwapping().
    bool private _swapping;

    // ─── Events ──────────────────────────────────────────────────────────────

    /// @notice Emitted when the first liquidity transfer to the pair starts trading.
    event TradingStarted();

    // ─── Constructor / initializer ───────────────────────────────────────────
    /// @dev Empty constructor: the token is CREATE2'd from a per-kind blueprint
    ///      with NO args, so every token of this kind is byte-identical and its
    ///      address is a pure function of {deployer, blueprint, salt}. All config
    ///      is set once by `initialize`, called by the deployer in the same tx.
    constructor() ERC20("", "") Ownable(msg.sender) {}

    /// @notice ERC20 name/symbol, recorded by initialize (the constructor stores "").
    function name() public view override returns (string memory) {
        return _tokenName;
    }

    function symbol() public view override returns (string memory) {
        return _tokenSymbol;
    }

    /// @notice One-time initializer; callable once, by the deployer (the diamond).
    function initialize(
        string calldata name_,
        string calldata symbol_,
        address router_,
        address helper_,
        TaxConfig calldata taxConfig_
    ) external {
        require(!_initialized, "Already initialized");
        _initialized = true;

        require(router_ != address(0), "Invalid router");
        require(helper_ != address(0), "Invalid helper");
        require(taxConfig_.quoteToken != address(0), "Invalid quote token");
        require(taxConfig_.minDispatch > 0, "Invalid min dispatch");
        require(taxConfig_.buyTaxBps <= MAX_TAX_BPS, "Buy tax exceeds max");
        require(taxConfig_.sellTaxBps <= MAX_TAX_BPS, "Sell tax exceeds max");
        require(taxConfig_.buyTaxBps + taxConfig_.sellTaxBps > 0, "Tax must be > 0");

        TaxAllocation memory allocationConfig = taxConfig_.allocation;
        uint256 allocationSum = uint256(allocationConfig.feeReceiver) +
            uint256(allocationConfig.holders) +
            uint256(allocationConfig.burn) +
            uint256(allocationConfig.liquidity);
        require(allocationSum == BPS_BASE, "Invalid allocation");

        if (allocationConfig.holders > 0) {
            require(taxConfig_.minHolderShare > 0, "Invalid holder config");
        }

        _tokenName = name_;
        _tokenSymbol = symbol_;
        configurator = msg.sender;
        ROUTER = router_;
        HELPER = helper_;
        QUOTE_TOKEN = taxConfig_.quoteToken;
        MIN_DISPATCH = taxConfig_.minDispatch;
        MIN_HOLDER_SHARE = taxConfig_.minHolderShare;
        FEE_RECEIVER = taxConfig_.feeReceiver;
        BUY_TAX_BPS = taxConfig_.buyTaxBps;
        SELL_TAX_BPS = taxConfig_.sellTaxBps;
        TAX_DURATION = taxConfig_.taxDuration;
        allocation = allocationConfig;

        // Resolve WETH from router
        WETH = IUniswapV2Router02(router_).WETH();

        // Create or resolve the token/quote pair
        address factory = IUniswapV2Router02(router_).factory();
        address pairAddr = IUniswapV2Factory(factory).getPair(
            address(this),
            taxConfig_.quoteToken
        );
        if (pairAddr == address(0)) {
            pairAddr = IUniswapV2Factory(factory).createPair(
                address(this),
                taxConfig_.quoteToken
            );
        }
        PAIR = pairAddr;

        // Mint total supply to the configurator (= the deploying launchpad authority).
        _mint(msg.sender, TOTAL_SUPPLY);

        renounceOwnership();
    }

    receive() external payable {}

    // ─── Configurator-only one-time bind setters ──────────────────────────────

    /// @notice Binds the fund manager address exactly once.
    function setFundManager(address fundManager_) external override {
        require(msg.sender == configurator, "Not configurator");
        require(fundManager == address(0), "Fund manager already set");
        require(fundManager_ != address(0), "Invalid fund manager");
        fundManager = fundManager_;
    }

    /// @notice One-time fee-receiver binding. Zero at construction for
    ///         vault-paired launches; bound in the same tx as the vault deploy.
    function setFeeReceiver(address feeReceiver_) external override {
        require(msg.sender == configurator, "Not configurator");
        require(FEE_RECEIVER == address(0), "Fee receiver already set");
        require(feeReceiver_ != address(0), "Invalid fee receiver");
        FEE_RECEIVER = feeReceiver_;
    }

    /// @notice Binds the TaxProcessor exactly once.
    function setTaxProcessor(address taxProcessor_) external override {
        require(msg.sender == configurator, "Not configurator");
        require(taxProcessor == address(0), "Tax processor already set");
        require(taxProcessor_ != address(0), "Invalid tax processor");
        taxProcessor = taxProcessor_;
    }

    /// @notice Binds the DividendTracker exactly once (only for holdersBps > 0 launches).
    function setDividendTracker(address dividendTracker_) external override {
        require(msg.sender == configurator, "Not configurator");
        require(dividendTracker == address(0), "Dividend tracker already set");
        require(dividendTracker_ != address(0), "Invalid dividend tracker");
        dividendTracker = dividendTracker_;
    }

    // ─── Processor-driven swap-window flag ───────────────────────────────────

    /// @notice Backward-compat effective rate = max(buy, sell).
    ///         Mandated by ICheeseTaxToken.
    function TAX_BPS()
        external
        view
        override(ICheeseTaxToken)
        returns (uint256)
    {
        return BUY_TAX_BPS >= SELL_TAX_BPS ? BUY_TAX_BPS : SELL_TAX_BPS;
    }

    /// @notice Called by the TaxProcessor to open/close the swap window so
    ///         internal router→pair transfers are not re-taxed. Only the bound
    ///         taxProcessor may call this.
    function setSwapping(bool v) external override {
        require(
            msg.sender == taxProcessor && taxProcessor != address(0),
            "Not processor"
        );
        _swapping = v;
    }

    // ─── Error messages reused across the setter guards ──────────────────────
    // (inline strings used above; separate getter below for external callers)

    // ─── Transfer hook ───────────────────────────────────────────────────────
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        // 1. Mint / burn — bypass everything
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        // 2. Internal mover bypass: processor-driven swap window, the token
        //    forwarding its own accumulated tax to the processor, and the
        //    processor's own outgoing transfers (burn, liquidity).
        if (_swapping || from == address(this) || from == taxProcessor) {
            super._update(from, to, value);
            return;
        }

        bool toIsPair   = (to   == PAIR);
        bool fromIsPair = (from == PAIR);

        // Pre-listing lock: before trading starts, only the platform's own
        // custody moves may transfer — the configurator (supply-out; the listing
        // seed is handled by branch 3 below) or the fund manager (curve buy/sell,
        // finalize pull-back). Blocks wallet-to-wallet / OTC before listing. The
        // pair-seeding case (to == PAIR) falls through to branch 3, which
        // additionally requires from == configurator.
        if (!tradingStarted && !toIsPair) {
            require(
                from == configurator ||
                    from == fundManager ||
                    to == fundManager,
                "Not listed"
            );
        }

        // 3. Trading-start: first transfer to pair (initial liquidity add).
        //    This transfer is untaxed; the guard checks all required binds.
        if (
            toIsPair &&
            !tradingStarted &&
            from != PAIR &&
            from != address(this)
        ) {
            // Only the configurator (the launchpad performing the official
            // listing) may seed the pair; any earlier LP add reverts.
            require(from == configurator, "Not listed");
            // Trading must never start with a missing collaborator — dispatch
            // would either silently skip a slice or call a null address.
            require(
                (allocation.feeReceiver == 0 || FEE_RECEIVER != address(0)) &&
                taxProcessor != address(0) &&
                (allocation.holders == 0 || dividendTracker != address(0)),
                "Binds not complete"
            );
            tradingStarted = true;
            tradingStartedAt = block.timestamp;
            emit TradingStarted();
            super._update(from, to, value);
            _notifyShare(from);
            _notifyShare(to);
            return;
        }

        // 4. Sell path: dispatch BEFORE collecting current transfer tax.
        //    Matches the monolith's ordering — accumulated fee from prior transfers
        //    is flushed before the new sell's tax is added. This avoids a situation
        //    where dispatch() runs mid-sell while the outer router swap is still
        //    consuming the pair's reserves.
        if (toIsPair && tradingStarted && !fromIsPair) {
            _tryDispatch();
        }

        // 5. Collect tax on buy or sell (pair-involved transfer, post-trading-start).
        //    Direction picks the rate: buy = tokens leaving the pair (fromIsPair),
        //    sell = tokens entering the pair (toIsPair). Tax stops once the optional
        //    duration has elapsed. Elapsed form avoids overflow on an unbounded
        //    TAX_DURATION (tradingStartedAt <= block.timestamp always).
        uint256 taxAmount = 0;
        uint256 rate = fromIsPair ? BUY_TAX_BPS : SELL_TAX_BPS;
        bool taxActive = TAX_DURATION == 0 ||
            block.timestamp - tradingStartedAt < TAX_DURATION;
        if (
            tradingStarted &&
            taxActive &&
            rate > 0 &&
            (toIsPair || fromIsPair) &&
            from != address(this)
        ) {
            taxAmount = (value * rate) / BPS_BASE;
            if (taxAmount > 0) {
                super._update(from, address(this), taxAmount);
                value -= taxAmount;
            }
        }

        // 6. The real transfer.
        super._update(from, to, value);

        // 7. Notify dividend tracker of updated balances.
        _notifyShare(from);
        if (from != to) {
            _notifyShare(to);
        }

        // 8. Non-pair wallet transfer: dispatch AFTER share updates.
        if (tradingStarted && !toIsPair && !fromIsPair && from != address(this)) {
            _tryDispatch();
        }
    }

    /// @dev Forwards the token's accrued tax balance to the processor (via a
    ///      from==address(this) transfer, bypassed by the internal-mover guard),
    ///      then pokes dispatch() best-effort so a processor failure can never
    ///      brick a transfer.
    function _tryDispatch() private {
        uint256 accrued = balanceOf(address(this));
        if (accrued >= MIN_DISPATCH && taxProcessor != address(0)) {
            // Forward accumulated tax to the processor. This is a
            // from==address(this) transfer so it is bypassed by guard #2.
            super._update(address(this), taxProcessor, accrued);
            try ITaxProcessor(taxProcessor).dispatch() {} catch {}
        }
    }

    /// @dev Notifies the DividendTracker of an account's updated balance.
    ///      No-ops when the tracker is not bound.
    ///      Filters out addresses that must never accumulate holder dividends:
    ///      the DEX pair (holds most supply but cannot claim), the DEAD burn
    ///      address, the token contract itself, the TaxProcessor, and the
    ///      FundManager. Without this filter the pair would capture the majority
    ///      of dividends, permanently diverting them unclaimable.
    function _notifyShare(address account) private {
        if (dividendTracker == address(0)) return;
        if (
            account == PAIR ||
            account == DEAD ||
            account == address(this) ||
            account == taxProcessor ||
            account == fundManager
        ) {
            return;
        }
        IDividendTracker(dividendTracker).setShare(account, balanceOf(account));
    }
}
