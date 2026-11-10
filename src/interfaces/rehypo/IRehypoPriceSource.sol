// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice What a priced rehypo source reads of the chain's Nuntius price source (`NuntiusPriceSource`): the
/// asset it quotes in, a token's asset record, and the USDG value of a token amount from a signed report.
interface IRehypoPriceSource {
    /// @notice The asset values are given in: USDG.
    function USDG() external view returns (address);

    /// @notice `token`'s Nuntius asset: its id (zero when it has none), the oldest signed price accepted, the fewest
    /// sources accepted, its decimals, and whether it is a Robinhood Stock Token.
    function assetOf(address token)
        external
        view
        returns (bytes32 assetId, uint32 maxAge, uint8 minSources, uint8 tokenDecimals, bool stockToken);

    /// @notice What `amount` raw units of `token` are worth in raw units of `USDG()` at the signed price in `report`,
    /// one whole token per share (no Stock Token multiplier), and when it was signed.
    /// @dev Reverts on a stale or future report, too few sources, an unnamed signer, a token without an asset, a Stock
    /// Token under a corporate action (`oraclePaused()`) or a zero value.
    function valueOf(address token, uint256 amount, bytes calldata report)
        external
        view
        returns (uint256 value, uint256 observedAt);
}

/// @notice A Robinhood Stock Token's display multiplier: how many shares one whole token stands for, 1e18-scaled.
interface IStockTokenMultiplier {
    function uiMultiplier() external view returns (uint256);
}
