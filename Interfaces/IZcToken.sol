// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "./IERC20Metadata.sol";
import "./IERC20.sol";
import "./IERC2612.sol";

/**
 * @dev Mint and burn interface for the ZCToken
 *
 */
interface IZcToken is IERC20, IERC20Metadata, IERC2612 {
    /**
     * @dev Mints...
     */
    function mint(address, uint256) external returns(bool);

    /**
     * @dev Burns...
     */
    function burn(address, uint256) external returns(bool);
}