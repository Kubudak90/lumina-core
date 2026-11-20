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
import {IDefaultInterestRateStrategyV2} from '../../src/contracts/interfaces/IDefaultInterestRateStrategyV2.sol';

interface ILighterCoreSourceView {
  function MARKET_ID() external view returns (uint16);

  function PRICE_DECIMALS() external view returns (uint8);

  function MIN_PRICE() external view returns (uint256);

  function MAX_PRICE() external view returns (uint256);

  function latestAnswer() external view returns (int256);
}

interface IFixedSourceView {
  function PRICE() external view returns (uint256);
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

  function getModulesPaginated(
    address start,
    uint256 pageSize
  ) external view returns (address[] memory array, address next);

  function VERSION() external view returns (string memory);
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

interface IAaveOracleAdmin {
  function getSourceOfAsset(address asset) external view returns (address);

  function setAssetSources(address[] calldata assets, address[] calldata sources) external;

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

interface IImmutableAdminProxy {
  function admin() external returns (address);
}

/**
 * @title DeployLighterDevnet
 * @notice Lumina core pool on Lighter EVM devnet (chain 19529), driven by the manifest
 * (`$LUMINA_MANIFEST`, see LighterManifest). Deploy order (plan.md, S4c decisions, amended after
 * the Codex r1 review); each phase is one forge invocation and the caller publishes the manifest
 * after each, so every phase starts from a recorded checkpoint:
 *
 *   (lumina-oracle phase 1: LighterCorePriceSource, FixedPriceSource)
 *   deployMarket()     the Aave v3 market batch (LighterMarketInput); AaveOracle sources
 *                      WETH -> ETH LighterCorePriceSource, USDC -> FixedPriceSource. No reserve.
 *   (lumina-oracle phase 2: LuminaPriceGuard with the real PoolAddressesProvider, dual oracles;
 *    the Safe adds guard market 0)
 *   prepareListing()   LuminaPriceGuard as the PriceOracleSentinel; the listing payload, recorded
 *                      in the manifest before it gets any role
 *   listAndSeed()      revoke any role the payload still holds; fund it with the seeds; grant it
 *                      POOL_ADMIN; one transaction lists both reserves, supplies the seeds
 *                      onBehalfOf 0x...dEaD and renounces the role. Launch caps and rates checked.
 *                      A rerun tops up a seed below the manifest amount.
 *   deployExecutor()   Executor (owner Safe, 1-day delay, emergency path disabled)
 *   (the Safe queues and cancels a no-op on the Executor, 2 of 3 owners; the caller records both
 *    transactions in the deploy checkpoint, `$LUMINA_DEPLOY_CHECKPOINT`)
 *   handOver()         verify the Safe (owners, threshold, singleton, fallback handler, no module,
 *                      no guard) and the probe receipts; grant every role to the Safe / Executor,
 *                      then revoke the deployer (CORE-02); exact admin and owner checks; manifest.
 *
 * Step 1 (libraries) is `DeployLighterLibraries.s.sol`; FOUNDRY_LIBRARIES must link all eight.
 * Every phase checks chain state first: a re-run after success sends nothing and leaves
 * `sourceCommits` as recorded; a phase that sends continues only from the recorded commit.
 *
 * Role layout after handOver (spec 3.4, CORE-02, plan.md S4a notes):
 *  - Executor: PoolAddressesProvider owner, ACL admin, ACL DEFAULT_ADMIN; POOL_ADMIN and RISK_ADMIN
 *    (config-engine payloads queued through the timelock); owner of the PoolAddressesProviderRegistry,
 *    EmissionManager, ProxyAdmin, WrappedTokenGateway and the market setup batch.
 *  - Safe: POOL_ADMIN, RISK_ADMIN, EMERGENCY_ADMIN, ASSET_LISTING_ADMIN; Executor owner; treasury.
 *  - Deployer: nothing.
 *
 * Usage (lumina-monorepo harness/deploy/README.md):
 *   LUMINA_MANIFEST=reports/lighter/<file>.json FOUNDRY_LIBRARIES=... forge script \
 *     scripts/lighter/DeployLighterDevnet.s.sol:DeployLighterDevnet --sig '<phase>()' \
 *     --rpc-url lighter --broadcast --slow --ffi --sender <deployer> (--unlocked | --account <ks>)
 * handOver() also needs LUMINA_DEPLOY_CHECKPOINT, LUMINA_SAFE_SINGLETON and
 * LUMINA_SAFE_FALLBACK_HANDLER (the Safe deployment's singleton and fallback handler).
 */
contract DeployLighterDevnet is LighterManifest, LighterMarketInput {
  address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
  uint256 internal constant EXECUTOR_DELAY = 1 days;
  uint256 internal constant SAFE_THRESHOLD = 2;
  /// @dev Aave's scaled-balance rounding: a supply of `amount` can read back as `amount - 1`.
  uint256 internal constant SEED_ROUNDING = 1;
  string internal constant LOGIC = 'src/contracts/protocol/libraries/logic/';
  string internal constant PROXY = 'InitializableImmutableAdminUpgradeabilityProxy';
  bytes32 internal constant INCENTIVES_CONTROLLER = keccak256('INCENTIVES_CONTROLLER');
  bytes32 internal constant EIP1967_ADMIN_SLOT =
    0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
  bytes32 internal constant SAFE_FALLBACK_HANDLER_SLOT =
    keccak256('fallback_manager.handler.address');
  bytes32 internal constant SAFE_GUARD_SLOT = keccak256('guard_manager.guard.address');
  address internal constant SAFE_SENTINEL_MODULES = address(1);
  bytes32 internal constant QUEUE_EVENT =
    keccak256('QueueTransaction(bytes32,address,bytes32,bytes,uint256)');
  bytes32 internal constant CANCEL_EVENT =
    keccak256('CancelTransaction(bytes32,address,bytes,uint256)');
  bytes32 internal constant SAFE_SUCCESS_EVENT = keccak256('ExecutionSuccess(bytes32,uint256)');

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
    uint256 wethSeed;
    uint256 usdcSeed;
  }

