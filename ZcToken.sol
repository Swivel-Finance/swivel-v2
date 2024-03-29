// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "../ERC/Erc2612.sol";
import "../Interfaces/IZcToken.sol";

/// NOTE the OZStlye naming conventions are kept for the internal methods
/// _burn and _mint as dangling underscores are generally not allowed.
contract ZcToken is Erc2612, IZcToken {
  address public immutable  admin;
  address public immutable underlying;
  uint256 public immutable maturity;

  /// @param u Underlying
  /// @param m Maturity
  /// @param n Name
  /// @param s Symbol
  constructor(address u, uint256 m, string memory n, string memory s) Erc2612(n, s) {
    admin = msg.sender;  
    underlying = u;
    maturity = m;
  }
  
  /// @param f Address to burn from
  /// @param a Amount to burn
  function burn(address f, uint256 a) external onlyAdmin(admin) override returns(bool) {
      _burn(f, a);
      return true;
  }

  /// @param t Address recieving the minted amount
  /// @param a The amount to mint
  function mint(address t, uint256 a) external onlyAdmin(admin) override returns(bool) {
      _mint(t, a);
      return true;
  }

  /// @param a Admin address
  modifier onlyAdmin(address a) {
    require(msg.sender == a, 'sender must be admin');
    _;
  }
}