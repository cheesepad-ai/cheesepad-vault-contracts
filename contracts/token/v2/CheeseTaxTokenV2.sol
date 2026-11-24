// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICheeseTaxTokenV2} from "./ICheeseTaxTokenV2.sol";
import {IDividendTrackerV2} from "./IDividendTrackerV2.sol";
import {ITaxProcessorV2} from "./ITaxProcessorV2.sol";
import {IUniswapV2Router02} from "../../interfaces/IUniswapV2Router02.sol";
import {IUniswapV2Factory} from "../../interfaces/IUniswapV2Factory.sol";
import {LibVenue} from "./LibVenue.sol";

/// @dev Liquidation-threshold bounds, at file scope so the launcher can read
///      them at deploy time (before any token instance exists) to derive the
///      per-launch liqExpectedOutputAmount. Re-exposed as public constants on the
///      token for on-chain reads. Not per-launch — the reference design bakes these
///      into the implementation.
uint256 constant CHEESE_V2_MIN_LIQ_THRESHOLD = 50_000 ether;
uint256 constant CHEESE_V2_START_LIQ_THRESHOLD = 400_000 ether;

/// @title CheeseTaxTokenV2
/// @notice Thin ERC20 tax token with an automatic lifecycle, a multi-pool tax set
///         with an anti-farmer window, and a bidirectionally-adjusted liquidation
///         threshold. Revenue routing and holder dividends are delegated to the
///         TaxProcessorV2 and DividendTrackerV2 bound at initialize. Ownership is
///         renounced at initialize, every collaborator and the taxed-venue set are
///         fixed there, and the `configurator` may only make the listing transfer,
///         after which it is cleared.
contract CheeseTaxTokenV2 is ERC20, Ownable, ICheeseTaxTokenV2 {
    // ─── Constants ───────────────────────────────────────────────────────────
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 public constant BPS_BASE = 10_000;
    uint8 public constant override TOKEN_TYPE = 4;
    uint256 public constant MAX_TAX_BPS = 1_000; // 10%
    address public constant DEAD = address(0xdEaD);
    /// @notice Absolute cap on tax / anti-farmer durations. An absolute bound (vs
    ///         one relative to the init timestamp) guarantees `listingTime + duration`
    ///         cannot overflow or wrap the packed uint64/uint48 clocks no matter how
    ///         much later listing happens, while still admitting the ~100-year
    ///         "permanent tax" the launcher uses.
    uint256 public constant MAX_DURATION = 150 * 365 days;

    /// @notice Liquidation-threshold bounds (token-level constants, not per-launch,
    ///         per the reference design where they are implementation immutables).
    ///         The accrued-tax liquidation threshold auto-adjusts within
    ///         [MIN_LIQ_THRESHOLD, START_LIQ_THRESHOLD]; every launch starts at START.
    uint256 public constant MIN_LIQ_THRESHOLD = CHEESE_V2_MIN_LIQ_THRESHOLD;
    uint256 public constant START_LIQ_THRESHOLD = CHEESE_V2_START_LIQ_THRESHOLD;

    /// @notice Lifecycle states, advanced automatically (no privileged calls).
    enum PoolState {
        BondingCurve,
        TaxEnforcedAntiFarmer,
        TaxEnforced,
        TaxFree
    }

    /// @notice Per-bucket allocation of collected tax, in BPS. Must sum to 10 000.
    struct TaxAllocation {
        uint16 feeReceiver;
        uint16 holders;
        uint16 burn;
        uint16 liquidity;
    }

    /// @notice Full tax configuration supplied to initialize.
    struct TaxConfig {
        uint256 buyTaxBps;
        uint256 sellTaxBps;
        uint256 taxDuration; // seconds from listing; must be >= antiFarmerDuration
        uint256 antiFarmerDuration; // seconds from listing
        TaxAllocation allocation;
        address feeReceiver;
        address quoteToken;
        uint256 minHolderShare;
        // Anti-farmer venue prediction (0 to skip). v2Factory comes from the router.
        address v3Factory;
        bytes32 v2PairInitCodeHash;
        bytes32 v3PoolInitCodeHash;
        uint24[] v3FeeTiers; // per-DEX V3 fee tiers (empty = no V3 venues)
    }

    /// @notice Collaborators bound at initialize. `dividendTracker` is set exactly
    ///         when the holders allocation is non-zero.
    struct Binds {
        address fundManager;
        address taxProcessor;
        address dividendTracker;
    }

    /// @dev All lifecycle-hot state packed into a single slot.
    struct PackedPoolState {
        uint8 state;
        uint16 buyTaxRate;
        uint16 sellTaxRate;
        bool notLiquidating;
        uint96 liquidationThreshold;
        uint64 taxExpirationTime;
        uint48 antiFarmerExpirationTime;
    }

    // ─── Config (written once by initialize) ─────────────────────────────────
    address public override QUOTE_TOKEN;
    address public override ROUTER;
    address public override PAIR;
    address public override WETH;
    address public override configurator;

    uint256 public override TAX_DURATION;
    uint256 public override antiFarmerDuration;
    uint256 public initialLiquidationThreshold;
    uint256 public minLiquidationThreshold;
    TaxAllocation public allocation;

    string private _tokenName;
    string private _tokenSymbol;
    bool private _initialized;

    // ─── Collaborator refs (bound at initialize) ──────────────────────────────
    address public override fundManager;
    address public override FEE_RECEIVER;
    address public override taxProcessor;
    address public override dividendTracker;

    // ─── Transfer-path state ─────────────────────────────────────────────────
    PackedPoolState public poolState;
    address public override mainPool;
    mapping(address => bool) private _pools;

    /// @notice AMM venues (e.g. V4 singletons) that can't be address-predicted, whose
    ///         LP-adds are blocked before listing so no off-book market opens early.
    ///         Snapshotted once at initialize; there is no add/remove, and it is only
    ///         consulted pre-listing — it can never gate post-listing trading.
    mapping(address => bool) public isPreListingGuardedVenue;

    bool public override tradingStarted;
    uint256 public override tradingStartedAt;
    bool private _swapping;
    bool private _lockedUntilListing;

    // ─── Events ──────────────────────────────────────────────────────────────
    event TradingStarted();

    /// @dev Empty constructor: the token is CREATE2'd from a per-kind blueprint
    ///      with no args, so every token of this kind is byte-identical.
    constructor() ERC20("", "") Ownable(msg.sender) {}

    function name() public view override returns (string memory) {
        return _tokenName;
    }

    function symbol() public view override returns (string memory) {
        return _tokenSymbol;
    }

    /// @notice One-time initializer; callable once, by the deployer (the configurator).
    function initialize(
        string calldata name_,
        string calldata symbol_,
        address router_,
        TaxConfig calldata taxConfig_,
        LibVenue.LaunchVenues calldata venues_,
        Binds calldata binds_
    ) external {
        require(!_initialized, "Already initialized");
        _initialized = true;

        require(router_ != address(0), "Invalid router");
        require(taxConfig_.quoteToken != address(0), "Invalid quote token");
        require(taxConfig_.buyTaxBps <= MAX_TAX_BPS, "Buy tax exceeds max");
        require(taxConfig_.sellTaxBps <= MAX_TAX_BPS, "Sell tax exceeds max");
        require(taxConfig_.buyTaxBps + taxConfig_.sellTaxBps > 0, "Tax must be > 0");
        // Reject the zero sentinel outright rather than let it mean "permanent" (as
        // legacy launch clients assume) or "immediate tax-free" (what listing would
        // otherwise store: taxExpirationTime == listing timestamp -> the first trade
        // flips TaxFree). A launch that means permanent tax must pass an explicit
        // long duration (up to MAX_DURATION); a microsale that configures tax but
        // never funds it is caught here rather than silently listing tax-free.
        require(taxConfig_.taxDuration > 0, "Tax duration required");
        require(
            taxConfig_.taxDuration >= taxConfig_.antiFarmerDuration,
            "Tax duration too short"
        );
        // Bound both durations by an ABSOLUTE maximum (not one relative to the init
        // timestamp): expiry is computed from the later listing timestamp, so an
        // init-relative bound would still wrap the packed uint64/uint48 clocks if
        // listing lands even one second later. A fixed cap can never wrap for
        // millennia and avoids a huge-duration launch bricking `_startTrading`.
        require(taxConfig_.taxDuration <= MAX_DURATION, "Tax duration too long");
        require(
            taxConfig_.antiFarmerDuration <= MAX_DURATION,
            "Anti-farmer duration too long"
        );

        TaxAllocation memory alloc = taxConfig_.allocation;
        require(
            uint256(alloc.feeReceiver) +
                uint256(alloc.holders) +
                uint256(alloc.burn) +
                uint256(alloc.liquidity) ==
                BPS_BASE,
            "Invalid allocation"
        );
        if (alloc.holders > 0) {
            require(taxConfig_.minHolderShare > 0, "Invalid holder config");
        }

        _tokenName = name_;
        _tokenSymbol = symbol_;
        configurator = msg.sender;
        ROUTER = router_;
        QUOTE_TOKEN = taxConfig_.quoteToken;
        _bind(taxConfig_.feeReceiver, alloc.holders, binds_);
        TAX_DURATION = taxConfig_.taxDuration;
        antiFarmerDuration = taxConfig_.antiFarmerDuration;
        initialLiquidationThreshold = START_LIQ_THRESHOLD;
        minLiquidationThreshold = MIN_LIQ_THRESHOLD;
        allocation = alloc;

        WETH = IUniswapV2Router02(router_).WETH();

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
        mainPool = pairAddr;
        // Register the main pair + venues across every anti-farmer DEX (TOKEN/WETH V2
        // pair, V3 fee-tier pools, per-stable pairs), then snapshot the pre-listing
        // guarded venues. Split into helpers to keep initialize under the stack limit.
        _registerVenues(
            pairAddr,
            factory,
            taxConfig_,
            venues_.extraDexes,
            venues_.extraQuoteTokens
        );
        _snapshotGuardedVenues(venues_.guardedVenues);

        poolState = PackedPoolState({
            state: uint8(PoolState.BondingCurve),
            buyTaxRate: uint16(taxConfig_.buyTaxBps),
            sellTaxRate: uint16(taxConfig_.sellTaxBps),
            notLiquidating: true,
            liquidationThreshold: uint96(START_LIQ_THRESHOLD),
            taxExpirationTime: 0,
            antiFarmerExpirationTime: 0
        });

        _mint(msg.sender, TOTAL_SUPPLY);
        renounceOwnership();
    }

    /// @dev Binds the fee receiver and collaborators. Split out of initialize to keep
    ///      its stack under the EVM limit.
    function _bind(address feeReceiver_, uint16 holders, Binds calldata b) private {
        require(feeReceiver_ != address(0), "Invalid fee receiver");
        require(b.fundManager != address(0), "Invalid fund manager");
        require(b.taxProcessor != address(0), "Invalid tax processor");
        require(
            (holders > 0) == (b.dividendTracker != address(0)),
            "Invalid dividend tracker"
        );
        FEE_RECEIVER = feeReceiver_;
        fundManager = b.fundManager;
        taxProcessor = b.taxProcessor;
        dividendTracker = b.dividendTracker;
    }

    /// @dev Registers venues for the launch DEX + every extra anti-farmer DEX. Split
    ///      out of initialize to keep its stack under the EVM limit.
    function _registerVenues(
        address pairAddr,
        address factory,
        TaxConfig calldata taxConfig_,
        LibVenue.Dex[] calldata extraDexes_,
        address[] calldata extraQuoteTokens_
    ) private {
        LibVenue.register(
            _pools,
            pairAddr,
            address(this),
            taxConfig_.quoteToken,
            WETH,
            LibVenue.Dex({
                v2Factory: factory,
                v2InitCodeHash: taxConfig_.v2PairInitCodeHash,
                v3Factory: taxConfig_.v3Factory,
                v3PoolInitCodeHash: taxConfig_.v3PoolInitCodeHash,
                v3FeeTiers: taxConfig_.v3FeeTiers
            }),
            extraDexes_,
            extraQuoteTokens_
        );
    }

    /// @dev Snapshots the pre-listing guarded venues (immutable per token).
    function _snapshotGuardedVenues(address[] calldata venues) private {
        for (uint256 i = 0; i < venues.length; i++) {
            if (venues[i] != address(0)) {
                isPreListingGuardedVenue[venues[i]] = true;
            }
        }
    }

    receive() external payable {}

    /// @notice Opens/closes the swap window so router→pair transfers are not
    ///         re-taxed. Callable only by the bound tax processor.
    function setSwapping(bool v) external override {
        require(
            msg.sender == taxProcessor && taxProcessor != address(0),
            "Not processor"
        );
        _swapping = v;
    }

    /// @notice Restricts pre-listing transfers to fund-manager and configurator
    ///         flows until the listing. Configurator only, before listing; one-way.
    function lockTransfersUntilListing() external override {
        require(msg.sender == configurator, "Not configurator");
        require(!tradingStarted, "Already listed");
        _lockedUntilListing = true;
    }

    /// @notice True while the pre-listing transfer lock is in force.
    function transfersLockedUntilListing() external view override returns (bool) {
        return _lockedUntilListing && !tradingStarted;
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    function state() external view override returns (uint8) {
        return poolState.state;
    }

    function isPool(address account) public view override returns (bool) {
        return _pools[account];
    }

    function liquidationThreshold() external view override returns (uint256) {
        return poolState.liquidationThreshold;
    }

    function BUY_TAX_BPS() external view override returns (uint256) {
        return poolState.buyTaxRate;
    }

    function SELL_TAX_BPS() external view override returns (uint256) {
        return poolState.sellTaxRate;
    }

    /// @notice Backward-compat effective rate = max(buy, sell).
    function TAX_BPS() external view override returns (uint256) {
        PackedPoolState memory ps = poolState;
        return ps.buyTaxRate >= ps.sellTaxRate ? ps.buyTaxRate : ps.sellTaxRate;
    }

    // ─── Transfer hook ─────────────────────────────────────────────────────────
    function _update(address from, address to, uint256 value) internal override {
        // Mint / burn — bypass everything.
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        // Internal movers: processor swap window, the token forwarding its own
        // accrued tax, and the processor's outgoing transfers.
        if (_swapping || from == address(this) || from == taxProcessor) {
            super._update(from, to, value);
            return;
        }

        PoolState st = PoolState(poolState.state);

        if (st == PoolState.BondingCurve) {
            _preListingTransfer(from, to, value);
            return;
        }

        // Flush accrued tax (and advance the lifecycle) before taxing this transfer.
        _maybeLiquidate(to);

        PackedPoolState memory ps = poolState;
        uint256 tax = _computeTax(from, to, value, ps);
        if (tax > 0) {
            super._update(from, address(this), tax);
            value -= tax;
        }
        super._update(from, to, value);

        _notifyShare(from);
        if (from != to) {
            _notifyShare(to);
        }
    }

    /// @dev Pre-listing transfers: wallet-to-wallet is free unless locked; no
    ///      registered pool may be seeded before listing. The
    ///      first configurator→pair transfer is the listing and starts trading (untaxed).
    function _preListingTransfer(address from, address to, uint256 value) private {
        if (to == PAIR) {
            require(from == configurator, "Not listed");
            _startTrading();
            super._update(from, to, value);
            _notifyShare(from);
            _notifyShare(to);
            return;
        }

        require(!_pools[from] && !_pools[to], "Pool restricted");
        require(
            !isPreListingGuardedVenue[from] && !isPreListingGuardedVenue[to],
            "Venue not open"
        );
        require(
            !_lockedUntilListing ||
                from == fundManager ||
                to == fundManager ||
                from == configurator,
            "Transfers locked"
        );
        super._update(from, to, value);
        _notifyShare(from);
        _notifyShare(to);
    }

    /// @dev Transitions BondingCurve → TaxEnforcedAntiFarmer, pins both clocks to
    ///      the listing moment, and clears the configurator.
    function _startTrading() private {
        PackedPoolState memory ps = poolState;
        ps.state = uint8(PoolState.TaxEnforcedAntiFarmer);
        ps.taxExpirationTime = uint64(block.timestamp + TAX_DURATION);
        ps.antiFarmerExpirationTime = uint48(
            block.timestamp + antiFarmerDuration
        );
        poolState = ps;
        tradingStarted = true;
        tradingStartedAt = block.timestamp;
        configurator = address(0);
        emit TradingStarted();
    }

    /// @dev Advances the lifecycle by timestamp (independent of direction, so
    ///      expiry never waits for a sell) and, on a sell past the threshold,
    ///      forwards accrued tax to the processor and applies its threshold signal.
    function _maybeLiquidate(address to) private {
        PackedPoolState memory ps = poolState;
        if (!ps.notLiquidating) {
            return;
        }

        bool changed;
        if (
            PoolState(ps.state) != PoolState.TaxFree &&
            block.timestamp >= ps.taxExpirationTime
        ) {
            ps.state = uint8(PoolState.TaxFree);
            ps.buyTaxRate = 0;
            ps.sellTaxRate = 0;
            changed = true;
        } else if (
            PoolState(ps.state) == PoolState.TaxEnforcedAntiFarmer &&
            block.timestamp >= ps.antiFarmerExpirationTime
        ) {
            ps.state = uint8(PoolState.TaxEnforced);
            changed = true;
        }

        uint256 accrued = balanceOf(address(this));
        bool liquidate = accrued > 0 &&
            _pools[to] &&
            (PoolState(ps.state) == PoolState.TaxFree ||
                accrued >= ps.liquidationThreshold);

        if (liquidate && taxProcessor != address(0)) {
            ps.notLiquidating = false;
            poolState = ps;

            super._update(address(this), taxProcessor, accrued);
            try ITaxProcessorV2(taxProcessor).processTaxTokens(accrued) returns (
                int8 direction
            ) {
                _adjustThreshold(direction);
            } catch {}

            ps = poolState;
            ps.notLiquidating = true;
            poolState = ps;
        } else if (changed) {
            poolState = ps;
        }
    }

    /// @dev Computes tax for the current transfer: buys-from / sells-to any
    ///      registered pool during the anti-farmer window, else only `mainPool`.
    function _computeTax(
        address from,
        address to,
        uint256 value,
        PackedPoolState memory ps
    ) private view returns (uint256) {
        PoolState st = PoolState(ps.state);
        if (st == PoolState.TaxFree) {
            return 0;
        }

        bool fromPool;
        bool toPool;
        if (st == PoolState.TaxEnforcedAntiFarmer) {
            fromPool = _pools[from];
            toPool = _pools[to];
        } else {
            fromPool = (from == mainPool);
            toPool = (to == mainPool);
        }

        // A pool→pool hop (both endpoints registered, reachable via multi-hop
        // routing) must not launder the higher sell rate into the buy rate; charge
        // the stricter of the two so it can never bypass tax.
        if (fromPool && toPool) {
            uint16 rate = ps.buyTaxRate >= ps.sellTaxRate
                ? ps.buyTaxRate
                : ps.sellTaxRate;
            return (value * rate) / BPS_BASE;
        }
        if (fromPool) {
            return (value * ps.buyTaxRate) / BPS_BASE;
        }
        if (toPool) {
            return (value * ps.sellTaxRate) / BPS_BASE;
        }
        return 0;
    }

    /// @dev Adjusts the liquidation threshold ±1% per liquidation, clamped to
    ///      [minLiquidationThreshold, initialLiquidationThreshold].
    function _adjustThreshold(int8 direction) private {
        if (direction == 0) {
            return;
        }
        PackedPoolState memory ps = poolState;
        uint256 t = ps.liquidationThreshold;
        if (direction > 0) {
            t = (t * 101) / 100;
            if (t > initialLiquidationThreshold) {
                t = initialLiquidationThreshold;
            }
        } else {
            t = (t * 99) / 100;
            if (t < minLiquidationThreshold) {
                t = minLiquidationThreshold;
            }
        }
        ps.liquidationThreshold = uint96(t);
        poolState = ps;
    }

    /// @dev Notifies the dividend tracker of an account's balance, skipping
    ///      addresses that must never accrue holder dividends.
    function _notifyShare(address account) private {
        if (dividendTracker == address(0)) {
            return;
        }
        if (
            _pools[account] ||
            isPreListingGuardedVenue[account] ||
            account == DEAD ||
            account == address(this) ||
            account == taxProcessor ||
            account == fundManager
        ) {
            return;
        }
        IDividendTrackerV2(dividendTracker).setShare(
            account,
            balanceOf(account)
        );
    }
}
