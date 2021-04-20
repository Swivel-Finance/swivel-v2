# swivel-v2
Fixed-Maturity Markets &amp; Zero-Coupon Bond

**Swivelv2** -- The contract that manages all order settlement.

**zcToken** -- An ERC-20 Token that represents a 1-1 redeemable amount of underlying upon maturity. A zero-coupon token.

**VaultTracker** -- The contract that tracks floating side balances.

## To Do

-- Move cToken minting & move zcToken transfer/floating position creation to outside the batch function (Saving gas when filling multiple orders)

-- Review terminology and settle on final naming for both sides.

-- Finalize decision on whether payment for interest coupon should be settled immediately or paid in zero-coupon bonds


