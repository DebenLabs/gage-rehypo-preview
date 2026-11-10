// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24 <0.9.0;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @notice The part of a gage partner vault (`IntentVault`, gage `contracts/src/intent/IntentVault.sol`) the lender
/// hook and its keeper use: its ERC-4626 surface plus the reads and claims that are gage's own.
/// @dev Facts the hook is built around, all from that vault:
/// - every share change (deposit, withdraw, transfer) first checkpoints the reward record of each open loan, up to
///   64, and records the holder's balance-seconds: far too much gas, and too many ways to revert, for a swap;
/// - share changes revert from the end of a loan's term until it is settled (`SettlementDue`), in the second a
///   position is bought (`SaleTooSoon`), and when an owed reward cannot be delivered (`RewardsPending`); the ERC-4626
///   maxima read zero in the first two cases only;
/// - a deposit under one whole unit of the asset reverts (`InvalidAmount`);
/// - lent principal is priced in `previewRedeem` but cannot be withdrawn: `maxWithdraw` is bounded by free cash.
interface IGageVault is IERC4626 {
    /// @notice The earliest end of term among open loans; pricing, deposits and withdrawals pause from then until the
    /// loan is settled. `type(uint40).max` with no open loan.
    function earliestMaturity() external view returns (uint40);

    /// @notice Cash plus what the vault's reserve can pay out now: what every holder's withdrawals share.
    function freeLiquidity() external view returns (uint256);

    /// @notice The share of the vault's assets a new loan must leave free ("Cash kept free"), in basis points.
    function bufferBps() external view returns (uint16);

    /// @notice How many side pockets the vault has opened; pocket ids run from 1 to this.
    function pocketCount() external view returns (uint256);

    /// @notice What `who` may still claim from a side pocket.
    function pocketClaimable(uint256 pocketId, address who) external view returns (uint256);

    /// @notice A side pocket: its loan, its token (the lend asset for earnings, a loan's collateral for a recovery),
    /// the amount, the supply it is split over, what has been claimed, and an always-zero snapshot id.
    function pockets(uint256 pocketId)
        external
        view
        returns (uint256 loanId, address token, uint256 amount, uint256 supply, uint256 claimed, uint64 snapshotId);

    /// @notice Withdraw the caller's part of several side pockets; every one of them must pay something.
    function claimPockets(uint256[] calldata pocketIds) external;

    /// @notice Accrued sGAGE the holder may claim.
    function rewardClaimable(address who) external view returns (uint256);

    /// @notice Withdraw the caller's accrued sGAGE; reverts when there is none.
    function claimRewards() external returns (uint256 amount);

    /// @notice Book every listed loan whose outcome is known; anyone may call. Settling a loan past the end of its
    /// term ends the pause `earliestMaturity` marks.
    function settle(uint256[] calldata ids) external;
}
