// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

/// @notice The Intent factories a rehypothecation source may lend through: those `GenerationDeployer` built from its
/// fixed blueprints, and r13's release generations it was
/// given once at its construction. Nothing can add another.
/// @dev A source accepts a vault only when `isFactory(IntentVault(vault).PROTOCOL_SOURCE())` and
/// `IntentFactory(factory).isVault(vault)` both hold.
interface IIntentFactoryRegistry {
    /// @notice Whether `factory` is an Intent factory this registry recorded.
    /// @param factory The address to check.
    /// @return recorded True only for a factory this registry deployed or was given at its construction.
    function isFactory(address factory) external view returns (bool recorded);
}
