// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IOneDayPriceSource
/// @notice The independent price the keeper settlement holds its sale to: what a collateral amount is worth in the
///         core's lent asset, from a Chainlink price the source checks itself, never from the pools the sale uses.
/// @dev The seam between `GageV2CashoutRouter` and the price Chainlink provides. An on-chain feed's source reads the
///      aggregator's latest round and takes no report (`ChainlinkFeedPriceSource`). A Data Streams source verifies the
///      signed report the keeper fetched and passes through, with Chainlink's verifier, which may change state and
///      charge a fee: so `valueOf` is not a view. The router names its source with `setPriceSource`.
interface IOneDayPriceSource {
    /// @notice The asset values are given in: the asset the router's core lends (USDG on every USDG core).
    function USDG() external view returns (address);

    /// @notice What `amount` raw units of `token` are worth in raw units of `USDG()`, and when the price was observed.
    /// @dev Reverts when the source holds no fresh, valid price for `token`; never returns a zero value.
    /// @param token The collateral token.
    /// @param amount The amount, in the token's raw units.
    /// @param report What a report-carrying source verifies (a Data Streams report); empty for an on-chain feed.
    /// @return value The amount's worth, in raw units of `USDG()`.
    /// @return observedAt When the price was observed, in seconds since the epoch.
    function valueOf(address token, uint256 amount, bytes calldata report)
        external
        returns (uint256 value, uint256 observedAt);
}
