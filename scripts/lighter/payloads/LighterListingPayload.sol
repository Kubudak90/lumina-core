// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {AaveV3Payload} from '../../../src/contracts/extensions/v3-config-engine/AaveV3Payload.sol';
import {IAaveV3ConfigEngine as IEngine} from '../../../src/contracts/extensions/v3-config-engine/IAaveV3ConfigEngine.sol';
import {LighterMarketInput} from '../../../src/deployments/inputs/LighterMarketInput.sol';
import {IPool} from '../../../src/contracts/interfaces/IPool.sol';
import {IERC20} from '../../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';

interface ILighterListingEngine {
  function POOL() external view returns (IPool);
}

interface ILighterListingAcl {
  function POOL_ADMIN_ROLE() external view returns (bytes32);

  function renounceRole(bytes32 role, address account) external;
}

/**
 * @title LighterListingPayload
 * @notice Lists the spec 3.1 reserves (WETH, USDC) and seeds them, in one transaction.
 *
 * `execute()` (only `CALLER`, the deployer):
 *  1. lists both reserves through the config engine's ListingEngine with the risk, cap and rate
 *     parameters of `LighterMarketInput`; the ListingEngine also sets the AaveOracle sources
 *     (WETH -> ETH LighterCorePriceSource, USDC -> FixedPriceSource), the aToken treasury (the
 *     engine's COLLECTOR = the Safe) and the incentives controller (CORE-05, CORE-10);
 *  2. supplies the seeds it holds (transferred to it beforehand) `onBehalfOf` SEED_HOLDER
 *     (0x...dEaD, so they can never be withdrawn); the reserves are never open to a first public
 *     supply before the seed (spec 3.1, 5 item 9);
 *  3. renounces the POOL_ADMIN role it was granted for this call.
 * A failure in any step reverts all three.
 *
 * The deploy grants POOL_ADMIN right before `execute()`; if the run stops in between, the next
 * run revokes it (the payload address is checkpointed in the manifest before the grant).
 *
 * No calls back into any governance contract; it delegatecalls only into `CONFIG_ENGINE`, which
 * delegatecalls into its engine libraries. Not meant to run through the Executor.
 */
contract LighterListingPayload is AaveV3Payload, LighterMarketInput {
  address public constant SEED_HOLDER = 0x000000000000000000000000000000000000dEaD;

  address public immutable CALLER;
  address public immutable ETH_PRICE_SOURCE;
  address public immutable USDC_PRICE_SOURCE;
  IPool public immutable POOL;
  uint256 public immutable WETH_SEED;
  uint256 public immutable USDC_SEED;

  constructor(
    IEngine engine,
    address caller,
    address ethPriceSource,
    address usdcPriceSource,
    uint256 wethSeed,
    uint256 usdcSeed
  ) AaveV3Payload(engine) {
    require(caller != address(0), 'caller');
    require(ethPriceSource.code.length > 0, 'ETH price source has no code');
    require(usdcPriceSource.code.length > 0, 'USDC price source has no code');
    require(wethSeed > 0 && usdcSeed > 0, 'seeds must be positive');
    CALLER = caller;
    ETH_PRICE_SOURCE = ethPriceSource;
    USDC_PRICE_SOURCE = usdcPriceSource;
    POOL = ILighterListingEngine(address(engine)).POOL();
    WETH_SEED = wethSeed;
    USDC_SEED = usdcSeed;
  }

  function _preExecute() internal view override {
    require(msg.sender == CALLER, 'LighterListingPayload: only CALLER');
    require(
      IERC20(LIGHTER_WETH9).balanceOf(address(this)) >= WETH_SEED &&
        IERC20(LIGHTER_USDC).balanceOf(address(this)) >= USDC_SEED,
      'LighterListingPayload: seeds not funded'
    );
  }

  function _postExecute() internal override {
    _seed(LIGHTER_WETH9, WETH_SEED);
    _seed(LIGHTER_USDC, USDC_SEED);
    ILighterListingAcl acl = ILighterListingAcl(POOL.ADDRESSES_PROVIDER().getACLManager());
    acl.renounceRole(acl.POOL_ADMIN_ROLE(), address(this));
  }

  function _seed(address asset, uint256 amount) internal {
    require(IERC20(asset).approve(address(POOL), amount), 'approve');
    POOL.supply(asset, amount, SEED_HOLDER, 0);
  }

  function newListings() public view override returns (IEngine.Listing[] memory) {
    return _lighterListings(ETH_PRICE_SOURCE, USDC_PRICE_SOURCE);
  }

  function getPoolContext() public pure override returns (IEngine.PoolContext memory) {
    return _lighterPoolContext();
  }
}
