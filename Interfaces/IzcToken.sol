  
// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "../Interfaces/IERC20.sol";
import "../Interfaces/IERC2612.sol";

interface IzcToken is IERC20, IERC2612 {
    function maturity() external view returns(uint);
    function mint(address, uint) external returns(bool);
    function burn(address, uint) external returns(bool);
    // function transfer(address, uint) external returns (bool);
    // function transferFrom(address, address, uint) external returns (bool);
    // function approve(address, uint) external returns (bool);
}