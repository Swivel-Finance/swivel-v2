// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../Utils/Abstracts.sol";

contract VaultTracker {
    
    uint256 public maturity;
    
    address public underlying;
    
    address public cTokenAddress;
    
    address public admin;
    
    bool matured;
    
    uint256 maturityRate;
    
    CErc20 cToken = CErc20(cTokenAddress);
    
    mapping(address => vault) public vaults;
    
    struct vault {
        uint256 notional;
        uint256 redeemable;
        uint256 exchangeRate;
    }
    
    constructor (uint256 maturity_, address underlying_, address cToken_) {
        maturity = maturity_;
        underlying = underlying_;
        cTokenAddress = cToken_;
        admin = msg.sender;
    }
    
    function addNotional(address owner, uint256 amount) public {
        require(msg.sender == admin, "Only Admin");
        vault memory position = vaults[owner];
        
        if (position.notional > 0) {
            
            uint256 interest;
        
            // If market has matured, calculate marginal interest between the maturity rate and previous position exchange rate
            // Otherwise, calculate marginal exchange rate between current and previous exchange rate.
            if (matured == true) {
                // Calculate marginal interest
                uint256 yield = ((maturityRate * 1e26) / position.exchangeRate) - 1e26; 
                interest = (yield * position.notional) / 1e26;
            }
            else {
                // Calculate marginal interest
                uint256 yield = ((cToken.exchangeRateCurrent() * 1e26) / position.exchangeRate) - 1e26; 
                interest = (yield * position.notional) / 1e26;
            }
            
            // Add interest and amount to position, reset cToken exchange rate
            position.redeemable += interest;
            position.notional += amount;
            position.exchangeRate = cToken.exchangeRateCurrent();
        }
        
        else {
            position.notional += amount;
            position.exchangeRate = cToken.exchangeRateCurrent();
        }
    }
    
    function removeNotional(address owner, uint256 amount) public {
        require(msg.sender == admin, "Only Admin");
        vault memory vault_ = vaults[owner];
        
        require(vault_.notional >= amount, "Amount exceeds vault balance");
        
       uint256 interest;
        
        // If market has matured, calculate marginal interest between the maturity rate and previous position exchange rate
        // Otherwise, calculate marginal exchange rate between current and previous exchange rate.
        if (matured == true) {
            // Calculate marginal interest
            uint256 yield = ((maturityRate * 1e26) / vault_.exchangeRate) - 1e26; 
            interest = (yield * vault_.notional) / 1e26;
        }
        else {
            // Calculate marginal interest
            uint256 yield = ((cToken.exchangeRateCurrent() * 1e26) / vault_.exchangeRate) - 1e26; 
            interest = (yield * vault_.notional) / 1e26;
        }
        
        // Remove amount from position, Add interest to position, reset cToken exchange rate
        vault_.redeemable += interest;
        vault_.notional -= amount;
        vault_.exchangeRate = cToken.exchangeRateCurrent();
    }
    
    function redeemInterest(address owner) public returns(uint256 redeemAmount) {
        require(msg.sender == admin, "Only Admin");
        
        vault memory vault_ = vaults[owner];
        redeemAmount = vault_.redeemable;
        uint256 interest;
        
        // If market has matured, calculate marginal interest between the maturity rate and previous position exchange rate
        // Otherwise, calculate marginal exchange rate between current and previous exchange rate.
        if (matured == true) {
            // Calculate marginal interest
            uint256 yield = ((maturityRate * 1e26) / vault_.exchangeRate) - 1e26; 
            interest = (yield * vault_.notional) / 1e26;
        }
        else {
            // Calculate marginal interest
            uint256 yield = ((cToken.exchangeRateCurrent() * 1e26) / vault_.exchangeRate) - 1e26; 
            interest = (yield * vault_.notional) / 1e26;
        }
        // Add marginal interest to previously accrued redeemable interest
        redeemAmount += interest;
        
        vault_.exchangeRate = cToken.exchangeRateCurrent();
        vault_.redeemable = 0;

        return(redeemAmount);
    }
    
    function matureMarket() public {
        require(block.timestamp >= maturity, "Maturity has not been reached.");
        matured = true;
        maturityRate = cToken.exchangeRateCurrent();
    }
    
    
    function returnVaultAmounts(address owner) public view returns (uint256 underlyingAmount, uint256 redeemableUnderlying) {
        return(vaults[owner].notional,vaults[owner].redeemable);
    }
    
}