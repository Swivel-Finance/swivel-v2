// SPDX-License-Identifier: UNLICENSED
pragma experimental ABIEncoderV2;
pragma solidity 0.8.0;

import '../Utils/Sig.sol';
import '../Utils/Hash.sol';
import '../Utils/Abstracts.sol';
import '../zcToken.sol';
import '../FloatingMarket.sol';

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
        address floatingMarket;
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

    /// @notice Emitted on floating position creation
    event InitiateFloating (bytes32 indexed key, address indexed owner);
    
    /// @notice Emitted on order cancellation
    event Cancel (bytes32 indexed key);
    
    /// @notice Emitted on floating position release/exit
    event vaultInterestRedeemed (address indexed owner, address underlying, uint256 amount);
    
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
        require(msg.sender == admin, 'Only Admin');
        
        // Create new zcToken
        address zcTokenAddress = address(new zcToken(maturity,underlying,name,symbol));
        // Create new floating side market
        address floatingMarketAddress = address(new FloatingMarket(maturity,underlying,cToken));
        
        // Map underlying address to cToken, zcToken, and floating market addresses
        markets[underlying][maturity] = tokenAddresses(cToken,zcTokenAddress,floatingMarketAddress);
        
        // Emit new market corrosponding addresses
        emit newMarket(maturity,underlying,cToken,zcTokenAddress);
                
        return (true);
    }
    
    
    /// @notice Can be called after maturity,allowing all of the zcTokens to gain interest on Compound until they release their funds
    /// @param underlying : Underlying token address associated with the given zcToken Market
    /// @param maturity : Maturity timestamp associated with the given zcToken Market
    function matureMarket(address underlying, uint256 maturity) public  returns (bool) {
        require(isMature[underlying][maturity]==false, 'Market has already matured');
        
        tokenAddresses memory tokenAddresses_ = markets[underlying][maturity];

        CErc20 cToken_ = CErc20(tokenAddresses_.cToken);
        zcToken zcToken_ = zcToken(tokenAddresses_.zcToken);
        FloatingMarket floatingMarket_ = FloatingMarket(tokenAddresses_.floatingMarket);
        
        require(block.timestamp >= zcToken_.maturity(), "Market maturity has not yet been reached");
        
        // Set the base maturity cToken exchange rate at maturity to the current cToken exchange rate
        uint256 maturityRate_ = cToken_.exchangeRateCurrent();
        
        maturityRate[underlying][maturity] = maturityRate_;
        
        // Set Floating Market "matured" to true
        floatingMarket_.matureMarket();
        
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
        require (isMature[underlying][maturity] == true, "Market must have matured before redemption");
        
        tokenAddresses memory tokenAddresses_ = markets[underlying][maturity];
 
        zcToken zcToken_ = zcToken(tokenAddresses_.zcToken);
        CErc20 cToken_ = CErc20(tokenAddresses_.cToken);
        Erc20 uToken = Erc20(underlying);

        // Burn user's zcTokens
        require(zcToken_.burn(msg.sender,zcTokenAmount), 'Not enough zcTokens / issue with burn');
        
        // Call internal function to determine the amount of principle to return
        uint256 principleReturned = calculateTotalReturn(underlying, maturity, zcTokenAmount);
        
        // Redeem principleReturned of underlying token to Swivel Contract from Compound 
        require(cToken_.redeemUnderlying(principleReturned) == 0 ,'cToken redemption failed');
    
        // Transfer the principleReturned in underlying tokens to the user
        require(uToken.transfer(msg.sender, principleReturned), 'Transfer of underlying token to user failed');
                
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
    
    /// @notice Calculates the total amount of underlying returned including interest generated since the `matureMarket` function has been called
    /// @param underlying : Underlying token address associated with the given floating Market
    /// @param maturity : Maturity timestamp associated with the given floating Market
    function redeemVaultInterest(address underlying, uint256 maturity, address owner) public  returns (bool) {
        
        tokenAddresses memory tokenAddresses_ = markets[underlying][maturity];
        
        FloatingMarket floatingMarket_ = FloatingMarket(tokenAddresses_.floatingMarket);
        CErc20 cToken_ = CErc20(tokenAddresses_.cToken);
        Erc20 uToken = Erc20(underlying);
        
        // Call to the floating market contract to release the position and calculate the interest generated
        uint256 interestGenerated = floatingMarket_.redeemInterest(msg.sender);
        
        // Redeem the interest generated by the position to Swivel Contract from Compound
        require(cToken_.redeemUnderlying(interestGenerated) == 0, "Redemption from Compound Failed");
        
        // Transfer the interest generated in underlying tokens to the user
        require(uToken.transfer(owner, interestGenerated), 'Transfer of interest generated from Swivel failed');
                
        return (true);
    }
    
    
///ORDERBOOK METHODS
    
    /// @param o Array of offline Swivel.Orders
    /// @param a Array of order volume (interest) amounts relative to passed orders
    /// @param c Array of Components from valid ECDSA signatures
    function exitFill(Hash.Order[] calldata o, uint256[] calldata a, Sig.Components[] calldata c) public returns (bool) {
  
        for (uint256 i=0; i < o.length; i++) {
            if (o[i].exit == false) {
                if (o[i].floating == false) {
                    require(exitFixedWithFixedInitiateOrder(o[i], a[i], c[i]));
                }
                else {
                    require(exitVaultWithVaultInitiateOrder(o[i], a[i], c[i]));
                }
            }
            else {
                if (o[i].floating == false) {
                    require(exitVaultWithFixedExitOrder(o[i], a[i], c[i]));
                }
                else {
                    require(exitFixedWithVaultExitOrder(o[i], a[i], c[i]));
                }   
            }   
        }
        return true;
    }
    
    
        // a is the amount of principal filled 
    function exitVaultWithVaultInitiateOrder(Hash.Order calldata o, uint256 a, Sig.Components calldata c) valid(o,c) internal returns (bool) {
        
        Erc20 uToken = Erc20(o.underlying);
        FloatingMarket floatingMarket_ = FloatingMarket(markets[o.underlying][o.maturity].floatingMarket);
        
        require(a <= ((o.principal) - (filled[o.key])));
        
        uint256 interestFilled = (((a * 1e18)/o.principal) * o.interest / 1e18);
            
        floatingMarket_.removeUnderlying(msg.sender, a);

        floatingMarket_.addUnderlying(msg.sender, a);
        
        uToken.transferFrom(o.maker, msg.sender, interestFilled);
        
        filled[o.key] += a;
        
        //event for fixed initiation and exit
        
                
        return (true);
    }
    
    
    // a is the amount in principal filled (fixed exits == floating initiates on the OB)
    function exitVaultWithFixedExitOrder(Hash.Order calldata o, uint256 a, Sig.Components calldata c) valid(o,c) internal returns (bool) {
        
        tokenAddresses memory tokenAddresses_ = markets[o.underlying][o.maturity];
        Erc20 uToken = Erc20(o.underlying);

        require(a <= ((o.principal) - (filled[o.key])));
        
        uint256 interestFilled = (((a * 1e18)/o.principal) * o.interest / 1e18);
        
        // Burn zcTokens for fixed exit party
        zcToken(tokenAddresses_.zcToken).burn(o.maker, a);
        
        // Burn interest coupon for floating exit party
        FloatingMarket(tokenAddresses_.floatingMarket).removeUnderlying(msg.sender, a);
        
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
    
    // a is the amount in principal filled (fixed exits == floating initiates on the OB)
    function exitFixedWithVaultExitOrder(Hash.Order calldata o, uint256 a, Sig.Components calldata c) valid(o,c) internal returns (bool) {
        
        tokenAddresses memory tokenAddresses_ = markets[o.underlying][o.maturity];
        Erc20 uToken = Erc20(o.underlying);

        require(a <= ((o.principal) - (filled[o.key])));
        
        uint256 interestFilled = (((a * 1e18)/o.principal) * o.interest / 1e18);
        
        // Burn zcTokens for fixed exit party
        zcToken(tokenAddresses_.zcToken).burn(msg.sender, a);
        
        // Burn interest coupon for floating exit party
        FloatingMarket(tokenAddresses_.floatingMarket).removeUnderlying(o.maker, a);
        
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
    
    // a is the amount in principal filled (fixed exits == floating initiates on the OB)
    function exitFixedWithFixedInitiateOrder(Hash.Order calldata o, uint256 a, Sig.Components calldata c) valid(o,c) internal returns (bool) {
        
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
    
    
    
    /// @param o Array of offline Swivel.Orders
    /// @param a Array of order volume (principal) amounts relative to passed orders
    /// @param c Array of Components from valid ECDSA signatures
    function initiateFill(Hash.Order[] calldata o, uint256[] calldata a, Sig.Components[] calldata c) public returns (bool) {

        for (uint256 i=0; i < o.length; i++) {
            if (o[i].exit == false) {
                if (o[i].floating == false) {
                    require(initiateVaultFillingFixedInitiate(o[i], a[i], c[i]));
                }
                else {
                    require(initiateFixedFillingVaultInitiate(o[i], a[i], c[i]));
                }
            }
            else {
                if (o[i].floating == false) {
                    require(initiateFixedFillingFixedExit(o[i], a[i], c[i]));
                }
                else {
                    require(initiateVaultFillingVaultExit(o[i], a[i], c[i]));
                }
            }
        }
        return true;
    }
    
    function initiateFixedFillingFixedExit(Hash.Order calldata o, uint256 a, Sig.Components calldata c) internal valid(o, c) returns (bool) {
        
        tokenAddresses memory tokenAddresses_ = markets[o.underlying][o.maturity];
        
        zcToken zcToken_ = zcToken(tokenAddresses_.zcToken);
        
        // Checks the side, and the amount compared to amount available
        require(a <= ((o.principal - filled[o.key])), 'taker amount > available volume');
        
        // .interest is interest * ratio / 1e18 where ratio is (a * 1e18) / principal
        uint256 interestFilled = (((a * 1e18)/o.principal) * o.interest / 1e18);
    
        // transfer tokens to this contract
        Erc20 uToken = Erc20(o.underlying);
        require(uToken.transferFrom(msg.sender, o.maker, (a-interestFilled)), 'Principal transfer to exiting party failed');
        require(zcToken_.transferFrom(o.maker, msg.sender, a), 'Zero-Coupon Token transfer failed');
        
        filled[o.key] += a;
                
        return (true);
    }
    
    
    function initiateVaultFillingVaultExit(Hash.Order calldata o, uint256 a, Sig.Components calldata c) internal valid(o, c) returns (bool) {
        
        tokenAddresses memory tokenAddresses_ = markets[o.underlying][o.maturity];
        
        FloatingMarket floatingMarket_ = FloatingMarket(tokenAddresses_.floatingMarket);
        
        // Checks the side, and the amount compared to amount available
        require(a <= (o.principal - filled[o.key]), 'taker amount > available volume');
        
        uint256 interestFilled = (((a * 1e18)/o.principal) * o.interest / 1e18);
     
        // transfer tokens to this contract
        Erc20 uToken = Erc20(o.underlying);
        require(uToken.transferFrom(msg.sender, o.maker, interestFilled), 'Premium transfer for interest coupon failed');
        
        floatingMarket_.removeUnderlying(o.maker, a);
        
        floatingMarket_.addUnderlying(msg.sender, a);
        
        filled[o.key] += a;
                
        return (true);
    }

    /// @param o An offline Swivel.Order
    /// @param a order volume (principal) amount this agreement is filling
    /// @param c Components of a valid ECDSA signature
    function initiateVaultFillingFixedInitiate(Hash.Order calldata o,uint256 a,Sig.Components calldata c) internal valid(o, c) returns (bool) {
        
        // Checks the side, and the amount compared to amount available
        require(a <= (o.principal - filled[o.key]), 'taker amount > available volume');
        
        uint256 interestFilled = (((a * 1e18)/o.principal) * o.interest / 1e18);
        
        // transfer tokens to this contract
        Erc20 uToken = Erc20(o.underlying);
        require(uToken.transferFrom(msg.sender, o.maker, interestFilled), 'Interest transfer from floating to fixed failed');
        require(uToken.transferFrom(o.maker, address(this), a), 'Principal transfer from fixed to protocol failed');
        
        tokenAddresses memory tokenAddresses_ = markets[o.underlying][o.maturity];
        
        zcToken zcToken_ = zcToken(tokenAddresses_.zcToken);
        
        zcToken_.mint(msg.sender, a);
        
        FloatingMarket floatingMarket_ = FloatingMarket(tokenAddresses_.floatingMarket);
        
        floatingMarket_.addUnderlying(o.maker, a);
        
        filled[o.key] += a;
        
        return (true);
    }
    
    /// @param o An offline Swivel.Order
    /// @param a order volume (principal) amount this agreement is filling
    /// @param c Components of a valid ECDSA signature
    function initiateFixedFillingVaultInitiate(Hash.Order calldata o, uint256 a, Sig.Components calldata c) public valid(o, c) returns (bool) {
        
        // Checks the side, and the amount compared to amount available
        require((a <= o.principal - filled[o.key]), 'taker amount > available volume');

        uint256 interestFilled = (((a * 1e18)/o.principal) * o.interest / 1e18);
    
        // transfer tokens to this contract
        Erc20 uToken = Erc20(o.underlying);
        require(uToken.transferFrom(o.maker, msg.sender, interestFilled), 'Interest transfer from floating to fixed failed');
        require(uToken.transferFrom(msg.sender, address(this), a), 'Principal transfer from fixed to protocol failed');
        
        tokenAddresses memory tokenAddresses_ = markets[o.underlying][o.maturity];
        
        zcToken(tokenAddresses_.zcToken).mint(msg.sender, a);
        
        FloatingMarket(tokenAddresses_.floatingMarket).addUnderlying(o.maker, a);
        
        filled[o.key] += a;
        
        return (true);
  }
    

  function cancel(Hash.Order calldata o, Sig.Components calldata c) public returns (bool) {
    require(o.maker == Sig.recover(Hash.message(DOMAIN, Hash.order(o)), c), 'invalid signature');

    cancelled[o.key] = true;

    emit Cancel(o.key);

    return true;
  }

  /// @param u address of the underlying token contract
  /// @param n number of token to be minted
  function mintCToken(address u,address c, uint256 n) internal returns (uint256) {
    Erc20 uToken = Erc20(u); 
    // approve for n on uToken, facilitating the eventual transfer
    require(uToken.approve(c, n), 'underlying approval failed');
    CErc20 cToken = CErc20(c);
    return cToken.mint(n);
  }

  /// @param n Number of underlying token to be redeemed
  function redeemCToken(uint256 n,address c) internal returns (uint256) {
    return CErc20(c).redeemUnderlying(n);
  }
      
    
  /// @dev Agreements may only be Initiated if the Order is valid.
  /// @param o An offline Swivel.Order
  /// @param c Components of a valid ECDSA signature
  modifier valid(Hash.Order calldata o, Sig.Components calldata c) {
    require(cancelled[o.key] == false, 'order has been cancelled');
    require(o.expiry >= block.timestamp, 'order has expired');
    require(o.maker == Sig.recover(Hash.message(DOMAIN, Hash.order(o)), c), 'invalid signature');
    _;
  }
}