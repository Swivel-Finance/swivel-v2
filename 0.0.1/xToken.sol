// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "ERC20Permit.sol";
import "Abstracts.sol";

contract xToken is ERC20Permit  {

    event Redeemed(address indexed from, uint256 fyDaiIn, uint256 daiOut);
    
    event Matured(uint256 maturityTime, uint256 maturityRate);

    uint256 constant internal MAX_TIME_TO_MATURITY = 126144000; // seconds in four years
    
    uint256 public maturity;
    
    address public underlying;
    
    address public admin;

    constructor(
        //address swivel_,
        uint256 maturity_,
        address underlying_,
        string memory name,
        string memory symbol
    ) ERC20Permit(name, symbol) {
        
        require(maturity_ > block.timestamp && maturity_ < block.timestamp + MAX_TIME_TO_MATURITY, "Invalid maturity");
        
        maturity = maturity_;
        
        underlying = underlying_;
        
        admin = msg.sender;
    }
    
    function burn(address from, uint256 xTokenAmount) public returns (uint256){
        require(msg.sender == admin);
        
        // burn from the imported ERC20Permit
        _burn(from, xTokenAmount);

        return xTokenAmount;
    }



    function mint(address to, uint256 fyDaiAmount) public {
        require(msg.sender == admin);
        _mint(to, fyDaiAmount);
    }


}