  /// @dev Market contracts (from the batch report in deployMarket, the manifest afterwards).
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
  bool internal _sent;

  // ============================================================================================
  // Phases
  // ============================================================================================

  function deployMarket() external {
    _begin();
    if (_isDeployed('.contracts.poolAddressesProvider.address')) {
      _readMarket();
      console.log('deployMarket: market already deployed at', _m.provider);
    } else {
      uint256 firstBlock = block.number;
      MarketReport memory r = _deployBatch();
      _writeMarket(r, firstBlock);
    }
    _checkMarketWiring();
    _setSources();
    _finish('deployMarket');
  }

  function prepareListing() external {
    _begin();
    _readMarket();
    _checkMarketWiring();
    _checkSourcesSet();
    _readGuard();
    _setSentinel();
    if (_listed()) {
      console.log('prepareListing: reserves already listed');
    } else if (_isDeployed('.contracts.listingPayload.address')) {
      _m.listingPayload = _address('.contracts.listingPayload.address');
      _checkPayload(_m.listingPayload);
      console.log('prepareListing: payload already deployed', _m.listingPayload);
    } else {
      _startBroadcast();
      _m.listingPayload = address(
        new LighterListingPayload(
          IEngine(_m.configEngine),
          _in.deployer,
          _in.ethSource,
          _in.usdcSource,
          _in.wethSeed,
          _in.usdcSeed
        )
      );
      vm.stopBroadcast();
      _checkPayload(_m.listingPayload);
      // Checkpoint: the payload is in the manifest before it is granted anything.
      _writeContract('listingPayload', _m.listingPayload, 'LighterListingPayload');
    }
    _finish('prepareListing');
  }

  function listAndSeed() external {
    _begin();
    _readMarket();
    _checkMarketWiring();
    _checkSourcesSet();
    _readGuard();
    require(
      IProviderAdmin(_m.provider).getPriceOracleSentinel() == _in.guard,
      'listAndSeed: the sentinel is not set (run prepareListing)'
    );
    if (_isDeployed('.contracts.listingPayload.address')) {
      _m.listingPayload = _address('.contracts.listingPayload.address');
      _clearRoles(_m.listingPayload);
    }

    if (!_listed()) {
      require(
        _m.listingPayload != address(0),
        'listAndSeed: no listing payload (run prepareListing)'
      );
      _checkPayload(_m.listingPayload);
      _requireManifestRiskMatchesInput();
      _fundPayload(_m.listingPayload);
      IACL acl = IACL(_m.aclManager);
      require(
        acl.hasRole(acl.DEFAULT_ADMIN_ROLE(), _in.deployer),
        'listAndSeed: reserves unlisted and the deployer is no longer ACL admin'
      );
      bytes32 poolAdmin = acl.POOL_ADMIN_ROLE();
      _startBroadcast();
      acl.grantRole(poolAdmin, _m.listingPayload);
      // One transaction: list both reserves, seed them onBehalfOf 0x...dEaD, renounce the role.
      LighterListingPayload(_m.listingPayload).execute();
      vm.stopBroadcast();
      _requireNoRole(_m.listingPayload, 'listing payload');
      _checkLaunchValues();
    } else {
      console.log('listAndSeed: reserves already listed');
    }
    _checkReserveWiring();
    _topUpSeeds();
    _writeReserves();
    _finish('listAndSeed');
  }

  function deployExecutor() external {
    _begin();
    _readMarket();
    _checkMarketWiring();
    _readGuard();
    if (_isDeployed('.contracts.executor.address')) {
      _m.executor = _address('.contracts.executor.address');
      console.log('deployExecutor: Executor already deployed', _m.executor);
    } else {
      _startBroadcast();
      _m.executor = address(new Executor(_in.safe, EXECUTOR_DELAY));
      vm.stopBroadcast();
      _writeContract('executor', _m.executor, 'Executor');
    }
    _checkExecutor();
    _verifySafe();
    _finish('deployExecutor');
  }

