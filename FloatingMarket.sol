// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../Utils/Abstracts.sol";

contract FloatingMarket {
    
    uint256 public maturity;
    
    address public underlying;
    
    address public cTokenAddress;
    
    address public admin;
    
    bool matured;
    
    uint256 maturityRate;
    
    CErc20 cToken = CErc20(cTokenAddress);
    
    mapping(address => floatingVault) public positions;
    
    struct floatingVault {
        uint256 principal;
        uint256 redeemable;
        uint256 exchangeRate;
    }
    
    constructor (uint256 maturity_, address underlying_, address cToken_) {
        maturity = maturity_;
        underlying = underlying_;
        cTokenAddress = cToken_;
        admin = msg.sender;
        
    }
    
    function addUnderlying(address owner, uint256 amount) public {
        require(msg.sender == admin, "Only Admin");
        floatingVault memory position = positions[owner];
        
        if (position.principal > 0) {
            
            uint256 interest;
        
            // If market has matured, calculate marginal interest between the maturity rate and previous position exchange rate
            // Otherwise, calculate marginal exchange rate between current and previous exchange rate.
            if (matured == true) {
                // Calculate marginal interest
                uint256 yield = ((maturityRate * 1e26) / position.exchangeRate) - 1e26; 
                interest = (yield * position.principal) / 1e26;
            }
            else {
                // Calculate marginal interest
                uint256 yield = ((cToken.exchangeRateCurrent() * 1e26) / position.exchangeRate) - 1e26; 
                interest = (yield * position.principal) / 1e26;
            }
            
            // Add interest and amount to position, reset cToken exchange rate
            positions[owner].redeemable += interest;
            positions[owner].principal += amount;
            positions[owner].exchangeRate = cToken.exchangeRateCurrent();
        }
        
        else {
            positions[owner].principal += amount;
            positions[owner].exchangeRate = cToken.exchangeRateCurrent();
        }
    }
    
    function removeUnderlying(address owner, uint256 amount) public {
        require(msg.sender == admin, "Only Admin");
        floatingVault memory position = positions[owner];
        
        require(position.principal >= amount, "Amount exceeds vault balance");
        
       uint256 interest;
        
        // If market has matured, calculate marginal interest between the maturity rate and previous position exchange rate
        // Otherwise, calculate marginal exchange rate between current and previous exchange rate.
        if (matured == true) {
            // Calculate marginal interest
            uint256 yield = ((maturityRate * 1e26) / position.exchangeRate) - 1e26; 
            interest = (yield * position.principal) / 1e26;
        }
        else {
            // Calculate marginal interest
            uint256 yield = ((cToken.exchangeRateCurrent() * 1e26) / position.exchangeRate) - 1e26; 
            interest = (yield * position.principal) / 1e26;
        }
        
        // Remove amount from position, Add interest to position, reset cToken exchange rate
        positions[owner].redeemable += interest;
        positions[owner].principal -= amount;
        positions[owner].exchangeRate = cToken.exchangeRateCurrent();
    }
    
    function redeemInterest(address owner) public returns(uint256 redeemAmount) {
        require(msg.sender == admin, "Only Admin");
        
        floatingVault memory position = positions[owner];
        redeemAmount = positions[owner].redeemable;
        uint256 interest;
        
        // If market has matured, calculate marginal interest between the maturity rate and previous position exchange rate
        // Otherwise, calculate marginal exchange rate between current and previous exchange rate.
        if (matured == true) {
            // Calculate marginal interest
            uint256 yield = ((maturityRate * 1e26) / position.exchangeRate) - 1e26; 
            interest = (yield * position.principal) / 1e26;
        }
        else {
            // Calculate marginal interest
            uint256 yield = ((cToken.exchangeRateCurrent() * 1e26) / position.exchangeRate) - 1e26; 
            interest = (yield * position.principal) / 1e26;
        }
        // Add marginal interest to previously accrued redeemable interest
        redeemAmount += interest;
        
        positions[owner].exchangeRate = cToken.exchangeRateCurrent();
        positions[owner].redeemable = 0;

        return(redeemAmount);
    }
    
    function matureMarket() public {
        require(block.timestamp >= maturity, "Maturity has not been reached.");
        matured = true;
        maturityRate = cToken.exchangeRateCurrent();
    }
    
    
    function returnVaultAmounts(address owner) public view returns (uint256 underlyingAmount, uint256 redeemableUnderlying) {
        return(positions[owner].principal,positions[owner].redeemable);
    }
    
}