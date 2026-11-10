// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice The keeper's +-0.5% stable band around a sqrt price (101 ticks as gage's source counts them, inside its
/// `MAX_STABLE_BAND_TICKS`), for the kit's tests.
library KitBands {
    /// @dev sqrt(0.995) and sqrt(1.005) in Q96.
    uint256 internal constant LO_X96 = 79_029_843_899_059_723_247_256_258_061;
    uint256 internal constant HI_X96 = 79_425_985_949_584_624_389_260_073_348;

    function around(uint160 p) internal pure returns (uint160 lo, uint160 hi) {
        return (uint160(Math.mulDiv(p, LO_X96, 1 << 96)), uint160(Math.mulDiv(p, HI_X96, 1 << 96)));
    }

    /// @dev A band as wide whose upper edge is `hi`.
    function to(uint160 hi) internal pure returns (uint160, uint160) {
        return (uint160(Math.mulDiv(hi, LO_X96, HI_X96)), hi);
    }

    /// @dev A band as wide whose lower edge is `lo`.
    function from(uint160 lo) internal pure returns (uint160, uint160) {
        return (lo, uint160(Math.mulDiv(lo, HI_X96, LO_X96)));
    }
}
