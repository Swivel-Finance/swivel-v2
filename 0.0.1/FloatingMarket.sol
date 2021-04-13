pragma solidity ^0.8.0;

import "./Swivelv2.sol";


contract FloatingMarket {
    
    uint256 public maturity;
    
    address public underlying;
    
    address public cTokenAddress;
    
    address public admin;
    
    CErc20 cToken = CErc20(cTokenAddress);
    
    mapping(bytes32 => mapping( bytes32 => position)) public positions;
    
    struct position {
        address owner;
        uint256 amount;
        uint256 initialRate;
        bool released;
    }
    
    constructor (uint256 maturity_, address underlying_, address cToken_){
        maturity = maturity_;
        underlying = underlying_;
        cTokenAddress = cToken_;
        admin = msg.sender;
        
    }
    
    function createPosition(bytes32 orderKey, bytes32 positionKey, uint256 amount, address user) public {
        require(msg.sender == admin, "Only Admin");
        
        positions[orderKey][positionKey] = position(
            user,
            amount,
            cToken.exchangeRateCurrent(),
            false
            );
            
        
    }
    
    function releasePosition(bytes32 orderKey, bytes32 positionKey) public returns (uint256) {
        require(msg.sender == admin, "Only Admin");
        require(block.timestamp >= maturity, "Cannot release before maturity");
        
        position memory position_ = positions[orderKey][positionKey];
    
        require(position_.released == false, "Position already released");
        
        uint256 yield = ((cToken.exchangeRateCurrent() * 1e26) / position_.initialRate) - 1e26; 
        uint256 interest = (yield * position_.amount) / 1e26;
        
        positions[orderKey][positionKey].released = true;
        
        return interest;
        
    }
    
    function returnAmountOwner(bytes32 orderKey, bytes32 positionKey) public view returns (address owner, uint256 amount) {
        position memory position_ = positions[orderKey][positionKey];
        return(position_.owner,position_.amount);
    }
    
}