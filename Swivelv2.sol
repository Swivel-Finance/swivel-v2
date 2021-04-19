// SPDX-License-Identifier: UNLICENSED
pragma experimental ABIEncoderV2;
pragma solidity 0.8.0;

import '../Utils/Sig.sol';
import '../Utils/Hash.sol';
import '../Utils/Abstracts.sol';
import '../zcToken.sol';
import '../VaultTracker.sol';

contract Swivel {
    
    
///STRUCTS & VARIABLES   
    
    // TODO visibility of these...
    string constant public NAME = "Swivel Finance";
    string constant public VERSION = "2.0.0";
    
    /// @dev EIP712 domain separator.
    bytes32 public DOMAIN;
    
    address public admin;

    struct tokenAddresses {
        address cToken;
        address zcToken;
        address vaultTracker;
    }


///MAPPINGS

    /// @dev maps the key of an order to a boolean indicating if an order was cancelled
    mapping (bytes32 => bool) public cancelled;
    
    /// @dev maps the key of an order to an amount representing its taken volume
    mapping (bytes32 => uint256) public filled;
    
    /// @dev maps an underlying token address to the address for cToken and zcToken within a given maturity
    mapping (address => mapping (uint256 => tokenAddresses)) public markets;
    
    /// @dev maps a specific market to a bool in order to determine wheter it has matured yet
    mapping (address => mapping (uint256 => bool)) public isMature;
    
    /// @dev maps a specific market to a uint in order to determine wheter its cToken exchange rate at maturity
    mapping (address => mapping (uint256 => uint256)) public maturityRate;


///EVENTS

    /// @notice Emitted on order cancellation
    event Cancel (bytes32 indexed key);
    
    /// @notice Emitted on the creation of a new underlying&maturity market pairing
    event newMarket(uint256 maturity, address underlying, address cToken, address zcToken);
    
    /// @notice Emitted after a market's maturity has been reached and when the `Mature` function is called
    event Matured(address underlying, uint256 maturity, uint256 timeMatured, uint256 maturityRate);



    /// @notice Creates domain hash for signature verification and sets admin
    constructor() {
        DOMAIN = Hash.domain(NAME, VERSION, block.chainid, address(this));
      
        admin = msg.sender;
    }


///METHODS

///MARKET METHODS 
    /// @notice Allows the admin to create new markets
    /// @param name : Name of the new zcToken market
    /// @param symbol : Symbol of the new zcToken market
    /// @param maturity : Maturity timestamp of the new market
    /// @param underlying : Underlying token address associated with the new market
    /// @param cToken : cToken address associated with underlying for the new market
    function createMarket(string memory name, string memory symbol, uint256 maturity, address underlying, address cToken) public  returns (bool) {
        require(msg.sender == admin);
        
        // Create new zcToken
        address zcTokenAddress = address(new zcToken(maturity,underlying,name,symbol));
        // Create new floating side market
        address vaultTrackerAddress = address(new VaultTracker(maturity,underlying,cToken));
        
        // Map underlying address to cToken, zcToken, and floating market addresses
        markets[underlying][maturity] = tokenAddresses(cToken,zcTokenAddress,vaultTrackerAddress);
        
        // Emit new market corrosponding addresses
        emit newMarket(maturity,underlying,cToken,zcTokenAddress);
                
        return (true);
    }
    
    
    /// @notice Can be called after maturity, allowing all of the zcTokens to earn floating interest on Compound until they release their funds
    /// @param underlying : Underlying token address associated with the given zcToken Market
    /// @param maturity : Maturity timestamp associated with the given zcToken Market
    function matureMarket(address underlying, uint256 maturity) public  returns (bool) {
        require(isMature[underlying][maturity]==false, 'Market already matured');
        
        tokenAddresses memory tokenAddresses_ = markets[underlying][maturity];

        CErc20 cToken_ = CErc20(tokenAddresses_.cToken);
        zcToken zcToken_ = zcToken(tokenAddresses_.zcToken);
        VaultTracker vaultTracker_ = VaultTracker(tokenAddresses_.vaultTracker);
        
        require(block.timestamp >= zcToken_.maturity(), "Maturity not reached");
        
        // Set the base maturity cToken exchange rate at maturity to the current cToken exchange rate
        uint256 maturityRate_ = cToken_.exchangeRateCurrent();
        
        maturityRate[underlying][maturity] = maturityRate_;
        
        // Set Floating Market "matured" to true
        vaultTracker_.matureMarket();
        
        // Set the maturity state to true (for zcb market)
        isMature[underlying][maturity] = true;
        
        emit Matured(underlying, maturity, block.timestamp, maturityRate_);
                
        return (true);
    }
    
    /// @notice Allows zcToken holders to redeem their tokens for underlying tokens after maturity has been reached.
    /// @param underlying : Underlying token address associated with the given zcToken Market
    /// @param maturity : Maturity timestamp associated with the given zcToken Market
    /// @param zcTokenAmount : Amount of zcTokens being redeemed
    function redeemzcToken(address underlying, uint256 maturity, uint256 zcTokenAmount) public  returns (bool) {
        
        // TODO Do we use a require here and require it to have been matured, or attempt to mature if it has not? Both require a comparison (just tested, if statement is cheaper)
        
        // If market hasn't matured, mature it and redeem exactly the zcTokenAmount
        if (isMature[underlying][maturity] == false) {
            
            // Attempt to Mature it
            matureMarket(underlying, maturity);
            
            tokenAddresses memory tokenAddresses_ = markets[underlying][maturity];
 
            zcToken zcToken_ = zcToken(tokenAddresses_.zcToken);
            CErc20 cToken_ = CErc20(tokenAddresses_.cToken);
            Erc20 uToken = Erc20(underlying);
    
            // Burn user's zcTokens
            require(zcToken_.burn(msg.sender, zcTokenAmount), 'Could not burn');
            
            // Redeem principleReturned of underlying token to Swivel Contract from Compound 
            require(cToken_.redeemUnderlying(zcTokenAmount) == 0 ,'cToken redemption failed');
        
            // Transfer the principleReturned in underlying tokens to the user
            require(uToken.transfer(msg.sender, zcTokenAmount), 'Transfer of redemption failed');
                    
        }
        // If market has matured, redeem the zcTokenAmount + the marginal floating interest generated on Compound since maturity
        else {
            
            tokenAddresses memory tokenAddresses_ = markets[underlying][maturity];
     
            zcToken zcToken_ = zcToken(tokenAddresses_.zcToken);
            CErc20 cToken_ = CErc20(tokenAddresses_.cToken);
            Erc20 uToken = Erc20(underlying);
    
            // Burn user's zcTokens
            require(zcToken_.burn(msg.sender, zcTokenAmount), 'Could not burn');
            
            // Call internal function to determine the amount of principle to return (including marginal interest since maturity)
            uint256 principleReturned = calculateTotalReturn(underlying, maturity, zcTokenAmount);
            
            // Redeem principleReturned of underlying token to Swivel Contract from Compound 
            require(cToken_.redeemUnderlying(principleReturned) == 0 ,'cToken redemption failed');
        
            // Transfer the principleReturned in underlying tokens to the user
            require(uToken.transfer(msg.sender, principleReturned), 'Transfer of redemption failed');
        
        }
        return (true);        
    }
    
    /// @notice Calcualtes the total amount of underlying returned including interest generated since the `matureMarket` function has been called
    /// @param underlying : Underlying token address associated with the given zcToken Market
    /// @param maturity : Maturity timestamp associated with the given zcToken Market
    /// @param amount : Amount of zcTokens being redeemed
    function calculateTotalReturn(address underlying, uint256 maturity, uint256 amount) internal returns(uint256) {
        tokenAddresses memory tokenAddresses_ = markets[underlying][maturity];
        
        CErc20 cToken_ = CErc20(tokenAddresses_.cToken);
        
        // cToken exchange rate at maturity
        uint256 maturityRate_ = maturityRate[underlying][maturity];
        
        // Calculate difference between the cToken exchange rate @ maturite and the current cToken exchange rate
        uint256 rateDifference = cToken_.exchangeRateCurrent() - maturityRate[underlying][maturity];
        
        // Calculate the yield generated after maturity in %. Precise to 9 decimals (5.25% = .0525 = 52500000)
        uint256 residualYield = (((rateDifference * 1e26) / maturityRate_)/1e17)+1E9;
        
        // Calculate the total amount of underlying principle to return
        uint256 totalReturned = (residualYield * amount) / 1e9;
        
        return totalReturned; 
    }
    
    /// @notice Allows Vault owners to redeem any currently accrued interest within a given ____
    /// @param underlying : Underlying token address associated with the given ____
    /// @param maturity : Maturity timestamp associated with the given floating Market
    function redeemVaultInterest(address underlying, uint256 maturity) public  returns (bool) {
        
        tokenAddresses memory tokenAddresses_ = markets[underlying][maturity];
        
        VaultTracker vaultTracker_ = VaultTracker(tokenAddresses_.vaultTracker);
        CErc20 cToken_ = CErc20(tokenAddresses_.cToken);
        Erc20 uToken = Erc20(underlying);
        
        // Call to the floating market contract to release the position and calculate the interest generated
        uint256 interestGenerated = vaultTracker_.redeemInterest(msg.sender);
        
        // Redeem the interest generated by the position to Swivel Contract from Compound
        require(cToken_.redeemUnderlying(interestGenerated) == 0, "Redemption from Compound Failed");
        
        // Transfer the interest generated in underlying tokens to the user
        require(uToken.transfer(msg.sender, interestGenerated), 'Transfer of redeemable failed');
                
        return (true);
    }
    
    
///ORDERBOOK METHODS
    
    
    /// @notice Allows a user to exit/sell a currently held position to the marketplace.
    /// @param : o Array of offline Swivel.Orders
    /// @param : a Array of order volume (principal) amounts relative to passed orders
    /// @param : c Components of a valid ECDSA signature
    function exit(Hash.Order[] calldata o, uint256[] calldata a, Sig.Components[] calldata c) public returns (bool) {
  
        for (uint256 i=0; i < o.length; i++) {
            // Determine whether the order being filled is an exit
            if (o[i].exit == false) {
                // Determine whether the order being filled is a vault initiate or a zcToken initiate
                if (o[i].floating == false) {
                    // If filling a zcToken initiate with an exit, one is exiting zcTokens
                    require(exitzcTokenFillingzcTokenInitiateOrder(o[i], a[i], c[i]));
                }
                else {
                    // If filling a vault initiate with an exit, one is exiting vault notional
                    require(exitVaultFillingVaultInitiateOrder(o[i], a[i], c[i]));
                }
            }
            else {
                // Determine whether the order being filled is a vault exit or zcToken exit
                if (o[i].floating == false) {
                    // If filling a zcToken exit with an exit, one is exiting vault
                    require(exitVaultFillingzcTokenExitOrder(o[i], a[i], c[i]));
                }
                else {
                    // If filling a vault exit with an exit, one is exiting zcTokens
                    require(exitzcTokenFillingVaultExitOrder(o[i], a[i], c[i]));
                }   
            }   
        }
        return true;
    }
    
    /// @notice Allows a user to exit their Vault by filling an offline vault initiate order
    /// @param : o The order being filled
    /// @param : o Amount of volume (principal) being filled by the taker's exit
    /// @param : c Components of a valid ECDSA signature
    function exitVaultFillingVaultInitiateOrder(Hash.Order calldata o, uint256 a, Sig.Components calldata c) valid(o,c) internal returns (bool) {
        
        Erc20 uToken = Erc20(o.underlying);
        VaultTracker vaultTracker_ = VaultTracker(markets[o.underlying][o.maturity].vaultTracker);
        
        require(a <= ((o.principal) - (filled[o.key])));
        
        uint256 interestFilled = (((a * 1e18)/o.principal) * o.interest / 1e18);
            
        vaultTracker_.removeNotional(msg.sender, a);

        vaultTracker_.addNotional(msg.sender, a);
        
        uToken.transferFrom(o.maker, msg.sender, interestFilled);
        
        filled[o.key] += a;
        
        //event for fixed initiation and exit
        
                
        return (true);
    }
    
    
    /// @notice Allows a user to exit their Vault filling an offline zcToken exit order
    /// @param : o The order being filled
    /// @param : o Amount of volume (principal) being filled by the taker's exit
    /// @param : c Components of a valid ECDSA signature
    function exitVaultFillingzcTokenExitOrder(Hash.Order calldata o, uint256 a, Sig.Components calldata c) valid(o,c) internal returns (bool) {
        
        tokenAddresses memory tokenAddresses_ = markets[o.underlying][o.maturity];
        Erc20 uToken = Erc20(o.underlying);

        require(a <= ((o.principal) - (filled[o.key])));
        
        uint256 interestFilled = (((a * 1e18)/o.principal) * o.interest / 1e18);
        
        // Burn zcTokens for fixed exit party
        zcToken(tokenAddresses_.zcToken).burn(o.maker, a);
        
        // Burn interest coupon for floating exit party
        VaultTracker(tokenAddresses_.vaultTracker).removeNotional(msg.sender, a);
        
        // Transfer cost of interest coupon to floating party
        uToken.transferFrom(o.maker, msg.sender, interestFilled);
        
        // Redeem principal from compound now that coupon and zcb have been redeemed
        require((CErc20(tokenAddresses_.cToken).redeemUnderlying(a) == 0), "Compound Redemption Error");
        
        // Transfer principal back to fixed exit party now that the interest coupon and zcb have been redeemed
        uToken.transfer(o.maker, a);
        
        filled[o.key] += a;
        
        //event for fixed initiation and exit
        return (true);
    }
    
    /// @notice Allows a user to exit their zcTokens by filling an offline vault exit order
    /// @param : o The order being filled
    /// @param : o Amount of volume (principal) being filled by the taker's exit
    /// @param : c Components of a valid ECDSA signature
    function exitzcTokenFillingVaultExitOrder(Hash.Order calldata o, uint256 a, Sig.Components calldata c) valid(o,c) internal returns (bool) {
        
        tokenAddresses memory tokenAddresses_ = markets[o.underlying][o.maturity];
        Erc20 uToken = Erc20(o.underlying);

        require(a <= ((o.principal) - (filled[o.key])));
        
        uint256 interestFilled = (((a * 1e18)/o.principal) * o.interest / 1e18);
        
        // Burn zcTokens for fixed exit party
        zcToken(tokenAddresses_.zcToken).burn(msg.sender, a);
        
        // Burn interest coupon for floating exit party
        VaultTracker(tokenAddresses_.vaultTracker).removeNotional(o.maker, a);
        
        // Transfer cost of interest coupon to floating party
        uToken.transferFrom(msg.sender, o.maker, interestFilled);
        
        // Redeem principal from compound now that coupon and zcb have been redeemed
        require((CErc20(tokenAddresses_.cToken).redeemUnderlying(a) == 0), "Compound Redemption Error");
        
        // Transfer principal back to fixed exit party now that the interest coupon and zcb have been redeemed
        uToken.transfer(msg.sender, a);
        
        filled[o.key] += a;
        
        //event for fixed initiation and exit
        return (true);
    }
    
    /// @notice Allows a user to exit their zcTokens by filling an offline zcToken initiate order
    /// @param : o The order being filled
    /// @param : o Amount of volume (principal) being filled by the taker's exit
    /// @param : c Components of a valid ECDSA signature
    function exitzcTokenFillingzcTokenInitiateOrder(Hash.Order calldata o, uint256 a, Sig.Components calldata c) valid(o,c) internal returns (bool) {
        
        Erc20 uToken = Erc20(o.underlying);

        require(a <= ((o.principal) - (filled[o.key])));
        
        uint256 interestFilled = (((a * 1e18)/o.principal) * o.interest / 1e18);
        
        // Burn zcTokens for fixed exit party
        zcToken(markets[o.underlying][o.maturity].zcToken).transferFrom(msg.sender, o.maker, a);

        // Transfer underlying from initiating party to exiting party, minus the price the exit party pays for the exit (interest).
        uToken.transferFrom(o.maker, msg.sender, (a-interestFilled));
        
        filled[o.key] += a;       
        
        //event for fixed initiation and exit
        
        return (true);
    }
    
    /// @notice Allows a user to initiate a position
    /// @param : o Array of offline Swivel.Orders
    /// @param : a Array of order volume (principal) amounts relative to passed orders
    /// @param : c Array of Components from valid ECDSA signatures
    function initiate(Hash.Order[] calldata o, uint256[] calldata a, Sig.Components[] calldata c) public returns (bool) {

        for (uint256 i=0; i < o.length; i++) {
            if (o[i].exit == false) {
                if (o[i].floating == false) {
                    require(initiateVaultFillingzcTokenInitiate(o[i], a[i], c[i]));
                }
                else {
                    require(initiatezcTokenFillingVaultInitiate(o[i], a[i], c[i]));
                }
            }
            else {
                if (o[i].floating == false) {
                    require(initiatezcTokenFillingzcTokenExit(o[i], a[i], c[i]));
                }
                else {
                    require(initiateVaultFillingVaultExit(o[i], a[i], c[i]));
                }
            }
        }
        return true;
    }
    
    /// @notice Allows a user to initiate zcToken? by filling an offline zcToken exit order
    /// @param : o The order being filled
    /// @param : o Amount of volume (principal) being filled by the taker's exit
    /// @param : c Components of a valid ECDSA signature  
    function initiatezcTokenFillingzcTokenExit(Hash.Order calldata o, uint256 a, Sig.Components calldata c) internal valid(o, c) returns (bool) {
        
        tokenAddresses memory tokenAddresses_ = markets[o.underlying][o.maturity];
        
        zcToken zcToken_ = zcToken(tokenAddresses_.zcToken);
        
        // Checks the side, and the amount compared to amount available
        require(a <= ((o.principal - filled[o.key])), 'taker amount > available volume');
        
        // .interest is interest * ratio / 1e18 where ratio is (a * 1e18) / principal
        uint256 interestFilled = (((a * 1e18)/o.principal) * o.interest / 1e18);
    
        // transfer tokens to this contract
        Erc20 uToken = Erc20(o.underlying);
        require(uToken.transferFrom(msg.sender, o.maker, (a-interestFilled)), 'Principal transfer failed');
        require(zcToken_.transferFrom(o.maker, msg.sender, a), 'Zero-Coupon Token transfer failed');
        
        filled[o.key] += a;
                
        return (true);
    }
    
    /// @notice Allows a user to initiate a Vault by filling an offline vault exit order
    /// @param : o The order being filled
    /// @param : o Amount of volume (principal) being filled by the taker's exit
    /// @param : c Components of a valid ECDSA signature
    function initiateVaultFillingVaultExit(Hash.Order calldata o, uint256 a, Sig.Components calldata c) internal valid(o, c) returns (bool) {
        
        tokenAddresses memory tokenAddresses_ = markets[o.underlying][o.maturity];
        
        VaultTracker vaultTracker_ = VaultTracker(tokenAddresses_.vaultTracker);
        
        // Checks the side, and the amount compared to amount available
        require(a <= (o.principal - filled[o.key]), 'taker amount > available volume');
        
        uint256 interestFilled = (((a * 1e18)/o.principal) * o.interest / 1e18);
     
        // transfer tokens to this contract
        Erc20 uToken = Erc20(o.underlying);
        require(uToken.transferFrom(msg.sender, o.maker, interestFilled), 'Premium transfer for interest coupon failed');
        
        vaultTracker_.removeNotional(o.maker, a);
        
        vaultTracker_.addNotional(msg.sender, a);
        
        filled[o.key] += a;
                
        return (true);
    }

    /// @notice Allows a user to initiate a Vault by filling an offline zcToken initiate order
    /// @param : o The order being filled
    /// @param : o Amount of volume (principal) being filled by the taker's exit
    /// @param : c Components of a valid ECDSA signature
    function initiateVaultFillingzcTokenInitiate(Hash.Order calldata o,uint256 a,Sig.Components calldata c) internal valid(o, c) returns (bool) {
        
        // Checks the side, and the amount compared to amount available
        require(a <= (o.principal - filled[o.key]), 'taker amount > available volume');
        
        uint256 interestFilled = (((a * 1e18)/o.principal) * o.interest / 1e18);
        
        // transfer tokens to this contract
        Erc20 uToken = Erc20(o.underlying);
        require(uToken.transferFrom(msg.sender, o.maker, interestFilled), 'Premium transfer failed');
        require(uToken.transferFrom(o.maker, address(this), a), 'Principal transfer failed');
        
        tokenAddresses memory tokenAddresses_ = markets[o.underlying][o.maturity];
        
        uToken.approve(tokenAddresses_.cToken, a);
        require(CErc20(tokenAddresses_.cToken).mint(a) == 0, 'Minting cTokens Failed');
        
        zcToken(tokenAddresses_.zcToken).mint(msg.sender, a);
        
        VaultTracker(tokenAddresses_.vaultTracker).addNotional(o.maker, a);
        
        filled[o.key] += a;
        
        return (true);
    }
    
    /// @notice Allows a user to initiate a zcToken _ by filling an offline vault initiate order
    /// @param : o The order being filled
    /// @param : o Amount of volume (principal) being filled by the taker's exit
    /// @param : c Components of a valid ECDSA signature
    function initiatezcTokenFillingVaultInitiate(Hash.Order calldata o, uint256 a, Sig.Components calldata c) public valid(o, c) returns (bool) {
        
        // Checks the side, and the amount compared to amount available
        require((a <= o.principal - filled[o.key]), 'taker amount > available volume');

        uint256 interestFilled = (((a * 1e18)/o.principal) * o.interest / 1e18);
    
        // transfer tokens to this contract
        Erc20 uToken = Erc20(o.underlying);
        require(uToken.transferFrom(o.maker, msg.sender, interestFilled), 'Interest transfer failed');
        require(uToken.transferFrom(msg.sender, address(this), a), 'Principal transfer failed');
        
        tokenAddresses memory tokenAddresses_ = markets[o.underlying][o.maturity];
        
        uToken.approve(tokenAddresses_.cToken, a);
        require(CErc20(tokenAddresses_.cToken).mint(a) == 0, 'Minting cTokens Failed');
        
        zcToken(tokenAddresses_.zcToken).mint(msg.sender, a);
        
        VaultTracker(tokenAddresses_.vaultTracker).addNotional(o.maker, a);
        
        filled[o.key] += a;
        
        return (true);
  }

  /// @notice Allows a user to cancel an order, preventing it from being filled in the future
  /// @param o An offline Swivel.Order
  /// @param c Components of a valid ECDSA signature
  function cancel(Hash.Order calldata o, Sig.Components calldata c) public returns (bool) {
    require(o.maker == Sig.recover(Hash.message(DOMAIN, Hash.order(o)), c), 'invalid signature');

    cancelled[o.key] = true;

    emit Cancel(o.key);

    return true;
  }

    
  /// @dev Agreements may only be Initiated if the Order is valid.
  /// @param o An offline Swivel.Order
  /// @param c Components of a valid ECDSA signature
  modifier valid(Hash.Order calldata o, Sig.Components calldata c) {
    require(cancelled[o.key] == false, 'order cancelled');
    require(o.expiry >= block.timestamp, 'order expired');
    require(o.maker == Sig.recover(Hash.message(DOMAIN, Hash.order(o)), c), 'invalid signature');
    _;
  }
}