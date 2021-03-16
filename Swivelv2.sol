// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.0;

import './Sig.sol';
import './HashFixed.sol';
import './xToken.sol';
import './FloatingMarket.sol';

contract Swivel {
    // TODO visibility of these...
    string constant public NAME = "Swivel Finance";
    string constant public VERSION = "2.0.0";
    /// @dev DAI compound token, passed to constructor
    address public CTOKEN;
    /// @dev EIP712 domain separator.
    bytes32 public DOMAIN;
    
    address public admin;
    
    struct floatingPosition {
        address owner;
        uint256 amount;
        uint256 initialRate;
        bool released;
    }
    
    struct tokenAddresses {
        address cToken;
        address xToken;
        address floatingMarket;
    }





    /// @dev maps the key of an order to a boolean indicating if an order was cancelled
    mapping (bytes32 => bool) public cancelled;
    
    /// @dev maps the key of an order to an amount representing its taken volume
    mapping (bytes32 => uint256) public filled;
    
    /// @dev maps an underlying token address to the address for cToken and xToken within a given maturity
    mapping (address => mapping (uint256 => tokenAddresses)) public markets;
    
    /// @dev maps a specific market to a bool in order to determine wheter it has matured yet
    mapping (address => mapping (uint256 => bool)) public isMature;
    
    /// @dev maps a specific market to a uint in order to determine wheter its cToken exchange rate at maturity
    mapping (address => mapping (uint256 => uint256)) public maturityRate;





    /// @notice Emitted on floating position creation
    event InitiateFloating (bytes32 indexed key, address indexed owner);
    
    /// @notice Emitted on order cancellation
    event Cancel (bytes32 indexed key);
    
    /// @notice Emitted on floating position release/exit
    event ReleaseFloating (bytes32 indexed key, address indexed owner);
    
    /// @notice Emitted on the creation of a new underlying&maturity market pairing
    event newMarket(uint256 maturity, address underlying, address cToken, address xToken);
    
    /// @notice Emitted after a market's maturity has been reached and when the `Mature` function is called
    event Matured(address underlying, uint256 maturity, uint256 timeMatured, uint256 maturityRate);





    /// @notice Creates domain hash for signature verification and sets admin
    constructor() {
        DOMAIN = Hash.domain(NAME, VERSION, block.chainid, address(this));
        
        admin = msg.sender;
    }
 
 
 
 
 
 
    /// @notice Allows the admin to create new markets
    /// @param name : Name of the new xToken market
    /// @param symbol : Symbol of the new xToken market
    /// @param maturity : Maturity timestamp of the new market
    /// @param underlying : Underlying token address associated with the new market
    /// @param cToken : cToken address associated with underlying for the new market
    function createMarket(string memory name, string memory symbol, uint256 maturity, address underlying, address cToken) public {
        require(msg.sender == admin, 'Only Admin');
        
        // Create new xToken
        address xTokenAddress = address(new xToken(maturity,underlying,name,symbol));
        // Create new floating side market
        address floatingMarketAddress = address(new FloatingMarket(maturity,underlying,cToken));
        
        // Map underlying address to cToken, xToken, and floating market addresses
        markets[underlying][maturity] = tokenAddresses(cToken,xTokenAddress,floatingMarketAddress);
        
        // Emit new market corrosponding addresses
        emit newMarket(maturity,underlying,cToken,xTokenAddress);
    }
    
    
    
    /// @notice Can be called after maturity,allowing all of the xTokens to gain interest on Compound until they release their funds
    /// @param underlying : Underlying token address associated with the given xToken Market
    /// @param maturity : Maturity timestamp associated with the given xToken Market
    function matureMarket(address underlying, uint256 maturity) public {
        require(isMature[underlying][maturity]==false, 'Market has already matured');
        
        tokenAddresses memory tokenAddresses_ = markets[underlying][maturity];

        CErc20 cToken_ = CErc20(tokenAddresses_.cToken);
        xToken xToken_ = xToken(tokenAddresses_.xToken);
        
        require(block.timestamp >= xToken_.maturity(), "Market maturity has not yet been reached");
        
        // Set the base cToken exchange rate at maturity to the current cToken exchange rate
        uint256 maturityRate_ = cToken_.exchangeRateCurrent();
        
        maturityRate[underlying][maturity] = maturityRate_;
        
        // Set the maturity state to true
        isMature[underlying][maturity] = true;
        
        emit Matured(underlying, maturity, block.timestamp, maturityRate_);
    
    }
    
    /// @notice Allows xToken holders to redeem their tokens for underlying tokens after maturity has been reached.
    /// @param underlying : Underlying token address associated with the given xToken Market
    /// @param maturity : Maturity timestamp associated with the given xToken Market
    /// @param xTokenAmount : Amount of xTokens being redeemed
    function redeemxToken(address underlying, uint256 maturity, uint256 xTokenAmount) public {
        require (isMature[underlying][maturity] == true, "Market must have matured before redemption");
        
        tokenAddresses memory tokenAddresses_ = markets[underlying][maturity];
 
        xToken xToken_ = xToken(tokenAddresses_.xToken);
        CErc20 cToken_ = CErc20(tokenAddresses_.cToken);
        Erc20 uToken = Erc20(underlying);

        // Burn user's xTokens
        require(xToken_.burn(msg.sender,xTokenAmount) == xTokenAmount, 'Not enough xTokens / issue with burn');
        
        // Call internal function to determine the amount of principle to return
        uint256 principleReturned = calculateTotalReturn(underlying, maturity, xTokenAmount);
        
        // Redeem principleReturned of underlying token to Swivel Contract from Compound 
        require(cToken_.redeemUnderlying(principleReturned) == 0 ,'cToken redemption failed');
    
        // Transfer the principleReturned in underlying tokens to the user
        require(uToken.transfer(msg.sender, principleReturned), 'Transfer of underlying token to user failed');
    }
    
    /// @notice Calcualtes the total amount of underlying returned including interest generated since the `matureMarket` function has been called
    /// @param underlying : Underlying token address associated with the given xToken Market
    /// @param maturity : Maturity timestamp associated with the given xToken Market
    /// @param xTokenAmount : Amount of xTokens being redeemed
    function calculateTotalReturn(address underlying, uint256 maturity, uint256 xTokenAmount) internal returns(uint256) {
        tokenAddresses memory tokenAddresses_ = markets[underlying][maturity];
        
        CErc20 cToken_ = CErc20(tokenAddresses_.cToken);
        
        // cToken exchange rate at maturity
        uint256 maturityRate_ = maturityRate[underlying][maturity];
        
        // Calculate difference between the cToken exchange rate @ maturite and the current cToken exchange rate
        uint256 rateDifference = cToken_.exchangeRateCurrent() - maturityRate[underlying][maturity];
        
        // Calculate the yield generated after maturity in %. Precise to 9 decimals (5.25% = .0525 = 52500000)
        uint256 residualYield = (((rateDifference * 1e26) / maturityRate_)/1e17)+1E9;
        
        // Calculate the total amount of underlying principle to return
        uint256 totalReturned = (residualYield * xTokenAmount) / 1e9;
        
        return totalReturned; 
    }
    
    /// @notice Calculates the total amount of underlying returned including interest generated since the `matureMarket` function has been called
    /// @param key : Identifying key. Keccak of address + time + salt generated when the position was initiated
    /// @param underlying : Underlying token address associated with the given floating Market
    /// @param maturity : Maturity timestamp associated with the given floating Market
    function redeemFloatingPosition(bytes32 key, address underlying, uint256 maturity) public {
        require (isMature[underlying][maturity] == true, "Market must have matured before redemption");
        
        tokenAddresses memory tokenAddresses_ = markets[underlying][maturity];
        
        FloatingMarket floatingMarket_ = FloatingMarket(tokenAddresses_.floatingMarket);
        CErc20 cToken_ = CErc20(tokenAddresses_.cToken);
        Erc20 uToken = Erc20(underlying);
        
        // Call to the floating market contract to release the position and calculate the interest generated
        uint256 interestGenerated = floatingMarket_.releasePosition(key);
        
        // Redeem the interest generated by the position to Swivel Contract from Compound
        require(cToken_.redeemUnderlying(interestGenerated) == 0, "Redemption from Compound Failed");
        
        // Determine owner. Need bug fixing to store just 1 variable
        (address owner,uint256 amount,uint256 rate, bool released) = floatingMarket_.positions(key);
        
        // Transfer the interest generated in underlying tokens to the user
        require(uToken.transfer(owner, interestGenerated), 'Transfer of interest generated from Swivel failed');
    }
    

    /// @notice Internal function to call an xToken contract and mint a user tokens
    /// @param underlying : Underlying token address associated with the given xToken Market
    /// @param maturity : Maturity timestamp associated with the given xToken Market
    /// @param xTokenAmount : Amount of xTokens being minted
    /// @param fixedSide : Address of the user that is being minted xTokens
    function mintxToken(address underlying, uint256 maturity, uint256 xTokenAmount, address fixedSide) internal {
        tokenAddresses memory tokenAddresses_ = markets[underlying][maturity];
        
        xToken xToken_ = xToken(tokenAddresses_.xToken);
        
        xToken_.mint(fixedSide,xTokenAmount);
    }
    
    /// @notice Internal function to call an xToken contract and burn a user's tokens
    /// @param underlying : Underlying token address associated with the given xToken Market
    /// @param maturity : Maturity timestamp associated with the given xToken Market
    /// @param xTokenAmount : Amount of xTokens being minted
    function burnxToken(address underlying, uint256 maturity, uint256 xTokenAmount) internal {
        tokenAddresses memory tokenAddresses_ = markets[underlying][maturity];
        
        xToken xToken_ = xToken(tokenAddresses_.xToken);
        
        xToken_.burn(msg.sender,xTokenAmount);
    }
    
    /// @notice Internal function to call a floating market contract and initiate a floating position
    /// @param key : Identifying key. Keccak of address + time + salt generated when the position was initiated
    /// @param underlying : Underlying token address associated with the given floating Market
    /// @param maturity : Maturity timestamp associated with the given floating Market
    function initiateFloatingPosition(bytes32 key, address underlying, uint256 maturity, uint256 amount) internal {
        tokenAddresses memory tokenAddresses_ = markets[underlying][maturity];
        
        FloatingMarket floatingMarket_ = FloatingMarket(tokenAddresses_.floatingMarket);
        
        floatingMarket_.createPosition(amount, msg.sender, key);
    }
    
    /// @notice Exit a currently active floating position (While batch filling other floating-side orders)
    /// @param key : Identifying key. Keccak of address + time + salt generated when the position was initiated
    /// @param underlying : Underlying token address associated with the given floating Market
    /// @param maturity : Maturity timestamp associated with the given floating Market
    function exitFloatingPosition(bytes32 key,uint256 maturity, address underlying, uint256[] calldata a, Order[] calldata o, Sig.Components[] calldata c) public {
        
        FloatingMarket floatingMarket_ = FloatingMarket(markets[underlying][maturity].floatingMarket);
    
        (address owner, uint256 amount, uint256 rate, bool released) = floatingMarket_.positions(key);
        
        require(owner == msg.sender, "Only position owner can exit the position");
        
        exitFloatingPositionLoop(amount,maturity,underlying,a,o,c);
    
        redeemFloatingPosition(key, underlying, maturity);
    }
    
    /// @notice Internal function to loop through each order a floating exit is filling
    /// @param underlying : Underlying token address associated with the given floating Market
    /// @param maturity : Maturity timestamp associated with the given floating Market
    function exitFloatingPositionLoop(uint256 positionAmount, uint256 maturity, address underlying,uint256[] calldata a,Order[] calldata o, Sig.Components[] calldata c) internal {
        
        Erc20 uToken = Erc20(underlying);  
        
        uint256 amountExited;
        for (uint256 i=0; i < o.length; i++) {
            
            Order memory _order = o[i];
            
            require(_order.maturity == maturity, "Wrong Maturity");
            require(_order.underlying == underlying, "Wrong Token");
            require(_order.floating == true, "Wrong order side");
            
            // Validate order signature
            require(_order.maker == ecrecover(
            	keccak256(abi.encodePacked(
            		"\x19\x01",
            		DOMAIN,
            		hashOrder(_order)
            		)),
            		c[i].v,
            		c[i].r,
            		c[i].s), 
            "Invalid Signature");
             
            //require fill amount < = principal remaining in the order
            require(a[i] <= ((o[i].principal) - (filled[o[i].key])));
         
            filled[o[i].key] += a[i];
         
            uint256 interestFilled = (((a[i] * 1e26)/o[i].principal) * o[i].interest / 1e26);
         
            uToken.transferFrom(o[i].maker, msg.sender, interestFilled);
         
            amountExited += a[i];
         
            initiateFloatingPosition(o[i].key,underlying,maturity,a[i]);
            //event for new positions
         
        }
        
        require(amountExited == positionAmount, "Must exit entire position");
        //event for position exit
    }
    
    /// @notice Exit a currently active fixed position by selling a given number of xTokens for underlying tokens (while batch filling fixed side orders)
    /// @param underlying : Underlying token address associated with the given floating Market
    /// @param maturity : Maturity timestamp associated with the given floating Market
    function sellxTokens(uint256 maturity, address underlying, uint256[] calldata a, Order[] calldata o, Sig.Components[] calldata c) public {
        
        xToken xToken_ = xToken(markets[underlying][maturity].xToken);
        Erc20 uToken = Erc20(underlying);
        
        for (uint256 i=0; i < o.length; i++) {
            
            Order memory _order = o[i];
            
            require(_order.maturity == maturity, "Wrong Maturity");
            require(_order.underlying == underlying, "Wrong Token");
            require(_order.floating == false, "Wrong order side");
            
            // Validate order signature
            require(_order.maker == ecrecover(
            	keccak256(abi.encodePacked(
            		"\x19\x01",
            		DOMAIN,
            		hashOrder(_order)
            		)),
            		c[i].v,
            		c[i].r,
            		c[i].s), 
            "Invalid Signature");
            
            
            //
            uint256 principalFilled = (((a[i] * 1e26)/o[i].interest) * o[i].principal / 1e26);
             
            require(a[i] <= ((o[i].principal) - (filled[o[i].key])));
            
            filled[o[i].key] += a[i];
            
            xToken_.transferFrom(msg.sender,o[i].maker,principalFilled);
            uToken.transferFrom(o[i].maker, msg.sender, principalFilled-a[i]);
             
            //event for fixed initiation and exit
        }
        
        
    }


  /// @param o An offline Swivel.Order
  /// @param a order volume (interest) amount this agreement is filling
  /// @param k Key of this agreement
  /// @param c Components of a valid ECDSA signature
  function fillFixed(
    Hash.Order calldata o,
    uint256 a,
    bytes32 k,
    Sig.Components calldata c
  ) public valid(o, c) returns (bool) {
    require(a <= (o.interest - filled[o.key]), 'taker amount > available volume');
    require(o.floating == false, 'Order filled on wrong side');
    // .principal is principal * ratio / 1ETH were ratio is (a * 1ETH) / interest
    uint256 principal = o.principal * ((a * 1 ether) / o.interest) / 1 ether;


    // transfer tokens to this contract
    Erc20 uToken = Erc20(o.underlying);
    require(uToken.transferFrom(msg.sender, o.maker, a), 'Interest transfer from floating to fixed failed');
    require(uToken.transferFrom(o.maker, address(this), principal), 'Principal transfer from fixed to protocol failed');
    
    mintxToken(o.underlying,o.maturity,principal,o.maker);
    
    initiateFloatingPosition(k,o.underlying,o.maturity,principal);
    
  }

  /// @param o Array of offline Swivel.Orders
  /// @param a Array of order volume (interest) amounts relative to passed orders
  /// @param k Key for these agreements
  /// @param c Array of Components from valid ECDSA signatures
  function batchFillFixed(
    Hash.Order[] calldata o,
    uint256[] calldata a,
    bytes32 k,
    Sig.Components[] calldata c
  ) public returns (bool) {
    for (uint256 i=0; i < o.length; i++) {
      require(fillFixed(o[i], a[i], k, c[i]));     
    }

    return true;
  }

  /// @param o An offline Swivel.Order
  /// @param a order volume (principal) amount this agreement is filling
  /// @param k Key of this new agreement
  /// @param c Components of a valid ECDSA signature
  function fillFloating(
    Hash.Order calldata o,
    uint256 a,
    bytes32 k,
    Sig.Components calldata c
  ) public valid(o, c) returns (bool) {
    require(a <= (o.principal - filled[o.key]), 'taker amount > available volume');
    require(o.floating == true, 'Order filled on wrong side');
    // .interest is interest * ratio / 1ETH where ratio is (a * 1ETH) / principal
    uint256 interest = o.interest * ((a * 1 ether) / o.principal) / 1 ether;

    // transfer tokens to this contract
    Erc20 uToken = Erc20(o.underlying);
    require(uToken.transferFrom(o.maker, msg.sender, interest), 'Interest transfer from floating to fixed failed');
    require(uToken.transferFrom(msg.sender, address(this), a), 'Principal transfer from fixed to protocol failed');

    mintxToken(o.underlying,o.maturity,a,msg.sender);
    
    initiateFloatingPosition(k,o.underlying,o.maturity,a);
  }

  /// @param o Array of offline Swivel.Order
  /// @param a Array of order volume (principal) amounts relative to passed orders
  /// @param k Key for these agreements
  /// @param c Array of Components from valid ECDSA signatures
  function batchFillFloating(
    Hash.Order[] calldata o,
    uint256[] calldata  a,
    bytes32[] calldata k,
    Sig.Components[] calldata c
  ) public returns (bool) {
     for (uint256 i=0; i < o.length; i++) {
      require(fillFloating(o[i], a[i], k[i], c[i]));     
    }

    return true;
  }

  function cancel(Hash.Order calldata o, Sig.Components calldata c) public returns (bool) {
    require(o.maker == Sig.recover(Hash.message(DOMAIN, Hash.order(o)), c), 'invalid signature');

    cancelled[o.key] = true;

    emit Cancel(o.key);

    return true;
  }

  /// @param u address of the underlying token contract
  /// @param n number of token to be minted
  function mintCToken(address u, uint256 n) internal returns (uint256) {
    Erc20 uToken = Erc20(u); 
    // approve for n on uToken, facilitating the eventual transfer
    require(uToken.approve(CTOKEN, n), 'underlying approval failed');
    CErc20 cToken = CErc20(CTOKEN);
    return cToken.mint(n);
  }

  /// @param n Number of underlying token to be redeemed
  function redeemCToken(uint256 n) internal returns (uint256) {
    return CErc20(CTOKEN).redeemUnderlying(n);
  }






    // Order Hash Schema
    bytes32 constant ORDER_TYPEHASH = keccak256(
    	"order(bytes32 key,address maker,address underlying,bool floating,uint256 principal,uint256 interest,uint256 maturity,uint256 expiry)"
    );
    
    struct Order {
        bytes32 key;
        address maker;
        address underlying;
        bool floating;
        uint256 principal;
        uint256 interest;
        uint256 maturity;
        uint256 expiry;
      }
      
        /// Order Hash Function
    /// @param _order: order struct
    function hashOrder(Order memory _order)private pure returns(bytes32){
    	return keccak256(abi.encode(
    		ORDER_TYPEHASH,
    		_order.key,
    		_order.maker,
    		_order.underlying,
    		_order.floating,
    		_order.principal,
    		_order.interest,
    		_order.maturity,
    		_order.expiry
    	));
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