  function handOver() external {
    _begin();
    _readMarket();
    _checkMarketWiring();
    _checkSourcesSet();
    _readGuard();
    _m.executor = _requireDeployed('.contracts.executor.address');
    if (_isDeployed('.contracts.listingPayload.address')) {
      _m.listingPayload = _address('.contracts.listingPayload.address');
    }
    require(_listed(), 'handOver: reserves are not listed');
    require(
      IProviderAdmin(_m.provider).getPriceOracleSentinel() == _in.guard,
      'handOver: sentinel'
    );

    // Before anything is handed over: the Safe can drive the Executor (real 2-of-3 probe).
    _verifySafe();
    _checkExecutor();
    _verifyProbe();
    if (_m.listingPayload != address(0)) _clearRoles(_m.listingPayload);
    _checkReserveWiring();
    _requireSeeds();

    _handOver();
    _revokeDeployer();

    _assertFinalState();
    _writeReserves();
    _write('.roles.core', _coreRolesJson());
    _write('.roles.guard.guardian', _jAddress(_in.safe));
    _write('.roles.guard.keeper', _jAddress(_in.keeper));
    _finish('handOver');
  }

  // ============================================================================================
  // Common
  // ============================================================================================

  function _begin() internal {
    _loadManifest();
    _readInputs();
    _requireNoForgeLibraryDeploys(_in.deployer);
    _requireLibrariesLinked();
    _checkSources();
  }

  /// @dev The first broadcast of a phase checks the checkout and the recorded commit.
  function _startBroadcast() internal {
    if (!_sent) {
      _beforeBroadcast();
      _sent = true;
    }
    vm.startBroadcast(_in.deployer);
  }

  function _finish(string memory phase) internal {
    if (_sent) _recordSourceCommit();
    else console.log(phase, ': nothing sent');
  }

