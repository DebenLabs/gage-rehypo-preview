// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IRehypoFeeSource} from "../../src/AnchoredFeeHook.sol";

/// @notice A stand-in for a venue's fee module (`IRehypoFeeSource`): it quotes one fee for each direction of one pool,
/// nothing for any other pool, and can be told to fail in each way a real one could. Its answer is written by hand, so
/// the malformed ones are what a hook really receives.
contract FeeModuleStandIn {
    /// @dev How the module answers: 0 its quote; 1 a revert; 2 burning all the gas it is given; 3 four bytes; 4 a value
    /// past `uint24`; 5 nothing; 6 its quote followed by 16 KiB.
    uint8 public mode;
    bytes32 public pool;
    uint24 public feeZeroForOne;
    uint24 public feeOneForZero;

    function set(bytes32 pool_, uint24 zeroForOne, uint24 oneForZero) external {
        (pool, feeZeroForOne, feeOneForZero) = (pool_, zeroForOne, oneForZero);
    }

    function setMode(uint8 mode_) external {
        mode = mode_;
    }

    fallback() external {
        require(msg.sig == IRehypoFeeSource.currentFee.selector, "not currentFee");
        uint8 m = mode;
        if (m == 1) revert("no fee today");
        if (m == 2) {
            while (true) {}
        }
        if (m == 3) {
            assembly ("memory-safe") {
                mstore(0, 500)
                return(28, 4)
            }
        }
        if (m == 4) {
            assembly ("memory-safe") {
                mstore(0, 0x1000000)
                return(0, 32)
            }
        }
        if (m == 5) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        (bytes32 id, bool zeroForOne) = abi.decode(msg.data[4:], (bytes32, bool));
        uint256 fee = id == pool ? (zeroForOne ? feeZeroForOne : feeOneForZero) : 0;
        uint256 size = m == 6 ? 32 + 16_384 : 32;
        assembly ("memory-safe") {
            let at := mload(0x40)
            mstore(at, fee)
            return(at, size)
        }
    }
}
