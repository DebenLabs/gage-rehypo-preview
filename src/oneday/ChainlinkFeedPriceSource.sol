// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IOneDayPriceSource} from "../interfaces/IOneDayPriceSource.sol";

/// @notice The calls this source makes on a Chainlink aggregator proxy (Chainlink's `AggregatorV3Interface`).
interface IChainlinkFeed {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice A Robinhood Stock Token's advisory flag, set while a corporate action updates the token's terms.
interface IStockTokenOracle {
    function oraclePaused() external view returns (bool);
}

/// @title ChainlinkFeedPriceSource
/// @notice the independent price from Chainlink's on-chain feeds, read as the rate service's mark reads them:
///         a token's USD feed, which on Robinhood Chain prices one whole token, its multiplier included (an SGOV token
///         read 101.36 on its feed and 101.30 on its pool while its multiplier was 1.0072, 23 October 2026), and
///         USDG's own USD feed, which lowers a value while USDG is above a dollar and never raises one.
/// @dev Read by `GageV2CashoutRouter`'s keeper settlement through `IOneDayPriceSource`. It takes no report: a source
///      for Chainlink's Data Streams verifies one there instead. It holds nothing and moves nothing; its owner only
///      names each token's feed.
contract ChainlinkFeedPriceSource is IOneDayPriceSource, Ownable2Step {
    /// @notice The oldest round a feed may be set to accept: a stock feed posts on a 0.5% move or every 24 hours, so a
    ///         round older than 26 hours is out of session.
    uint32 public constant MAX_AGE_LIMIT = 26 hours;
    /// @notice The most decimals a token, a feed or USDG may have here.
    uint8 public constant MAX_DECIMALS = 18;

    /// @inheritdoc IOneDayPriceSource
    address public immutable USDG;
    /// @notice USDG's decimals.
    uint8 public immutable USDG_DECIMALS;
    /// @notice USDG's own USD feed, or zero to take USDG at a dollar.
    IChainlinkFeed public immutable USDG_USD;

    /// @notice A token's feed: the proxy, the oldest round accepted, the token's decimals, and whether the token is a
    ///         Robinhood Stock Token whose `oraclePaused()` refuses a value.
    struct Feed {
        IChainlinkFeed feed;
        uint32 maxAge;
        uint8 tokenDecimals;
        bool stockToken;
    }

    /// @notice Each token's feed; a zero feed means the token has none.
    mapping(address token => Feed) public feedOf;

    /// @dev A bound or an address the constructor or `setFeed` refuses.
    error InvalidConfiguration();
    /// @dev An on-chain feed takes no report.
    error UnexpectedReport();
    error NoFeed(address token);
    error OraclePaused(address token);
    /// @dev A round older than its feed's bound, from the future, or never updated.
    error StalePrice(address token, uint256 updatedAt);
    error InvalidAnswer(address token, int256 answer);
    /// @dev The amount is worth less than one raw unit of USDG.
    error ZeroValue(address token, uint256 amount);

    event FeedSet(address indexed token, address indexed feed, uint32 maxAge, bool stockToken);

    /// @param usdg The asset values are given in: the asset the router's core lends.
    /// @param usdgUsd USDG's own USD feed, or zero to take USDG at a dollar.
    /// @param admin The owner, who names each token's feed.
    constructor(IERC20Metadata usdg, IChainlinkFeed usdgUsd, address admin) Ownable(admin) {
        if (address(usdg).code.length == 0) revert InvalidConfiguration();
        uint8 decimals = usdg.decimals();
        if (
            decimals > MAX_DECIMALS
                || (address(usdgUsd) != address(0)
                    && (address(usdgUsd).code.length == 0 || usdgUsd.decimals() > MAX_DECIMALS))
        ) revert InvalidConfiguration();
        USDG = address(usdg);
        USDG_DECIMALS = decimals;
        USDG_USD = usdgUsd;
    }

    /// @notice Name `token`'s Chainlink USD feed and the oldest round it accepts, or remove the token with a zero feed.
    /// @dev The bound is from one second to `MAX_AGE_LIMIT`. A Stock Token must answer `oraclePaused()` now, or every
    ///      value of it would revert at settlement.
    /// @param token The collateral token.
    /// @param feed Its USD feed's proxy, or zero to remove the token.
    /// @param maxAge The oldest round accepted, in seconds.
    /// @param stockToken Whether the token is a Robinhood Stock Token, whose `oraclePaused()` refuses a value.
    function setFeed(address token, IChainlinkFeed feed, uint32 maxAge, bool stockToken) external onlyOwner {
        if (address(feed) == address(0)) {
            delete feedOf[token];
            emit FeedSet(token, address(0), 0, false);
            return;
        }
        if (token.code.length == 0 || address(feed).code.length == 0 || maxAge == 0 || maxAge > MAX_AGE_LIMIT) {
            revert InvalidConfiguration();
        }
        uint8 tokenDecimals = IERC20Metadata(token).decimals();
        if (tokenDecimals > MAX_DECIMALS || feed.decimals() > MAX_DECIMALS) revert InvalidConfiguration();
        if (stockToken) IStockTokenOracle(token).oraclePaused();
        feedOf[token] = Feed(feed, maxAge, tokenDecimals, stockToken);
        emit FeedSet(token, address(feed), maxAge, stockToken);
    }

    /// @inheritdoc IOneDayPriceSource
    /// @dev The feed's latest round, positive and no older than its bound, times the amount, in USDG at a dollar; then
    ///      divided by USDG's own price when its feed reads above a dollar. A Stock Token under a corporate action
    ///      (`oraclePaused()`) has no value. `observedAt` is the round's update time.
    function valueOf(address token, uint256 amount, bytes calldata report)
        external
        view
        returns (uint256 value, uint256 observedAt)
    {
        if (report.length != 0) revert UnexpectedReport();
        Feed memory f = feedOf[token];
        if (address(f.feed) == address(0)) revert NoFeed(token);
        if (f.stockToken && IStockTokenOracle(token).oraclePaused()) revert OraclePaused(token);
        (, int256 answer,, uint256 updatedAt,) = f.feed.latestRoundData();
        if (answer <= 0) revert InvalidAnswer(token, answer);
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > f.maxAge) {
            revert StalePrice(token, updatedAt);
        }
        value = Math.mulDiv(
            amount, uint256(answer) * 10 ** USDG_DECIMALS, 10 ** (uint256(f.tokenDecimals) + f.feed.decimals())
        );
        if (address(USDG_USD) != address(0)) {
            (, int256 usd,,,) = USDG_USD.latestRoundData();
            uint256 dollar = 10 ** uint256(USDG_USD.decimals());
            if (usd > 0 && uint256(usd) > dollar) value = Math.mulDiv(value, dollar, uint256(usd));
        }
        if (value == 0) revert ZeroValue(token, amount);
        observedAt = updatedAt;
    }
}
