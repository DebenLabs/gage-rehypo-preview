// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IRehypoPriceSource} from "../interfaces/rehypo/IRehypoPriceSource.sol";

/// @title RehypoPriceRouter
/// @notice The price source a rehypo source factory names (`GageRehypoSourceFactory.PRICE_SOURCE`), with a feed for each
/// token: a token's price comes from the feed its owner names for it, a `NuntiusPriceSource` or any contract that
/// values a token in the same USDG from a report its keeper brings (`IRehypoPriceSource`). So each priced pool's token
/// takes the feed that signs it (Nuntius signs USDG, USDC and USDT, not every dollar stable), without a new factory. A
/// priced source reads its price through here only in its keeper's `rebalanceAt`, outside every unlock: swaps, LP moves
/// and exits never read it.
/// @dev It forwards and holds nothing. A feed must value in this router's USDG and know the token (a nonzero asset id)
/// when it is named. The owner is the deployment EOA, as a Nuntius source's owner is, who names its signers: a feed
/// moves a source's centre only as far as that source's own centre move and peg allow, and only through its keeper.
contract RehypoPriceRouter is IRehypoPriceSource, Ownable2Step {
    /// @notice The asset every feed values in: USDG.
    address public immutable USDG;
    /// @notice Each token's feed; zero when it has none.
    mapping(address token => IRehypoPriceSource feed) public feedOf;

    /// @notice `token` takes its price from `feed` from now on; zero removes it.
    event FeedSet(address indexed token, address indexed feed);

    /// @dev A zero USDG, or a feed that values in another USDG, is this router, or does not know the token.
    error InvalidConfiguration();
    /// @notice No feed is named for `token`.
    error NoFeed(address token);

    /// @param usdg The asset values are given in.
    /// @param admin The owner, who names each token's feed.
    constructor(address usdg, address admin) Ownable(admin) {
        if (usdg.code.length == 0) revert InvalidConfiguration();
        USDG = usdg;
    }

    /// @notice Name `token`'s feed, or remove it with zero.
    /// @param token The priced token.
    /// @param feed A price source valuing in this router's USDG that names an asset for `token`, or zero.
    function setFeed(address token, IRehypoPriceSource feed) external onlyOwner {
        if (address(feed) != address(0)) {
            if (address(feed) == address(this) || feed.USDG() != USDG) revert InvalidConfiguration();
            (bytes32 assetId,,,,) = feed.assetOf(token);
            if (assetId == bytes32(0)) revert InvalidConfiguration();
        }
        feedOf[token] = feed;
        emit FeedSet(token, address(feed));
    }

    /// @notice `token`'s asset as its feed records it; all zero when it has no feed.
    function assetOf(address token)
        external
        view
        returns (bytes32 assetId, uint32 maxAge, uint8 minSources, uint8 tokenDecimals, bool stockToken)
    {
        IRehypoPriceSource feed = feedOf[token];
        if (address(feed) == address(0)) return (bytes32(0), 0, 0, 0, false);
        return feed.assetOf(token);
    }

    /// @notice What `amount` raw units of `token` are worth in raw units of USDG at the price `report` carries, as
    /// `token`'s feed values it, and when that price was signed; every refusal of the feed passes up unchanged.
    function valueOf(address token, uint256 amount, bytes calldata report)
        external
        view
        returns (uint256 value, uint256 observedAt)
    {
        IRehypoPriceSource feed = feedOf[token];
        if (address(feed) == address(0)) revert NoFeed(token);
        return feed.valueOf(token, amount, report);
    }
}
