// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';
import '../../scripts/lighter/DeployLighterDevnet.s.sol';
import {ACLManager} from '../../src/contracts/protocol/configuration/ACLManager.sol';
import {IPoolConfigurator} from '../../src/contracts/interfaces/IPoolConfigurator.sol';
import {ConfiguratorInputTypes} from '../../src/contracts/protocol/libraries/types/ConfiguratorInputTypes.sol';
import {AaveOracle} from '../../src/contracts/misc/AaveOracle.sol';
import {PoolAddressesProvider} from '../../src/contracts/protocol/configuration/PoolAddressesProvider.sol';
import {ATokenInstance} from '../../src/contracts/instances/ATokenInstance.sol';
import {IPool} from '../../src/contracts/interfaces/IPool.sol';
import {WETH9} from '../../src/contracts/dependencies/weth/WETH9.sol';
import {MockAggregator} from '../../src/contracts/mocks/oracle/CLAggregators/MockAggregator.sol';
import {LighterTestUsdc, CodeHolder} from './LighterMarketInput.t.sol';

/// @dev Minimal PriceGuard stub matching IPriceGuardView + IPriceOracleSentinel for unit tests.
contract MockPriceGuard {
  address public immutable ADDRESSES_PROVIDER;
  address public immutable guardian;
  address public immutable keeper;
  address public source0;

  constructor(address provider_, address guardian_, address keeper_, address source0_) {
    ADDRESSES_PROVIDER = provider_;
    guardian = guardian_;
    keeper = keeper_;
    source0 = source0_;
  }

  function pendingGuardian() external pure returns (address) {
    return address(0);
  }

  function maxRefAge() external pure returns (uint256) {
    return 180;
  }

  function maxDeviationBps() external pure returns (uint256) {
    return 300;
  }

  function maxCorePriceAge() external pure returns (uint256) {
    return 600;
  }

  function marketIds() external pure returns (uint16[] memory ids) {
    ids = new uint16[](1);
    ids[0] = 0;
  }

  function getMarket(
    uint16
  ) external view returns (bool, address, uint256, uint64, uint256, uint64, uint64) {
    return (true, source0, 0, 0, 0, 0, 0);
  }

  function isBorrowAllowed() external pure returns (bool) {
    return true;
  }

  function isLiquidationAllowed() external pure returns (bool) {
    return true;
  }
}

/// @dev Minimal DualOracle stub matching IDualOracleView for unit tests.
contract MockDualOracle {
  address public immutable ASSET;
  address public immutable COLLATERAL;
  address public immutable ASSET_PRICE_SOURCE;
  address public immutable COLLATERAL_PRICE_SOURCE;
  address public immutable GUARD;

  constructor(address a, address c, address asrc, address csrc, address g) {
    ASSET = a;
    COLLATERAL = c;
    ASSET_PRICE_SOURCE = asrc;
    COLLATERAL_PRICE_SOURCE = csrc;
    GUARD = g;
  }
}

/// @dev Minimal Executor payload for calling AaveOracle.setAssetSources through the 1-day timelock.
contract SetAssetSourcesPayload {
  address public immutable ORACLE;
  address public immutable ASSET;
  address public immutable SOURCE;

  constructor(address oracle_, address asset_, address source_) {
    ORACLE = oracle_;
    ASSET = asset_;
    SOURCE = source_;
  }

  function execute() external {
    address[] memory assets = new address[](1);
    address[] memory sources = new address[](1);
    assets[0] = ASSET;
    sources[0] = SOURCE;
    IAaveOracleAdmin(ORACLE).setAssetSources(assets, sources);
  }
}

/// @dev V2 AToken implementation with revision 2 for testing PoolConfigurator.updateAToken upgrades.
contract ATokenInstanceV2 is ATokenInstance {
  constructor(IPool pool) ATokenInstance(pool) {}

  function getRevision() internal pure override returns (uint256) {
    return 2;
  }
}

/// @dev Minimal Executor payload for calling PoolConfigurator.updateAToken through the 1-day timelock.
contract UpdateATokenPayload {
  address public immutable CONFIGURATOR;
  address public immutable ASSET;
  address public immutable TREASURY;
  address public immutable INCENTIVES;
  address public immutable IMPL;

  constructor(
    address configurator_,
    address asset_,
    address treasury_,
    address incentives_,
    address impl_
  ) {
    CONFIGURATOR = configurator_;
    ASSET = asset_;
    TREASURY = treasury_;
    INCENTIVES = incentives_;
    IMPL = impl_;
  }

  function execute() external {
    IPoolConfigurator(CONFIGURATOR).updateAToken(
      ConfiguratorInputTypes.UpdateATokenInput({
        asset: ASSET,
        treasury: TREASURY,
        incentivesController: INCENTIVES,
        name: 'Aave Lighter WETH v2',
        symbol: 'aLigWETH',
        implementation: IMPL,
        params: ''
      })
    );
  }
}

