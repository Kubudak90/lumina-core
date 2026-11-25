// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {console} from 'forge-std/console.sol';
import {LighterManifest} from './LighterManifest.sol';
import {LighterSeedMath} from './LighterSeedMath.sol';
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
  function ADDRESSES_PROVIDER() external view returns (address);

  function DEFAULT_ADMIN_ROLE() external view returns (bytes32);

  function POOL_ADMIN_ROLE() external view returns (bytes32);

  function EMERGENCY_ADMIN_ROLE() external view returns (bytes32);

  function RISK_ADMIN_ROLE() external view returns (bytes32);

  function FLASH_BORROWER_ROLE() external view returns (bytes32);

  function BRIDGE_ROLE() external view returns (bytes32);

  function ASSET_LISTING_ADMIN_ROLE() external view returns (bytes32);

  function hasRole(bytes32 role, address account) external view returns (bool);

  function getRoleAdmin(bytes32 role) external view returns (bytes32);

  function grantRole(bytes32 role, address account) external;

  function revokeRole(bytes32 role, address account) external;

  function renounceRole(bytes32 role, address account) external;
}

interface IPoolView {
  function ADDRESSES_PROVIDER() external view returns (address);

  function getReservesList() external view returns (address[] memory);

  function getReserveData(address asset) external view returns (DataTypes.ReserveDataLegacy memory);

  function getReserveNormalizedIncome(address asset) external view returns (uint256);

  function getLiquidationGracePeriod(address asset) external view returns (uint40);

  function getEModeCategoryCollateralConfig(
    uint8 id
  ) external view returns (DataTypes.CollateralConfig memory);

  function getEModeCategoryCollateralBitmap(uint8 id) external view returns (uint128);

  function getEModeCategoryBorrowableBitmap(uint8 id) external view returns (uint128);

  function getEModeCategoryLabel(uint8 id) external view returns (string memory);

  function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

interface IAaveOracleAdmin {
  function ADDRESSES_PROVIDER() external view returns (address);

  function getFallbackOracle() external view returns (address);

  function getSourceOfAsset(address asset) external view returns (address);

  function setAssetSources(address[] calldata assets, address[] calldata sources) external;

  function BASE_CURRENCY() external view returns (address);

  function BASE_CURRENCY_UNIT() external view returns (uint256);
}

interface IDataProviderView {
  function ADDRESSES_PROVIDER() external view returns (address);

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

interface IProviderRefView {
  function ADDRESSES_PROVIDER() external view returns (address);
}

interface IReserveTokenView {
  function POOL() external view returns (address);

  function UNDERLYING_ASSET_ADDRESS() external view returns (address);

  function RESERVE_TREASURY_ADDRESS() external view returns (address);

  function getIncentivesController() external view returns (address);
}

interface IRewardsView {
  function EMISSION_MANAGER() external view returns (address);
}

interface IEmissionManagerView {
  function getRewardsController() external view returns (address);
}

interface IGatewayView {
  function getWETHAddress() external view returns (address);
}

interface IStataFactoryView {
  function POOL() external view returns (address);

  function PROXY_ADMIN() external view returns (address);

  function STATA_TOKEN_IMPL() external view returns (address);
}

interface IStataImplView {
  function POOL() external view returns (address);

  function POOL_ADDRESSES_PROVIDER() external view returns (address);

  function INCENTIVES_CONTROLLER() external view returns (address);
}

interface IUiPoolDataProviderView {
  function networkBaseTokenPriceInUsdProxyAggregator() external view returns (address);

  function marketReferenceCurrencyPriceInUsdProxyAggregator() external view returns (address);
}

interface IMulticall3View {
  struct Call3 {
    address target;
    bool allowFailure;
    bytes callData;
  }

  struct Result {
    bool success;
    bytes returnData;
  }

  function aggregate3(Call3[] calldata calls) external view returns (Result[] memory returnData);

  function getChainId() external view returns (uint256);

