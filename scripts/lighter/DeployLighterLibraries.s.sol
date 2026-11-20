// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from 'forge-std/console.sol';
import {LighterManifest} from './LighterManifest.sol';
import {Create2Utils} from '../../src/deployments/contracts/utilities/Create2Utils.sol';
import {LibrariesReport} from '../../src/deployments/interfaces/IMarketReportTypes.sol';
import {AaveV3LibrariesBatch1} from '../../src/deployments/projects/aave-v3-libraries/AaveV3LibrariesBatch1.sol';
import {AaveV3LibrariesBatch2} from '../../src/deployments/projects/aave-v3-libraries/AaveV3LibrariesBatch2.sol';
import {BorrowLogic} from '../../src/contracts/protocol/libraries/logic/BorrowLogic.sol';
import {BridgeLogic} from '../../src/contracts/protocol/libraries/logic/BridgeLogic.sol';
import {ConfiguratorLogic} from '../../src/contracts/protocol/libraries/logic/ConfiguratorLogic.sol';
import {EModeLogic} from '../../src/contracts/protocol/libraries/logic/EModeLogic.sol';
import {FlashLoanLogic} from '../../src/contracts/protocol/libraries/logic/FlashLoanLogic.sol';
import {LiquidationLogic} from '../../src/contracts/protocol/libraries/logic/LiquidationLogic.sol';
import {PoolLogic} from '../../src/contracts/protocol/libraries/logic/PoolLogic.sol';
import {SupplyLogic} from '../../src/contracts/protocol/libraries/logic/SupplyLogic.sol';

/*
 * Step 1 of the Lighter core deploy: the Aave v3 logic libraries, through the existing pre-compile
 * batches (`AaveV3LibrariesBatch1/2`: CREATE2 via the Safe singleton factory, salt
 * `AAVE_V3_LIBRARIES_BATCH`), recorded in the manifest (`$LUMINA_MANIFEST`, see LighterManifest).
 *
 * Unlike `scripts/misc/LibraryPreCompile{One,Two}.sol` this never writes `.env` (forge auto-loads
 * it, so a stray FOUNDRY_LIBRARIES there would relink every later `forge test`): the caller builds
 * FOUNDRY_LIBRARIES from the manifest and passes it in the environment of the next invocation.
 *
 *   batch 1: FOUNDRY_LIBRARIES unset             DeployLighterLibrariesBatch1
 *   batch 2: FOUNDRY_LIBRARIES = batch-1 libs    DeployLighterLibrariesBatch2 (FlashLoanLogic links BorrowLogic)
 *   market:  FOUNDRY_LIBRARIES = all 8           DeployLighterDevnet
 *
 * Two script contracts, not one: forge links a script contract as a whole, and a batch-1 script
 * that also referenced FlashLoanLogic would make forge deploy (and broadcast) its own BorrowLogic.
 * Every script also refuses to run if forge queued library deployments of its own
 * (`_requireNoForgeLibraryDeploys`).
 *
 * Idempotent: a batch whose libraries all have code at their CREATE2 addresses sends nothing.
 * Run with --ffi (git provenance) and --slow.
 */

bytes32 constant LIBRARIES_SALT = keccak256('AAVE_V3_LIBRARIES_BATCH');

function _predictLibrary(bytes memory creationCode) pure returns (address) {
  return Create2Utils.computeCreate2Address(LIBRARIES_SALT, creationCode);
}

function _allHaveCode(address a, address b, address c, address d) view returns (bool) {
  return a.code.length > 0 && b.code.length > 0 && c.code.length > 0 && d.code.length > 0;
}

