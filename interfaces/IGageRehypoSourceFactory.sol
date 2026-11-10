// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

/// @notice The rehypo source factory: create and predict a pool token's source. Generated from its build; not deployed yet.
/// @dev Generated from the build of `src/rehypo/GageRehypoSourceFactory.sol` at d4e82b3be288.
interface IGageRehypoSourceFactory {
    struct RehypoSourceSettings {
        uint24 rangeTicks;
        address priceSource;
        address pricedToken;
        uint16 bandBps;
        uint16 centreMoveBps;
    }

    error InvalidConfiguration();
    error SourceCodeNotWritten();
    error UnknownPriceSource();

    event SourceCreated(
        address indexed source,
        address indexed asset,
        address indexed vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        address creator
    );
    event SourceFailsafe(address indexed source, uint16 failsafeBps);
    event SourcePeg(address indexed source, uint16 pegBps);
    event SourceSettings(
        address indexed source,
        uint24 rangeTicks,
        address indexed priceSource,
        address pricedToken,
        uint16 bandBps,
        uint16 centreMoveBps
    );

    function POOL_MANAGER() external view returns (address);
    function PRICE_SOURCE() external view returns (address);
    function REGISTRY() external view returns (address);
    function create(
        address asset,
        address vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        RehypoSourceSettings memory settings,
        uint16 failsafeBps,
        bytes32 salt
    ) external returns (address source);
    function create(
        address asset,
        address vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        RehypoSourceSettings memory settings,
        bytes32 salt
    ) external returns (address source);
    function create(address asset, address vault, address owner, address beneficiary, uint16 floatBps, bytes32 salt)
        external
        returns (address source);
    function create(
        address asset,
        address vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        RehypoSourceSettings memory settings,
        uint16 failsafeBps,
        uint16 pegBps,
        bytes32 salt
    ) external returns (address source);
    function isSource(address source) external view returns (bool created);
    function predict(
        address creator,
        address asset,
        address vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        RehypoSourceSettings memory settings,
        bytes32 salt
    ) external view returns (address);
    function predict(
        address creator,
        address asset,
        address vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        bytes32 salt
    ) external view returns (address);
    function predict(
        address creator,
        address asset,
        address vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        RehypoSourceSettings memory settings,
        uint16 failsafeBps,
        uint16 pegBps,
        bytes32 salt
    ) external view returns (address);
    function predict(
        address creator,
        address asset,
        address vault,
        address owner,
        address beneficiary,
        uint16 floatBps,
        RehypoSourceSettings memory settings,
        uint16 failsafeBps,
        bytes32 salt
    ) external view returns (address);
}
