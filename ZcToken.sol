// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "../ERC/Erc20Permit.sol";
import "../Interfaces/IZcToken.sol";

contract ZcToken is Erc20Permit, IZcToken {
  address public admin;
  address public underlying;
  uint256 public maturity;

  /// @param u Underlying
  /// @param m Maturity
  /// @param n Name
  /// @param s Symbol
  constructor(address u, uint256 m, string memory n, string memory s) Erc20(n, s) {
      underlying = u;
      maturity = m;
      admin = msg.sender;
  }
  
  /// @param f From
  /// @param a Amount
  function burn(address f, uint256 a) external onlyAdmin(admin) override returns(bool) {
      _burn(f, a);
      return true;
  }

  /// @param t To
  /// @param a Amount
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