/// @notice BorrowLogic, BridgeLogic, ConfiguratorLogic, EModeLogic (no library dependencies).
contract DeployLighterLibrariesBatch1 is LighterManifest {
  function run() external {
    _loadManifest();
    address deployer = _requireAddress('.deployer');
    _requireNoForgeLibraryDeploys(deployer);
    LibrariesReport memory r;
    r.borrowLogic = _predictLibrary(type(BorrowLogic).creationCode);
    r.bridgeLogic = _predictLibrary(type(BridgeLogic).creationCode);
    r.configuratorLogic = _predictLibrary(type(ConfiguratorLogic).creationCode);
    r.eModeLogic = _predictLibrary(type(EModeLogic).creationCode);

    if (_allHaveCode(r.borrowLogic, r.bridgeLogic, r.configuratorLogic, r.eModeLogic)) {
      console.log('libraries batch 1: already deployed, nothing sent');
    } else {
      _requireCleanCheckout();
      vm.startBroadcast(deployer);
      AaveV3LibrariesBatch1 batch = new AaveV3LibrariesBatch1();
      vm.stopBroadcast();
      LibrariesReport memory deployed = batch.getLibrariesReport();
      require(deployed.borrowLogic == r.borrowLogic, 'BorrowLogic address');
      require(deployed.bridgeLogic == r.bridgeLogic, 'BridgeLogic address');
      require(deployed.configuratorLogic == r.configuratorLogic, 'ConfiguratorLogic address');
      require(deployed.eModeLogic == r.eModeLogic, 'EModeLogic address');
    }

    _writeContract('borrowLogic', r.borrowLogic, 'BorrowLogic');
    _writeContract('bridgeLogic', r.bridgeLogic, 'BridgeLogic');
    _writeContract('configuratorLogic', r.configuratorLogic, 'ConfiguratorLogic');
    _writeContract('eModeLogic', r.eModeLogic, 'EModeLogic');
    _writeSourceCommit();
  }
}

/// @notice FlashLoanLogic (links BorrowLogic), LiquidationLogic, PoolLogic, SupplyLogic.
contract DeployLighterLibrariesBatch2 is LighterManifest {
  function run() external {
    _loadManifest();
    address deployer = _requireAddress('.deployer');
    _requireNoForgeLibraryDeploys(deployer);
    address borrowLogic = _requireDeployed('.contracts.borrowLogic.address');
    require(
      _containsAddress(type(FlashLoanLogic).creationCode, borrowLogic),
      'FlashLoanLogic is not linked to the manifest BorrowLogic: set FOUNDRY_LIBRARIES from batch 1'
    );

    LibrariesReport memory r;
    r.flashLoanLogic = _predictLibrary(type(FlashLoanLogic).creationCode);
    r.liquidationLogic = _predictLibrary(type(LiquidationLogic).creationCode);
    r.poolLogic = _predictLibrary(type(PoolLogic).creationCode);
    r.supplyLogic = _predictLibrary(type(SupplyLogic).creationCode);

    if (_allHaveCode(r.flashLoanLogic, r.liquidationLogic, r.poolLogic, r.supplyLogic)) {
      console.log('libraries batch 2: already deployed, nothing sent');
    } else {
      _requireCleanCheckout();
      vm.startBroadcast(deployer);
      AaveV3LibrariesBatch2 batch = new AaveV3LibrariesBatch2();
      vm.stopBroadcast();
      LibrariesReport memory deployed = batch.getLibrariesReport();
      require(deployed.flashLoanLogic == r.flashLoanLogic, 'FlashLoanLogic address');
      require(deployed.liquidationLogic == r.liquidationLogic, 'LiquidationLogic address');
      require(deployed.poolLogic == r.poolLogic, 'PoolLogic address');
      require(deployed.supplyLogic == r.supplyLogic, 'SupplyLogic address');
    }

    _writeContract('flashLoanLogic', r.flashLoanLogic, 'FlashLoanLogic');
    _writeContract('liquidationLogic', r.liquidationLogic, 'LiquidationLogic');
    _writeContract('poolLogic', r.poolLogic, 'PoolLogic');
    _writeContract('supplyLogic', r.supplyLogic, 'SupplyLogic');
    _writeSourceCommit();
  }
}
