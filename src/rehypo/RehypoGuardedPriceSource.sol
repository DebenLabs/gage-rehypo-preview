// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IRehypoPriceSource} from "../interfaces/rehypo/IRehypoPriceSource.sol";

/// @title RehypoGuardedPriceSource
/// @notice The price source of a rehypo pool quoted in a dollar token other than USDG, whose sources pull rather than
/// freeze: a fund token against frxUSD, for example. It values the priced token in USDG through `FEED` (a
/// `RehypoNavPriceSource`, or any `IRehypoPriceSource`), takes the quote token at one dollar (one whole token for one
/// whole USDG, as `RehypoParPriceSource` does) once `PEG_FEED` values it within `PEG_BPS` of a dollar, and gives the
/// value in the quote token: its `USDG()` is the quote token, so a rehypo source created on it quotes the pool's other
/// token rather than USDG. Every refusal (either feed's, the peg's, a value rounding to nothing) is answered with a
/// zero value, which a rehypo source's keeper move takes as no price: it pulls its swap float
/// (`GageRehypoSource.Pulled`) instead of reverting and leaving its last position trading.
/// @dev It holds nothing, has no owner and changes nothing: its feeds and peg are fixed at deployment, so no switch of
/// either feed reaches a source created on it without a new price source, a new factory and new sources. A rehypo
/// source factory names one price source, so the pool's sources come from a factory created on this one. A feed's
/// revert with no data (out of gas, a call to an address with no code) is passed up rather than answered with zero, so
/// the gas a keeper sends cannot choose a pull. With the par feed as `PEG_FEED` the peg check can never fail: the peg
/// needs a feed that values the quote token at its market price.
contract RehypoGuardedPriceSource is IRehypoPriceSource {
    uint16 public constant BPS = 10_000;
    /// @notice The bounds of the peg, either side of a dollar.
    uint16 public constant MIN_PEG_BPS = 10;
    uint16 public constant MAX_PEG_BPS = 100;
    /// @notice The most decimals the quote token or USDG may have here.
    uint8 public constant MAX_DECIMALS = 18;

    /// @notice The asset values are given in: the quote token, taken at a dollar (named as the interface names it).
    address public immutable USDG;
    /// @notice The dollar both feeds value in: the chain's USDG.
    address public immutable DOLLAR;
    /// @notice The priced token's feed, valuing it in `DOLLAR`.
    IRehypoPriceSource public immutable FEED;
    /// @notice The quote token's feed, valuing it in `DOLLAR`: the peg check.
    IRehypoPriceSource public immutable PEG_FEED;
    /// @notice How far from a dollar `PEG_FEED` may value the quote token, in basis points.
    uint16 public immutable PEG_BPS;
    /// @notice The amount of the quote token the peg check values: a million whole tokens.
    uint256 public immutable QUOTE_PROBE;
    /// @dev The peg as `PEG_FEED`'s value of `QUOTE_PROBE` (a million whole tokens at a dollar is a million whole
    /// `DOLLAR`s): the lowest and highest value accepted.
    uint256 internal immutable PEG_LO;
    uint256 internal immutable PEG_HI;
    /// @dev One whole quote token and one whole `DOLLAR`, in raw units.
    uint256 internal immutable QUOTE_UNIT;
    uint256 internal immutable DOLLAR_UNIT;

    /// @dev A missing contract, feeds valuing in different dollars, a quote token that is that dollar or that the peg
    /// feed does not know, a peg out of bounds, or too many decimals.
    error InvalidConfiguration();

    /// @param quote The pool's quote token (frxUSD), taken at a dollar.
    /// @param feed The priced token's feed.
    /// @param pegFeed The quote token's feed, valuing in the same dollar as `feed`.
    /// @param pegBps The peg, from `MIN_PEG_BPS` to `MAX_PEG_BPS`.
    constructor(address quote, IRehypoPriceSource feed, IRehypoPriceSource pegFeed, uint16 pegBps) {
        if (quote.code.length == 0 || address(feed).code.length == 0 || address(pegFeed).code.length == 0) {
            revert InvalidConfiguration();
        }
        address dollar = feed.USDG();
        if (pegFeed.USDG() != dollar || quote == dollar || pegBps < MIN_PEG_BPS || pegBps > MAX_PEG_BPS) {
            revert InvalidConfiguration();
        }
        (bytes32 assetId,,,,) = pegFeed.assetOf(quote);
        if (assetId == bytes32(0)) revert InvalidConfiguration();
        uint256 quoteDecimals = IERC20Metadata(quote).decimals();
        uint256 dollarDecimals = IERC20Metadata(dollar).decimals();
        if (quoteDecimals > MAX_DECIMALS || dollarDecimals > MAX_DECIMALS) revert InvalidConfiguration();
        USDG = quote;
        DOLLAR = dollar;
        FEED = feed;
        PEG_FEED = pegFeed;
        PEG_BPS = pegBps;
        QUOTE_PROBE = 10 ** (quoteDecimals + 6);
        uint256 par = 10 ** (dollarDecimals + 6);
        PEG_LO = Math.mulDiv(par, BPS - pegBps, BPS, Math.Rounding.Ceil);
        PEG_HI = Math.mulDiv(par, BPS + pegBps, BPS);
        QUOTE_UNIT = 10 ** quoteDecimals;
        DOLLAR_UNIT = 10 ** dollarDecimals;
    }

    /// @inheritdoc IRehypoPriceSource
    /// @dev The priced feed's record of `token`.
    function assetOf(address token)
        external
        view
        returns (bytes32 assetId, uint32 maxAge, uint8 minSources, uint8 tokenDecimals, bool stockToken)
    {
        return FEED.assetOf(token);
    }

    /// @notice What `amount` raw units of `token` are worth in raw units of the quote token: `FEED`'s USDG value, the
    /// quote token at a dollar, rounded down, and when `FEED` observed its price. Zero, observed now, when either feed
    /// refuses, when `PEG_FEED` values the quote token further than `PEG_BPS` from a dollar, or when the value rounds
    /// to nothing: a rehypo source then pulls.
    /// @param report Empty when both feeds take an empty report; otherwise `abi.encode(feedReport, pegReport)`.
    function valueOf(address token, uint256 amount, bytes calldata report)
        external
        view
        returns (uint256 value, uint256 observedAt)
    {
        bytes memory feedReport;
        bytes memory pegReport;
        if (report.length != 0) (feedReport, pegReport) = abi.decode(report, (bytes, bytes));
        uint256 dollars;
        try FEED.valueOf(token, amount, feedReport) returns (uint256 v, uint256 at) {
            (dollars, observedAt) = (v, at);
        } catch (bytes memory reason) {
            return _refused(reason);
        }
        try PEG_FEED.valueOf(USDG, QUOTE_PROBE, pegReport) returns (uint256 q, uint256) {
            if (q < PEG_LO || q > PEG_HI) return (0, block.timestamp);
        } catch (bytes memory reason) {
            return _refused(reason);
        }
        value = Math.mulDiv(dollars, QUOTE_UNIT, DOLLAR_UNIT);
        if (value == 0) observedAt = block.timestamp;
    }

    /// @dev A feed's refusal: no price, observed now; a revert with no data is passed up.
    function _refused(bytes memory reason) private view returns (uint256, uint256) {
        if (reason.length == 0) {
            assembly ("memory-safe") {
                revert(add(reason, 32), mload(reason))
            }
        }
        return (0, block.timestamp);
    }
}
