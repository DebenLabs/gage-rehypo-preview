// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

/// @notice The part of a gage `IntentFactory` (gage `contracts/src/intent/IntentFactory.sol`, mandate version 13) a
/// partner uses to create its pool's vaults. One factory per lend asset: the USDG generation's, and one per lend-asset
/// generation (GLD, NVDA,...). Creation is open to admitted creators only, and the creator is the vault's curator
/// for good.
interface IIntentFactory {
    /// @dev Field for field `IntentVault.Mandate`: the order is the ABI.
    struct Mandate {
        /// @dev Must be the caller of `create`: the partner's Safe.
        address curator;
        /// @dev Basis points per category, in `IntentCategory` order (STOCK, MEME, RH_ECOSYSTEM, COMMODITY); one
        /// universe only, real-world assets (STOCK, COMMODITY) or the Robinhood ecosystem (MEME, RH_ECOSYSTEM).
        uint16[4] categoryWeights;
        /// @dev The collateral tokens the vault lends against; each must be admitted and classified on the factory.
        address[] assets;
        uint32 maxLoanTerm;
        /// @dev The performance fee on interest, 500 to 1500 basis points; the protocol takes a tenth of it.
        uint16 feeBps;
        uint8 minGrade;
        uint8 minRateGrade;
        uint128 maxLoanPrincipal;
        uint16 maxAssetBps;
        /// @dev "Cash kept free": the share of the vault's assets every new loan must leave free.
        uint16 bufferBps;
        uint16 executionCapBps;
    }

    /// @dev `secondaryOnly` (mandate 13, needs `secondaryEnabled`) makes a vault that only buys existing
    /// loans and never funds a listing, for good. A pool's vaults lend, so the kit passes false.
    function create(
        Mandate calldata mandate,
        bool secondaryEnabled,
        uint16 secondaryExtraBps,
        bool secondaryOnly,
        string calldata name
    ) external returns (address vault);

    function isCreator(address creator) external view returns (bool);

    function openCreation() external view returns (bool);

    function isVault(address vault) external view returns (bool);

    function owner() external view returns (address);

    function setCreator(address creator, bool allowed) external;

    function CORE() external view returns (address);
}
