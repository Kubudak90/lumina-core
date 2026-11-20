// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {AaveV3Payload} from '../../../src/contracts/extensions/v3-config-engine/AaveV3Payload.sol';
import {IAaveV3ConfigEngine as IEngine} from '../../../src/contracts/extensions/v3-config-engine/IAaveV3ConfigEngine.sol';

/**
 * @title LighterCapsUpdatePayload
 * @notice Config-engine payload that sets the supply and borrow cap of one reserve. Executed by
 * the governance `Executor` (DELEGATECALL into `execute()`), which needs RISK_ADMIN or POOL_ADMIN.
 * Pass `EngineFlags.KEEP_CURRENT` for a cap that stays as it is.
 *
 * Payload review checklist (plan.md, S4a notes): stateless (immutables only); no call back into
 * the Executor; not a proxy; delegatecalls only into `CONFIG_ENGINE` (and from there into the
 * engine's CapsEngine library), both fixed at deployment.
 */
contract LighterCapsUpdatePayload is AaveV3Payload {
  address public immutable ASSET;
  uint256 public immutable SUPPLY_CAP;
  uint256 public immutable BORROW_CAP;

  constructor(
    IEngine engine,
    address asset,
    uint256 supplyCap,
    uint256 borrowCap
  ) AaveV3Payload(engine) {
    require(asset != address(0), 'asset');
    ASSET = asset;
    SUPPLY_CAP = supplyCap;
    BORROW_CAP = borrowCap;
  }

  function capsUpdates() public view override returns (IEngine.CapsUpdate[] memory updates) {
    updates = new IEngine.CapsUpdate[](1);
    updates[0] = IEngine.CapsUpdate({asset: ASSET, supplyCap: SUPPLY_CAP, borrowCap: BORROW_CAP});
  }

  function getPoolContext() public pure override returns (IEngine.PoolContext memory) {
    return IEngine.PoolContext({networkName: 'Lighter', networkAbbreviation: 'Lig'});
  }
}
