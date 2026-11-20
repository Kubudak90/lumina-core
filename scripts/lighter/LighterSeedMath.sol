// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title LighterSeedMath
 * @notice The deposit that tops a seed up to the manifest amount, computed in Aave's scaled units.
 *
 * An aToken balance is `rayMul(scaledBalance, index)` and a supply of `amount` mints
 * `rayDiv(amount, index)` scaled units (both round half up). Depositing the plain balance shortfall
 * fails at a high liquidity index: at 5 x RAY a 2-unit shortfall mints `rayDiv(2, 5 RAY) = 0`, which
 * reverts. So the target is a scaled balance, `ceil(seed x RAY / index)`, and the deposit is the
 * scaled increase converted back, rounded up: it always mints at least the increase, never 0.
 * The harness funding (lumina-monorepo harness/deploy/lib/steps.mjs) uses the same formula.
 */
library LighterSeedMath {
  uint256 internal constant RAY = 1e27;

  /// @return amount to supply so that `rayMul(scaledBalance + rayDiv(amount, index), index) >= seed`
  function topUpAmount(
    uint256 seed,
    uint256 scaledBalance,
    uint256 index
  ) internal pure returns (uint256 amount) {
    require(index >= RAY, 'LighterSeedMath: index below RAY');
    uint256 targetScaled = ceilDiv(seed * RAY, index);
    if (scaledBalance >= targetScaled) return 0;
    amount = ceilDiv((targetScaled - scaledBalance) * index, RAY);
  }

  function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
    return a == 0 ? 0 : (a - 1) / b + 1;
  }

  /// @dev Aave WadRayMath.rayDiv (half up).
  function rayDiv(uint256 a, uint256 b) internal pure returns (uint256) {
    return (a * RAY + b / 2) / b;
  }

  /// @dev Aave WadRayMath.rayMul (half up).
  function rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
    return (a * b + RAY / 2) / RAY;
  }
}
