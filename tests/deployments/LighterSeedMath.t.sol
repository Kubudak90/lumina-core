// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';
import {LighterSeedMath} from '../../scripts/lighter/LighterSeedMath.sol';
import {WadRayMath} from '../../src/contracts/protocol/libraries/math/WadRayMath.sol';

/// @notice The seed top-up deposit (r1#4): computed from the scaled shortfall, never a zero mint.
contract LighterSeedMathTest is Test {
  uint256 internal constant RAY = 1e27;

  function test_matchesAaveRounding() public pure {
    assertEq(LighterSeedMath.rayDiv(7, 3 * RAY), WadRayMath.rayDiv(7, 3 * RAY));
    assertEq(LighterSeedMath.rayMul(7, 3 * RAY), WadRayMath.rayMul(7, 3 * RAY));
  }

  /// At a 5 x RAY index a 2-unit balance shortfall mints nothing when deposited as is.
  function test_highIndex_twoUnitShortfall() public pure {
    uint256 index = 5 * RAY;
    uint256 scaled = 1_000;
    uint256 balance = WadRayMath.rayMul(scaled, index); // 5000
    uint256 seed = balance + 2;
    assertEq(WadRayMath.rayDiv(seed - balance, index), 0, 'the naive deposit mints 0 (reverts)');

    uint256 amount = LighterSeedMath.topUpAmount(seed, scaled, index);
    uint256 minted = WadRayMath.rayDiv(amount, index);
    assertGt(minted, 0, 'never a zero mint');
    assertGe(WadRayMath.rayMul(scaled + minted, index), seed, 'reaches the seed');
    assertEq(amount, 5, 'one scaled unit = 5 base units');
  }

  function test_nothingWhenAlreadySeeded() public pure {
    assertEq(LighterSeedMath.topUpAmount(5_000, 1_000, 5 * RAY), 0);
    assertEq(LighterSeedMath.topUpAmount(1e16, 1e16, RAY), 0);
  }

  function testFuzz_topUpReachesSeed(uint256 seed, uint256 scaled, uint256 index) public pure {
    index = bound(index, RAY, 100 * RAY);
    seed = bound(seed, 1, 1e30);
    scaled = bound(scaled, 0, 1e30);
    uint256 amount = LighterSeedMath.topUpAmount(seed, scaled, index);
    uint256 minted = WadRayMath.rayDiv(amount, index);
    if (amount > 0) assertGt(minted, 0, 'never a zero mint');
    assertGe(WadRayMath.rayMul(scaled + minted, index), seed, 'balance reaches the seed');
  }
}
