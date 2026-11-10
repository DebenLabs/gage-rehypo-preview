// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

/// @notice What a rehypo source needs of the gage partner vault it lends through (`IntentVault`, its ERC-4626 surface
/// and some of its own views and claims).
interface IRehypoVault {
    /// @notice The token the vault lends and its shares are priced in.
    function asset() external view returns (address);

    /// @notice The vault shares `account` holds.
    function balanceOf(address account) external view returns (uint256);

    /// @notice The assets `shares` are worth at the vault's one price, rounded down. Never reverts.
    function convertToAssets(uint256 shares) external view returns (uint256);

    /// @notice The most a deposit takes now: zero while a finished loan waits for its settle.
    function maxDeposit(address receiver) external view returns (uint256);

    /// @notice The most `owner` can withdraw now, its free cash: zero while a finished loan waits for its settle.
    function maxWithdraw(address owner) external view returns (uint256);

    /// @notice ERC-4626 deposit: the caller pays `assets`, `receiver` gets the shares.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice ERC-4626 withdraw: pay `receiver` `assets`, burning `owner`'s shares.
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    /// @notice The end of the vault's earliest open loan: from it until that loan's settle, shares do not move.
    function earliestMaturity() external view returns (uint40);

    /// @notice Pay the caller its part of each side pocket named: recovered collateral, or earnings in the asset.
    function claimPockets(uint256[] calldata pocketIds) external;

    /// @notice Pay the caller the sGAGE its shares have earned.
    function claimRewards() external returns (uint256 amount);

    /// @notice The Intent factory that created the vault.
    function PROTOCOL_SOURCE() external view returns (address);

    /// @notice Let `spender` move up to `amount` of the caller's vault shares: the exit desk, for the shares an exit
    /// commits.
    function approve(address spender, uint256 amount) external returns (bool);

    /// @notice The shares a withdrawal of `assets` burns now, rounded up.
    function previewWithdraw(uint256 assets) external view returns (uint256 shares);
}

/// @notice The record an Intent factory keeps of the vaults it created (`IntentFactory.isVault`), and the chain's exit
/// desk it names.
interface IRehypoVaultFactory {
    /// @notice Whether this factory created `vault`.
    function isVault(address vault) external view returns (bool);

    /// @notice The exit desk the factory names now; zero while exits are closed, or before mandate 13.
    function exitDesk() external view returns (address);
}

/// @notice What a rehypo source asks of the chain's exit desk (`IntentExitDesk`) to leave its vault for
/// its LPs: commit its vault shares and list a holding for them, withdraw the commitment, and collect what its sales
/// paid, which the desk owes by asset.
interface IRehypoExitDesk {
    /// @notice Commit `shares` of the caller's in `vault` and list holding `id` for them; `id` zero lists nothing.
    function exitNow(address vault, uint256 shares, uint256 id) external;

    /// @notice Withdraw the caller's commitment in `vault`.
    function cancel(address vault) external;

    /// @notice Pay the caller everything its exits' sales owe it in `asset`.
    function withdraw(address asset) external returns (uint256 amount);

    /// @notice What the exits' sales owe `owner` in `asset`.
    function owed(address asset, address owner) external view returns (uint256);

    /// @notice `owner`'s commitment in `vault`: the shares the desk may still redeem, and its last listing.
    function exits(address vault, address owner) external view returns (uint256 shares, uint256 id, uint64 nonce);
}
