// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IUniswapV2Router02} from "../interfaces/IUniswapV2Router02.sol";
import {IUniswapV2Factory} from "../interfaces/IUniswapV2Factory.sol";
import {LibVenue} from "./v2/LibVenue.sol";

/// @notice Deployed via a per-kind blueprint (arg-free CREATE2) and configured
///         once by `initialize`; ownership is renounced there, so the token has
///         no owner after deployment (`owner()` returns the zero address).
contract CheeseToken is ERC20, Ownable {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 public constant DECIMALS = 18;
    uint8 public constant TOKEN_TYPE = 0;

    /// @notice Authority allowed to perform the official listing (the deployer).
    ///         Cleared to the zero address by the listing transfer.
    address public configurator;

    /// @notice The canonical token/quote pair, resolved or created at initialize.
    ///         Only the configurator may make the first transfer into it (the official
    ///         listing); any earlier transfer into the pair reverts, so the opening
    ///         price cannot be pre-empted. That first seed flips `tradingStarted`.
    address public pair;
    bool public tradingStarted;

    /// @notice The pool's fund manager. Zero until bound once via setFundManager.
    address public fundManager;

    /// @notice Venues that may not be seeded before listing.
    mapping(address => bool) public isPreListingBlockedVenue;

    /// @notice Name/symbol backing storage (the empty-constructor ERC20 stores "").
    string private _tokenName;
    string private _tokenSymbol;

    /// @notice Single-shot initialize guard.
    bool private _initialized;

    bool private _lockedUntilListing;

    /// @dev Empty constructor: the token is CREATE2'd from a per-kind blueprint
    ///      with NO args, so every token of this kind is byte-identical and its
    ///      address is a pure function of {deployer, blueprint, salt}. All config
    ///      is set once by `initialize`, called by the deployer in the same tx.
    constructor() ERC20("", "") Ownable(msg.sender) {}

    /// @notice One-time initializer; callable once, by the deployer (the configurator).
    function initialize(
        string calldata name_,
        string calldata symbol_,
        address router_,
        address quoteToken_,
        LibVenue.Dex[] calldata dexes,
        address[] calldata extraQuoteTokens,
        address[] calldata guardedVenues
    ) external {
        require(!_initialized, "Already initialized");
        _initialized = true;
        require(router_ != address(0), "Invalid router");
        require(quoteToken_ != address(0), "Invalid quote token");

        _tokenName = name_;
        _tokenSymbol = symbol_;
        configurator = msg.sender;

        address factory = IUniswapV2Router02(router_).factory();
        address existing = IUniswapV2Factory(factory).getPair(
            address(this),
            quoteToken_
        );
        pair = existing == address(0)
            ? IUniswapV2Factory(factory).createPair(address(this), quoteToken_)
            : existing;

        _snapshotBlockedVenues(
            router_,
            quoteToken_,
            dexes,
            extraQuoteTokens,
            guardedVenues
        );

        _mint(msg.sender, TOTAL_SUPPLY);

        renounceOwnership();
    }

    /// @dev Snapshots the pre-graduate venue block set.
    function _snapshotBlockedVenues(
        address router_,
        address quoteToken_,
        LibVenue.Dex[] calldata dexes,
        address[] calldata extraQuoteTokens,
        address[] calldata guardedVenues
    ) private {
        LibVenue.registerVenues(
            isPreListingBlockedVenue,
            pair,
            address(this),
            quoteToken_,
            IUniswapV2Router02(router_).WETH(),
            dexes,
            extraQuoteTokens
        );
        for (uint256 i = 0; i < guardedVenues.length; i++) {
            isPreListingBlockedVenue[guardedVenues[i]] = true;
        }
    }

    function name() public view override returns (string memory) {
        return _tokenName;
    }

    function symbol() public view override returns (string memory) {
        return _tokenSymbol;
    }

    function decimals() public pure override returns (uint8) {
        return uint8(DECIMALS);
    }

    /// @notice Binds the fund manager exactly once, by the configurator.
    function setFundManager(address fundManager_) external {
        require(msg.sender == configurator, "Not configurator");
        require(fundManager == address(0), "Fund manager already set");
        require(fundManager_ != address(0), "Invalid fund manager");
        fundManager = fundManager_;
    }

    /// @notice Restricts pre-listing transfers to fund-manager and configurator
    ///         flows until the listing. Configurator only, before listing; one-way.
    function lockTransfersUntilListing() external {
        require(msg.sender == configurator, "Not configurator");
        require(!tradingStarted, "Already listed");
        _lockedUntilListing = true;
    }

    /// @notice True while the pre-listing transfer lock is in force.
    function transfersLockedUntilListing() external view returns (bool) {
        return _lockedUntilListing && !tradingStarted;
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        // Mint / burn bypass everything.
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        if (!tradingStarted) {
            if (to == pair && from == configurator) {
                // The configurator's first pair seed is the listing.
                tradingStarted = true;
                configurator = address(0);
            } else {
                require(
                    !isPreListingBlockedVenue[from] &&
                        !isPreListingBlockedVenue[to],
                    "Not listed"
                );
                require(
                    !_lockedUntilListing ||
                        from == fundManager ||
                        to == fundManager ||
                        from == configurator,
                    "Transfers locked"
                );
            }
        }
        super._update(from, to, value);
    }
}