  function getBlockNumber() external view returns (uint256);
}

interface IScaledBalance {
  function scaledBalanceOf(address user) external view returns (uint256);
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
 * Role layout after handOver (spec 3.4, CORE-02, audit-fixes-v1 F1):
 *  - Executor: PoolAddressesProvider owner, ACL admin, ACL DEFAULT_ADMIN, POOL_ADMIN, RISK_ADMIN
 *    (upgrades, oracle sources, reserve listing/removal, ACL changes, and config-engine payloads
 *    queued through the 1-day timelock); owner of the PoolAddressesProviderRegistry,
 *    EmissionManager, ProxyAdmin, WrappedTokenGateway and the market setup batch.
 *  - Safe: RISK_ADMIN and EMERGENCY_ADMIN only (neither POOL_ADMIN nor ASSET_LISTING_ADMIN);
 *    Executor owner; treasury.
 *  - ASSET_LISTING_ADMIN, FLASH_BORROWER, BRIDGE: empty.
 *  - Deployer: nothing.
 *
 * Usage (lumina-monorepo harness/deploy/README.md):
 *   LUMINA_MANIFEST=reports/lighter/<file>.json FOUNDRY_LIBRARIES=... forge script \
 *     scripts/lighter/DeployLighterDevnet.s.sol:DeployLighterDevnet --sig '<phase>()' \
 *     --rpc-url lighter --broadcast --slow --ffi --sender <deployer> (--unlocked | --account <ks>)
 * handOver() also needs LUMINA_DEPLOY_CHECKPOINT (the deploy checkpoint with the Safe probe).
 */
contract DeployLighterDevnet is LighterManifest, LighterMarketInput {
  address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
  uint256 internal constant EXECUTOR_DELAY = 1 days;
  uint256 internal constant SAFE_THRESHOLD = 2;
  uint256 internal constant SAFE_OWNERS = 3;
  /// @dev Canonical Safe v1.3.0 code (harness/bytecode/manifest.json, the Lighter preinstalls).
  bytes32 internal constant SAFE_PROXY_RUNTIME_HASH =
    0xb89c1b3bdf2cf8827818646bce9a8f6e372885f8c55e5c07acbd307cb133b000;
  address internal constant SAFE_L2_SINGLETON = 0xfb1bffC9d739B8D520DaF37dF666da4C687191EA;
  bytes32 internal constant SAFE_L2_SINGLETON_HASH =
    0x21842597390c4c6e3c1239e434a682b054bd9548eee5e9b1d6a4482731023c0f;
  address internal constant SAFE_SINGLETON = 0x69f4D1788e39c87893C980c06EdF4b7f686e2938;
  bytes32 internal constant SAFE_SINGLETON_HASH =
    0xbba688fbdb21ad2bb58bc320638b43d94e7d100f6f3ebaab0a4e4de6304b1c2e;
  bytes32 internal constant SAFE_FALLBACK_HANDLER_HASH =
    0x03e69f7ce809e81687c69b19a7d7cca45b6d551ffdec73d9bb87178476de1abf;
  bytes32 internal constant MULTICALL3_CODEHASH =
    0xd5c15df687b16f2ff992fc8d767b4216323184a2bbc6ee2f9c398c318e770891;
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
    address multicall3;
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

  /**
   * @notice Revokes any ACL role the listing payload still holds (a run that stopped between the
   * grant and `execute()`). Runs first on every rerun and depends on nothing but the manifest's
   * ACL manager and payload: no price source, wiring or listing check can keep the role open.
   */
  function clearListingRoles() external {
    _loadManifest();
    _in.deployer = _requireAddress('.deployer');
    _requireNoForgeLibraryDeploys(_in.deployer);
    if (
      _isDeployed('.contracts.aclManager.address') &&
      _isDeployed('.contracts.listingPayload.address')
    ) {
      _m.aclManager = _address('.contracts.aclManager.address');
      _clearRoles(_address('.contracts.listingPayload.address'));
    }
    _finish('clearListingRoles');
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

    // Manifest risk/rate/flag inputs must match LighterMarketInput on every run (F6).
    _requireManifestRiskMatchesInput();
    if (!_listed()) {
      require(
        _m.listingPayload != address(0),
        'listAndSeed: no listing payload (run prepareListing)'
      );
      _checkPayload(_m.listingPayload);
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
    } else {
      console.log('listAndSeed: reserves already listed');
    }
    _checkCoreReserves();
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
    // An interrupted Safe probe may have left its no-op queued; handOver requires an empty queue.
    _checkExecutor(false);
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
    _checkExecutor(true);
    _verifyProbe();
    if (_m.listingPayload != address(0)) _clearRoles(_m.listingPayload);
    _requireManifestRiskMatchesInput();
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

  /// @dev The harness reads the marker: a phase without transactions writes no forge plan.
  function _finish(string memory phase) internal {
    if (_sent) {
      _recordSourceCommit();
      console.log('LUMINA-PHASE:', phase, 'transactions');
    } else {
      console.log('LUMINA-PHASE:', phase, 'no transactions');
    }
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

  /// @dev Committed manifest risk/flag/rate fields must match LighterMarketInput (F6).
  function _requireManifestRiskMatchesInput() internal view {
    LighterReserveParams[] memory params = _lighterReserveParams();
    for (uint256 k = 0; k < 2; k++) {
      LighterReserveParams memory p = params[k];
      uint256 i = p.asset == LIGHTER_WETH9 ? _in.wethMarketIndex : _in.usdcMarketIndex;
      bool ok = _uint(_market(i, 'ltvBps')) == p.ltv &&
        _uint(_market(i, 'liquidationThresholdBps')) == p.liqThreshold &&
        _uint(_market(i, 'liquidationBonusBps')) == p.liqBonus &&
        _uint(_market(i, 'liquidationProtocolFeeBps')) == p.liqProtocolFee &&
        _uint(_market(i, 'reserveFactorBps')) == p.reserveFactor &&
        _uint(_market(i, 'debtCeiling')) == 0 &&
        _bool(_market(i, 'active')) &&
        !_bool(_market(i, 'frozen')) &&
        !_bool(_market(i, 'paused')) &&
        _bool(_market(i, 'borrowingEnabled')) &&
        !_bool(_market(i, 'flashLoanEnabled')) &&
        _uint(_market(i, 'optimalUsageRatioBps')) == p.rates.optimalUsageRatio &&
        _uint(_market(i, 'baseVariableBorrowRateBps')) == p.rates.baseVariableBorrowRate &&
        _uint(_market(i, 'variableRateSlope1Bps')) == p.rates.variableRateSlope1 &&
        _uint(_market(i, 'variableRateSlope2Bps')) == p.rates.variableRateSlope2;
      if (!_isNull(_market(i, 'supplyCap'))) {
        ok = ok && _uint(_market(i, 'supplyCap')) == p.supplyCap;
      }
      if (!_isNull(_market(i, 'borrowCap'))) {
        ok = ok && _uint(_market(i, 'borrowCap')) == p.borrowCap;
      }
      require(
        ok,
        string.concat('manifest markets.core ', p.symbol, ' differs from LighterMarketInput')
      );
    }
  }

  /// @dev F6 phase 1: exact reserves list, decoded ReserveConfigurationMap (LTV/LT/LB/decimals/
  /// flags/RF/caps/liqProtocolFee/debtCeiling), rate strategy + 4 bps params, and no pending grace.
  function _checkCoreReserves() internal view {
    address[] memory list = IPoolView(_m.pool).getReservesList();
    require(list.length == 2, 'final: reserves list length');
    require(
      (list[0] == LIGHTER_WETH9 && list[1] == LIGHTER_USDC) ||
        (list[0] == LIGHTER_USDC && list[1] == LIGHTER_WETH9),
      'final: reserves list mismatch'
    );
    LighterReserveParams[] memory params = _lighterReserveParams();
    for (uint256 i = 0; i < params.length; i++) {
      _checkOneCoreReserve(params[i]);
    }
  }

  function _checkOneCoreReserve(LighterReserveParams memory p) internal view {
    DataTypes.ReserveDataLegacy memory rd = IPoolView(_m.pool).getReserveData(p.asset);
    uint256 cfg = rd.configuration.data;
    require((cfg & 0xffff) == p.ltv, string.concat(p.symbol, ': ltv / LT'));
    require(((cfg >> 16) & 0xffff) == p.liqThreshold, string.concat(p.symbol, ': ltv / LT'));
    require(
      ((cfg >> 32) & 0xffff) == 100_00 + p.liqBonus,
      string.concat(p.symbol, ': liquidation bonus')
    );
    require(((cfg >> 48) & 0xff) == p.decimals, string.concat(p.symbol, ': decimals'));
    require(((cfg >> 56) & 1) == 1, string.concat(p.symbol, ': not active'));
    require(((cfg >> 57) & 1) == 0, string.concat(p.symbol, ': frozen'));
    require(((cfg >> 58) & 1) == 1, string.concat(p.symbol, ': borrowing disabled'));
    require(((cfg >> 60) & 1) == 0, string.concat(p.symbol, ': paused'));
    require(((cfg >> 61) & 1) == 0, string.concat(p.symbol, ': borrowable in isolation'));
    require(((cfg >> 62) & 1) == 0, string.concat(p.symbol, ': siloed borrowing'));
    require(((cfg >> 63) & 1) == 0, string.concat(p.symbol, ': flash loans enabled'));
    require(((cfg >> 64) & 0xffff) == p.reserveFactor, string.concat(p.symbol, ': reserve factor'));
    uint256 borrowCap = (cfg >> 80) & ((1 << 36) - 1);
    uint256 supplyCap = (cfg >> 116) & ((1 << 36) - 1);
    require(supplyCap == p.supplyCap && borrowCap == p.borrowCap, string.concat(p.symbol, ': launch caps'));
    require(
      ((cfg >> 152) & 0xffff) == p.liqProtocolFee,
      string.concat(p.symbol, ': liquidation protocol fee')
    );
    require(((cfg >> 212) & ((1 << 40) - 1)) == 0, string.concat(p.symbol, ': debt ceiling'));
    require(
      rd.interestRateStrategyAddress == _m.rateStrategy,
      string.concat(p.symbol, ': rate strategy')
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
    require(
      IPoolView(_m.pool).getLiquidationGracePeriod(p.asset) < block.timestamp,
      string.concat(p.symbol, ': pending liquidation grace period')
    );
  }

  /// @dev Every run: sources, treasury, rate strategy, active and unfrozen (not the tunables).
  function _checkReserveWiring() internal view {
    _checkSourcesSet();
    LighterReserveParams[] memory params = _lighterReserveParams();
    for (uint256 i = 0; i < params.length; i++) {
      address asset = params[i].asset;
      ReserveConfig memory c = _reserveConfig(asset);
      require(c.active && !c.frozen, string.concat(params[i].symbol, ': not active'));
      require(c.borrowing, string.concat(params[i].symbol, ': borrowing disabled'));
      require(c.collateral, string.concat(params[i].symbol, ': not usable as collateral'));
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
    // An interrupted earlier top-up may have left an approval: always cleared (N8).
    if (IERC20(asset).allowance(_in.deployer, _m.pool) != 0) {
      _startBroadcast();
      IERC20(asset).approve(_m.pool, 0);
      vm.stopBroadcast();
    }
    address aToken = IPoolView(_m.pool).getReserveData(asset).aTokenAddress;
    if (IERC20(aToken).balanceOf(DEAD) + SEED_ROUNDING >= seed) return;
    // Deposit from the scaled-balance shortfall, rounded up: never a zero mint (r1#4).
    uint256 amount = LighterSeedMath.topUpAmount(
      seed,
      IScaledBalance(aToken).scaledBalanceOf(DEAD),
      IPoolView(_m.pool).getReserveNormalizedIncome(asset)
    );
    require(
      IERC20(asset).balanceOf(_in.deployer) >= amount,
      string.concat(
        'seed top-up: the deployer holds less than ',
        vm.toString(amount),
        ' of ',
        vm.toString(asset)
      )
    );
    console.log('seed top-up', asset, amount);
    _startBroadcast();
    IERC20(asset).approve(_m.pool, amount);
    IPoolView(_m.pool).supply(asset, amount, DEAD, 0);
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

  function _checkExecutor(bool requireEmptyQueue) internal view {
    Executor executor = Executor(_m.executor);
    require(executor.owner() == _in.safe, 'Executor owner is not the Safe');
    require(executor.pendingOwner() == address(0), 'Executor has a pending owner');
    require(executor.delay() == EXECUTOR_DELAY, 'Executor delay');
    require(!executor.emergencyEnabled(), 'Executor emergency path enabled');
    if (requireEmptyQueue) require(executor.queuedCount() == 0, 'Executor has queued actions');
  }

  /**
   * @dev The Safe behind every role, before anything is handed over (r1#3), pinned to spec 3.4
   * rather than to the manifest's own lists: exactly SAFE_OWNERS owners (each a manifest owner) and
   * threshold SAFE_THRESHOLD; the runtime is the GnosisSafeProxy v1.3.0 proxy; slot 0 is the
   * manifest's `safe.singleton` and its code is that canonical v1.3.0 singleton's; the fallback
   * handler slot is `safe.fallbackHandler` and its code is the v1.3.0 CompatibilityFallbackHandler;
   * no module, no transaction guard, the manifest version.
   */
  function _verifySafe() internal view {
    address safe = _in.safe;
    require(
      safe.codehash == SAFE_PROXY_RUNTIME_HASH,
      'Safe: runtime is not the GnosisSafeProxy v1.3.0 proxy'
    );
    address[] memory owners = ISafeView(safe).getOwners();
    address[] memory expected = vm.parseJsonAddressArray(_json, '.safe.owners');
    require(
      owners.length == SAFE_OWNERS && expected.length == SAFE_OWNERS,
      'Safe: owner count is not 3'
    );
    for (uint256 i = 0; i < expected.length; i++) {
      bool found;
      for (uint256 j = 0; j < owners.length; j++) found = found || owners[j] == expected[i];
      require(found, string.concat('Safe lacks owner ', vm.toString(expected[i])));
    }
    require(ISafeView(safe).getThreshold() == SAFE_THRESHOLD, 'Safe: threshold is not 2');
    address singleton = address(uint160(uint256(vm.load(safe, bytes32(0)))));
    require(
      singleton == _requireAddress('.safe.singleton'),
      'Safe: singleton is not safe.singleton'
    );
    require(
      (singleton == SAFE_L2_SINGLETON && singleton.codehash == SAFE_L2_SINGLETON_HASH) ||
        (singleton == SAFE_SINGLETON && singleton.codehash == SAFE_SINGLETON_HASH),
      'Safe: singleton code is not the canonical v1.3.0 singleton'
    );
    address handler = address(uint160(uint256(vm.load(safe, SAFE_FALLBACK_HANDLER_SLOT))));
    require(
      handler == _requireAddress('.safe.fallbackHandler'),
      'Safe: fallback handler is not safe.fallbackHandler'
    );
    require(
      handler.codehash == SAFE_FALLBACK_HANDLER_HASH,
      'Safe: fallback handler code is not CompatibilityFallbackHandler v1.3.0'
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
      vm.keyExistsJson(cp, '.safeProbe') &&
        keccak256(bytes(vm.parseJsonString(cp, '.safeProbe.state'))) == keccak256('done'),
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
    uint256 deployedAt = _uint('.deploymentBlock');
    uint256 queuedIn = _checkProbeTx(
      vm.parseJsonBytes32(cp, '.safeProbe.queueTx'),
      QUEUE_EVENT,
      action,
      deployedAt
    );
    uint256 cancelledIn = _checkProbeTx(
      vm.parseJsonBytes32(cp, '.safeProbe.cancelTx'),
      CANCEL_EVENT,
      action,
      deployedAt
    );
    require(cancelledIn >= queuedIn, 'Safe probe: cancel before queue');
    require(!executor.isQueued(action), 'Safe probe: action still queued');
    console.log(
      'Safe probe verified on this fork: queued in block',
      queuedIn,
      'cancelled in block',
      cancelledIn
    );
  }

  /**
   * @dev On the active fork (eth_getLogs, canonical block): the transaction carries the
   * Executor's event for exactly this action (queueTransaction / cancelTransaction are
   * owner-only, so the Safe made the call) and the Safe's ExecutionSuccess (2 of 3 signatures).
   * @return blockNumber of the transaction
   */
  function _checkProbeTx(
    bytes32 txHash,
    bytes32 eventSig,
    bytes32 action,
    uint256 fromBlock
  ) internal returns (uint256 blockNumber) {
    blockNumber = _requireLog(_m.executor, eventSig, action, txHash, fromBlock);
    require(
      _requireLog(_in.safe, SAFE_SUCCESS_EVENT, bytes32(0), txHash, blockNumber) == blockNumber,
      'Safe probe: no Safe ExecutionSuccess in the transaction'
    );
  }

  function _handOver() internal {
    IACL acl = IACL(_m.aclManager);
    address exec = _m.executor;
    address safe = _in.safe;
    bytes32[7] memory roles = _allRoles(acl);
    // ACL (F1): every target role is granted before anything is revoked.
    // Safe holds RISK_ADMIN and EMERGENCY_ADMIN only; Executor holds DEFAULT_ADMIN, POOL_ADMIN, RISK_ADMIN.
    _grant(acl, roles[0], exec); // DEFAULT_ADMIN
    _grant(acl, roles[1], exec); // POOL_ADMIN (Executor only; behind 1-day delay)
    _grant(acl, roles[3], safe); // RISK_ADMIN
    _grant(acl, roles[3], exec);
    _grant(acl, roles[2], safe); // EMERGENCY_ADMIN
    // Interrupted pre-F1 handover edge case: strip POOL_ADMIN / ASSET_LISTING_ADMIN if Safe holds them.
    _revokeIfHeld(acl, roles[1], safe);
    _revokeIfHeld(acl, roles[6], safe);

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

  function _revokeIfHeld(IACL acl, bytes32 role, address account) internal {
    if (!acl.hasRole(role, account)) return;
    require(
      acl.hasRole(acl.DEFAULT_ADMIN_ROLE(), _in.deployer),
      'handOver: an unwanted role is held and the deployer is no longer ACL admin'
    );
    _startBroadcast();
    acl.revokeRole(role, account);
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

  /// @dev Roles (F1), exact owners and proxy admins (#5), F6 phase 1 core state, back-pointers,
  /// Multicall3, wiring invariant and seeds.
  function _assertFinalState() internal {
    _assertFinalRolesAndAdmins();
    _checkCoreReserves();
    require(
      IAaveOracleAdmin(_m.aaveOracle).getFallbackOracle() == address(0),
      'final: fallback oracle'
    );
    _checkNoEModeCategories();
    _checkBackPointers();
    _checkMulticall3();

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

  function _assertFinalRolesAndAdmins() internal {
    IACL acl = IACL(_m.aclManager);
    address exec = _m.executor;
    address safe = _in.safe;
    bytes32[7] memory roles = _allRoles(acl);
    _requireNoRole(_in.deployer, 'the deployer');
    if (_m.listingPayload != address(0)) _requireNoRole(_m.listingPayload, 'the listing payload');
    if (bytes(_json).length > 0 && vm.keyExistsJson(_json, '.compromised')) {
      address[] memory compromised = vm.parseJsonAddressArray(_json, '.compromised');
      for (uint256 i = 0; i < compromised.length; i++) {
        _requireNoRole(compromised[i], 'compromised account');
      }
    }
    for (uint256 i = 0; i < roles.length; i++) {
      require(acl.getRoleAdmin(roles[i]) == roles[0], 'final: role admin is not DEFAULT_ADMIN');
    }
    // F1 ACL layout: DEFAULT_ADMIN [Executor]; POOL_ADMIN [Executor]; EMERGENCY_ADMIN [Safe];
    // RISK_ADMIN [Safe, Executor]; FLASH_BORROWER []; BRIDGE []; ASSET_LISTING_ADMIN [].
    require(acl.hasRole(roles[0], exec) && !acl.hasRole(roles[0], safe), 'final: DEFAULT_ADMIN');
    require(!acl.hasRole(roles[1], safe) && acl.hasRole(roles[1], exec), 'final: POOL_ADMIN');
    require(acl.hasRole(roles[2], safe) && !acl.hasRole(roles[2], exec), 'final: EMERGENCY_ADMIN');
    require(acl.hasRole(roles[3], safe) && acl.hasRole(roles[3], exec), 'final: RISK_ADMIN');
    require(!acl.hasRole(roles[4], safe) && !acl.hasRole(roles[4], exec), 'final: FLASH_BORROWER');
    require(!acl.hasRole(roles[5], safe) && !acl.hasRole(roles[5], exec), 'final: BRIDGE');
    require(
      !acl.hasRole(roles[6], safe) && !acl.hasRole(roles[6], exec),
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
  }

  /// @dev F6 phase 1: eMode categories 1..255 must all be unconfigured.
  function _checkNoEModeCategories() internal view {
    IPoolView pool = IPoolView(_m.pool);
    for (uint256 id = 1; id <= 255; id++) {
      uint8 cat = uint8(id);
      DataTypes.CollateralConfig memory cfg = pool.getEModeCategoryCollateralConfig(cat);
      require(
        cfg.ltv == 0 &&
          cfg.liquidationThreshold == 0 &&
          cfg.liquidationBonus == 0 &&
          pool.getEModeCategoryCollateralBitmap(cat) == 0 &&
          pool.getEModeCategoryBorrowableBitmap(cat) == 0 &&
          bytes(pool.getEModeCategoryLabel(cat)).length == 0,
        string.concat('final: eMode category configured: ', vm.toString(id))
      );
    }
  }

  /// @dev F6 phase 1: every core, reserve token, guard and periphery back-pointer, plus
  /// PoolConfigurator proxy storage slots derived from the compiler's storageLayout.
  function _checkBackPointers() internal view {
    require(IPoolView(_m.pool).ADDRESSES_PROVIDER() == _m.provider, 'final: Pool provider');
    require(
      IPoolView(_implementationOf(_m.pool)).ADDRESSES_PROVIDER() == _m.provider,
      'final: Pool impl provider'
    );
    require(IACL(_m.aclManager).ADDRESSES_PROVIDER() == _m.provider, 'final: ACLManager provider');
    require(
      IAaveOracleAdmin(_m.aaveOracle).ADDRESSES_PROVIDER() == _m.provider,
      'final: AaveOracle provider'
    );
    require(
      IDataProviderView(_m.dataProvider).ADDRESSES_PROVIDER() == _m.provider,
      'final: PoolDataProvider provider'
    );
    require(
      IProviderAdmin(_m.provider).getPoolDataProvider() == _m.dataProvider,
      'final: provider dataProvider'
    );
    require(
      IProviderRefView(_m.rateStrategy).ADDRESSES_PROVIDER() == _m.provider,
      'final: rateStrategy provider'
    );
    require(
      IPriceGuardView(_in.guard).ADDRESSES_PROVIDER() == _m.provider,
      'final: guard provider'
    );
    _checkConfiguratorStorage();
    _checkReserveAndPeripheryBackPointers();
  }

  /// @dev Derives `_addressesProvider` and `_pool` slots from PoolConfiguratorInstance's compiled
  /// storageLayout artifact and verifies the proxy's storage matches the manifest.
  function _checkConfiguratorStorage() internal view {
    string memory art = vm.readFile(
      'out/PoolConfiguratorInstance.sol/PoolConfiguratorInstance.json'
    );
    bool foundProvider;
    bool foundPool;
    uint256 providerSlot;
    uint256 providerOffset;
    uint256 poolSlot;
    uint256 poolOffset;
    for (uint256 i = 0; ; i++) {
      string memory base = string.concat('.storageLayout.storage[', vm.toString(i), ']');
      if (!vm.keyExistsJson(art, string.concat(base, '.label'))) break;
      bytes32 labelHash = keccak256(bytes(vm.parseJsonString(art, string.concat(base, '.label'))));
      if (labelHash == keccak256('_addressesProvider')) {
        providerSlot = vm.parseUint(vm.parseJsonString(art, string.concat(base, '.slot')));
        providerOffset = vm.parseJsonUint(art, string.concat(base, '.offset'));
        foundProvider = true;
      } else if (labelHash == keccak256('_pool')) {
        poolSlot = vm.parseUint(vm.parseJsonString(art, string.concat(base, '.slot')));
        poolOffset = vm.parseJsonUint(art, string.concat(base, '.offset'));
        foundPool = true;
      }
    }
    require(foundProvider && foundPool, 'final: PoolConfigurator storageLayout missing slots');
    require(providerOffset <= 12 && poolOffset <= 12, 'final: PoolConfigurator storageLayout offset');
    address storedProvider = address(
      uint160(uint256(vm.load(_m.configurator, bytes32(providerSlot))) >> (providerOffset * 8))
    );
    address storedPool = address(
      uint160(uint256(vm.load(_m.configurator, bytes32(poolSlot))) >> (poolOffset * 8))
    );
    require(storedProvider == _m.provider, 'final: PoolConfigurator _addressesProvider');
    require(storedPool == _m.pool, 'final: PoolConfigurator _pool');
  }

  function _checkReserveAndPeripheryBackPointers() internal view {
    address rewards = _requireDeployed('.contracts.rewardsController.address');
    for (uint256 i = 0; i < 2; i++) {
      address asset = i == 0 ? LIGHTER_WETH9 : LIGHTER_USDC;
      DataTypes.ReserveDataLegacy memory rd = IPoolView(_m.pool).getReserveData(asset);
      IReserveTokenView aTok = IReserveTokenView(rd.aTokenAddress);
      IReserveTokenView vTok = IReserveTokenView(rd.variableDebtTokenAddress);
      require(aTok.POOL() == _m.pool, 'final: aToken POOL');
      require(aTok.UNDERLYING_ASSET_ADDRESS() == asset, 'final: aToken underlying');
      require(aTok.RESERVE_TREASURY_ADDRESS() == _in.safe, 'final: aToken treasury');
      require(aTok.getIncentivesController() == rewards, 'final: aToken rewards');
      require(
        IReserveTokenView(_implementationOf(rd.aTokenAddress)).POOL() == _m.pool,
        'final: aToken impl POOL'
      );
      require(vTok.POOL() == _m.pool, 'final: variableDebtToken POOL');
      require(vTok.UNDERLYING_ASSET_ADDRESS() == asset, 'final: variableDebtToken underlying');
      require(vTok.getIncentivesController() == rewards, 'final: variableDebtToken rewards');
      require(
        IReserveTokenView(_implementationOf(rd.variableDebtTokenAddress)).POOL() == _m.pool,
        'final: variableDebtToken impl POOL'
      );
    }

    require(
      IRewardsView(rewards).EMISSION_MANAGER() == _m.emissionManager &&
        IRewardsView(_implementationOf(rewards)).EMISSION_MANAGER() == _m.emissionManager,
      'final: RewardsController EMISSION_MANAGER'
    );
    require(
      IEmissionManagerView(_m.emissionManager).getRewardsController() == rewards,
      'final: EmissionManager rewards'
    );
    require(
      IGatewayView(_m.gateway).getWETHAddress() == LIGHTER_WETH9,
      'final: WrappedTokenGateway WETH'
    );
    address factory = _requireDeployed('.contracts.staticATokenFactory.address');
    address stataImpl = _requireDeployed('.contracts.staticATokenImplementation.address');
    require(
      IStataFactoryView(factory).POOL() == _m.pool &&
        IStataFactoryView(_implementationOf(factory)).POOL() == _m.pool &&
        IStataFactoryView(factory).PROXY_ADMIN() == _m.proxyAdmin &&
        IStataFactoryView(factory).STATA_TOKEN_IMPL() == stataImpl,
      'final: StaticATokenFactory back-pointers'
    );
    require(
      IStataImplView(stataImpl).POOL() == _m.pool &&
        IStataImplView(stataImpl).POOL_ADDRESSES_PROVIDER() == _m.provider &&
        IStataImplView(stataImpl).INCENTIVES_CONTROLLER() == rewards,
      'final: StaticATokenImplementation back-pointers'
    );
    AaveV3ConfigEngine engine = AaveV3ConfigEngine(_m.configEngine);
    require(
      address(engine.POOL()) == _m.pool &&
        address(engine.POOL_CONFIGURATOR()) == _m.configurator &&
        address(engine.ORACLE()) == _m.aaveOracle &&
        engine.COLLECTOR() == _in.safe &&
        engine.DEFAULT_INTEREST_RATE_STRATEGY() == _m.rateStrategy &&
        engine.REWARDS_CONTROLLER() == rewards,
      'final: ConfigEngine back-pointers'
    );
    if (_m.listingPayload != address(0)) {
      LighterListingPayload lp = LighterListingPayload(_m.listingPayload);
      require(
        address(lp.POOL()) == _m.pool && address(lp.CONFIG_ENGINE()) == _m.configEngine,
        'final: ListingPayload back-pointers'
      );
    }
    IUiPoolDataProviderView ui = IUiPoolDataProviderView(
      _requireDeployed('.contracts.uiPoolDataProvider.address')
    );
    require(
      ui.networkBaseTokenPriceInUsdProxyAggregator() == _in.ethSource &&
        ui.marketReferenceCurrencyPriceInUsdProxyAggregator() == _in.usdcSource,
      'final: UiPoolDataProvider aggregators'
    );
  }

  /// @dev F6 phase 1: Multicall3 canonical runtime codehash and aggregate3 probe.
  function _checkMulticall3() internal view {
    address mc = _in.multicall3;
    require(mc.codehash == MULTICALL3_CODEHASH, 'final: Multicall3 codehash');
    IMulticall3View.Call3[] memory calls = new IMulticall3View.Call3[](2);
    calls[0] = IMulticall3View.Call3({
      target: mc,
      allowFailure: false,
      callData: abi.encodeCall(IMulticall3View.getChainId, ())
    });
    calls[1] = IMulticall3View.Call3({
      target: mc,
      allowFailure: false,
      callData: abi.encodeCall(IMulticall3View.getBlockNumber, ())
    });
    IMulticall3View.Result[] memory res = IMulticall3View(mc).aggregate3(calls);
    require(res.length == 2 && res[0].success && res[1].success, 'final: Multicall3 aggregate3');
    require(abi.decode(res[0].returnData, (uint256)) == block.chainid, 'final: Multicall3 chainId');
    require(
      abi.decode(res[1].returnData, (uint256)) == block.number,
      'final: Multicall3 blockNumber'
    );
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
    _in.multicall3 = _requireDeployed('.multicall3');
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

  /// @dev Reserve token contracts and markets.core (risk/flag/rate values from committed input).
  function _writeReserves() internal {
    _writeReserveTokens(LIGHTER_WETH9, 'WETH');
    _writeReserveTokens(LIGHTER_USDC, 'USDC');
    LighterReserveParams[] memory params = _lighterReserveParams();
    string[2] memory entries;
    entries[_in.wethMarketIndex] = _marketJson(params[0], _in.ethSource, _in.wethSeed);
    entries[_in.usdcMarketIndex] = _marketJson(params[1], _in.usdcSource, _in.usdcSeed);
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

  /// @dev One markets.core entry (F6): token addresses from the deployed Pool; every risk, cap,
  /// flag, rate and seed value from the committed input (LighterMarketInput + manifest seedAmount),
  /// never from chain reads.
  function _marketJson(
    LighterReserveParams memory p,
    address source,
    uint256 seed
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
    string memory risk = string.concat(
      ',"ltvBps":',
      _jUint(p.ltv),
      ',"liquidationThresholdBps":',
      _jUint(p.liqThreshold),
      ',"liquidationBonusBps":',
      _jUint(p.liqBonus),
      ',"liquidationProtocolFeeBps":',
      _jUint(p.liqProtocolFee),
      ',"reserveFactorBps":',
      _jUint(p.reserveFactor),
      ',"debtCeiling":0,"supplyCap":',
      _jUint(p.supplyCap),
      ',"borrowCap":',
      _jUint(p.borrowCap)
    );
    string memory flagsAndRates = string.concat(
      ',"active":true,"frozen":false,"paused":false,"borrowingEnabled":true,"flashLoanEnabled":false',
      ',"optimalUsageRatioBps":',
      _jUint(p.rates.optimalUsageRatio),
      ',"baseVariableBorrowRateBps":',
      _jUint(p.rates.baseVariableBorrowRate),
      ',"variableRateSlope1Bps":',
      _jUint(p.rates.variableRateSlope1),
      ',"variableRateSlope2Bps":',
      _jUint(p.rates.variableRateSlope2),
      ',"seedAmount":',
      _jUintString(seed),
      '}'
    );
    return string.concat(head, risk, flagsAndRates);
  }

  function _coreRolesJson() internal view returns (string memory) {
    address exec = _m.executor;
    address safe = _in.safe;
    address[] memory one = new address[](1);
    address[] memory two = new address[](2);
    address[] memory none = new address[](0);
    one[0] = exec;
    string memory execOnly = _jAddressArray(one);
    two[0] = safe;
    two[1] = exec;
    string memory safeAndExec = _jAddressArray(two);
    one[0] = safe;
    string memory safeOnly = _jAddressArray(one);
    string memory empty = _jAddressArray(none);
    string memory acl = string.concat(
      '{"DEFAULT_ADMIN":',
      execOnly,
      ',"POOL_ADMIN":',
      execOnly,
      ',"EMERGENCY_ADMIN":',
      safeOnly,
      ',"RISK_ADMIN":',
      safeAndExec,
      ',"FLASH_BORROWER":',
      empty,
      ',"BRIDGE":',
      empty,
      ',"ASSET_LISTING_ADMIN":',
      empty,
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
