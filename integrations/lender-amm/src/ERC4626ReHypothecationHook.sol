// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {ReHypothecationHook} from "@openzeppelin/uniswap-hooks/src/general/ReHypothecationHook.sol";

/// @notice OpenZeppelin's `ReHypothecationHook` on two ERC-4626 yield sources, one per pool token, with nothing more:
/// the four yield-source overrides the base asks for and the pool checks below. Its only functions that move the
/// hook's source shares are the base's LP functions (`seedLiquidity`, `addReHypothecatedLiquidity`,
/// `removeReHypothecatedLiquidity`) and the PoolManager's swap callbacks. A pool binds only if its tokens are the two
/// sources' assets, in order, and neither is the native currency.
contract ERC4626ReHypothecationHook is ReHypothecationHook {
    using SafeERC20 for IERC20;

    error UnsupportedCurrency();
    error InvalidYieldSource();

    address private immutable YIELD_SOURCE_0;
    address private immutable YIELD_SOURCE_1;

    /// @param manager The Uniswap v4 PoolManager.
    /// @param yieldSource0 The ERC-4626 source of the pool's currency0.
    /// @param yieldSource1 The ERC-4626 source of the pool's currency1.
    constructor(IPoolManager manager, address yieldSource0, address yieldSource1)
        BaseHook(manager)
        ERC20("ReHypothecatedShare", "RHS")
    {
        if (yieldSource0 == address(0) || yieldSource1 == address(0)) revert InvalidYieldSource();
        YIELD_SOURCE_0 = yieldSource0;
        YIELD_SOURCE_1 = yieldSource1;
    }

    /// @dev The pool's tokens must be the sources' assets, currency0 the first source's: a pool of any other pair can
    /// never bind the hook first. The native currency has no ERC-4626 source.
    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        virtual
        override
        returns (bytes4)
    {
        if (
            key.currency0.isAddressZero() || Currency.unwrap(key.currency0) != IERC4626(YIELD_SOURCE_0).asset()
                || Currency.unwrap(key.currency1) != IERC4626(YIELD_SOURCE_1).asset()
        ) revert UnsupportedCurrency();
        return super._beforeInitialize(sender, key, sqrtPriceX96);
    }

    /// @inheritdoc ReHypothecationHook
    function getCurrencyYieldSource(Currency currency) public view override returns (address) {
        PoolKey memory key = getPoolKey();
        if (currency == key.currency0) return YIELD_SOURCE_0;
        if (currency == key.currency1) return YIELD_SOURCE_1;
        revert UnsupportedCurrency();
    }

    /// @inheritdoc ReHypothecationHook
    function _depositToYieldSource(Currency currency, uint256 amount) internal virtual override {
        address source = getCurrencyYieldSource(currency);
        IERC20(Currency.unwrap(currency)).forceApprove(source, amount);
        IERC4626(source).deposit(amount, address(this));
    }

    /// @inheritdoc ReHypothecationHook
    function _withdrawFromYieldSource(Currency currency, uint256 amount) internal virtual override {
        IERC4626(getCurrencyYieldSource(currency)).withdraw(amount, address(this), address(this));
    }

    /// @inheritdoc ReHypothecationHook
    function _getAmountInYieldSource(Currency currency) internal view virtual override returns (uint256) {
        IERC4626 source = IERC4626(getCurrencyYieldSource(currency));
        return source.convertToAssets(source.balanceOf(address(this)));
    }

    /// @inheritdoc ReHypothecationHook
    function _getMaxWithdrawFromYieldSource(Currency currency) internal view virtual override returns (uint256) {
        return IERC4626(getCurrencyYieldSource(currency)).maxWithdraw(address(this));
    }

    /// @dev No native currency: ERC-4626 sources hold ERC-20s.
    receive() external payable override {
        revert UnsupportedCurrency();
    }
}
