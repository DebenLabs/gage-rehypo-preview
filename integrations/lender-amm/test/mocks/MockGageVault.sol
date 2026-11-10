// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice A stand-in for gage's `IntentVault` with the behaviour the lender hook depends on, each rule named after the
/// vault's own (`src/intent/IntentVault.sol`): the conversion with 10^12 virtual shares over one
/// six-decimal unit of virtual assets, the one-whole-unit minimum deposit, lent principal that is priced but not free,
/// the last holder's `OutstandingLoans`, and the refusal moments. The fork suite runs the same paths on the real vault.
contract MockGageVault is ERC20 {
    using SafeERC20 for IERC20;

    uint256 internal constant VIRTUAL_SHARES = 1e12;

    IERC20 internal immutable _ASSET;
    uint256 internal immutable _SCALE;
    uint256 internal immutable _MIN_DEPOSIT;

    uint256 public cash;
    uint256 public performingPrincipal;
    uint256 public accrued;
    uint40 internal _earliestMaturity = type(uint40).max;
    uint16 public bufferBps = 1000;
    /// @dev The second a position was bought, when no share may move (`SaleTooSoon`).
    uint40 public purchaseSecond;
    /// @dev A reward source that cannot deliver: every share change reverts `RewardsPending`, the maxima do not show it.
    bool public rewardsPending;
    /// @dev Every call reverts, views included: proves a path never touches the vault.
    bool public offline;
    uint256 public calls;

    struct Pocket {
        address token;
        address holder;
        uint256 amount;
        bool claimed;
    }

    mapping(uint256 => Pocket) internal _pockets;
    uint256 public pocketCount;
    IERC20 public rewardToken;
    mapping(address => uint256) public rewardClaimable;

    error Offline();
    error InvalidAmount();
    error Slippage();
    error SettlementDue();
    error SaleTooSoon();
    error RewardsPending();
    error OutstandingLoans();
    error InsufficientLiquidity();

    constructor(IERC20 asset_) ERC20("gage partner vault", "gSHARE") {
        _ASSET = asset_;
        uint8 d = IERC20Metadata(address(asset_)).decimals();
        _SCALE = 10 ** d / 1e6;
        _MIN_DEPOSIT = 10 ** d;
    }

    modifier online() {
        if (offline) revert Offline();
        _;
    }

    // ---------------------------------------------------------------- the vault's surface

    function asset() external view online returns (address) {
        return address(_ASSET);
    }

    function balanceOf(address who) public view override online returns (uint256) {
        return super.balanceOf(who);
    }

    function totalAssets() public view online returns (uint256) {
        return cash + performingPrincipal + accrued;
    }

    function earliestMaturity() external view online returns (uint40) {
        return _earliestMaturity;
    }

    function freeLiquidity() public view online returns (uint256) {
        return cash;
    }

    function convertToShares(uint256 assets) public view online returns (uint256) {
        return Math.mulDiv(assets, totalSupply() + VIRTUAL_SHARES, totalAssets() + _SCALE);
    }

    function convertToAssets(uint256 shares) public view online returns (uint256) {
        return Math.mulDiv(shares, totalAssets() + _SCALE, totalSupply() + VIRTUAL_SHARES);
    }

    function previewRedeem(uint256 shares) external view online returns (uint256) {
        return convertToAssets(shares);
    }

    function previewWithdraw(uint256 assets) public view online returns (uint256) {
        return Math.mulDiv(assets, totalSupply() + VIRTUAL_SHARES, totalAssets() + _SCALE, Math.Rounding.Ceil);
    }

    /// @dev IntentVault `_maximum`: zero at a settlement due and in a purchase second; `RewardsPending` is not modelled.
    function maxDeposit(address) external view online returns (uint256) {
        return _paused() ? 0 : type(uint128).max;
    }

    function maxWithdraw(address owner) external view online returns (uint256) {
        if (_paused()) return 0;
        uint256 shares = balanceOf(owner);
        if (shares == totalSupply() && shares != 0 && performingPrincipal != 0) --shares;
        return Math.min(cash, convertToAssets(shares));
    }

    function deposit(uint256 assets, address receiver) external online returns (uint256 shares) {
        ++calls;
        _requireShareChange();
        shares = convertToShares(assets);
        if (assets < _MIN_DEPOSIT) revert InvalidAmount();
        if (shares == 0) revert Slippage();
        _ASSET.safeTransferFrom(msg.sender, address(this), assets);
        cash += assets;
        _mint(receiver, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) external online returns (uint256 shares) {
        ++calls;
        _requireShareChange();
        shares = previewWithdraw(assets);
        if (shares > balanceOf(owner)) revert InvalidAmount();
        if (shares == totalSupply() && performingPrincipal != 0) revert OutstandingLoans();
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        if (assets > cash) revert InsufficientLiquidity();
        cash -= assets;
        _burn(owner, shares);
        _ASSET.safeTransfer(receiver, assets);
    }

    function pockets(uint256 id) external view online returns (uint256, address, uint256, uint256, uint256, uint64) {
        Pocket storage p = _pockets[id];
        return (id, p.token, p.amount, 0, p.claimed ? p.amount : 0, 0);
    }

    function pocketClaimable(uint256 id, address who) public view online returns (uint256) {
        Pocket storage p = _pockets[id];
        return p.holder == who && !p.claimed ? p.amount : 0;
    }

    function claimPockets(uint256[] calldata ids) external online {
        ++calls;
        for (uint256 i; i < ids.length; ++i) {
            uint256 amount = pocketClaimable(ids[i], msg.sender);
            if (amount == 0) revert InvalidAmount();
            _pockets[ids[i]].claimed = true;
            IERC20(_pockets[ids[i]].token).safeTransfer(msg.sender, amount);
        }
    }

    function claimRewards() external online returns (uint256 amount) {
        ++calls;
        amount = rewardClaimable[msg.sender];
        if (amount == 0) revert InvalidAmount();
        rewardClaimable[msg.sender] = 0;
        rewardToken.safeTransfer(msg.sender, amount);
    }

    function settle(uint256[] calldata) external online {
        _earliestMaturity = type(uint40).max;
    }

    /// @dev The vault stands in for its own Intent factory: tests record the vault itself in a registry.
    function PROTOCOL_SOURCE() external view returns (address) {
        return address(this);
    }

    function isVault(address v) external view returns (bool) {
        return v == address(this);
    }

    // ---------------------------------------------------------------- test controls

    /// @dev A loan funded from cash: priced at principal, no longer free.
    function lend(uint256 principal) external {
        if (principal > cash) revert InsufficientLiquidity();
        cash -= principal;
        performingPrincipal += principal;
    }

    /// @dev Interest a loan has earned so far: priced, not yet cash.
    function accrue(uint256 interest) external {
        accrued += interest;
    }

    /// @dev A repayment; the caller has sent `principal + interest` of the asset here.
    function repay(uint256 principal, uint256 interest) external {
        performingPrincipal -= principal;
        accrued -= Math.min(accrued, interest);
        cash += principal + interest;
    }

    /// @dev A written-off loan: its principal and interest leave the price.
    function writeOff(uint256 principal) external {
        performingPrincipal -= principal;
        accrued = 0;
    }

    function setEarliestMaturity(uint40 at) external {
        _earliestMaturity = at;
    }

    function setPurchaseSecond(uint40 at) external {
        purchaseSecond = at;
    }

    function setRewardsPending(bool pending) external {
        rewardsPending = pending;
    }

    function setOffline(bool enabled) external {
        offline = enabled;
    }

    /// @dev A pocket for `holder`; the caller has sent `amount` of `token` here.
    function openPocket(address token, address holder, uint256 amount) external returns (uint256 id) {
        id = ++pocketCount;
        _pockets[id] = Pocket(token, holder, amount, false);
    }

    /// @dev sGAGE owed to `holder`; the caller has sent `amount` of `token` here.
    function setReward(IERC20 token, address holder, uint256 amount) external {
        rewardToken = token;
        rewardClaimable[holder] += amount;
    }

    function _paused() internal view returns (bool) {
        return block.timestamp >= _earliestMaturity || block.timestamp == purchaseSecond;
    }

    function _requireShareChange() internal view {
        if (block.timestamp >= _earliestMaturity) revert SettlementDue();
        if (block.timestamp == purchaseSecond) revert SaleTooSoon();
        if (rewardsPending) revert RewardsPending();
    }
}
