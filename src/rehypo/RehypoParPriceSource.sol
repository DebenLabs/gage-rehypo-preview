// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IRehypoPriceSource} from "../interfaces/rehypo/IRehypoPriceSource.sol";

/// @title RehypoParPriceSource
/// @notice A feed for a rehypo price router (`RehypoPriceRouter`) that values a dollar stablecoin at one dollar: one
/// whole token for one whole USDG, with no report and no signer. It is the feed of a stablecoin nobody signs a price
/// for (frxUSD, eUSD, aUSD on Robinhood Chain): a pegged source then centres its range on one for one at every keeper
/// move, and nothing a keeper brings can move that centre.
/// @dev It reads nothing but the tokens' decimals, holds nothing and has no owner. It says nothing about whether the
/// token is still worth a dollar: the stops are elsewhere. A pegged source's own band shuts swaps to a sliver once its
/// pool trades past it, and its keeper moves nothing while the pool's price or the issuer's state says the peg is off.
/// It values any token it is asked about, so the router's owner chooses which tokens take it. The value is observed at
/// the block's time: a source moves on it at most once a second.
contract RehypoParPriceSource is IRehypoPriceSource {
    /// @notice The asset values are given in: USDG.
    address public immutable USDG;
    uint8 private immutable USDG_DECIMALS;

    /// @dev A USDG with no code.
    error InvalidConfiguration();
    /// @notice This feed takes no report: its value is the token's face.
    error ReportNotEmpty();
    /// @notice `amount` of `token` is worth less than one raw unit of USDG.
    error NoValue(address token);

    /// @param usdg The asset values are given in.
    constructor(address usdg) {
        if (usdg.code.length == 0) revert InvalidConfiguration();
        USDG = usdg;
        USDG_DECIMALS = IERC20Metadata(usdg).decimals();
    }

    /// @notice `token`'s asset: an id of its own, no age and no sources (nothing is signed), its decimals, never a
    /// Stock Token. Reverts for an address that is not a token.
    function assetOf(address token)
        external
        view
        returns (bytes32 assetId, uint32 maxAge, uint8 minSources, uint8 tokenDecimals, bool stockToken)
    {
        return (keccak256(abi.encode("PAR/USD", token)), 0, 0, IERC20Metadata(token).decimals(), false);
    }

    /// @notice What `amount` raw units of `token` are worth in raw units of USDG at one whole token for one whole USDG,
    /// rounded down, observed now.
    /// @param report Must be empty.
    function valueOf(address token, uint256 amount, bytes calldata report)
        external
        view
        returns (uint256 value, uint256 observedAt)
    {
        if (report.length != 0) revert ReportNotEmpty();
        uint256 decimals = IERC20Metadata(token).decimals();
        uint256 quote = USDG_DECIMALS;
        value = decimals >= quote ? amount / 10 ** (decimals - quote) : amount * 10 ** (quote - decimals);
        if (value == 0) revert NoValue(token);
        return (value, block.timestamp);
    }
}
