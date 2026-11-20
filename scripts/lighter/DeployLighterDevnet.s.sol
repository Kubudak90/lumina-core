// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from 'forge-std/console.sol';
import {LighterManifest} from './LighterManifest.sol';
import {LighterListingPayload} from './payloads/LighterListingPayload.sol';
import {LighterMarketInput} from '../../src/deployments/inputs/LighterMarketInput.sol';
import '../../src/deployments/interfaces/IMarketReportTypes.sol';
import {AaveV3BatchOrchestration} from '../../src/deployments/projects/aave-v3-batched/AaveV3BatchOrchestration.sol';
import {IAaveV3ConfigEngine as IEngine} from '../../src/contracts/extensions/v3-config-engine/IAaveV3ConfigEngine.sol';
import {AaveV3ConfigEngine} from '../../src/contracts/extensions/v3-config-engine/AaveV3ConfigEngine.sol';
import {Executor} from '../../src/contracts/extensions/v3-config-engine/Executor.sol';
import {PoolInstance} from '../../src/contracts/instances/PoolInstance.sol';
import {PoolConfiguratorInstance} from '../../src/contracts/instances/PoolConfiguratorInstance.sol';
import {IOwnable} from 'solidity-utils/contracts/transparent-proxy/interfaces/IOwnable.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {DataTypes} from '../../src/contracts/protocol/libraries/types/DataTypes.sol';

interface ILighterCoreSourceView {
  function MARKET_ID() external view returns (uint16);

  function PRICE_DECIMALS() external view returns (uint8);

  function MIN_PRICE() external view returns (uint256);

  function MAX_PRICE() external view returns (uint256);

  function latestAnswer() external view returns (int256);
}

interface IFixedSourceView {
  function PRICE() external view returns (uint256);

  function latestAnswer() external view returns (int256);
}

interface IPriceGuardView {
  function ADDRESSES_PROVIDER() external view returns (address);

  function guardian() external view returns (address);

  function pendingGuardian() external view returns (address);

  function keeper() external view returns (address);

  function maxRefAge() external view returns (uint256);

  function maxDeviationBps() external view returns (uint256);

  function maxCorePriceAge() external view returns (uint256);

  function marketIds() external view returns (uint16[] memory);

  function getMarket(
    uint16 marketId
  ) external view returns (bool, address, uint256, uint64, uint256, uint64, uint64);
}

interface IDualOracleView {
  function ASSET() external view returns (address);

  function COLLATERAL() external view returns (address);

  function ASSET_PRICE_SOURCE() external view returns (address);

  function COLLATERAL_PRICE_SOURCE() external view returns (address);

  function GUARD() external view returns (address);
}

interface ISafeView {
  function getOwners() external view returns (address[] memory);

  function getThreshold() external view returns (uint256);
}

interface IProviderAdmin {
  function owner() external view returns (address);

  function getPool() external view returns (address);

  function getPoolConfigurator() external view returns (address);

  function getPriceOracle() external view returns (address);

  function getACLManager() external view returns (address);

  function getACLAdmin() external view returns (address);

  function getPoolDataProvider() external view returns (address);

  function getPriceOracleSentinel() external view returns (address);

  function getAddress(bytes32 id) external view returns (address);

  function setPriceOracleSentinel(address sentinel) external;

  function setACLAdmin(address admin) external;

  function transferOwnership(address newOwner) external;
}

interface IACL {
  function DEFAULT_ADMIN_ROLE() external view returns (bytes32);

  function POOL_ADMIN_ROLE() external view returns (bytes32);

  function EMERGENCY_ADMIN_ROLE() external view returns (bytes32);

  function RISK_ADMIN_ROLE() external view returns (bytes32);

  function FLASH_BORROWER_ROLE() external view returns (bytes32);

  function BRIDGE_ROLE() external view returns (bytes32);

  function ASSET_LISTING_ADMIN_ROLE() external view returns (bytes32);

  function hasRole(bytes32 role, address account) external view returns (bool);

  function grantRole(bytes32 role, address account) external;

  function revokeRole(bytes32 role, address account) external;

  function renounceRole(bytes32 role, address account) external;
}

interface IPoolView {
  function getReserveData(address asset) external view returns (DataTypes.ReserveDataLegacy memory);

  function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

interface IAaveOracleView {
  function getSourceOfAsset(address asset) external view returns (address);

  function BASE_CURRENCY() external view returns (address);

  function BASE_CURRENCY_UNIT() external view returns (uint256);
}

interface IDataProviderView {
  function getReserveConfigurationData(
    address asset
  )
    external
    view
    returns (uint256, uint256, uint256, uint256, uint256, bool, bool, bool, bool, bool);

  function getReserveCaps(
    address asset
  ) external view returns (uint256 borrowCap, uint256 supplyCap);

  function getLiquidationProtocolFee(address asset) external view returns (uint256);