  // ============================================================================================
  // deployMarket
  // ============================================================================================

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
          usdcPriceSource: _in.usdcSource
        })
      );
    // AaveV3SetupBatch is this phase's first CREATE (checked against its report below).
    address setupBatch = vm.computeCreateAddress(_in.deployer, vm.getNonce(_in.deployer));
    _startBroadcast();
    r = AaveV3BatchOrchestration.deployAaveV3(_in.deployer, roles, config, flags, empty);
    vm.stopBroadcast();

    require(
      IMarketReportView(setupBatch).getMarketReport().poolAddressesProvider ==
        r.poolAddressesProvider,
      'setup batch address'
    );
    require(IOwnable(setupBatch).owner() == _in.deployer, 'setup batch owner');
    require(
      r.treasury == _in.safe && r.treasuryImplementation == address(0),
      'treasury is the Safe'
    );
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
  }

  /// @dev AaveOracle sources: WETH -> ETH LighterCorePriceSource, USDC -> FixedPriceSource.
  function _setSources() internal {
    IAaveOracleAdmin oracle = IAaveOracleAdmin(_m.aaveOracle);
    if (
      oracle.getSourceOfAsset(LIGHTER_WETH9) != _in.ethSource ||
      oracle.getSourceOfAsset(LIGHTER_USDC) != _in.usdcSource
    ) {
      IACL acl = IACL(_m.aclManager);
      require(
        acl.hasRole(acl.POOL_ADMIN_ROLE(), _in.deployer),
        'deployMarket: sources unset and the deployer is no longer POOL_ADMIN'
      );
      address[] memory assets = new address[](2);
      address[] memory sources = new address[](2);
      assets[0] = LIGHTER_WETH9;
      sources[0] = _in.ethSource;
      assets[1] = LIGHTER_USDC;
      sources[1] = _in.usdcSource;
      _startBroadcast();
      oracle.setAssetSources(assets, sources);
      vm.stopBroadcast();
    }
    _checkSourcesSet();
  }

  // ============================================================================================
  // prepareListing / listAndSeed
  // ============================================================================================

  function _setSentinel() internal {
    IProviderAdmin provider = IProviderAdmin(_m.provider);
    if (provider.getPriceOracleSentinel() == _in.guard) return;
    require(
      provider.owner() == _in.deployer,
      'sentinel unset and the deployer no longer owns the provider'
    );
    _startBroadcast();
    provider.setPriceOracleSentinel(_in.guard);
    vm.stopBroadcast();
    require(provider.getPriceOracleSentinel() == _in.guard, 'sentinel');
  }

  /// @dev True when both reserves are listed; reverts when exactly one is.
  function _listed() internal view returns (bool) {
    IPoolView pool = IPoolView(_m.pool);
    bool weth = pool.getReserveData(LIGHTER_WETH9).aTokenAddress != address(0);
    bool usdc = pool.getReserveData(LIGHTER_USDC).aTokenAddress != address(0);
    require(weth == usdc, 'exactly one reserve is listed; fix by hand');
    return weth;
  }

  function _checkPayload(address payload) internal view {
    LighterListingPayload p = LighterListingPayload(payload);
    require(
      address(p.CONFIG_ENGINE()) == _m.configEngine &&
        p.CALLER() == _in.deployer &&
        p.ETH_PRICE_SOURCE() == _in.ethSource &&
        p.USDC_PRICE_SOURCE() == _in.usdcSource &&
        address(p.POOL()) == _m.pool &&
        p.WETH_SEED() == _in.wethSeed &&
        p.USDC_SEED() == _in.usdcSeed,
      'listing payload differs from the manifest (engine, caller, sources or seeds); reset contracts.listingPayload'
    );
  }

  function _fundPayload(address payload) internal {
    _fund(LIGHTER_WETH9, payload, _in.wethSeed);
    _fund(LIGHTER_USDC, payload, _in.usdcSeed);
  }

  function _fund(address asset, address payload, uint256 seed) internal {
    uint256 have = IERC20(asset).balanceOf(payload);
    if (have >= seed) return;
    uint256 need = seed - have;
    require(
      IERC20(asset).balanceOf(_in.deployer) >= need,
      string.concat('the deployer holds less than the seed of ', vm.toString(asset))
    );
    _startBroadcast();
    require(IERC20(asset).transfer(payload, need), 'seed transfer');
    vm.stopBroadcast();
  }

  /// @dev Any ACL role `account` still holds is revoked (an interrupted listing leaves POOL_ADMIN).
  function _clearRoles(address account) internal {
    IACL acl = IACL(_m.aclManager);
    bytes32[7] memory roles = _allRoles(acl);
    for (uint256 i = 0; i < roles.length; i++) {
      if (!acl.hasRole(roles[i], account)) continue;
      require(
        acl.hasRole(roles[0], _in.deployer),
        'the listing payload holds an ACL role and the deployer is no longer ACL admin'
      );
      _startBroadcast();
      acl.revokeRole(roles[i], account);
      vm.stopBroadcast();
    }
    _requireNoRole(account, 'listing payload');
  }

  function _requireNoRole(address account, string memory label) internal view {
    IACL acl = IACL(_m.aclManager);
    bytes32[7] memory roles = _allRoles(acl);
    for (uint256 i = 0; i < roles.length; i++) {
      require(!acl.hasRole(roles[i], account), string.concat(label, ' holds an ACL role'));
    }
  }

  function _allRoles(IACL acl) internal view returns (bytes32[7] memory) {
    return [
      acl.DEFAULT_ADMIN_ROLE(),
      acl.POOL_ADMIN_ROLE(),
      acl.EMERGENCY_ADMIN_ROLE(),
      acl.RISK_ADMIN_ROLE(),
      acl.FLASH_BORROWER_ROLE(),
      acl.BRIDGE_ROLE(),
      acl.ASSET_LISTING_ADMIN_ROLE()
    ];
  }

  /// @dev First setup only: the manifest must not encode other risk parameters than the input.
  function _requireManifestRiskMatchesInput() internal view {
    LighterReserveParams[] memory params = _lighterReserveParams();
    for (uint256 k = 0; k < 2; k++) {
      LighterReserveParams memory p = params[k];
      uint256 i = p.asset == LIGHTER_WETH9 ? _in.wethMarketIndex : _in.usdcMarketIndex;
      require(
        _uint(_market(i, 'ltvBps')) == p.ltv &&
          _uint(_market(i, 'liquidationThresholdBps')) == p.liqThreshold &&
          _uint(_market(i, 'liquidationBonusBps')) == p.liqBonus &&
          _uint(_market(i, 'reserveFactorBps')) == p.reserveFactor,
        string.concat('manifest markets.core ', p.symbol, ' differs from LighterMarketInput')
      );
    }
  }

  /// @dev First setup only (#7): every launch value read back equals LighterMarketInput.
  function _checkLaunchValues() internal view {
    LighterReserveParams[] memory params = _lighterReserveParams();
    IDataProviderView dp = IDataProviderView(_m.dataProvider);
    for (uint256 i = 0; i < params.length; i++) {
      LighterReserveParams memory p = params[i];
      ReserveConfig memory c = _reserveConfig(p.asset);
      require(c.decimals == p.decimals, string.concat(p.symbol, ': decimals'));
      require(c.ltv == p.ltv && c.lt == p.liqThreshold, string.concat(p.symbol, ': ltv / LT'));
      require(c.lb == 100_00 + p.liqBonus, string.concat(p.symbol, ': liquidation bonus'));
      require(c.rf == p.reserveFactor, string.concat(p.symbol, ': reserve factor'));
      require(
        dp.getLiquidationProtocolFee(p.asset) == p.liqProtocolFee,
        string.concat(p.symbol, ': liquidation protocol fee')
      );
      require(!dp.getFlashLoanEnabled(p.asset), string.concat(p.symbol, ': flash loans enabled'));
      (uint256 borrowCap, uint256 supplyCap) = dp.getReserveCaps(p.asset);
      require(
        supplyCap == p.supplyCap && borrowCap == p.borrowCap,
        string.concat(p.symbol, ': launch caps')
      );
      IDefaultInterestRateStrategyV2.InterestRateData memory rate = IDefaultInterestRateStrategyV2(
        _m.rateStrategy
      ).getInterestRateDataBps(p.asset);
      require(
        rate.optimalUsageRatio == p.rates.optimalUsageRatio &&
          rate.baseVariableBorrowRate == p.rates.baseVariableBorrowRate &&
          rate.variableRateSlope1 == p.rates.variableRateSlope1 &&
          rate.variableRateSlope2 == p.rates.variableRateSlope2,
        string.concat(p.symbol, ': launch interest rate curve')
      );
    }
  }

  /// @dev Every run: sources, treasury, rate strategy, active and unfrozen (not the tunables).
  function _checkReserveWiring() internal view {
    _checkSourcesSet();
    LighterReserveParams[] memory params = _lighterReserveParams();
    for (uint256 i = 0; i < params.length; i++) {
      address asset = params[i].asset;
      ReserveConfig memory c = _reserveConfig(asset);
      require(c.active && !c.frozen, string.concat(params[i].symbol, ': not active'));
      DataTypes.ReserveDataLegacy memory rd = IPoolView(_m.pool).getReserveData(asset);
      require(
        rd.interestRateStrategyAddress == _m.rateStrategy,
        string.concat(params[i].symbol, ': rate strategy')
      );
      require(
        IAToken(rd.aTokenAddress).RESERVE_TREASURY_ADDRESS() == _in.safe,
        string.concat(params[i].symbol, ': treasury is not the Safe')
      );
    }
  }

  /// @dev A seed reads back at least the manifest amount minus Aave's rounding; else top it up.
  function _topUpSeeds() internal {
    _topUp(LIGHTER_WETH9, _in.wethSeed);
    _topUp(LIGHTER_USDC, _in.usdcSeed);
    _requireSeeds();
  }

  function _topUp(address asset, uint256 seed) internal {
    address aToken = IPoolView(_m.pool).getReserveData(asset).aTokenAddress;
    uint256 held = IERC20(aToken).balanceOf(DEAD);
    if (held + SEED_ROUNDING >= seed) return;
    uint256 shortfall = seed - held;
    require(
      IERC20(asset).balanceOf(_in.deployer) >= shortfall,
      string.concat(
        'seed top-up: the deployer holds less than the shortfall of ',
        vm.toString(asset)
      )
    );
    console.log('seed top-up', asset, shortfall);
    _startBroadcast();
    IERC20(asset).approve(_m.pool, shortfall);
    IPoolView(_m.pool).supply(asset, shortfall, DEAD, 0);
    vm.stopBroadcast();
    require(IERC20(asset).allowance(_in.deployer, _m.pool) == 0, 'top-up allowance left');
  }

  function _requireSeeds() internal view {
    address[2] memory assets = [LIGHTER_WETH9, LIGHTER_USDC];
    uint256[2] memory seeds = [_in.wethSeed, _in.usdcSeed];
    for (uint256 i = 0; i < 2; i++) {
      address aToken = IPoolView(_m.pool).getReserveData(assets[i]).aTokenAddress;
      require(
        IERC20(aToken).balanceOf(DEAD) + SEED_ROUNDING >= seeds[i],
        string.concat('seed below the manifest amount: ', vm.toString(assets[i]))
      );
    }
  }

  // ============================================================================================
  // deployExecutor / handOver
  // ============================================================================================

  function _checkExecutor() internal view {
    Executor executor = Executor(_m.executor);
    require(executor.owner() == _in.safe, 'Executor owner is not the Safe');
    require(executor.pendingOwner() == address(0), 'Executor has a pending owner');
    require(executor.delay() == EXECUTOR_DELAY, 'Executor delay');
    require(!executor.emergencyEnabled(), 'Executor emergency path enabled');
    require(executor.queuedCount() == 0, 'Executor has queued actions');
  }

  /**
   * @dev The Safe behind every role: code, the manifest owners and threshold 2, the expected
   * singleton and fallback handler (LUMINA_SAFE_SINGLETON / LUMINA_SAFE_FALLBACK_HANDLER, the
   * values the Safe deployment used), no module, no transaction guard, the manifest version.
   */
  function _verifySafe() internal view {
    address safe = _in.safe;
    require(safe.code.length > 0, 'Safe: no code');
    address[] memory owners = ISafeView(safe).getOwners();
    address[] memory expected = vm.parseJsonAddressArray(_json, '.safe.owners');
    require(owners.length == expected.length, 'Safe: owner count');
    for (uint256 i = 0; i < expected.length; i++) {
      bool found;
      for (uint256 j = 0; j < owners.length; j++) found = found || owners[j] == expected[i];
      require(found, string.concat('Safe lacks owner ', vm.toString(expected[i])));
    }
    require(
      ISafeView(safe).getThreshold() == SAFE_THRESHOLD &&
        _uint('.safe.threshold') == SAFE_THRESHOLD,
      'Safe: threshold is not 2'
    );
    address singleton = address(uint160(uint256(vm.load(safe, bytes32(0)))));
    require(singleton == vm.envAddress('LUMINA_SAFE_SINGLETON'), 'Safe: unexpected singleton');
    address handler = address(uint160(uint256(vm.load(safe, SAFE_FALLBACK_HANDLER_SLOT))));
    require(
      handler == vm.envAddress('LUMINA_SAFE_FALLBACK_HANDLER'),
      'Safe: unexpected fallback handler'
    );
    require(vm.load(safe, SAFE_GUARD_SLOT) == bytes32(0), 'Safe: a transaction guard is set');
    (address[] memory modules, ) = ISafeView(safe).getModulesPaginated(SAFE_SENTINEL_MODULES, 10);
    require(modules.length == 0, 'Safe: a module is enabled');
    require(
      keccak256(bytes(ISafeView(safe).VERSION())) ==
        keccak256(bytes(vm.parseJsonString(_json, '.safe.version'))),
      'Safe: version differs from the manifest'
    );
  }

  /**
   * @dev The deploy checkpoint (`$LUMINA_DEPLOY_CHECKPOINT`, `.safeProbe`) must name a no-op the
   * Safe queued and then cancelled on this Executor, with both receipts mined and successful,
   * sent to the Safe, carrying the Safe's ExecutionSuccess and the Executor's event for exactly
   * that action. Without it nothing is handed over.
   */
  function _verifyProbe() internal {
    string memory cp = vm.readFile(vm.envString('LUMINA_DEPLOY_CHECKPOINT'));
    require(
      vm.keyExistsJson(cp, '.safeProbe'),
      'handOver: no Safe probe recorded in the checkpoint'
    );
    Executor executor = Executor(_m.executor);
    require(
      vm.parseJsonAddress(cp, '.safeProbe.executor') == _m.executor &&
        vm.parseJsonAddress(cp, '.safeProbe.safe') == _in.safe,
      'Safe probe: other Executor or Safe'
    );
    bytes memory data = vm.parseJsonBytes(cp, '.safeProbe.data');
    require(
      keccak256(data) == keccak256(abi.encodeCall(Executor.setDelay, (EXECUTOR_DELAY))),
      'Safe probe: not the no-op setDelay(1 day)'
    );
    uint256 eta = vm.parseJsonUint(cp, '.safeProbe.eta');
    bytes32 action = executor.getTransactionHash(address(executor), data, eta);
    require(action == vm.parseJsonBytes32(cp, '.safeProbe.action'), 'Safe probe: action hash');
    uint256 queuedIn = _checkProbeReceipt(
      vm.parseJsonBytes32(cp, '.safeProbe.queueTx'),
      QUEUE_EVENT,
      action
    );
    uint256 cancelledIn = _checkProbeReceipt(
      vm.parseJsonBytes32(cp, '.safeProbe.cancelTx'),
      CANCEL_EVENT,
      action
    );
    require(cancelledIn >= queuedIn, 'Safe probe: cancel before queue');
    require(!executor.isQueued(action), 'Safe probe: action still queued');
    console.log(
      'Safe probe verified: queued in block',
      queuedIn,
      'cancelled in block',
      cancelledIn
    );
  }

  /// @return blockNumber of the receipt
  function _checkProbeReceipt(
    bytes32 txHash,
    bytes32 eventSig,
    bytes32 action
  ) internal returns (uint256) {
    string memory r = _receipt(txHash);
    require(vm.parseJsonUint(r, '.status') == 1, 'Safe probe: transaction failed');
    require(vm.parseJsonAddress(r, '.to') == _in.safe, 'Safe probe: not sent to the Safe');
    bool executorEvent;
    bool safeSuccess;
    for (uint256 i = 0; vm.keyExistsJson(r, string.concat('.logs[', vm.toString(i), ']')); i++) {
      string memory log = string.concat('.logs[', vm.toString(i), ']');
      address emitter = vm.parseJsonAddress(r, string.concat(log, '.address'));
      bytes32 topic0 = vm.parseJsonBytes32(r, string.concat(log, '.topics[0]'));
      if (emitter == _m.executor && topic0 == eventSig) {
        executorEvent =
          executorEvent ||
          vm.parseJsonBytes32(r, string.concat(log, '.topics[1]')) == action;
      }
      if (emitter == _in.safe && topic0 == SAFE_SUCCESS_EVENT) safeSuccess = true;
    }
    require(executorEvent, 'Safe probe: the Executor event for the action is missing');
    require(safeSuccess, 'Safe probe: no Safe ExecutionSuccess');
    return vm.parseJsonUint(r, '.blockNumber');
  }

  function _handOver() internal {
    IACL acl = IACL(_m.aclManager);
    address exec = _m.executor;
    address safe = _in.safe;
    bytes32[7] memory roles = _allRoles(acl);
    // ACL: every target role is granted before anything is revoked.
    _grant(acl, roles[0], exec); // DEFAULT_ADMIN
    _grant(acl, roles[1], safe); // POOL_ADMIN
    _grant(acl, roles[1], exec);
    _grant(acl, roles[3], safe); // RISK_ADMIN
    _grant(acl, roles[3], exec);
    _grant(acl, roles[2], safe); // EMERGENCY_ADMIN
    _grant(acl, roles[6], safe); // ASSET_LISTING_ADMIN

    // PoolAddressesProvider: ACL admin first (owner-only), then ownership.
    IProviderAdmin provider = IProviderAdmin(_m.provider);
    if (provider.getACLAdmin() != exec) {
      _startBroadcast();
      provider.setACLAdmin(exec);
      vm.stopBroadcast();
    }
    _transferOwnership(_m.provider, exec);
    _transferOwnership(_m.registry, exec);
    _transferOwnership(_m.emissionManager, exec);
    _transferOwnership(_m.proxyAdmin, exec);
    _transferOwnership(_m.gateway, exec);
    _transferOwnership(_m.setupBatch, exec);
  }

  function _grant(IACL acl, bytes32 role, address account) internal {
    if (acl.hasRole(role, account)) return;
    require(
      acl.hasRole(acl.DEFAULT_ADMIN_ROLE(), _in.deployer),
      'handOver: a role is missing and the deployer is no longer ACL admin'
    );
    _startBroadcast();
    acl.grantRole(role, account);
    vm.stopBroadcast();
  }

  function _transferOwnership(address target, address newOwner) internal {
    address current = IOwnable(target).owner();
    if (current == newOwner) return;
    require(
      current == _in.deployer,
      string.concat('handOver: unexpected owner of ', vm.toString(target))
    );
    _startBroadcast();
    IOwnable(target).transferOwnership(newOwner);
    vm.stopBroadcast();
  }

  function _revokeDeployer() internal {
    IACL acl = IACL(_m.aclManager);
    bytes32[7] memory roles = _allRoles(acl);
    bool any;
    for (uint256 i = 0; i < roles.length; i++) any = any || acl.hasRole(roles[i], _in.deployer);
    if (!any) return;
    // The Executor must already be DEFAULT_ADMIN, so no role is left without an admin.
    require(acl.hasRole(roles[0], _m.executor), 'revoke: Executor is not DEFAULT_ADMIN yet');
    _startBroadcast();
    for (uint256 i = 1; i < roles.length; i++) {
      if (acl.hasRole(roles[i], _in.deployer)) acl.revokeRole(roles[i], _in.deployer);
    }
    if (acl.hasRole(roles[0], _in.deployer)) acl.renounceRole(roles[0], _in.deployer);
    vm.stopBroadcast();
  }

  /// @dev Roles, exact owners and proxy admins (#5), and the wiring invariant.
  function _assertFinalState() internal {
    IACL acl = IACL(_m.aclManager);
    address exec = _m.executor;
    address safe = _in.safe;
    bytes32[7] memory roles = _allRoles(acl);
    _requireNoRole(_in.deployer, 'the deployer');
    if (_m.listingPayload != address(0)) _requireNoRole(_m.listingPayload, 'the listing payload');
    require(acl.hasRole(roles[0], exec) && !acl.hasRole(roles[0], safe), 'final: DEFAULT_ADMIN');
    require(acl.hasRole(roles[1], safe) && acl.hasRole(roles[1], exec), 'final: POOL_ADMIN');
    require(acl.hasRole(roles[2], safe) && !acl.hasRole(roles[2], exec), 'final: EMERGENCY_ADMIN');
    require(acl.hasRole(roles[3], safe) && acl.hasRole(roles[3], exec), 'final: RISK_ADMIN');
    require(
      acl.hasRole(roles[6], safe) && !acl.hasRole(roles[6], exec),
      'final: ASSET_LISTING_ADMIN'
    );

    // Owners: exactly the Executor (decision 2).
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

    // Proxy admins: immutable admins answer admin() only to themselves; the transparent proxy's
    // admin is read from its EIP-1967 slot (admin() from anyone else reaches the implementation).
    _requireImmutableAdmin(_m.pool, _m.provider, 'Pool');
    _requireImmutableAdmin(_m.configurator, _m.provider, 'PoolConfigurator');
    address rewards = provider.getAddress(INCENTIVES_CONTROLLER);
    require(rewards == _requireDeployed('.contracts.rewardsController.address'), 'final: rewards');
    _requireImmutableAdmin(rewards, _m.provider, 'RewardsController');
    for (uint256 i = 0; i < 2; i++) {
      DataTypes.ReserveDataLegacy memory rd = IPoolView(_m.pool).getReserveData(
        i == 0 ? LIGHTER_WETH9 : LIGHTER_USDC
      );
      _requireImmutableAdmin(rd.aTokenAddress, _m.configurator, 'aToken');
      _requireImmutableAdmin(rd.variableDebtTokenAddress, _m.configurator, 'variableDebtToken');
    }
    address factory = _requireDeployed('.contracts.staticATokenFactory.address');
    require(
      address(uint160(uint256(vm.load(factory, EIP1967_ADMIN_SLOT)))) == _m.proxyAdmin,
      'final: StataTokenFactory proxy admin is not the ProxyAdmin'
    );

    // Wiring invariant (plan.md): one LighterCorePriceSource behind guard market 0, the AaveOracle
    // WETH source and the WETH side of both dual oracles.
    (bool guarded, address guardSource, , , , , ) = IPriceGuardView(_in.guard).getMarket(0);
    require(guarded && guardSource == _in.ethSource, 'final: guard market 0 source');
    require(
      IAaveOracleAdmin(_m.aaveOracle).getSourceOfAsset(LIGHTER_WETH9) == _in.ethSource,
      'final: AaveOracle WETH source'
    );
    require(
      IDualOracleView(_in.dualUsdcWeth).COLLATERAL_PRICE_SOURCE() == _in.ethSource &&
        IDualOracleView(_in.dualWethUsdc).ASSET_PRICE_SOURCE() == _in.ethSource,
      'final: dual oracle ETH source'
    );
    _requireSeeds();
  }

  function _requireImmutableAdmin(address proxy, address admin, string memory label) internal {
    vm.prank(admin);
    require(
      IImmutableAdminProxy(proxy).admin() == admin,
      string.concat('final: ', label, ' proxy admin')
    );
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

    bool weth;
    bool usdc;
    for (uint256 i = 0; i < 2; i++) {
      address asset = _requireAddress(_market(i, 'asset'));
      if (asset == LIGHTER_WETH9 && !weth) {
        _in.wethMarketIndex = i;
        weth = true;
      } else if (asset == LIGHTER_USDC && !usdc) {
        _in.usdcMarketIndex = i;
        usdc = true;
      } else {
        revert('manifest: markets.core must be WETH and USDC');
      }
    }
    _in.wethSeed = _uint(_market(_in.wethMarketIndex, 'seedAmount'));
    _in.usdcSeed = _uint(_market(_in.usdcMarketIndex, 'seedAmount'));
    require(_in.wethSeed > 0 && _in.usdcSeed > 0, 'manifest: seedAmount must be positive');
  }

  function _market(uint256 i, string memory field) internal pure returns (string memory) {
    return string.concat('.markets.core[', vm.toString(i), '].', field);
  }

  /// @dev The price sources (lumina-oracle phase 1) against the manifest.
  function _checkSources() internal view {
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
  }

  /// @dev The guard and dual oracles (lumina-oracle phase 2), against the real provider.
  function _readGuard() internal {
    _in.guard = _requireDeployed('.contracts.priceGuard.address');
    _in.dualUsdcWeth = _requireDeployed('.contracts.dualOracleUsdcWeth.address');
    _in.dualWethUsdc = _requireDeployed('.contracts.dualOracleWethUsdc.address');
    IPriceGuardView guard = IPriceGuardView(_in.guard);
    require(
      guard.ADDRESSES_PROVIDER() == _m.provider,
      'guard: ADDRESSES_PROVIDER is not the provider'
    );
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
      'guard: market 0 is not guarded with the ETH source (the Safe adds it first)'
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

  function _checkSourcesSet() internal view {
    IAaveOracleAdmin oracle = IAaveOracleAdmin(_m.aaveOracle);
    require(oracle.BASE_CURRENCY() == address(0), 'AaveOracle base currency is not USD');
    require(oracle.BASE_CURRENCY_UNIT() == 1e8, 'AaveOracle base currency unit is not 1e8');
    require(oracle.getSourceOfAsset(LIGHTER_WETH9) == _in.ethSource, 'AaveOracle WETH source');
    require(oracle.getSourceOfAsset(LIGHTER_USDC) == _in.usdcSource, 'AaveOracle USDC source');
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

  // ============================================================================================
  // Manifest: writes (always from chain reads)
  // ============================================================================================

  function _writeMarket(MarketReport memory r, uint256 firstBlock) internal {
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
    require(
      _implementationOf(r.rewardsControllerProxy) == r.rewardsControllerImplementation,
      'rewards controller implementation'
    );
    _write(
      '.contracts.rewardsController',
      _proxyJson(
        r.rewardsControllerProxy,
        PROXY,
        _contractJson(r.rewardsControllerImplementation, 'RewardsController')
      )
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
    require(
      _implementationOf(r.staticATokenFactoryProxy) == r.staticATokenFactoryImplementation,
      'static aToken factory implementation'
    );
    _write(
      '.contracts.staticATokenFactory',
      _proxyJson(
        r.staticATokenFactoryProxy,
        'TransparentUpgradeableProxy',
        _contractJson(r.staticATokenFactoryImplementation, 'StataTokenFactory')
      )
    );
    _writeContract('staticATokenImplementation', r.staticATokenImplementation, 'StataTokenV2');
    _writeContract('transparentProxyFactory', r.transparentProxyFactory, 'TransparentProxyFactory');
    _writeContract('marketSetupBatch', _m.setupBatch, 'AaveV3SetupBatch');
    if (_isNull('.deploymentBlock')) _write('.deploymentBlock', _jUint(firstBlock));
  }

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

  /// @dev Reserve token contracts and markets.core, read from the chain.
  function _writeReserves() internal {
    _writeReserveTokens(LIGHTER_WETH9, 'WETH');
    _writeReserveTokens(LIGHTER_USDC, 'USDC');
    LighterReserveParams[] memory params = _lighterReserveParams();
    string[2] memory entries;
    entries[_in.wethMarketIndex] = _marketJson(_in.wethMarketIndex, params[0], _in.ethSource);
    entries[_in.usdcMarketIndex] = _marketJson(_in.usdcMarketIndex, params[1], _in.usdcSource);
    _write('.markets.core', string.concat('[', entries[0], ',', entries[1], ']'));
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

  /// @dev One markets.core entry: every value read back from the chain (not the input constants).
  function _marketJson(
    uint256 index,
    LighterReserveParams memory p,
    address source
  ) internal view returns (string memory) {
    DataTypes.ReserveDataLegacy memory rd = IPoolView(_m.pool).getReserveData(p.asset);
    require(
      IAaveOracleAdmin(_m.aaveOracle).getSourceOfAsset(p.asset) == source,
      'markets.core priceSource'
    );
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
    return string.concat(head, _marketRiskJson(index, p.asset), _marketParamsJson(p.asset), '}');
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

  function _marketParamsJson(address asset) internal view returns (string memory) {
    IDataProviderView dp = IDataProviderView(_m.dataProvider);
    IDefaultInterestRateStrategyV2.InterestRateData memory rate = IDefaultInterestRateStrategyV2(
      _m.rateStrategy
    ).getInterestRateDataBps(asset);
    return
      string.concat(
        ',"params":{"liquidationProtocolFeeBps":',
        _jUint(dp.getLiquidationProtocolFee(asset)),
        ',"flashloanable":',
        _jBool(dp.getFlashLoanEnabled(asset)),
        ',"optimalUsageRatioBps":',
        _jUint(rate.optimalUsageRatio),
        ',"baseVariableBorrowRateBps":',
        _jUint(rate.baseVariableBorrowRate),
        ',"variableRateSlope1Bps":',
        _jUint(rate.variableRateSlope1),
        ',"variableRateSlope2Bps":',
        _jUint(rate.variableRateSlope2),
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

interface IMarketReportView {
  function getMarketReport() external view returns (MarketReport memory);
}
