# swivel-v2
Fixed-Maturity Markets &amp; Zero-Coupon Bond

**Swivel** -- Manages order execution logic and custodies funds/deposits into underlying money-markets.

**Marketplace** -- Acts as a factory for given asset-maturity market pairs. Marketplace contains information on zcToken and Vault contracts, and controls the minting/burning of `zcToken` or Vault `Notional` balance according to functions sent from Swivel.

**zcToken** -- ERC-20 Token that represents a 1-1 redeemable amount of underlying upon maturity. A zero-coupon token.

**VaultTracker** -- Tracks floating side balances. The primary "Balance" is `Notional` which provides a basis to calculate interest. With a secondary `Redeemable` balance that represents interest accrued up until a previous contract interaction.
