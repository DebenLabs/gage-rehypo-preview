// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IRehypoVault} from "../interfaces/rehypo/IRehypoVault.sol";
import {IIntentFactoryRegistry} from "../interfaces/IIntentFactoryRegistry.sol";
import {GageRehypoSource, RehypoSourceSettings} from "./GageRehypoSource.sol";

/// @title GageRehypoSourceFactory
/// @notice Creates rehypo sources in one call, so a partner's Safe sets up a pool's sources in the same batch as
/// its hook: no owner, no settings, open to anyone. Each source is the creator's to configure through its own owner.
/// The next generation adds what a source fixes at creation: the narrowest range the partner's hook commits to, and
/// for a priced X/USDG pool its band and centre move on the chain's price source, which this factory names once
/// (`PRICE_SOURCE`): no source it creates centres on any other. That price source is a `RehypoPriceRouter`, which
/// names a feed for each token (a `NuntiusPriceSource`, or another signed feed), so a pegged dollar stable
/// (`PEG_BPS`) takes the feed that signs it.
/// @dev CREATE2 salted with the creator, so nobody can take another creator's address first. The source's creation code
/// lives in two data contracts the constructor writes once (`SOURCE_CODE_A` and `SOURCE_CODE_B`, each a zero byte then
/// its half of the code), so it counts against their EIP-170 limits rather than this factory's.
contract GageRehypoSourceFactory {
    /// @notice The Uniswap v4 PoolManager every source this factory creates holds its float in.
    IPoolManager public immutable POOL_MANAGER;
    /// @notice The generation deployer's record of the Intent factories whose vaults a source may lend through (2b).
    IIntentFactoryRegistry public immutable REGISTRY;
    /// @notice The chain's price source, the only one a priced source this factory creates may centre on: a
    /// `RehypoPriceRouter` naming each token's feed (an earlier factory names a `NuntiusPriceSource`, directly);
    /// zero when this factory creates no priced source.
    address public immutable PRICE_SOURCE;
    /// @dev The data contracts holding the first and second halves of `GageRehypoSource`'s creation code, each after a
    /// leading zero byte.
    address internal immutable SOURCE_CODE_A;
    address internal immutable SOURCE_CODE_B;

    /// @notice Whether this factory created `source`.
    mapping(address source => bool created) public isSource;

    /// @notice A new source: its asset, its vault (zero for float-only), its owner and the creator.
    event SourceCreated(
        address indexed source,
        address indexed asset,
        address indexed vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        address creator
    );
    /// @notice What the new source fixed at creation beyond its float target: its declared range (zero for the full
    /// range) and, for a priced source, its price source, priced token, band and centre move (all zero when stable).
    event SourceSettings(
        address indexed source,
        uint24 rangeTicks,
        address indexed priceSource,
        address pricedToken,
        uint16 bandBps,
        uint16 centreMoveBps
    );

    /// @notice The new source carries the vault failsafe (2.5): `failsafeBps` of its backing between keeper moves.
    event SourceFailsafe(address indexed source, uint16 failsafeBps);
    /// @notice The new priced source is pegged: a dollar stable whose keeper moves take a signed price within `pegBps`
    /// of one USDG, and which opens swaps to its whole float inside the band.
    event SourcePeg(address indexed source, uint16 pegBps);

    error InvalidConfiguration();
    error SourceCodeNotWritten();
    /// @notice A priced source's settings name a price source other than this factory's `PRICE_SOURCE`.
    error UnknownPriceSource();

    /// @param poolManager The Uniswap v4 PoolManager.
    /// @param registry The generation deployer (`IIntentFactoryRegistry`).
    /// @param priceSource The chain's Nuntius price source, or zero for a factory of stable sources only.
    constructor(IPoolManager poolManager, IIntentFactoryRegistry registry, address priceSource) {
        if (
            address(poolManager).code.length == 0 || address(registry).code.length == 0
                || (priceSource != address(0) && priceSource.code.length == 0)
        ) revert InvalidConfiguration();
        POOL_MANAGER = poolManager;
        REGISTRY = registry;
        PRICE_SOURCE = priceSource;
        bytes memory code = type(GageRehypoSource).creationCode;
        uint256 half = code.length / 2;
        SOURCE_CODE_A = _write(code, 0, half);
        SOURCE_CODE_B = _write(code, half, code.length - half);
    }

    /// @notice Create a stable full-range source for one pool token, as the first generation did. The owner then binds
    /// the hook (`bind`) and names keepers.
    /// @param asset The pool token.
    /// @param vault A gage partner vault of `asset` from a recorded Intent factory, or zero for a float-only source.
    /// @param owner The source's owner: the partner's Safe.
    /// @param beneficiary Where the source's sGAGE and recovered collateral go.
    /// @param floatBps The float target, in basis points of the backing.
    /// @param salt The creator's salt.
    /// @return source The new source.
    function create(IERC20 asset, IRehypoVault vault, address owner, address beneficiary, uint16 floatBps, bytes32 salt)
        external
        returns (GageRehypoSource source)
    {
        RehypoSourceSettings memory stable;
        return _create(asset, vault, owner, beneficiary, floatBps, stable, 0, 0, salt);
    }

    /// @notice Create a source for one pool token with its settings: the narrowest range the partner's hook commits to,
    /// and, for a priced X/USDG pool, its price source (this factory's `PRICE_SOURCE`, nothing else), priced token, band
    /// and centre move. The owner then binds the hook (`bind`) and names keepers.
    /// @param asset The pool token.
    /// @param vault A gage partner vault of `asset` from a recorded Intent factory, or zero for a float-only source.
    /// @param owner The source's owner: the partner's Safe.
    /// @param beneficiary Where the source's sGAGE and recovered collateral go.
    /// @param floatBps The float target, in basis points of the backing.
    /// @param settings The declared range and the price settings, all zero for a stable full-range source.
    /// @param salt The creator's salt.
    /// @return source The new source.
    function create(
        IERC20 asset,
        IRehypoVault vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        RehypoSourceSettings calldata settings,
        bytes32 salt
    ) external returns (GageRehypoSource source) {
        return _create(asset, vault, owner, beneficiary, floatBps, settings, 0, 0, salt);
    }

    /// @notice As `create` with settings, with the vault failsafe (2.5): the source may draw `failsafeBps` of its backing
    /// from its vault for its swaps between two keeper moves, when its depositor asks (`drawOnVault`).
    /// @param failsafeBps The failsafe's share of the backing between keeper moves, up to the source's
    ///        `MAX_FAILSAFE_BPS`.
    function create(
        IERC20 asset,
        IRehypoVault vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        RehypoSourceSettings calldata settings,
        uint16 failsafeBps,
        bytes32 salt
    ) external returns (GageRehypoSource source) {
        return _create(asset, vault, owner, beneficiary, floatBps, settings, failsafeBps, 0, salt);
    }

    /// @notice As `create` with settings and the failsafe, for a pegged source: a priced source of a dollar stable
    /// whose keeper moves take a signed price within `pegBps` of one USDG, and which opens swaps to its whole float
    /// inside the band (the source's `PEG_BPS`).
    /// @param pegBps The peg, from the source's `MIN_BAND_BPS` to its `MAX_PEG_BPS`; zero creates the same source as
    ///        `create` without it.
    function create(
        IERC20 asset,
        IRehypoVault vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        RehypoSourceSettings calldata settings,
        uint16 failsafeBps,
        uint16 pegBps,
        bytes32 salt
    ) external returns (GageRehypoSource source) {
        return _create(asset, vault, owner, beneficiary, floatBps, settings, failsafeBps, pegBps, salt);
    }

    /// @notice The address `create` gives `creator` for these arguments, for a stable full-range source.
    function predict(
        address creator,
        IERC20 asset,
        IRehypoVault vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        bytes32 salt
    ) external view returns (address) {
        RehypoSourceSettings memory stable;
        return _predict(creator, _initCode(asset, vault, owner, beneficiary, floatBps, stable, 0, 0), salt);
    }

    /// @notice The address `create` gives `creator` for these arguments and settings.
    function predict(
        address creator,
        IERC20 asset,
        IRehypoVault vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        RehypoSourceSettings calldata settings,
        bytes32 salt
    ) external view returns (address) {
        return _predict(creator, _initCode(asset, vault, owner, beneficiary, floatBps, settings, 0, 0), salt);
    }

    /// @notice The address `create` gives `creator` for these arguments, settings and failsafe.
    function predict(
        address creator,
        IERC20 asset,
        IRehypoVault vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        RehypoSourceSettings calldata settings,
        uint16 failsafeBps,
        bytes32 salt
    ) external view returns (address) {
        return _predict(creator, _initCode(asset, vault, owner, beneficiary, floatBps, settings, failsafeBps, 0), salt);
    }

    /// @notice The address `create` gives `creator` for these arguments, settings, failsafe and peg.
    function predict(
        address creator,
        IERC20 asset,
        IRehypoVault vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        RehypoSourceSettings calldata settings,
        uint16 failsafeBps,
        uint16 pegBps,
        bytes32 salt
    ) external view returns (address) {
        return _predict(
            creator, _initCode(asset, vault, owner, beneficiary, floatBps, settings, failsafeBps, pegBps), salt
        );
    }

    function _create(
        IERC20 asset,
        IRehypoVault vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        RehypoSourceSettings memory settings,
        uint16 failsafeBps,
        uint16 pegBps,
        bytes32 salt
    ) internal returns (GageRehypoSource source) {
        if (settings.priceSource != address(0) && settings.priceSource != PRICE_SOURCE) {
            revert UnknownPriceSource();
        }
        bytes memory init = _initCode(asset, vault, owner, beneficiary, floatBps, settings, failsafeBps, pegBps);
        bytes32 key = keccak256(abi.encode(msg.sender, salt));
        assembly ("memory-safe") {
            source := create2(0, add(init, 0x20), mload(init), key)
            if iszero(source) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
        isSource[address(source)] = true;
        emit SourceCreated(address(source), address(asset), address(vault), owner, beneficiary, floatBps, msg.sender);
        emit SourceSettings(
            address(source),
            settings.rangeTicks,
            settings.priceSource,
            settings.pricedToken,
            settings.bandBps,
            settings.centreMoveBps
        );
        if (failsafeBps != 0) emit SourceFailsafe(address(source), failsafeBps);
        if (pegBps != 0) emit SourcePeg(address(source), pegBps);
    }

    function _predict(address creator, bytes memory init, bytes32 salt) internal view returns (address) {
        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), keccak256(abi.encode(creator, salt)), keccak256(init))
        );
        return address(uint160(uint256(hash)));
    }

    /// @dev The source's creation code, read from the two data contracts, followed by its constructor arguments.
    function _initCode(
        IERC20 asset,
        IRehypoVault vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        RehypoSourceSettings memory settings,
        uint16 failsafeBps,
        uint16 pegBps
    ) internal view returns (bytes memory) {
        (string memory name, string memory symbol) = _names(asset);
        return abi.encodePacked(
            _read(SOURCE_CODE_A),
            _read(SOURCE_CODE_B),
            abi.encode(
                asset,
                vault,
                POOL_MANAGER,
                REGISTRY,
                owner,
                beneficiary,
                floatBps,
                settings,
                failsafeBps,
                pegBps,
                name,
                symbol
            )
        );
    }

    /// @dev A data contract of `len` bytes of `code` from `start`: an initcode that returns everything after its 12
    /// bytes, a STOP byte then those bytes.
    function _write(bytes memory code, uint256 start, uint256 len) internal returns (address data) {
        bytes memory init = new bytes(13 + len);
        bytes13 prefix = bytes13(abi.encodePacked(hex"61", uint16(len + 1), hex"80600c6000396000f300"));
        assembly ("memory-safe") {
            mstore(add(init, 0x20), prefix)
            mcopy(add(init, 0x2d), add(add(code, 0x20), start), len)
            data := create(0, add(init, 0x20), mload(init))
        }
        if (data == address(0)) revert SourceCodeNotWritten();
    }

    /// @dev A data contract's bytes after its leading zero.
    function _read(address code) internal view returns (bytes memory data) {
        uint256 size = code.code.length - 1;
        data = new bytes(size);
        assembly ("memory-safe") {
            extcodecopy(code, add(data, 0x20), 1, size)
        }
    }

    /// @dev "gage rehypo source <SYMBOL>" and "grs<SYMBOL>".
    function _names(IERC20 asset) internal view returns (string memory name, string memory symbol) {
        string memory s = IERC20Metadata(address(asset)).symbol();
        return (string.concat("gage rehypo source ", s), string.concat("grs", s));
    }
}
