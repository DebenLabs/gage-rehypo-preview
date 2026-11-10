// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IOneDayPriceSource} from "../interfaces/IOneDayPriceSource.sol";
import {IStockTokenOracle} from "./ChainlinkFeedPriceSource.sol";

/// @title NuntiusPriceSource
/// @notice the independent price for the keeper settlement: a price Kaskad's Nuntius enclave signed, which the
///         keeper fetches from Nuntius's API and passes through. The signature is checked here against signers this
///         contract's owner names, never against Kaskad's on-chain oracle, whose owner can admit a new signer.
/// @dev The message is Nuntius's own (`KaskadPriceOracleV2._verifyPriceSignature`): EIP-191 over
///      `abi.encodePacked(assetId, price, timestamp, numSources, sourcesHash)`, `assetId = keccak256("NVDA/USD")`, the
///      price with eight decimals. The token's asset id is the owner's, so a keeper cannot bring another asset's price.
///      USDG is taken at a dollar: above a dollar that values the collateral higher in USDG than it is, a stricter floor.
///      It holds nothing and moves nothing.
contract NuntiusPriceSource is IOneDayPriceSource, Ownable2Step {
    /// @notice The oldest signed price a token may be set to accept. Nuntius signs every 15 seconds or so; the keeper
    ///         may pick any price within its token's bound, so the bound also limits that choice.
    uint32 public constant MAX_AGE_LIMIT = 5 minutes;
    /// @notice How far ahead of the block a signed timestamp may run (the enclave's clock against the chain's).
    uint32 public constant MAX_FUTURE_SKEW = 1 minutes;
    /// @notice The most sources a token may be set to require.
    uint8 public constant MAX_MIN_SOURCES = 16;
    /// @notice The most signers named at once: enough for an enclave rotation to overlap.
    uint8 public constant MAX_SIGNERS = 4;
    /// @notice The most decimals a token or USDG may have here.
    uint8 public constant MAX_DECIMALS = 18;
    /// @notice Nuntius's price decimals.
    uint8 public constant PRICE_DECIMALS = 8;

    /// @inheritdoc IOneDayPriceSource
    address public immutable USDG;
    /// @notice USDG's decimals.
    uint8 public immutable USDG_DECIMALS;

    /// @notice A token's Nuntius asset: its id, the oldest signed price accepted, the fewest sources accepted, the
    ///         token's decimals, and whether the token is a Robinhood Stock Token whose `oraclePaused()` refuses a value.
    struct Asset {
        bytes32 assetId;
        uint32 maxAge;
        uint8 minSources;
        uint8 tokenDecimals;
        bool stockToken;
    }

    /// @notice What the keeper passes as `report`, ABI-encoded: Nuntius's fields for the token's asset.
    struct SignedPrice {
        uint256 price;
        uint256 timestamp;
        uint8 numSources;
        bytes32 sourcesHash;
        bytes signature;
    }

    /// @notice Each token's asset; a zero id means the token has none.
    mapping(address token => Asset) public assetOf;
    /// @notice Whether a Nuntius enclave address is accepted as a signer.
    mapping(address signer => bool) public isSigner;
    /// @notice How many signers are named.
    uint8 public signerCount;

    /// @dev A bound or an address the constructor, `setAsset` or `setSigner` refuses.
    error InvalidConfiguration();
    error NoAsset(address token);
    error OraclePaused(address token);
    /// @dev A signed price older than its token's bound, or further ahead of the block than `MAX_FUTURE_SKEW`.
    error StalePrice(address token, uint256 timestamp);
    error InvalidPrice(address token);
    error TooFewSources(address token, uint8 numSources);
    /// @dev The signature recovers to no named signer, or to none at all.
    error InvalidSignature(address token, address recovered);
    /// @dev The amount is worth less than one raw unit of USDG.
    error ZeroValue(address token, uint256 amount);

    event AssetSet(address indexed token, bytes32 indexed assetId, uint32 maxAge, uint8 minSources, bool stockToken);
    event SignerSet(address indexed signer, bool accepted);

    /// @param usdg The asset values are given in: the asset the router's core lends.
    /// @param admin The owner, who names each token's asset and the signers.
    constructor(IERC20Metadata usdg, address admin) Ownable(admin) {
        if (address(usdg).code.length == 0) revert InvalidConfiguration();
        uint8 decimals = usdg.decimals();
        if (decimals > MAX_DECIMALS) revert InvalidConfiguration();
        USDG = address(usdg);
        USDG_DECIMALS = decimals;
    }

    /// @notice Accept or drop a Nuntius enclave signer, at most `MAX_SIGNERS` at once.
    /// @param signer The enclave's address (Nuntius's `signer` field).
    /// @param accepted Whether its signatures are accepted.
    function setSigner(address signer, bool accepted) external onlyOwner {
        if (signer == address(0) || isSigner[signer] == accepted) revert InvalidConfiguration();
        if (accepted) {
            if (signerCount == MAX_SIGNERS) revert InvalidConfiguration();
            ++signerCount;
        } else {
            --signerCount;
        }
        isSigner[signer] = accepted;
        emit SignerSet(signer, accepted);
    }

    /// @notice Name `token`'s Nuntius asset and its bounds, or remove the token with a zero id.
    /// @dev The age is from one second to `MAX_AGE_LIMIT`, the sources from one to `MAX_MIN_SOURCES`. A Stock Token must
    ///      answer `oraclePaused()` now, or every value of it would revert at settlement.
    /// @param token The collateral token.
    /// @param assetId Nuntius's id of its USD price, `keccak256` of the symbol (`"NVDA/USD"`), or zero to remove it.
    /// @param maxAge The oldest signed price accepted, in seconds.
    /// @param minSources The fewest sources a signed price may carry.
    /// @param stockToken Whether the token is a Robinhood Stock Token, whose `oraclePaused()` refuses a value.
    function setAsset(address token, bytes32 assetId, uint32 maxAge, uint8 minSources, bool stockToken)
        external
        onlyOwner
    {
        if (assetId == bytes32(0)) {
            delete assetOf[token];
            emit AssetSet(token, bytes32(0), 0, 0, false);
            return;
        }
        if (
            token.code.length == 0 || maxAge == 0 || maxAge > MAX_AGE_LIMIT || minSources == 0
                || minSources > MAX_MIN_SOURCES
        ) revert InvalidConfiguration();
        uint8 tokenDecimals = IERC20Metadata(token).decimals();
        if (tokenDecimals > MAX_DECIMALS) revert InvalidConfiguration();
        if (stockToken) IStockTokenOracle(token).oraclePaused();
        assetOf[token] = Asset(assetId, maxAge, minSources, tokenDecimals, stockToken);
        emit AssetSet(token, assetId, maxAge, minSources, stockToken);
    }

    /// @inheritdoc IOneDayPriceSource
    /// @dev `report` is an ABI-encoded `SignedPrice` for the token's own asset id, signed by a named signer, positive,
    ///      from at least its token's sources and no older than its bound; the value is the amount times the price, USDG
    ///      at a dollar. A Stock Token under a corporate action (`oraclePaused()`) has no value. `observedAt` is the
    ///      signed timestamp.
    function valueOf(address token, uint256 amount, bytes calldata report)
        external
        view
        returns (uint256 value, uint256 observedAt)
    {
        Asset memory a = assetOf[token];
        if (a.assetId == bytes32(0)) revert NoAsset(token);
        if (a.stockToken && IStockTokenOracle(token).oraclePaused()) revert OraclePaused(token);
        SignedPrice memory p = abi.decode(report, (SignedPrice));
        if (p.price == 0) revert InvalidPrice(token);
        if (p.numSources < a.minSources) revert TooFewSources(token, p.numSources);
        if (p.timestamp > block.timestamp + MAX_FUTURE_SKEW || p.timestamp + a.maxAge < block.timestamp) {
            revert StalePrice(token, p.timestamp);
        }
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(
            keccak256(abi.encodePacked(a.assetId, p.price, p.timestamp, p.numSources, p.sourcesHash))
        );
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, p.signature);
        if (err != ECDSA.RecoverError.NoError || !isSigner[recovered]) revert InvalidSignature(token, recovered);
        value = Math.mulDiv(amount, p.price * 10 ** USDG_DECIMALS, 10 ** (uint256(a.tokenDecimals) + PRICE_DECIMALS));
        if (value == 0) revert ZeroValue(token, amount);
        observedAt = p.timestamp;
    }
}