/// @dev Test harness exposing internal DeployLighterDevnet handover, checks and JSON writers.
contract DeployLighterDevnetHarness is DeployLighterDevnet {
  function setInputs(Inputs memory inputs) external {
    _in = inputs;
  }

  function setMarket(Market memory market) external {
    _m = market;
  }

  function setManifestJson(string memory json) external {
    _json = json;
  }

  function exposed_handOver() external {
    _sent = true;
    _handOver();
  }

  function exposed_revokeDeployer() external {
    _sent = true;
    _revokeDeployer();
  }

  function exposed_assertFinalState() external {
    _assertFinalState();
  }

  function exposed_readInputs() external {
    _readInputs();
  }

  function exposed_coreRolesJson() external view returns (string memory) {
    return _coreRolesJson();
  }

  function exposed_marketJson(
    uint256 idx,
    address source,
    uint256 seed
  ) external view returns (string memory) {
    LighterReserveParams[] memory params = _lighterReserveParams();
    return _marketJson(params[idx], source, seed);
  }
}

/// @notice Unit tests for AF5a F1 (role layout) and F6 phase 1 (DeployLighterDevnet._assertFinalState
/// and manifest writer).
contract DeployLighterDevnetTest is Test, LighterMarketInput {
  address internal constant SAFE_SINGLETON_FACTORY = 0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7;
  address internal constant MULTICALL3 = 0xcA11bde05977b3631167028862bE2a173976CA11;
  uint256 internal constant WETH_SEED = 0.01 ether;
  uint256 internal constant USDC_SEED = 25e6;

  // Canonical Multicall3 runtime bytecode (matches MULTICALL3_CODEHASH = 0xd5c15df6...8e770891).
  bytes internal constant MULTICALL3_CODE =
    hex'6080604052600436106100f35760003560e01c80634d2301cc1161008a578063a8b0574e11610059578063a8b0574e1461025a578063bce38bd714610275578063c3077fa914610288578063ee82ac5e1461029b57600080fd5b80634d2301cc146101ec57806372425d9d1461022157806382ad56cb1461023457806386d516e81461024757600080fd5b80633408e470116100c65780633408e47014610191578063399542e9146101a45780633e64a696146101c657806342cbb15c146101d957600080fd5b80630f28c97d146100f8578063174dea711461011a578063252dba421461013a57806327e86d6e1461015b575b600080fd5b34801561010457600080fd5b50425b6040519081526020015b60405180910390f35b61012d610128366004610a85565b6102ba565b6040516101119190610bbe565b61014d610148366004610a85565b6104ef565b604051610111929190610bd8565b34801561016757600080fd5b50437fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff0140610107565b34801561019d57600080fd5b5046610107565b6101b76101b2366004610c60565b610690565b60405161011193929190610cba565b3480156101d257600080fd5b5048610107565b3480156101e557600080fd5b5043610107565b3480156101f857600080fd5b50610107610207366004610ce2565b73ffffffffffffffffffffffffffffffffffffffff163190565b34801561022d57600080fd5b5044610107565b61012d610242366004610a85565b6106ab565b34801561025357600080fd5b5045610107565b34801561026657600080fd5b50604051418152602001610111565b61012d610283366004610c60565b61085a565b6101b7610296366004610a85565b610a1a565b3480156102a757600080fd5b506101076102b6366004610d18565b4090565b60606000828067ffffffffffffffff8111156102d8576102d8610d31565b60405190808252806020026020018201604052801561031e57816020015b6040805180820190915260008152606060208201528152602001906001900390816102f65790505b5092503660005b8281101561047757600085828151811061034157610341610d60565b6020026020010151905087878381811061035d5761035d610d60565b905060200281019061036f9190610d8f565b6040810135958601959093506103886020850185610ce2565b73ffffffffffffffffffffffffffffffffffffffff16816103ac6060870187610dcd565b6040516103ba929190610e32565b60006040518083038185875af1925050503d80600081146103f7576040519150601f19603f3d011682016040523d82523d6000602084013e6103fc565b606091505b50602080850191909152901515808452908501351761046d577f08c379a000000000000000000000000000000000000000000000000000000000600052602060045260176024527f4d756c746963616c6c333a2063616c6c206661696c656400000000000000000060445260846000fd5b5050600101610325565b508234146104e6576040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152601a60248201527f4d756c746963616c6c333a2076616c7565206d69736d6174636800000000000060448201526064015b60405180910390fd5b50505092915050565b436060828067ffffffffffffffff81111561050c5761050c610d31565b60405190808252806020026020018201604052801561053f57816020015b606081526020019060019003908161052a5790505b5091503660005b8281101561068657600087878381811061056257610562610d60565b90506020028101906105749190610e42565b92506105836020840184610ce2565b73ffffffffffffffffffffffffffffffffffffffff166105a66020850185610dcd565b6040516105b4929190610e32565b6000604051808303816000865af19150503d80600081146105f1576040519150601f19603f3d011682016040523d82523d6000602084013e6105f6565b606091505b5086848151811061060957610609610d60565b602090810291909101015290508061067d576040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152601760248201527f4d756c746963616c6c333a2063616c6c206661696c656400000000000000000060448201526064016104dd565b50600101610546565b5050509250929050565b43804060606106a086868661085a565b905093509350939050565b6060818067ffffffffffffffff8111156106c7576106c7610d31565b60405190808252806020026020018201604052801561070d57816020015b6040805180820190915260008152606060208201528152602001906001900390816106e55790505b5091503660005b828110156104e657600084828151811061073057610730610d60565b6020026020010151905086868381811061074c5761074c610d60565b905060200281019061075e9190610e76565b925061076d6020840184610ce2565b73ffffffffffffffffffffffffffffffffffffffff166107906040850185610dcd565b60405161079e929190610e32565b6000604051808303816000865af19150503d80600081146107db576040519150601f19603f3d011682016040523d82523d6000602084013e6107e0565b606091505b506020808401919091529015158083529084013517610851577f08c379a000000000000000000000000000000000000000000000000000000000600052602060045260176024527f4d756c746963616c6c333a2063616c6c206661696c656400000000000000000060445260646000fd5b50600101610714565b6060818067ffffffffffffffff81111561087657610876610d31565b6040519080825280602002602001820160405280156108bc57816020015b6040805180820190915260008152606060208201528152602001906001900390816108945790505b5091503660005b82811015610a105760008482815181106108df576108df610d60565b602002602001015190508686838181106108fb576108fb610d60565b905060200281019061090d9190610e42565b925061091c6020840184610ce2565b73ffffffffffffffffffffffffffffffffffffffff1661093f6020850185610dcd565b60405161094d929190610e32565b6000604051808303816000865af19150503d806000811461098a576040519150601f19603f3d011682016040523d82523d6000602084013e61098f565b606091505b506020830152151581528715610a07578051610a07576040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152601760248201527f4d756c746963616c6c333a2063616c6c206661696c656400000000000000000060448201526064016104dd565b506001016108c3565b5050509392505050565b6000806060610a2b60018686610690565b919790965090945092505050565b60008083601f840112610a4b57600080fd5b50813567ffffffffffffffff811115610a6357600080fd5b6020830191508360208260051b8501011115610a7e57600080fd5b9250929050565b60008060208385031215610a9857600080fd5b823567ffffffffffffffff811115610aaf57600080fd5b610abb85828601610a39565b90969095509350505050565b6000815180845260005b81811015610aed57602081850181015186830182015201610ad1565b81811115610aff576000602083870101525b50601f017fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0169290920160200192915050565b600082825180855260208086019550808260051b84010181860160005b84811015610bb1578583037fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe001895281518051151584528401516040858501819052610b9d81860183610ac7565b9a86019a9450505090830190600101610b4f565b5090979650505050505050565b602081526000610bd16020830184610b32565b9392505050565b600060408201848352602060408185015281855180845260608601915060608160051b870101935082870160005b82811015610c52577fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffa0888703018452610c40868351610ac7565b95509284019290840190600101610c06565b509398975050505050505050565b600080600060408486031215610c7557600080fd5b83358015158114610c8557600080fd5b9250602084013567ffffffffffffffff811115610ca157600080fd5b610cad86828701610a39565b9497909650939450505050565b838152826020820152606060408201526000610cd96060830184610b32565b95945050505050565b600060208284031215610cf457600080fd5b813573ffffffffffffffffffffffffffffffffffffffff81168114610bd157600080fd5b600060208284031215610d2a57600080fd5b5035919050565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052604160045260246000fd5b7f4e487b7100000000000000000000000000000000000000000000000000000000600052603260045260246000fd5b600082357fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff81833603018112610dc357600080fd5b9190910192915050565b60008083357fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe1843603018112610e0257600080fd5b83018035915067ffffffffffffffff821115610e1d57600080fd5b602001915036819003821315610a7e57600080fd5b8183823760009101908152919050565b600082357fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc1833603018112610dc357600080fd5b600082357fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffa1833603018112610dc357600080fdfea2646970667358221220bb2b5c71a328032f97c676ae39a1ec2148d3e5d6f73d95e9b17910152d61f16264736f6c634300080c0033';

  DeployLighterDevnetHarness internal harness;
  address internal deployer = makeAddr('deployer');
  address internal keeper = makeAddr('keeper');
  address internal compromised = makeAddr('compromised');
  address internal safe;
  address internal ethSource;
  address internal usdcSource;
  address internal guard;
  address internal dualUsdcWeth;
  address internal dualWethUsdc;
  MarketReport internal report;
  address internal setupBatch;
  Executor internal executor;
  LighterListingPayload internal listing;

  function setUp() public {
    vm.chainId(LIGHTER_DEVNET_CHAIN_ID);
    vm.warp(1_750_000_000);
    vm.etch(
      SAFE_SINGLETON_FACTORY,
      hex'7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3'
    );
    vm.etch(MULTICALL3, MULTICALL3_CODE);
    WETH9 weth = new WETH9();
    vm.etch(LIGHTER_WETH9, address(weth).code);
    for (uint256 slot = 0; slot < 3; slot++) {
      vm.store(LIGHTER_WETH9, bytes32(slot), vm.load(address(weth), bytes32(slot)));
    }
    vm.etch(LIGHTER_USDC, address(new LighterTestUsdc()).code);
    safe = address(new CodeHolder());
    ethSource = address(new MockAggregator(3_000e8));
    usdcSource = address(new MockAggregator(1e8));

    (
      Roles memory roles,
      MarketConfig memory config,
      DeployFlags memory flags,
      MarketReport memory empty
    ) = _getLighterMarketInput(
        deployer,
        LighterExternalAddresses({
          safe: safe,
          ethPriceSource: ethSource,
          usdcPriceSource: usdcSource
        })
      );

    setupBatch = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
    vm.startPrank(deployer);
    report = AaveV3BatchOrchestration.deployAaveV3(deployer, roles, config, flags, empty);
    guard = address(new MockPriceGuard(report.poolAddressesProvider, safe, keeper, ethSource));
    dualUsdcWeth = address(
      new MockDualOracle(LIGHTER_USDC, LIGHTER_WETH9, usdcSource, ethSource, guard)
    );
    dualWethUsdc = address(
      new MockDualOracle(LIGHTER_WETH9, LIGHTER_USDC, ethSource, usdcSource, guard)
    );
    PoolAddressesProvider(report.poolAddressesProvider).setPriceOracleSentinel(guard);

    listing = new LighterListingPayload(
      IEngine(report.configEngine),
      deployer,
      ethSource,
      usdcSource,
      WETH_SEED,
      USDC_SEED
    );
    deal(LIGHTER_WETH9, address(listing), WETH_SEED);
    LighterTestUsdc(LIGHTER_USDC).mint(address(listing), USDC_SEED);
    ACLManager(report.aclManager).addPoolAdmin(address(listing));
    listing.execute();

    executor = new Executor(safe, 1 days);
    vm.stopPrank();

    // Perform handover with the exact F1 layout and revoke deployer.
    _completeHandover();

    harness = new DeployLighterDevnetHarness();
    harness.setInputs(
      DeployLighterDevnet.Inputs({
        deployer: deployer,
        safe: safe,
        keeper: keeper,
        multicall3: MULTICALL3,
        ethSource: ethSource,
        usdcSource: usdcSource,
        guard: guard,
        dualUsdcWeth: dualUsdcWeth,
        dualWethUsdc: dualWethUsdc,
        wethMarketIndex: 0,
        usdcMarketIndex: 1,
        wethSeed: WETH_SEED,
        usdcSeed: USDC_SEED
      })
    );
    harness.setMarket(
      DeployLighterDevnet.Market({
        provider: report.poolAddressesProvider,
        registry: report.poolAddressesProviderRegistry,
        aclManager: report.aclManager,
        pool: report.poolProxy,
        configurator: report.poolConfiguratorProxy,
        aaveOracle: report.aaveOracle,
        dataProvider: report.protocolDataProvider,
        rateStrategy: report.defaultInterestRateStrategy,
        configEngine: report.configEngine,
        emissionManager: report.emissionManager,
        proxyAdmin: report.proxyAdmin,
        gateway: report.wrappedTokenGateway,
        setupBatch: setupBatch,
        executor: address(executor),
        listingPayload: address(listing)
      })
    );
    harness.setManifestJson(_minimalManifestJson());
  }

  function _completeHandover() internal {
    ACLManager acl = ACLManager(report.aclManager);
    vm.startPrank(deployer);
    acl.grantRole(acl.DEFAULT_ADMIN_ROLE(), address(executor));
    acl.grantRole(acl.POOL_ADMIN_ROLE(), address(executor));
    acl.grantRole(acl.RISK_ADMIN_ROLE(), safe);
    acl.grantRole(acl.RISK_ADMIN_ROLE(), address(executor));
    acl.grantRole(acl.EMERGENCY_ADMIN_ROLE(), safe);
    PoolAddressesProvider(report.poolAddressesProvider).setACLAdmin(address(executor));
    IOwnable(report.poolAddressesProvider).transferOwnership(address(executor));
    IOwnable(report.poolAddressesProviderRegistry).transferOwnership(address(executor));
    IOwnable(report.emissionManager).transferOwnership(address(executor));
    IOwnable(report.proxyAdmin).transferOwnership(address(executor));
    IOwnable(report.wrappedTokenGateway).transferOwnership(address(executor));
    IOwnable(setupBatch).transferOwnership(address(executor));
    acl.revokeRole(acl.POOL_ADMIN_ROLE(), deployer);
    acl.renounceRole(acl.DEFAULT_ADMIN_ROLE(), deployer);
    vm.stopPrank();
  }

  function _minimalManifestJson() internal view returns (string memory) {
    return
      string.concat(
        '{"compromised":["',
        vm.toString(compromised),
        '"],"contracts":{"rewardsController":{"address":"',
        vm.toString(report.rewardsControllerProxy),
        '"},"staticATokenFactory":{"address":"',
        vm.toString(report.staticATokenFactoryProxy),
        '"},"staticATokenImplementation":{"address":"',
        vm.toString(report.staticATokenImplementation),
        '"},"uiPoolDataProvider":{"address":"',
        vm.toString(report.uiPoolDataProvider),
        '"}}}'
      );
  }

  // ------------------------------------------------------------------------------- F1 tests

  function test_F1_finalStatePassesOnCleanDeploy() public {
    harness.exposed_assertFinalState();
    ACLManager acl = ACLManager(report.aclManager);
    assertTrue(acl.hasRole(acl.DEFAULT_ADMIN_ROLE(), address(executor)));
    assertFalse(acl.hasRole(acl.DEFAULT_ADMIN_ROLE(), safe));
    assertTrue(acl.hasRole(acl.POOL_ADMIN_ROLE(), address(executor)));
    assertFalse(acl.hasRole(acl.POOL_ADMIN_ROLE(), safe));
    assertTrue(acl.hasRole(acl.RISK_ADMIN_ROLE(), safe));
    assertTrue(acl.hasRole(acl.RISK_ADMIN_ROLE(), address(executor)));
    assertTrue(acl.hasRole(acl.EMERGENCY_ADMIN_ROLE(), safe));
    assertFalse(acl.hasRole(acl.EMERGENCY_ADMIN_ROLE(), address(executor)));
    assertFalse(acl.hasRole(acl.ASSET_LISTING_ADMIN_ROLE(), safe));
    assertFalse(acl.hasRole(acl.ASSET_LISTING_ADMIN_ROLE(), address(executor)));
    assertFalse(acl.hasRole(acl.DEFAULT_ADMIN_ROLE(), deployer));
  }

  function test_F1_safeCannotCallUpdateATokenOrSetAssetSources_executorSucceedsAfterDelay() public {
    address newSource = address(new MockAggregator(3_100e8));
    address[] memory assets = new address[](1);
    address[] memory sources = new address[](1);
    assets[0] = LIGHTER_WETH9;
    sources[0] = newSource;

    // Safe reverts calling AaveOracle.setAssetSources
    vm.prank(safe);
    vm.expectRevert();
    AaveOracle(report.aaveOracle).setAssetSources(assets, sources);

    // Safe reverts calling PoolConfigurator.updateAToken
    address newATokenImpl = address(new ATokenInstanceV2(IPool(report.poolProxy)));
    vm.prank(safe);
    vm.expectRevert();
    IPoolConfigurator(report.poolConfiguratorProxy).updateAToken(
      ConfiguratorInputTypes.UpdateATokenInput({
        asset: LIGHTER_WETH9,
        treasury: safe,
        incentivesController: report.rewardsControllerProxy,
        name: 'Aave Lighter WETH v2',
        symbol: 'aLigWETH',
        implementation: newATokenImpl,
        params: ''
      })
    );

    // Same calls succeed through the Executor after the 1-day delay
    SetAssetSourcesPayload srcPayload = new SetAssetSourcesPayload(
      report.aaveOracle,
      LIGHTER_WETH9,
      newSource
    );
    UpdateATokenPayload upgradePayload = new UpdateATokenPayload(
      report.poolConfiguratorProxy,
      LIGHTER_WETH9,
      safe,
      report.rewardsControllerProxy,
      newATokenImpl
    );

    vm.startPrank(safe);
    (, uint256 eta1) = executor.queueTransaction(address(srcPayload), '');
    (, uint256 eta2) = executor.queueTransaction(address(upgradePayload), '');
    vm.stopPrank();

    vm.warp(eta1);
    vm.startPrank(safe);
    executor.execute(address(srcPayload), '', eta1);
    executor.execute(address(upgradePayload), '', eta2);
    vm.stopPrank();

    assertEq(AaveOracle(report.aaveOracle).getSourceOfAsset(LIGHTER_WETH9), newSource);
    address aWeth = IPool(report.poolProxy).getReserveData(LIGHTER_WETH9).aTokenAddress;
    bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    assertEq(address(uint160(uint256(vm.load(aWeth, implSlot)))), newATokenImpl);
  }

  function test_F1_assertFinalStateRejectsSafePoolAdminOrAssetListingAdmin() public {
    ACLManager acl = ACLManager(report.aclManager);
    bytes32 poolAdminRole = acl.POOL_ADMIN_ROLE();
    bytes32 listingAdminRole = acl.ASSET_LISTING_ADMIN_ROLE();
    uint256 snap = vm.snapshotState();

    vm.prank(address(executor));
    acl.grantRole(poolAdminRole, safe);
    vm.expectRevert(bytes('final: POOL_ADMIN'));
    harness.exposed_assertFinalState();

    vm.revertToState(snap);
    vm.prank(address(executor));
    acl.grantRole(listingAdminRole, safe);
    vm.expectRevert(bytes('final: ASSET_LISTING_ADMIN'));
    harness.exposed_assertFinalState();
  }

  function test_F1_interruptedPreF1HandoverStripsSafePoolAndListingAdmin() public {
    // Simulate a pre-F1 interrupted handover where deployer still has DEFAULT_ADMIN and Safe
    // was granted POOL_ADMIN and ASSET_LISTING_ADMIN.
    ACLManager acl = ACLManager(report.aclManager);
    bytes32 defaultAdminRole = acl.DEFAULT_ADMIN_ROLE();
    bytes32 poolAdminRole = acl.POOL_ADMIN_ROLE();
    bytes32 listingAdminRole = acl.ASSET_LISTING_ADMIN_ROLE();
    vm.startPrank(address(executor));
    acl.grantRole(defaultAdminRole, deployer);
    acl.grantRole(poolAdminRole, safe);
    acl.grantRole(listingAdminRole, safe);
    vm.stopPrank();

    assertTrue(acl.hasRole(poolAdminRole, safe));
    assertTrue(acl.hasRole(listingAdminRole, safe));

    // Re-running handover + revokeDeployer revokes those roles from Safe and passes final checks.
    harness.exposed_handOver();
    harness.exposed_revokeDeployer();
    harness.exposed_assertFinalState();
    assertFalse(acl.hasRole(poolAdminRole, safe));
    assertFalse(acl.hasRole(listingAdminRole, safe));
  }

  // ------------------------------------------------------------------------------- F6 phase 1 tests

  function test_F6_rejectsChangedLtv() public {
    vm.prank(safe);
    IPoolConfigurator(report.poolConfiguratorProxy).configureReserveAsCollateral(
      LIGHTER_WETH9,
      70_00,
      80_00,
      105_00
    );
    vm.expectRevert(bytes('WETH: ltv / LT'));
    harness.exposed_assertFinalState();
  }

  function test_F6_rejectsChangedRateSlope() public {
    vm.prank(safe);
    IPoolConfigurator(report.poolConfiguratorProxy).setReserveInterestRateData(
      LIGHTER_WETH9,
      abi.encode(
        IDefaultInterestRateStrategyV2.InterestRateData({
          optimalUsageRatio: 80_00,
          baseVariableBorrowRate: 0,
          variableRateSlope1: 3_00,
          variableRateSlope2: 90_00
        })
      )
    );
    vm.expectRevert(bytes('WETH: launch interest rate curve'));
    harness.exposed_assertFinalState();
  }

  function test_F6_rejectsPausedReserve() public {
    vm.prank(safe);
    IPoolConfigurator(report.poolConfiguratorProxy).setReservePause(LIGHTER_WETH9, true);
    vm.expectRevert(bytes('WETH: paused'));
    harness.exposed_assertFinalState();
  }

  function test_F6_rejectsPendingLiquidationGracePeriod() public {
    vm.prank(safe);
    IPoolConfigurator(report.poolConfiguratorProxy).setReservePause(LIGHTER_WETH9, true);
    vm.prank(safe);
    IPoolConfigurator(report.poolConfiguratorProxy).setReservePause(LIGHTER_WETH9, false, 3600);
    vm.expectRevert(bytes('WETH: pending liquidation grace period'));
    harness.exposed_assertFinalState();
  }

  function test_F6_rejectsNonZeroFallbackOracle() public {
    // Set AaveOracle._fallbackOracle (slot 2 in AaveOracle) directly via vm.store.
    // Wait: test via PoolAddressesProvider or AaveOracle.setFallbackOracle as Executor!
    vm.prank(address(executor));
    AaveOracle(report.aaveOracle).setFallbackOracle(ethSource);
    vm.expectRevert(bytes('final: fallback oracle'));
    harness.exposed_assertFinalState();
  }

  function test_F6_rejectsConfiguredEModeCategory() public {
    uint256 snap = vm.snapshotState();
    vm.prank(safe);
    IPoolConfigurator(report.poolConfiguratorProxy).setEModeCategory(1, 90_00, 93_00, 102_00, 'ETH');
    vm.expectRevert(bytes('final: eMode category configured: 1'));
    harness.exposed_assertFinalState();

    vm.revertToState(snap);
    vm.prank(safe);
    IPoolConfigurator(report.poolConfiguratorProxy).setEModeCategory(
      255,
      90_00,
      93_00,
      102_00,
      'MAX'
    );
    vm.expectRevert(bytes('final: eMode category configured: 255'));
    harness.exposed_assertFinalState();
  }

  function test_F6_rejectsWrongPoolConfiguratorStorageSlots() public {
    uint256 snap = vm.snapshotState();
    // Tamper slot 52 (_addressesProvider) on PoolConfigurator proxy
    vm.store(report.poolConfiguratorProxy, bytes32(uint256(52)), bytes32(uint256(uint160(safe))));
    vm.expectRevert(bytes('final: PoolConfigurator _addressesProvider'));
    harness.exposed_assertFinalState();

    vm.revertToState(snap);
    // Tamper slot 53 (_pool) on PoolConfigurator proxy
    vm.store(report.poolConfiguratorProxy, bytes32(uint256(53)), bytes32(uint256(uint160(safe))));
    vm.expectRevert(bytes('final: PoolConfigurator _pool'));
    harness.exposed_assertFinalState();
  }

  function test_F6_rejectsExtraReserveInReservesList() public {
    // Deploy a 3rd reserve via listing or tamper Pool._reservesListCount (slot 55 in PoolStorage? No, list a real 3rd token!)
    LighterTestUsdc extraToken = new LighterTestUsdc();
    address[] memory assets = new address[](1);
    address[] memory sources = new address[](1);
    assets[0] = address(extraToken);
    sources[0] = usdcSource;
    vm.prank(address(executor));
    AaveOracle(report.aaveOracle).setAssetSources(assets, sources);

    ConfiguratorInputTypes.InitReserveInput[] memory init = new ConfiguratorInputTypes.InitReserveInput[](1);
    DataTypes.ReserveDataLegacy memory wethRd = IPool(report.poolProxy).getReserveData(LIGHTER_WETH9);
    bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    init[0] = ConfiguratorInputTypes.InitReserveInput({
      aTokenImpl: address(uint160(uint256(vm.load(wethRd.aTokenAddress, implSlot)))),
      variableDebtTokenImpl: address(
        uint160(uint256(vm.load(wethRd.variableDebtTokenAddress, implSlot)))
      ),
      useVirtualBalance: true,
      interestRateStrategyAddress: report.defaultInterestRateStrategy,
      underlyingAsset: address(extraToken),
      treasury: safe,
      incentivesController: report.rewardsControllerProxy,
      aTokenName: 'Extra',
      aTokenSymbol: 'aEXT',
      variableDebtTokenName: 'Extra Debt',
      variableDebtTokenSymbol: 'vEXT',
      params: '',
      interestRateData: abi.encode(
        IDefaultInterestRateStrategyV2.InterestRateData({
          optimalUsageRatio: 80_00,
          baseVariableBorrowRate: 0,
          variableRateSlope1: 5_00,
          variableRateSlope2: 60_00
        })
      )
    });
    vm.prank(address(executor));
    IPoolConfigurator(report.poolConfiguratorProxy).initReserves(init);

    vm.expectRevert(bytes('final: reserves list length'));
    harness.exposed_assertFinalState();
  }

  function test_F6_rejectsWrongMulticall3Codehash() public {
    vm.etch(MULTICALL3, address(new CodeHolder()).code);
    vm.expectRevert(bytes('final: Multicall3 codehash'));
    harness.exposed_assertFinalState();
  }

  function test_F6_rejectsWrongAaveOracleProviderBackPointer() public {
    address fakeProvider = address(new PoolAddressesProvider('Fake', deployer));
    address otherOracle = address(
      new AaveOracle(
        IPoolAddressesProvider(fakeProvider),
        new address[](0),
        new address[](0),
        address(0),
        address(0),
        1e8
      )
    );
    DeployLighterDevnet.Market memory bad = DeployLighterDevnet.Market({
      provider: report.poolAddressesProvider,
      registry: report.poolAddressesProviderRegistry,
      aclManager: report.aclManager,
      pool: report.poolProxy,
      configurator: report.poolConfiguratorProxy,
      aaveOracle: otherOracle,
      dataProvider: report.protocolDataProvider,
      rateStrategy: report.defaultInterestRateStrategy,
      configEngine: report.configEngine,
      emissionManager: report.emissionManager,
      proxyAdmin: report.proxyAdmin,
      gateway: report.wrappedTokenGateway,
      setupBatch: setupBatch,
      executor: address(executor),
      listingPayload: address(listing)
    });
    harness.setMarket(bad);
    vm.expectRevert(bytes('final: AaveOracle provider'));
    harness.exposed_assertFinalState();
  }

  function test_F6_rejectsWrappedTokenGatewayForAnotherPool() public {
    address otherPool = report.poolConfiguratorProxy;
    address rogueGateway = address(
      new WrappedTokenGatewayV3(LIGHTER_WETH9, address(executor), IPool(otherPool))
    );
    DeployLighterDevnet.Market memory bad = DeployLighterDevnet.Market({
      provider: report.poolAddressesProvider,
      registry: report.poolAddressesProviderRegistry,
      aclManager: report.aclManager,
      pool: report.poolProxy,
      configurator: report.poolConfiguratorProxy,
      aaveOracle: report.aaveOracle,
      dataProvider: report.protocolDataProvider,
      rateStrategy: report.defaultInterestRateStrategy,
      configEngine: report.configEngine,
      emissionManager: report.emissionManager,
      proxyAdmin: report.proxyAdmin,
      gateway: rogueGateway,
      setupBatch: setupBatch,
      executor: address(executor),
      listingPayload: address(listing)
    });
    harness.setMarket(bad);
    vm.expectRevert(bytes('final: WrappedTokenGateway Pool binding'));
    harness.exposed_assertFinalState();
  }

  // ------------------------------------------------------------------------------- Manifest writer tests

  function test_F1_F6_manifestWriterEmitsCommittedInputsAndNewRoles() public {
    string memory rolesJson = harness.exposed_coreRolesJson();
    address[] memory poolAdmins = vm.parseJsonAddressArray(rolesJson, '.acl.POOL_ADMIN');
    address[] memory riskAdmins = vm.parseJsonAddressArray(rolesJson, '.acl.RISK_ADMIN');
    address[] memory emergencyAdmins = vm.parseJsonAddressArray(rolesJson, '.acl.EMERGENCY_ADMIN');
    address[] memory listingAdmins = vm.parseJsonAddressArray(rolesJson, '.acl.ASSET_LISTING_ADMIN');
    assertEq(poolAdmins.length, 1);
    assertEq(poolAdmins[0], address(executor));
    assertEq(riskAdmins.length, 2);
    assertEq(riskAdmins[0], safe);
    assertEq(riskAdmins[1], address(executor));
    assertEq(emergencyAdmins.length, 1);
    assertEq(emergencyAdmins[0], safe);
    assertEq(listingAdmins.length, 0);

    // Mutate WETH LTV on-chain to prove _marketJson emits committed LighterMarketInput, never chain reads.
    vm.prank(safe);
    IPoolConfigurator(report.poolConfiguratorProxy).configureReserveAsCollateral(
      LIGHTER_WETH9,
      60_00,
      80_00,
      105_00
    );
    string memory wethJson = harness.exposed_marketJson(0, ethSource, WETH_SEED);
    assertEq(vm.parseJsonUint(wethJson, '.ltvBps'), 7500);
    assertEq(vm.parseJsonUint(wethJson, '.liquidationThresholdBps'), 8000);
    assertEq(vm.parseJsonUint(wethJson, '.liquidationBonusBps'), 500);
    assertEq(vm.parseJsonUint(wethJson, '.liquidationProtocolFeeBps'), 1000);
    assertEq(vm.parseJsonUint(wethJson, '.reserveFactorBps'), 1500);
    assertEq(vm.parseJsonUint(wethJson, '.debtCeiling'), 0);
    assertEq(vm.parseJsonUint(wethJson, '.supplyCap'), 50);
    assertEq(vm.parseJsonUint(wethJson, '.borrowCap'), 25);
    assertTrue(vm.parseJsonBool(wethJson, '.active'));
    assertFalse(vm.parseJsonBool(wethJson, '.frozen'));
    assertFalse(vm.parseJsonBool(wethJson, '.paused'));
    assertTrue(vm.parseJsonBool(wethJson, '.borrowingEnabled'));
    assertFalse(vm.parseJsonBool(wethJson, '.flashLoanEnabled'));
    assertEq(vm.parseJsonUint(wethJson, '.optimalUsageRatioBps'), 8000);
    assertEq(vm.parseJsonUint(wethJson, '.baseVariableBorrowRateBps'), 0);
    assertEq(vm.parseJsonUint(wethJson, '.variableRateSlope1Bps'), 300);
    assertEq(vm.parseJsonUint(wethJson, '.variableRateSlope2Bps'), 8000);
    assertEq(vm.parseJsonUint(wethJson, '.seedAmount'), WETH_SEED);
  }

  // ------------------------------------------------------------------------------- AF5a-fix (b1)

  function _inputsJson(string memory coreMarketsJson) internal view returns (string memory) {
    string memory head = string.concat(
      '{"deployer":"',
      vm.toString(deployer),
      '","safe":{"address":"',
      vm.toString(safe),
      '"},"bots":{"keeper":"',
      vm.toString(keeper),
      '"},"multicall3":"',
      vm.toString(MULTICALL3),
      '","assets":{"WETH":{"address":"',
      vm.toString(LIGHTER_WETH9),
      '"},"USDC":{"address":"',
      vm.toString(LIGHTER_USDC),
      '"}}'
    );
    string memory tail = string.concat(
      ',"contracts":{"ethPriceSource":{"address":"',
      vm.toString(ethSource),
      '"},"usdcPriceSource":{"address":"',
      vm.toString(usdcSource),
      '"}},"oracle":{"coreSources":[{"address":"',
      vm.toString(ethSource),
      '","asset":"',
      vm.toString(LIGHTER_WETH9),
      '","marketId":0}],"fixedSources":[{"address":"',
      vm.toString(usdcSource),
      '","asset":"',
      vm.toString(LIGHTER_USDC),
      '"}]},"markets":{"core":',
      coreMarketsJson,
      '}}'
    );
    return string.concat(head, tail);
  }

  function test_b1_readInputsRequiresExactlyTwoCoreMarkets() public {
    string memory wethEntry = string.concat(
      '{"symbol":"WETH","asset":"',
      vm.toString(LIGHTER_WETH9),
      '","seedAmount":"',
      vm.toString(WETH_SEED),
      '"}'
    );
    string memory usdcEntry = string.concat(
      '{"symbol":"USDC","asset":"',
      vm.toString(LIGHTER_USDC),
      '","seedAmount":"',
      vm.toString(USDC_SEED),
      '"}'
    );
    string memory thirdEntry = string.concat(
      '{"symbol":"EXTRA","asset":"',
      vm.toString(makeAddr('extraAsset')),
      '","seedAmount":"1"}'
    );

    // Exactly two entries (WETH and USDC) passes.
    harness.setManifestJson(_inputsJson(string.concat('[', wethEntry, ',', usdcEntry, ']')));
    harness.exposed_readInputs();

    // A third entry (with fields or empty object) is refused before anything is written.
    harness.setManifestJson(
      _inputsJson(string.concat('[', wethEntry, ',', usdcEntry, ',', thirdEntry, ']'))
    );
    vm.expectRevert(bytes('manifest: markets.core must have exactly two entries'));
    harness.exposed_readInputs();

    harness.setManifestJson(_inputsJson(string.concat('[', wethEntry, ',', usdcEntry, ',{}]')));
    vm.expectRevert(bytes('manifest: markets.core must have exactly two entries'));
    harness.exposed_readInputs();

    // Fewer than two entries is also refused.
    harness.setManifestJson(_inputsJson(string.concat('[', wethEntry, ']')));
    vm.expectRevert(bytes('manifest: markets.core must have exactly two entries'));
    harness.exposed_readInputs();
  }
}
