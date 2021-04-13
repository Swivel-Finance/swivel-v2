// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "../ERC/ERC20Permit.sol";
import "../Interfaces/IzcToken.sol";

contract zcToken is ERC20Permit, IzcToken  {

    event Redeemed(address indexed from, uint256 fyDaiIn, uint256 daiOut);
    
    event Matured(uint256 maturityTime, uint256 maturityRate);

    uint256 constant internal MAX_TIME_TO_MATURITY = 126144000; // seconds in four years
    
    uint256 public override maturity;
    
    address public underlying;
    
    address public admin;

    constructor(uint256 maturity_, address underlying_, string memory name, string memory symbol) ERC20Permit(name, symbol) {
        
        require(maturity_ > block.timestamp && maturity_ < block.timestamp + MAX_TIME_TO_MATURITY, "Invalid maturity");
        
        maturity = maturity_;
        
        underlying = underlying_;
        
        admin = msg.sender;
    }
    
    function burn(address from, uint256 zcTokenAmount) external override returns(bool) {
        require(msg.sender == admin);
        _burn(from, zcTokenAmount);
        return(true);
    }

    function mint(address to, uint256 fyDaiAmount) public override returns(bool) {
        require(msg.sender == admin);
        _mint(to, fyDaiAmount);
        return(true);
    }

}