  function getFlashLoanEnabled(address asset) external view returns (bool);
}

/**
 * @title DeployLighterDevnet
 * @notice Lumina core pool on Lighter EVM devnet (chain 19529), driven by the manifest
 * (`$LUMINA_MANIFEST`, see LighterManifest). Two phases, each one forge invocation, so the manifest
 * is checkpointed between them:
 *
 *   deployMarket()          2. the Aave v3 market batch (LighterMarketInput)
 *   configureAndHandover()  3/5. list WETH and USDC through the config engine (sets the AaveOracle
 *                              sources: WETH -> ETH LighterCorePriceSource, USDC -> FixedPriceSource)
 *                           4. LuminaPriceGuard as the PriceOracleSentinel
 *                           6. seed both reserves (non-withdrawable supply onBehalfOf 0x...dEaD)
 *                           7. Executor (owner Safe, 1-day delay, emergency path disabled)
 *                           8. verify the Safe and the Executor on-chain before any handover
 *                           9. hand every role to the Safe / Executor (grant first)
 *                          10. revoke the deployer
 *                          11. write every address, implementation and codehash to the manifest
 *
 * Step 1 (libraries) is `DeployLighterLibraries.s.sol`; FOUNDRY_LIBRARIES must link all eight.
 * Oracle contracts come from lumina-oracle `scripts/deploy-lighter-oracles.js` and are only read
 * here. Every step checks chain state first, so a re-run after success sends nothing.
 *
 * Role layout after the run (spec 3.4, CORE-02, plan.md S4a notes):
 *  - Executor: PoolAddressesProvider owner, ACL admin, ACL DEFAULT_ADMIN; POOL_ADMIN and RISK_ADMIN
 *    (config-engine payloads queued through the timelock); owner of the PoolAddressesProviderRegistry,
 *    EmissionManager, ProxyAdmin, WrappedTokenGateway and the market setup batch.
 *  - Safe: POOL_ADMIN, RISK_ADMIN, EMERGENCY_ADMIN, ASSET_LISTING_ADMIN; Executor owner; treasury.
 *  - Deployer: nothing.
 *
 * Usage (see lumina-monorepo harness/deploy/README.md):
 *   LUMINA_MANIFEST=reports/lighter/manifest.json FOUNDRY_LIBRARIES=... forge script \
 *     scripts/lighter/DeployLighterDevnet.s.sol:DeployLighterDevnet --sig 'deployMarket()' \
 *     --rpc-url lighter --broadcast --slow --ffi --sender <deployer> (--unlocked | --account <ks>)
 */
contract DeployLighterDevnet is LighterManifest, LighterMarketInput {
  address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
  uint256 internal constant EXECUTOR_DELAY = 1 days;
  uint256 internal constant SAFE_THRESHOLD = 2;
  string internal constant LOGIC = 'src/contracts/protocol/libraries/logic/';

  /// @dev Inputs read from the manifest.
  struct Inputs {
    address deployer;
    address safe;
    address keeper;
    address ethSource;
    address usdcSource;
    address guard;
    address dualUsdcWeth;
    address dualWethUsdc;
    uint256 wethMarketIndex; // index of WETH in markets.core
    uint256 usdcMarketIndex;
  }

  /// @dev Market contracts (from the batch report, or the manifest in phase 2).
  struct Market {
    address provider;
    address registry;
    address aclManager;
    address pool;
    address configurator;
    address aaveOracle;
    address dataProvider;
    address rateStrategy;
    address configEngine;
    address emissionManager;
    address proxyAdmin;
    address gateway;
    address setupBatch;
    address executor;
    address listingPayload;
  }

  Inputs internal _in;
  Market internal _m;

  // ============================================================================================
  // Phase 1: market batch
  // ============================================================================================

  function deployMarket() external {
    _loadManifest();
    _readInputs();
    _requireNoForgeLibraryDeploys(_in.deployer);
    _checkOracleContracts();

    if (_isDeployed('.contracts.poolAddressesProvider.address')) {
      _readMarket();
      require(
        IPriceGuardView(_in.guard).ADDRESSES_PROVIDER() == _m.provider,
        'guard ADDRESSES_PROVIDER is not the manifest PoolAddressesProvider'
      );
      console.log('phase 1: market already deployed at', _m.provider, '- nothing sent');
      return;
    }

    _requireLibrariesLinked();
    _requireCleanCheckout();

    (address setupBatch, address predictedProvider) = _predictProvider();
    uint256 firstBlock = block.number;
    MarketReport memory r = _deployBatch();

    require(r.poolAddressesProvider == predictedProvider, 'PoolAddressesProvider address');
    require(
      r.treasury == _in.safe && r.treasuryImplementation == address(0),
      'treasury is the Safe'
    );
    require(IOwnable(setupBatch).owner() == _in.deployer, 'setup batch address');

    _m.provider = r.poolAddressesProvider;
    _m.registry = r.poolAddressesProviderRegistry;
    _m.aclManager = r.aclManager;
    _m.pool = r.poolProxy;
    _m.configurator = r.poolConfiguratorProxy;
    _m.aaveOracle = r.aaveOracle;
    _m.dataProvider = r.protocolDataProvider;
    _m.rateStrategy = r.defaultInterestRateStrategy;
    _m.configEngine = r.configEngine;
    _m.emissionManager = r.emissionManager;
    _m.proxyAdmin = r.proxyAdmin;
    _m.gateway = r.wrappedTokenGateway;
    _m.setupBatch = setupBatch;

    _checkMarketWiring();
    _writePhase1(r, firstBlock);
    console.log('phase 1: market deployed, PoolAddressesProvider', _m.provider);
  }

  /**
   * @dev The guard is deployed (lumina-oracle) before the market and pins the
   * PoolAddressesProvider, which AaveV3SetupBatch creates as its first CREATE:
   * PAP = CREATE(CREATE(deployer, n), 1), n = the deployer nonce of this phase's first
   * transaction. Refuse before sending anything if the guard was built for another address (the
   * deployer sent a transaction in between).
   */
  function _predictProvider() internal view returns (address setupBatch, address predicted) {
    uint64 nonce = vm.getNonce(_in.deployer);
    setupBatch = vm.computeCreateAddress(_in.deployer, nonce);
    predicted = vm.computeCreateAddress(setupBatch, 1);
    address guardProvider = IPriceGuardView(_in.guard).ADDRESSES_PROVIDER();
    require(
      guardProvider == predicted,
      string.concat(
        'guard ADDRESSES_PROVIDER ',
        vm.toString(guardProvider),
        ' != the PoolAddressesProvider this run would create ',
        vm.toString(predicted),
        ' (deployer nonce ',
        vm.toString(uint256(nonce)),
        '): the deployer must send nothing between the oracle and the core deploy; reset the guard and dual oracles in the manifest and redeploy them'
      )
    );
  }

  function _deployBatch() internal returns (MarketReport memory r) {
    (
      Roles memory roles,
      MarketConfig memory config,
      DeployFlags memory flags,
      MarketReport memory empty
    ) = _getLighterMarketInput(
        _in.deployer,
        LighterExternalAddresses({
          safe: _in.safe,
          ethPriceSource: _in.ethSource,
          usdcPriceSource: _in.usdcSource,
          priceGuard: _in.guard
        })
      );
    vm.startBroadcast(_in.deployer);
    r = AaveV3BatchOrchestration.deployAaveV3(_in.deployer, roles, config, flags, empty);
    vm.stopBroadcast();
  }

  // ============================================================================================
  // Phase 2: configure, seed, Executor, handover
  // ============================================================================================

  function configureAndHandover() external {
    _loadManifest();
    _readInputs();
    _requireNoForgeLibraryDeploys(_in.deployer);
    _checkOracleContracts();
    _readMarket();
    _checkMarketWiring();
    require(
      IPriceGuardView(_in.guard).ADDRESSES_PROVIDER() == _m.provider,
      'guard ADDRESSES_PROVIDER is not the manifest PoolAddressesProvider'
    );
    _requireLibrariesLinked();

    if (_isDeployed('.contracts.executor.address')) {
      _m.executor = _address('.contracts.executor.address');
    }
    if (_isDeployed('.contracts.listingPayload.address')) {
      _m.listingPayload = _address('.contracts.listingPayload.address');
    }

    bool deployerActs = _deployerHasAnything();
    if (deployerActs) _requireCleanCheckout();

    _setSentinel();
    _listReserves();
    _seedReserves();
    _deployExecutor();
    _verifySafeAndExecutor();
    _handOver();
    _revokeDeployer();

    _assertFinalState();
    _writePhase2();
    console.log('phase 2: configured and handed over; Executor', _m.executor);
  }

  // --------------------------------------------------------------------------------- step 4

  function _setSentinel() internal {
    IProviderAdmin provider = IProviderAdmin(_m.provider);
    if (provider.getPriceOracleSentinel() == _in.guard) {
      console.log('step 4: sentinel already set');
      return;
    }
    require(
      provider.owner() == _in.deployer,
      'step 4: sentinel unset and the deployer no longer owns the provider'
    );
    vm.startBroadcast(_in.deployer);
    provider.setPriceOracleSentinel(_in.guard);
    vm.stopBroadcast();
    require(provider.getPriceOracleSentinel() == _in.guard, 'step 4: sentinel');
  }

  // ----------------------------------------------------------------------------- step 3 + 5

  function _listReserves() internal {
    IPoolView pool = IPoolView(_m.pool);
    bool wethListed = pool.getReserveData(LIGHTER_WETH9).aTokenAddress != address(0);
    bool usdcListed = pool.getReserveData(LIGHTER_USDC).aTokenAddress != address(0);
    if (wethListed && usdcListed) {
      console.log('step 5: reserves already listed');
    } else {
      require(!wethListed && !usdcListed, 'step 5: exactly one reserve is listed; fix by hand');
      IACL acl = IACL(_m.aclManager);
      require(
        acl.hasRole(acl.DEFAULT_ADMIN_ROLE(), _in.deployer),
        'step 5: reserves unlisted and the deployer is no longer ACL admin'
      );
      bytes32 poolAdmin = acl.POOL_ADMIN_ROLE();

      vm.startBroadcast(_in.deployer);
      if (_m.listingPayload == address(0)) {
        _m.listingPayload = address(
          new LighterListingPayload(
            IEngine(_m.configEngine),
            _in.deployer,
            _in.ethSource,
            _in.usdcSource
          )
        );
      }
      acl.grantRole(poolAdmin, _m.listingPayload);
      LighterListingPayload(_m.listingPayload).execute();
      acl.revokeRole(poolAdmin, _m.listingPayload);
      vm.stopBroadcast();
      require(!acl.hasRole(poolAdmin, _m.listingPayload), 'step 5: payload keeps POOL_ADMIN');
    }
    _checkReserves();
  }

  /// @dev Step 3 sources and the step 5 parameters, read back from the chain.
  function _checkReserves() internal view {
    IAaveOracleView oracle = IAaveOracleView(_m.aaveOracle);
    require(oracle.BASE_CURRENCY() == address(0), 'AaveOracle base currency is not USD');
    require(oracle.BASE_CURRENCY_UNIT() == 1e8, 'AaveOracle base currency unit is not 1e8');
    require(oracle.getSourceOfAsset(LIGHTER_WETH9) == _in.ethSource, 'AaveOracle WETH source');
    require(oracle.getSourceOfAsset(LIGHTER_USDC) == _in.usdcSource, 'AaveOracle USDC source');

    LighterReserveParams[] memory params = _lighterReserveParams();
    for (uint256 i = 0; i < params.length; i++) _checkReserve(params[i]);
  }

  struct ReserveConfig {
    uint256 decimals;
    uint256 ltv;
    uint256 lt;
    uint256 lb;
    uint256 rf;
    bool collateral;
    bool borrowing;
    bool active;
    bool frozen;
  }

  /// @dev getReserveConfigurationData returns 10 static words; decoded as an array (stack depth).
  function _reserveConfig(address asset) internal view returns (ReserveConfig memory c) {
    (bool ok, bytes memory ret) = _m.dataProvider.staticcall(
      abi.encodeCall(IDataProviderView.getReserveConfigurationData, (asset))
    );
    require(ok && ret.length == 320, 'getReserveConfigurationData');
    uint256[10] memory w = abi.decode(ret, (uint256[10]));
    c.decimals = w[0];
    c.ltv = w[1];
    c.lt = w[2];
    c.lb = w[3];
    c.rf = w[4];
    c.collateral = w[5] == 1;
    c.borrowing = w[6] == 1;
    c.active = w[8] == 1;
    c.frozen = w[9] == 1;
  }

  function _checkReserve(LighterReserveParams memory p) internal view {
    ReserveConfig memory c = _reserveConfig(p.asset);
    require(c.decimals == p.decimals, string.concat(p.symbol, ': decimals'));
    require(c.ltv == p.ltv && c.lt == p.liqThreshold, string.concat(p.symbol, ': ltv / threshold'));
    require(c.lb == 100_00 + p.liqBonus, string.concat(p.symbol, ': liquidation bonus'));
    require(c.rf == p.reserveFactor, string.concat(p.symbol, ': reserve factor'));
    require(
      c.collateral && c.borrowing && c.active && !c.frozen,
      string.concat(p.symbol, ': flags')
    );
    IDataProviderView dp = IDataProviderView(_m.dataProvider);
    require(
      dp.getLiquidationProtocolFee(p.asset) == p.liqProtocolFee,
      string.concat(p.symbol, ': liquidation protocol fee')
    );
    require(!dp.getFlashLoanEnabled(p.asset), string.concat(p.symbol, ': flash loans enabled'));
    DataTypes.ReserveDataLegacy memory rd = IPoolView(_m.pool).getReserveData(p.asset);
    require(
      rd.interestRateStrategyAddress == _m.rateStrategy,
      string.concat(p.symbol, ': rate strategy')
    );
    require(
      IAToken(rd.aTokenAddress).RESERVE_TREASURY_ADDRESS() == _in.safe,
      string.concat(p.symbol, ': treasury is not the Safe')
    );
  }

  // --------------------------------------------------------------------------------- step 6

  function _seedReserves() internal {
    _seed(LIGHTER_WETH9, _in.wethMarketIndex);
    _seed(LIGHTER_USDC, _in.usdcMarketIndex);
  }

  function _seed(address asset, uint256 marketIndex) internal {
    uint256 amount = _uint(_market(marketIndex, 'seedAmount'));
    require(amount > 0, 'step 6: seedAmount must be positive');
    address aToken = IPoolView(_m.pool).getReserveData(asset).aTokenAddress;
    uint256 seeded = IERC20(aToken).balanceOf(DEAD);
    if (seeded > 0) {
      console.log('step 6: already seeded', asset, seeded);
      return;
    }
    require(
      IERC20(asset).balanceOf(_in.deployer) >= amount,
      string.concat('step 6: the deployer holds less than the seed of ', vm.toString(asset))
    );
    vm.startBroadcast(_in.deployer);
    IERC20(asset).approve(_m.pool, amount);
    IPoolView(_m.pool).supply(asset, amount, DEAD, 0);
    vm.stopBroadcast();
    require(IERC20(aToken).balanceOf(DEAD) >= amount - 1, 'step 6: seed not credited');
    require(IERC20(asset).allowance(_in.deployer, _m.pool) == 0, 'step 6: allowance left');
  }

  // --------------------------------------------------------------------------------- step 7

  function _deployExecutor() internal {
    if (_m.executor != address(0)) {
      console.log('step 7: Executor already deployed', _m.executor);
      return;
    }
    vm.startBroadcast(_in.deployer);
    _m.executor = address(new Executor(_in.safe, EXECUTOR_DELAY));
    vm.stopBroadcast();
  }

  // --------------------------------------------------------------------------------- step 8

  /// @dev Before any handover: a wrong Executor owner or a wrong Safe would lock governance.
  function _verifySafeAndExecutor() internal {
    require(_in.safe.code.length > 0, 'step 8: no code at the Safe');
    address[] memory owners = ISafeView(_in.safe).getOwners();
    address[] memory expected = vm.parseJsonAddressArray(_json, '.safe.owners');
    require(owners.length == expected.length, 'step 8: Safe owner count');
    for (uint256 i = 0; i < expected.length; i++) {
      bool found;
      for (uint256 j = 0; j < owners.length; j++) found = found || owners[j] == expected[i];
      require(found, string.concat('step 8: Safe lacks owner ', vm.toString(expected[i])));
    }
    require(
      ISafeView(_in.safe).getThreshold() == SAFE_THRESHOLD &&
        _uint('.safe.threshold') == SAFE_THRESHOLD,
      'step 8: Safe threshold is not 2'
    );

    Executor executor = Executor(_m.executor);
    require(executor.owner() == _in.safe, 'step 8: Executor owner is not the Safe');
    require(executor.pendingOwner() == address(0), 'step 8: Executor has a pending owner');
    require(executor.delay() == EXECUTOR_DELAY, 'step 8: Executor delay');
    require(!executor.emergencyEnabled(), 'step 8: Executor emergency path enabled');

    // Simulation only (reverted, never broadcast): the Safe can queue and cancel on the Executor.
    // The harness then proves it with real 2-of-3 Safe transactions.
    uint256 snapshot = vm.snapshotState();
    bytes memory data = abi.encodeCall(Executor.setDelay, (EXECUTOR_DELAY));
    vm.prank(_in.safe);
    (bytes32 txHash, uint256 eta) = executor.queueTransaction(address(executor), data);
    require(executor.isQueued(txHash), 'step 8: Safe cannot queue on the Executor');
    vm.prank(_in.safe);
    executor.cancelTransaction(address(executor), data, eta);
    require(!executor.isQueued(txHash), 'step 8: Safe cannot cancel on the Executor');
    vm.revertToState(snapshot);
  }

  // --------------------------------------------------------------------------------- step 9

  function _handOver() internal {
    IACL acl = IACL(_m.aclManager);
    address exec = _m.executor;
    address safe = _in.safe;

    vm.startBroadcast(_in.deployer);
    // ACL: grant every target role before anything is revoked.
    _grant(acl, acl.DEFAULT_ADMIN_ROLE(), exec);
    _grant(acl, acl.POOL_ADMIN_ROLE(), safe);
    _grant(acl, acl.POOL_ADMIN_ROLE(), exec);
    _grant(acl, acl.RISK_ADMIN_ROLE(), safe);
    _grant(acl, acl.RISK_ADMIN_ROLE(), exec);
    _grant(acl, acl.EMERGENCY_ADMIN_ROLE(), safe);
    _grant(acl, acl.ASSET_LISTING_ADMIN_ROLE(), safe);

    // PoolAddressesProvider: ACL admin first (owner-only), then ownership.
    IProviderAdmin provider = IProviderAdmin(_m.provider);
    if (provider.getACLAdmin() != exec) provider.setACLAdmin(exec);
    _transferOwnership(_m.provider, exec);
    _transferOwnership(_m.registry, exec);
    _transferOwnership(_m.emissionManager, exec);
    _transferOwnership(_m.proxyAdmin, exec);
    _transferOwnership(_m.gateway, exec);
    _transferOwnership(_m.setupBatch, exec);
    vm.stopBroadcast();
  }

  function _grant(IACL acl, bytes32 role, address account) internal {
    if (!acl.hasRole(role, account)) {
      require(
        acl.hasRole(acl.DEFAULT_ADMIN_ROLE(), _in.deployer),
        'step 9: a role is missing and the deployer is no longer ACL admin'
      );
      acl.grantRole(role, account);
    }
  }

  function _transferOwnership(address target, address newOwner) internal {
    address current = IOwnable(target).owner();
    if (current == newOwner) return;
    require(
      current == _in.deployer,
      string.concat('step 9: unexpected owner of ', vm.toString(target))
    );
    IOwnable(target).transferOwnership(newOwner);
  }

  // -------------------------------------------------------------------------------- step 10

  function _revokeDeployer() internal {
    IACL acl = IACL(_m.aclManager);
    bytes32 admin = acl.DEFAULT_ADMIN_ROLE();
    bytes32[6] memory others = [
      acl.POOL_ADMIN_ROLE(),
      acl.EMERGENCY_ADMIN_ROLE(),
      acl.RISK_ADMIN_ROLE(),
      acl.FLASH_BORROWER_ROLE(),
      acl.BRIDGE_ROLE(),
      acl.ASSET_LISTING_ADMIN_ROLE()
    ];
    bool any = acl.hasRole(admin, _in.deployer);
    for (uint256 i = 0; i < others.length; i++) any = any || acl.hasRole(others[i], _in.deployer);
    if (!any) {
      console.log('step 10: the deployer holds no ACL role');
      return;
    }
    // The Executor must already be DEFAULT_ADMIN, so no role is left without an admin.
    require(acl.hasRole(admin, _m.executor), 'step 10: Executor is not DEFAULT_ADMIN yet');
    vm.startBroadcast(_in.deployer);
    for (uint256 i = 0; i < others.length; i++) {
      if (acl.hasRole(others[i], _in.deployer)) acl.revokeRole(others[i], _in.deployer);
    }
    if (acl.hasRole(admin, _in.deployer)) acl.renounceRole(admin, _in.deployer);
    vm.stopBroadcast();
  }

  function _deployerHasAnything() internal view returns (bool) {
    if (!_isDeployed('.contracts.executor.address')) return true;
    IACL acl = IACL(_m.aclManager);
    if (acl.hasRole(acl.DEFAULT_ADMIN_ROLE(), _in.deployer)) return true;
    return IOwnable(_m.provider).owner() == _in.deployer;
  }

  // ------------------------------------------------------------------------- final checks

  function _assertFinalState() internal view {
    IACL acl = IACL(_m.aclManager);
    address d = _in.deployer;
    address exec = _m.executor;
    address safe = _in.safe;
    bytes32[7] memory all = [
      acl.DEFAULT_ADMIN_ROLE(),
      acl.POOL_ADMIN_ROLE(),
      acl.EMERGENCY_ADMIN_ROLE(),
      acl.RISK_ADMIN_ROLE(),
      acl.FLASH_BORROWER_ROLE(),
      acl.BRIDGE_ROLE(),
      acl.ASSET_LISTING_ADMIN_ROLE()
    ];
    for (uint256 i = 0; i < all.length; i++) {
      require(!acl.hasRole(all[i], d), 'final: the deployer holds an ACL role');
    }
    require(acl.hasRole(all[0], exec), 'final: Executor DEFAULT_ADMIN');
    require(!acl.hasRole(all[0], safe), 'final: Safe must not be DEFAULT_ADMIN');
    require(acl.hasRole(all[1], safe) && acl.hasRole(all[1], exec), 'final: POOL_ADMIN');
    require(acl.hasRole(all[2], safe) && !acl.hasRole(all[2], exec), 'final: EMERGENCY_ADMIN');
    require(acl.hasRole(all[3], safe) && acl.hasRole(all[3], exec), 'final: RISK_ADMIN');
    require(acl.hasRole(all[6], safe) && !acl.hasRole(all[6], exec), 'final: ASSET_LISTING_ADMIN');

    IProviderAdmin provider = IProviderAdmin(_m.provider);
    require(provider.owner() == exec, 'final: provider owner');
    require(provider.getACLAdmin() == exec, 'final: ACL admin');
    require(provider.getPriceOracleSentinel() == _in.guard, 'final: sentinel');
    require(IOwnable(_m.registry).owner() == exec, 'final: registry owner');
    require(IOwnable(_m.emissionManager).owner() == exec, 'final: EmissionManager owner');
    require(IOwnable(_m.proxyAdmin).owner() == exec, 'final: ProxyAdmin owner');
    require(IOwnable(_m.gateway).owner() == exec, 'final: WrappedTokenGateway owner');
    require(IOwnable(_m.setupBatch).owner() == exec, 'final: setup batch owner');
    require(Executor(exec).owner() == safe, 'final: Executor owner');

    // Wiring invariant (plan.md): one LighterCorePriceSource behind guard market 0, the AaveOracle
    // WETH source and the WETH side of both dual oracles.
    (bool guarded, address guardSource, , , , , ) = IPriceGuardView(_in.guard).getMarket(0);
    require(guarded && guardSource == _in.ethSource, 'final: guard market 0 source');
    require(
      IAaveOracleView(_m.aaveOracle).getSourceOfAsset(LIGHTER_WETH9) == _in.ethSource,
      'final: AaveOracle WETH source'
    );
    require(
      IDualOracleView(_in.dualUsdcWeth).COLLATERAL_PRICE_SOURCE() == _in.ethSource &&
        IDualOracleView(_in.dualWethUsdc).ASSET_PRICE_SOURCE() == _in.ethSource,
      'final: dual oracle ETH source'
    );
    for (uint256 i = 0; i < 2; i++) {
      address asset = i == 0 ? LIGHTER_WETH9 : LIGHTER_USDC;
      address aToken = IPoolView(_m.pool).getReserveData(asset).aTokenAddress;
      require(IERC20(aToken).balanceOf(DEAD) > 0, 'final: reserve not seeded');
    }
  }

  // ============================================================================================
  // Manifest: inputs
  // ============================================================================================

  function _readInputs() internal {
    _in.deployer = _requireAddress('.deployer');
    _in.safe = _requireDeployed('.safe.address');
    _in.keeper = _requireAddress('.bots.keeper');
    require(_requireAddress('.assets.WETH.address') == LIGHTER_WETH9, 'manifest: WETH address');
    require(_requireAddress('.assets.USDC.address') == LIGHTER_USDC, 'manifest: USDC address');

    _in.ethSource = _requireDeployed('.contracts.ethPriceSource.address');
    _in.usdcSource = _requireDeployed('.contracts.usdcPriceSource.address');
    _in.guard = _requireDeployed('.contracts.priceGuard.address');
    _in.dualUsdcWeth = _requireDeployed('.contracts.dualOracleUsdcWeth.address');
    _in.dualWethUsdc = _requireDeployed('.contracts.dualOracleWethUsdc.address');
    require(
      _address('.oracle.coreSources[0].address') == _in.ethSource &&
        _address('.oracle.coreSources[0].asset') == LIGHTER_WETH9 &&
        _uint('.oracle.coreSources[0].marketId') == 0,
      'manifest: oracle.coreSources[0] must be the ETH market-0 source of WETH'
    );
    require(
      _address('.oracle.fixedSources[0].address') == _in.usdcSource &&
        _address('.oracle.fixedSources[0].asset') == LIGHTER_USDC,
      'manifest: oracle.fixedSources[0] must be the USDC fixed source'
    );

    // markets.core holds WETH and USDC (any order) with the LighterMarketInput risk parameters.
    LighterReserveParams[] memory params = _lighterReserveParams();
    for (uint256 i = 0; i < 2; i++) {
      address asset = _requireAddress(_market(i, 'asset'));
      if (asset == LIGHTER_WETH9) _in.wethMarketIndex = i;
      else if (asset == LIGHTER_USDC) _in.usdcMarketIndex = i;
      else revert('manifest: markets.core must be WETH and USDC');
      LighterReserveParams memory p = asset == LIGHTER_WETH9 ? params[0] : params[1];
      require(
        _uint(_market(i, 'ltvBps')) == p.ltv &&
          _uint(_market(i, 'liquidationThresholdBps')) == p.liqThreshold &&
          _uint(_market(i, 'liquidationBonusBps')) == p.liqBonus &&
          _uint(_market(i, 'reserveFactorBps')) == p.reserveFactor,
        string.concat(
          'manifest: markets.core ',
          p.symbol,
          ' risk parameters differ from LighterMarketInput'
        )
      );
    }
    require(_in.wethMarketIndex != _in.usdcMarketIndex, 'manifest: markets.core');
  }

  function _market(uint256 i, string memory field) internal pure returns (string memory) {
    return string.concat('.markets.core[', vm.toString(i), '].', field);
  }

  /// @dev The oracle contracts from lumina-oracle: parameters and wiring, as far as they exist now.
  function _checkOracleContracts() internal view {
    ILighterCoreSourceView eth = ILighterCoreSourceView(_in.ethSource);
    require(eth.MARKET_ID() == 0, 'ETH source: MARKET_ID != 0');
    require(
      eth.PRICE_DECIMALS() == _uint('.oracle.coreSources[0].priceDecimals') &&
        eth.MIN_PRICE() == _uint('.oracle.coreSources[0].minPrice8') &&
        eth.MAX_PRICE() == _uint('.oracle.coreSources[0].maxPrice8'),
      'ETH source: parameters differ from the manifest'
    );
    require(eth.latestAnswer() > 0, 'ETH source: no price');
    require(IFixedSourceView(_in.usdcSource).PRICE() == 1e8, 'USDC source: price != 1e8');

    IPriceGuardView guard = IPriceGuardView(_in.guard);
    require(guard.guardian() == _in.safe, 'guard: guardian is not the Safe');
    require(guard.pendingGuardian() == address(0), 'guard: pending guardian');
    require(guard.keeper() == _in.keeper, 'guard: keeper is not bots.keeper');
    require(
      guard.maxRefAge() == _uint('.oracle.guard.maxRefAgeSec') &&
        guard.maxDeviationBps() == _uint('.oracle.guard.maxDeviationBps') &&
        guard.maxCorePriceAge() == _uint('.oracle.guard.maxCorePriceAgeSec'),
      'guard: parameters differ from the manifest'
    );
    (bool guarded, address source, , , , , ) = guard.getMarket(0);
    require(
      guarded && source == _in.ethSource,
      'guard: market 0 is not guarded with the ETH source (the Safe adds it before the core deploy)'
    );
    uint16[] memory ids = guard.marketIds();
    require(ids.length == 1 && ids[0] == 0, 'guard: marketIds must be [0]');

    _checkDual(_in.dualUsdcWeth, LIGHTER_USDC, LIGHTER_WETH9, _in.usdcSource, _in.ethSource);
    _checkDual(_in.dualWethUsdc, LIGHTER_WETH9, LIGHTER_USDC, _in.ethSource, _in.usdcSource);
  }

  function _checkDual(
    address dual,
    address asset,
    address collateral,
    address assetSource,
    address collateralSource
  ) internal view {
    IDualOracleView d = IDualOracleView(dual);
    require(
      d.ASSET() == asset &&
        d.COLLATERAL() == collateral &&
        d.ASSET_PRICE_SOURCE() == assetSource &&
        d.COLLATERAL_PRICE_SOURCE() == collateralSource &&
        d.GUARD() == _in.guard,
      string.concat('dual oracle wiring: ', vm.toString(dual))
    );
  }

  /// @dev FOUNDRY_LIBRARIES must link the manifest libraries into Pool and PoolConfigurator.
  function _requireLibrariesLinked() internal view {
    bytes memory pool = type(PoolInstance).creationCode;
    string[7] memory poolLibs = [
      'borrowLogic',
      'bridgeLogic',
      'eModeLogic',
      'flashLoanLogic',
      'liquidationLogic',
      'poolLogic',
      'supplyLogic'
    ];
    for (uint256 i = 0; i < poolLibs.length; i++) {
      address lib = _requireDeployed(string.concat('.contracts.', poolLibs[i], '.address'));
      require(
        _containsAddress(pool, lib),
        string.concat('PoolInstance is not linked to ', poolLibs[i], ': set FOUNDRY_LIBRARIES')
      );
    }
    address configuratorLogic = _requireDeployed('.contracts.configuratorLogic.address');
    require(
      _containsAddress(type(PoolConfiguratorInstance).creationCode, configuratorLogic),
      'PoolConfiguratorInstance is not linked to configuratorLogic: set FOUNDRY_LIBRARIES'
    );
  }

  // ============================================================================================
  // Manifest: market
  // ============================================================================================

  function _readMarket() internal {
    _m.provider = _requireDeployed('.contracts.poolAddressesProvider.address');
    _m.registry = _requireDeployed('.contracts.poolAddressesProviderRegistry.address');
    _m.aclManager = _requireDeployed('.contracts.aclManager.address');
    _m.pool = _requireDeployed('.contracts.pool.address');
    _m.configurator = _requireDeployed('.contracts.poolConfigurator.address');
    _m.aaveOracle = _requireDeployed('.contracts.aaveOracle.address');
    _m.dataProvider = _requireDeployed('.contracts.poolDataProvider.address');
    _m.rateStrategy = _requireDeployed('.contracts.reserveInterestRateStrategy.address');
    _m.configEngine = _requireDeployed('.contracts.configEngine.address');
    _m.emissionManager = _requireDeployed('.contracts.emissionManager.address');
    _m.proxyAdmin = _requireDeployed('.contracts.proxyAdmin.address');
    _m.gateway = _requireDeployed('.contracts.wrappedTokenGateway.address');
    _m.setupBatch = _requireDeployed('.contracts.marketSetupBatch.address');
  }

  function _checkMarketWiring() internal view {
    IProviderAdmin p = IProviderAdmin(_m.provider);
    require(p.getPool() == _m.pool, 'provider: pool');
    require(p.getPoolConfigurator() == _m.configurator, 'provider: configurator');
    require(p.getACLManager() == _m.aclManager, 'provider: ACL manager');
    require(p.getPriceOracle() == _m.aaveOracle, 'provider: price oracle');
    require(p.getPoolDataProvider() == _m.dataProvider, 'provider: data provider');
    AaveV3ConfigEngine engine = AaveV3ConfigEngine(_m.configEngine);
    require(
      address(engine.POOL()) == _m.pool &&
        address(engine.POOL_CONFIGURATOR()) == _m.configurator &&
        address(engine.ORACLE()) == _m.aaveOracle &&
        engine.COLLECTOR() == _in.safe &&
        engine.DEFAULT_INTEREST_RATE_STRATEGY() == _m.rateStrategy,
      'config engine wiring'
    );
  }

  function _writePhase1(MarketReport memory r, uint256 firstBlock) internal {
    _write('.assets.WETH.codehash', _jHash(LIGHTER_WETH9.codehash));
    _write('.assets.USDC.codehash', _jHash(LIGHTER_USDC.codehash));
    _writeContract('poolAddressesProvider', r.poolAddressesProvider, 'PoolAddressesProvider');
    _writeContract(
      'poolAddressesProviderRegistry',
      r.poolAddressesProviderRegistry,
      'PoolAddressesProviderRegistry'
    );
    _writeContract('aclManager', r.aclManager, 'ACLManager');
    _write('.contracts.pool', _proxyJson(r.poolProxy, PROXY, _poolImplementationJson(r)));
    _write(
      '.contracts.poolConfigurator',
      _proxyJson(r.poolConfiguratorProxy, PROXY, _configuratorImplementationJson(r))
    );
    _writeContract('aaveOracle', r.aaveOracle, 'AaveOracle');
    _writeContract('poolDataProvider', r.protocolDataProvider, 'AaveProtocolDataProvider');
    _writeContract(
      'reserveInterestRateStrategy',
      r.defaultInterestRateStrategy,
      'DefaultReserveInterestRateStrategyV2'
    );
    _write(
      '.contracts.rewardsController',
      _proxyJson(
        r.rewardsControllerProxy,
        PROXY,
        _contractJson(_implementationOf(r.rewardsControllerProxy), 'RewardsController')
      )
    );
    require(
      _implementationOf(r.rewardsControllerProxy) == r.rewardsControllerImplementation,
      'rewards controller implementation'
    );
    _writeContract('emissionManager', r.emissionManager, 'EmissionManager');
    _writeContract('proxyAdmin', r.proxyAdmin, 'ProxyAdmin');
    _writeContract('wrappedTokenGateway', r.wrappedTokenGateway, 'WrappedTokenGatewayV3');
    _writeContract('uiPoolDataProvider', r.uiPoolDataProvider, 'UiPoolDataProviderV3');
    _writeContract(
      'uiIncentiveDataProvider',
      r.uiIncentiveDataProvider,
      'UiIncentiveDataProviderV3'
    );
    _writeContract('walletBalanceProvider', r.walletBalanceProvider, 'WalletBalanceProvider');
    _writeConfigEngine(r.configEngine);
    _write(
      '.contracts.staticATokenFactory',
      _proxyJson(
        r.staticATokenFactoryProxy,
        'TransparentUpgradeableProxy',
        _contractJson(r.staticATokenFactoryImplementation, 'StataTokenFactory')
      )
    );
    require(
      _implementationOf(r.staticATokenFactoryProxy) == r.staticATokenFactoryImplementation,
      'static aToken factory implementation'
    );
    _writeContract('staticATokenImplementation', r.staticATokenImplementation, 'StataTokenV2');
    _writeContract('transparentProxyFactory', r.transparentProxyFactory, 'TransparentProxyFactory');
    _writeContract('marketSetupBatch', _m.setupBatch, 'AaveV3SetupBatch');
    if (_isNull('.deploymentBlock')) _write('.deploymentBlock', _jUint(firstBlock));
    _writeSourceCommit();
  }

  string internal constant PROXY = 'InitializableImmutableAdminUpgradeabilityProxy';

  function _poolImplementationJson(MarketReport memory r) internal view returns (string memory) {
    address impl = _implementationOf(r.poolProxy);
    require(impl == r.poolImplementation, 'pool implementation');
    string memory libs = string.concat(
      '{',
      _libEntry('BorrowLogic', 'borrowLogic'),
      ',',
      _libEntry('BridgeLogic', 'bridgeLogic'),
      ',',
      _libEntry('EModeLogic', 'eModeLogic'),
      ',',
      _libEntry('FlashLoanLogic', 'flashLoanLogic'),
      ',',
      _libEntry('LiquidationLogic', 'liquidationLogic'),
      ',',
      _libEntry('PoolLogic', 'poolLogic'),
      ',',
      _libEntry('SupplyLogic', 'supplyLogic'),
      '}'
    );
    return _contractJsonWithLibraries(impl, 'PoolInstance', libs);
  }

  function _configuratorImplementationJson(
    MarketReport memory r
  ) internal view returns (string memory) {
    address impl = _implementationOf(r.poolConfiguratorProxy);
    require(impl == r.poolConfiguratorImplementation, 'configurator implementation');
    string memory libs = string.concat(
      '{',
      _libEntry('ConfiguratorLogic', 'configuratorLogic'),
      '}'
    );
    return _contractJsonWithLibraries(impl, 'PoolConfiguratorInstance', libs);
  }

  function _libEntry(string memory name, string memory key) internal view returns (string memory) {
    return
      string.concat(
        _q(string.concat(LOGIC, name, '.sol:', name)),
        ':',
        _jAddress(_requireDeployed(string.concat('.contracts.', key, '.address')))
      );
  }

  /// @dev The config engine and the engine libraries it delegatecalls into (payload review).
  function _writeConfigEngine(address configEngine) internal {
    AaveV3ConfigEngine engine = AaveV3ConfigEngine(configEngine);
    _writeContract('configEngine', configEngine, 'AaveV3ConfigEngine');
    _writeContract('listingEngine', engine.LISTING_ENGINE(), 'ListingEngine');
    _writeContract('eModeEngine', engine.EMODE_ENGINE(), 'EModeEngine');
    _writeContract('borrowEngine', engine.BORROW_ENGINE(), 'BorrowEngine');
    _writeContract('collateralEngine', engine.COLLATERAL_ENGINE(), 'CollateralEngine');
    _writeContract('priceFeedEngine', engine.PRICE_FEED_ENGINE(), 'PriceFeedEngine');
    _writeContract('rateEngine', engine.RATE_ENGINE(), 'RateEngine');
    _writeContract('capsEngine', engine.CAPS_ENGINE(), 'CapsEngine');
  }

  function _writePhase2() internal {
    _writeContract('executor', _m.executor, 'Executor');
    if (_m.listingPayload != address(0)) {
      _writeContract('listingPayload', _m.listingPayload, 'LighterListingPayload');
    }
    _writeReserveTokens(LIGHTER_WETH9, 'WETH');
    _writeReserveTokens(LIGHTER_USDC, 'USDC');
    _write('.markets.core', _marketsJson());
    _write('.roles.core', _coreRolesJson());
    _write('.roles.guard.guardian', _jAddress(_in.safe));
    _write('.roles.guard.keeper', _jAddress(_in.keeper));
  }

  function _writeReserveTokens(address asset, string memory symbol) internal {
    DataTypes.ReserveDataLegacy memory rd = IPoolView(_m.pool).getReserveData(asset);
    _write(
      string.concat('.contracts.aToken', symbol),
      _proxyJson(
        rd.aTokenAddress,
        PROXY,
        _contractJson(_implementationOf(rd.aTokenAddress), 'ATokenInstance')
      )
    );
    _write(
      string.concat('.contracts.variableDebtToken', symbol),
      _proxyJson(
        rd.variableDebtTokenAddress,
        PROXY,
        _contractJson(_implementationOf(rd.variableDebtTokenAddress), 'VariableDebtTokenInstance')
      )
    );
  }

  function _marketsJson() internal view returns (string memory) {
    string[2] memory entries;
    entries[_in.wethMarketIndex] = _marketJson(
      _in.wethMarketIndex,
      _lighterReserveParams()[0],
      _in.ethSource
    );
    entries[_in.usdcMarketIndex] = _marketJson(
      _in.usdcMarketIndex,
      _lighterReserveParams()[1],
      _in.usdcSource
    );
    return string.concat('[', entries[0], ',', entries[1], ']');
  }

  /// @dev One markets.core entry with the on-chain values (read back, not the input constants).
  function _marketJson(
    uint256 index,
    LighterReserveParams memory p,
    address source
  ) internal view returns (string memory) {
    DataTypes.ReserveDataLegacy memory rd = IPoolView(_m.pool).getReserveData(p.asset);
    string memory head = string.concat(
      '{"symbol":',
      _q(p.symbol),
      ',"asset":',
      _jAddress(p.asset),
      ',"aToken":',
      _jAddress(rd.aTokenAddress),
      ',"variableDebtToken":',
      _jAddress(rd.variableDebtTokenAddress),
      ',"priceSource":',
      _jAddress(source)
    );
    return string.concat(head, _marketRiskJson(index, p.asset), _marketParamsJson(p), '}');
  }

  function _marketRiskJson(uint256 index, address asset) internal view returns (string memory) {
    ReserveConfig memory c = _reserveConfig(asset);
    (uint256 borrowCap, uint256 supplyCap) = IDataProviderView(_m.dataProvider).getReserveCaps(
      asset
    );
    return
      string.concat(
        ',"ltvBps":',
        _jUint(c.ltv),
        ',"liquidationThresholdBps":',
        _jUint(c.lt),
        ',"liquidationBonusBps":',
        _jUint(c.lb - 100_00),
        ',"reserveFactorBps":',
        _jUint(c.rf),
        ',"supplyCap":',
        _jUint(supplyCap),
        ',"borrowCap":',
        _jUint(borrowCap),
        ',"seedAmount":',
        _jUintString(_uint(_market(index, 'seedAmount')))
      );
  }

  function _marketParamsJson(LighterReserveParams memory p) internal view returns (string memory) {
    IDataProviderView dp = IDataProviderView(_m.dataProvider);
    return
      string.concat(
        ',"params":{"liquidationProtocolFeeBps":',
        _jUint(dp.getLiquidationProtocolFee(p.asset)),
        ',"flashloanable":',
        _jBool(dp.getFlashLoanEnabled(p.asset)),
        ',"optimalUsageRatioBps":',
        _jUint(p.rates.optimalUsageRatio),
        ',"baseVariableBorrowRateBps":',
        _jUint(p.rates.baseVariableBorrowRate),
        ',"variableRateSlope1Bps":',
        _jUint(p.rates.variableRateSlope1),
        ',"variableRateSlope2Bps":',
        _jUint(p.rates.variableRateSlope2),
        ',"seedHolder":',
        _jAddress(DEAD),
        '}'
      );
  }

  function _coreRolesJson() internal view returns (string memory) {
    address exec = _m.executor;
    address safe = _in.safe;
    address[] memory one = new address[](1);
    address[] memory two = new address[](2);
    address[] memory none = new address[](0);
    one[0] = exec;
    string memory defaultAdmin = _jAddressArray(one);
    two[0] = safe;
    two[1] = exec;
    string memory safeAndExec = _jAddressArray(two);
    one[0] = safe;
    string memory safeOnly = _jAddressArray(one);
    string memory acl = string.concat(
      '{"DEFAULT_ADMIN":',
      defaultAdmin,
      ',"POOL_ADMIN":',
      safeAndExec,
      ',"EMERGENCY_ADMIN":',
      safeOnly,
      ',"RISK_ADMIN":',
      safeAndExec,
      ',"FLASH_BORROWER":',
      _jAddressArray(none),
      ',"BRIDGE":',
      _jAddressArray(none),
      ',"ASSET_LISTING_ADMIN":',
      safeOnly,
      '}'
    );
    return
      string.concat(
        '{"poolAddressesProviderOwner":',
        _jAddress(exec),
        ',"aclAdmin":',
        _jAddress(exec),
        ',"acl":',
        acl,
        ',"executorOwner":',
        _jAddress(safe),
        ',"executorEmergencyEnabled":false,"executorDelaySec":',
        _jUint(EXECUTOR_DELAY),
        ',"treasury":',
        _jAddress(safe),
        '}'
      );
  }
}
