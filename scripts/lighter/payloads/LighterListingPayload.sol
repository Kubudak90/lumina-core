// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {AaveV3Payload} from '../../../src/contracts/extensions/v3-config-engine/AaveV3Payload.sol';
import {IAaveV3ConfigEngine as IEngine} from '../../../src/contracts/extensions/v3-config-engine/IAaveV3ConfigEngine.sol';
import {LighterMarketInput} from '../../../src/deployments/inputs/LighterMarketInput.sol';

/**
 * @title LighterListingPayload
 * @notice Lists the spec 3.1 reserves (WETH, USDC) through the config engine's ListingEngine, with
 * the risk, cap and rate parameters of `LighterMarketInput`. The ListingEngine sets the AaveOracle
 * sources (WETH -> ETH LighterCorePriceSource, USDC -> FixedPriceSource), the aToken treasury
 * (the engine's COLLECTOR = the Safe) and the incentives controller (CORE-05, CORE-10).
 *
 * Deploy-time only: `DeployLighterDevnet` grants this contract POOL_ADMIN, calls `execute()` and
 * revokes the role in the same broadcast. `execute()` is restricted to `CALLER` (the deployer) so
 * nobody else can run it in the window between the grant and the call.
 *
 * Stateless (immutables only), no calls back into any governance contract; it delegatecalls only
 * into `CONFIG_ENGINE`, which delegatecalls into its engine libraries.
 */
contract LighterListingPayload is AaveV3Payload, LighterMarketInput {
  address public immutable CALLER;
  address public immutable ETH_PRICE_SOURCE;
  address public immutable USDC_PRICE_SOURCE;

  constructor(
    IEngine engine,
    address caller,
    address ethPriceSource,
    address usdcPriceSource
  ) AaveV3Payload(engine) {
    require(caller != address(0), 'caller');
    require(ethPriceSource.code.length > 0, 'ETH price source has no code');
    require(usdcPriceSource.code.length > 0, 'USDC price source has no code');
    CALLER = caller;
    ETH_PRICE_SOURCE = ethPriceSource;
    USDC_PRICE_SOURCE = usdcPriceSource;
  }

  function _preExecute() internal view override {
    require(msg.sender == CALLER, 'LighterListingPayload: only CALLER');
  }

  function newListings() public view override returns (IEngine.Listing[] memory) {
    return _lighterListings(ETH_PRICE_SOURCE, USDC_PRICE_SOURCE);
  }

  function getPoolContext() public pure override returns (IEngine.PoolContext memory) {
    return _lighterPoolContext();
  }
}
