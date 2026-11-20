// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';
import '../../src/deployments/interfaces/IMarketReportTypes.sol';
import {LighterMarketInput} from '../../src/deployments/inputs/LighterMarketInput.sol';
import {AaveV3BatchOrchestration} from '../../src/deployments/projects/aave-v3-batched/AaveV3BatchOrchestration.sol';
import {IAaveV3ConfigEngine as IEngine} from '../../src/contracts/extensions/v3-config-engine/IAaveV3ConfigEngine.sol';
import {EngineFlags} from '../../src/contracts/extensions/v3-config-engine/EngineFlags.sol';
import {Executor} from '../../src/contracts/extensions/v3-config-engine/Executor.sol';
import {ACLManager} from '../../src/contracts/protocol/configuration/ACLManager.sol';
import {AaveProtocolDataProvider} from '../../src/contracts/helpers/AaveProtocolDataProvider.sol';
import {IAaveOracle} from '../../src/contracts/interfaces/IAaveOracle.sol';
import {IPool} from '../../src/contracts/interfaces/IPool.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {IDefaultInterestRateStrategyV2} from '../../src/contracts/interfaces/IDefaultInterestRateStrategyV2.sol';
import {WETH9} from '../../src/contracts/dependencies/weth/WETH9.sol';
import {MockAggregator} from '../../src/contracts/mocks/oracle/CLAggregators/MockAggregator.sol';
import {LighterListingPayload} from '../../scripts/lighter/payloads/LighterListingPayload.sol';
import {LighterCapsUpdatePayload} from '../../scripts/lighter/payloads/LighterCapsUpdatePayload.sol';

/// @dev Minimal six-decimal ERC20 etched at the Lighter USDC address (decimals are code).
contract LighterTestUsdc {
  mapping(address => uint256) public balanceOf;
  mapping(address => mapping(address => uint256)) public allowance;
  uint256 public totalSupply;

  function decimals() external pure returns (uint8) {
    return 6;
  }

  function symbol() external pure returns (string memory) {
    return 'USDC';
  }

  function name() external pure returns (string memory) {
    return 'USD Coin';
  }

  function mint(address to, uint256 amount) external {
    totalSupply += amount;
    balanceOf[to] += amount;
  }

  function approve(address spender, uint256 amount) external returns (bool) {
    allowance[msg.sender][spender] = amount;
    return true;
  }

  function transfer(address to, uint256 amount) external returns (bool) {
    balanceOf[msg.sender] -= amount;
    balanceOf[to] += amount;
    return true;
  }

  function transferFrom(address from, address to, uint256 amount) external returns (bool) {
    allowance[from][msg.sender] -= amount;
    balanceOf[from] -= amount;
    balanceOf[to] += amount;
    return true;
  }
}

contract CodeHolder {}

/// @notice LighterMarketInput (CORE-05/09) and the Lighter listing / caps payloads, on a local EVM
/// with chain id 19529 and the Lighter WETH9 / USDC addresses etched.
contract LighterMarketInputTest is Test, LighterMarketInput {
  address internal constant SAFE_SINGLETON_FACTORY = 0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7;
  address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
  uint256 internal constant WETH_SEED = 0.01 ether;
  uint256 internal constant USDC_SEED = 25e6;

  address internal deployer = makeAddr('deployer');
  address internal safe;
  address internal ethSource;
  address internal usdcSource;

  function setUp() public {
    vm.chainId(LIGHTER_DEVNET_CHAIN_ID);
    vm.etch(
      SAFE_SINGLETON_FACTORY,
      hex'7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3'
    );
    WETH9 weth = new WETH9();
    vm.etch(LIGHTER_WETH9, address(weth).code);
    for (uint256 slot = 0; slot < 3; slot++) {
      vm.store(LIGHTER_WETH9, bytes32(slot), vm.load(address(weth), bytes32(slot)));
    }
    vm.etch(LIGHTER_USDC, address(new LighterTestUsdc()).code);
    safe = address(new CodeHolder());
    ethSource = address(new MockAggregator(3_000e8));
    usdcSource = address(new MockAggregator(1e8));
  }

  function _ext() internal view returns (LighterExternalAddresses memory) {
    return
      LighterExternalAddresses({
        safe: safe,
        ethPriceSource: ethSource,
        usdcPriceSource: usdcSource
      });
  }

  function getLighterMarketInput(
    address d,
    LighterExternalAddresses memory ext
  )
    external
    view
    returns (Roles memory, MarketConfig memory, DeployFlags memory, MarketReport memory)
  {
    return _getLighterMarketInput(d, ext);
  }

  function getMarketInput() external pure {
    _getMarketInput(address(0));
  }

  // ------------------------------------------------------------------------------- input

  function test_upstreamEntryPointIsDisabled() public {
    vm.expectRevert(
      bytes('LighterMarketInput: use _getLighterMarketInput with the manifest addresses')
    );
    this.getMarketInput();
  }

  function test_rolesAndConfig() public view {
    (
      Roles memory roles,
      MarketConfig memory config,
      DeployFlags memory flags,
      MarketReport memory report
    ) = this.getLighterMarketInput(deployer, _ext());
    assertEq(roles.marketOwner, deployer, 'market owner (temporary)');
    assertEq(roles.poolAdmin, deployer, 'pool admin (temporary)');
    assertEq(roles.emergencyAdmin, safe, 'EMERGENCY_ADMIN goes to the Safe directly');
    assertEq(config.providerId, 19529);
    assertEq(config.oracleDecimals, 8);
    assertEq(config.wrappedNativeToken, LIGHTER_WETH9);
    assertEq(config.treasury, safe, 'treasury is the Safe');
    assertEq(config.networkBaseTokenPriceInUsdProxyAggregator, ethSource, 'CORE-08 ETH/USD');
    assertEq(config.marketReferenceCurrencyPriceInUsdProxyAggregator, usdcSource, 'CORE-08 $1');
    assertEq(config.paraswapAugustusRegistry, address(0));
    assertEq(config.l2SequencerUptimeFeed, address(0));
    assertFalse(flags.l2);
    assertEq(report.poolAddressesProvider, address(0));
  }

  function test_refusesOtherChains() public {
    vm.chainId(84532);
    vm.expectRevert(bytes('LighterMarketInput: not chain 19529'));
    this.getLighterMarketInput(deployer, _ext());
  }

  function test_refusesCodelessAddresses() public {
    LighterExternalAddresses memory ext = _ext();
    ext.safe = makeAddr('eoa');
    vm.expectRevert(bytes('LighterMarketInput: no code at Safe'));
    this.getLighterMarketInput(deployer, ext);

    ext = _ext();
    ext.ethPriceSource = address(0);
    vm.expectRevert(bytes('LighterMarketInput: no code at ETH price source'));
    this.getLighterMarketInput(deployer, ext);

    ext = _ext();
    ext.usdcPriceSource = makeAddr('nothing');
    vm.expectRevert(bytes('LighterMarketInput: no code at USDC price source'));
    this.getLighterMarketInput(deployer, ext);

    vm.etch(LIGHTER_USDC, '');
    vm.expectRevert(bytes('LighterMarketInput: no code at USDC'));
    this.getLighterMarketInput(deployer, _ext());

    vm.etch(LIGHTER_WETH9, '');
    vm.expectRevert(bytes('LighterMarketInput: no code at WETH9'));
    this.getLighterMarketInput(deployer, _ext());
  }

  function test_refusesTheSafeOrAContractAsDeployer() public {
    vm.expectRevert(bytes('LighterMarketInput: deployer must be an EOA distinct from the Safe'));
    this.getLighterMarketInput(safe, _ext());
  }

  function test_spec31RiskParameters() public pure {
    LighterReserveParams[] memory p = _lighterReserveParams();
    assertEq(p.length, 2);
    assertEq(p[0].asset, LIGHTER_WETH9);
    assertEq(p[0].ltv, 75_00);
    assertEq(p[0].liqThreshold, 80_00);
    assertEq(p[0].liqBonus, 5_00);
    assertEq(p[0].reserveFactor, 15_00);
    assertEq(p[1].asset, LIGHTER_USDC);
    assertEq(p[1].decimals, 6);
    assertEq(p[1].ltv, 75_00);
    assertEq(p[1].liqThreshold, 78_00);
    assertEq(p[1].liqBonus, 5_00);
    assertEq(p[1].reserveFactor, 10_00);
    for (uint256 i = 0; i < p.length; i++) {
      assertLt(p[i].ltv, p[i].liqThreshold, 'LTV < LT');
      assertLe(
        p[i].liqThreshold * (100_00 + p[i].liqBonus),
        100_00 * 100_00,
        'LT x (1 + LB) <= 100%'
      );
      assertEq(p[i].liqProtocolFee, 10_00, '10% of the bonus');
      assertGt(p[i].supplyCap, p[i].borrowCap, 'borrow cap below supply cap');
      assertLe(p[i].supplyCap, 150_000, 'small caps');
      assertEq(p[i].rates.optimalUsageRatio, 80_00, 'conservative kink');
      assertGt(p[i].rates.variableRateSlope2, p[i].rates.variableRateSlope1);
    }
  }

  // --------------------------------------------------------------------- market + payloads

  function _deployMarket() internal returns (MarketReport memory r) {
    (
      Roles memory roles,
      MarketConfig memory config,
      DeployFlags memory flags,
      MarketReport memory empty
    ) = this.getLighterMarketInput(deployer, _ext());
    vm.startPrank(deployer);
    r = AaveV3BatchOrchestration.deployAaveV3(deployer, roles, config, flags, empty);
    vm.stopPrank();
  }

  function _fundedPayload(MarketReport memory r) internal returns (LighterListingPayload listing) {
    listing = new LighterListingPayload(
      IEngine(r.configEngine),
      deployer,
      ethSource,
      usdcSource,
      WETH_SEED,
      USDC_SEED
    );
    deal(LIGHTER_WETH9, address(listing), WETH_SEED);
    LighterTestUsdc(LIGHTER_USDC).mint(address(listing), USDC_SEED);
  }

  function test_listingPayload_listsSeedsAndRenouncesInOneCall() public {
    MarketReport memory r = _deployMarket();
    assertEq(r.treasury, safe, 'treasury');
    assertEq(r.treasuryImplementation, address(0), 'no Collector');
    ACLManager acl = ACLManager(r.aclManager);
    assertTrue(acl.isEmergencyAdmin(safe), 'Safe is EMERGENCY_ADMIN from the batch');
    assertFalse(acl.isEmergencyAdmin(deployer), 'deployer never EMERGENCY_ADMIN');

    LighterListingPayload listing = _fundedPayload(r);
    vm.prank(deployer);
    acl.addPoolAdmin(address(listing));
    vm.expectRevert(bytes('LighterListingPayload: only CALLER'));
    listing.execute();
    vm.prank(deployer);
    listing.execute();

    // The role ends with the call; the seeds sit with 0x...dEaD from the same transaction.
    assertFalse(acl.isPoolAdmin(address(listing)), 'POOL_ADMIN renounced in execute()');
    LighterReserveParams[] memory p = _lighterReserveParams();
    _checkListed(r, p[0], WETH_SEED, address(listing));
    _checkListed(r, p[1], USDC_SEED, address(listing));
    assertEq(IAaveOracle(r.aaveOracle).getSourceOfAsset(LIGHTER_WETH9), ethSource);
    assertEq(IAaveOracle(r.aaveOracle).getSourceOfAsset(LIGHTER_USDC), usdcSource);
  }

  function _checkListed(
    MarketReport memory r,
    LighterReserveParams memory p,
    uint256 seed,
    address listing
  ) internal view {
    AaveProtocolDataProvider dp = AaveProtocolDataProvider(r.protocolDataProvider);
    (, uint256 ltv, uint256 lt, uint256 lb, uint256 rf, bool collateral, bool borrowing, , , ) = dp
      .getReserveConfigurationData(p.asset);
    assertEq(ltv, p.ltv);
    assertEq(lt, p.liqThreshold);
    assertEq(lb, 100_00 + p.liqBonus);
    assertEq(rf, p.reserveFactor);
    assertTrue(collateral && borrowing);
    (uint256 borrowCap, uint256 supplyCap) = dp.getReserveCaps(p.asset);
    assertEq(borrowCap, p.borrowCap);
    assertEq(supplyCap, p.supplyCap);
    assertEq(dp.getLiquidationProtocolFee(p.asset), p.liqProtocolFee);
    assertFalse(dp.getFlashLoanEnabled(p.asset), 'flash loans disabled');
    _checkRate(r, p);
    address aToken = IPool(r.poolProxy).getReserveData(p.asset).aTokenAddress;
    assertEq(IAToken(aToken).RESERVE_TREASURY_ADDRESS(), safe, 'aToken treasury');
    assertApproxEqAbs(IERC20(aToken).balanceOf(DEAD), seed, 1, 'seed held by 0x...dEaD');
    assertEq(IERC20(p.asset).balanceOf(listing), 0, 'payload spent its seed');
  }

  function _checkRate(MarketReport memory r, LighterReserveParams memory p) internal view {
    IDefaultInterestRateStrategyV2.InterestRateData memory rate = IDefaultInterestRateStrategyV2(
      r.defaultInterestRateStrategy
    ).getInterestRateDataBps(p.asset);
    assertEq(rate.optimalUsageRatio, p.rates.optimalUsageRatio);
    assertEq(rate.baseVariableBorrowRate, p.rates.baseVariableBorrowRate);
    assertEq(rate.variableRateSlope1, p.rates.variableRateSlope1);
    assertEq(rate.variableRateSlope2, p.rates.variableRateSlope2);
  }

  function test_listingPayload_unfundedRevertsAndListsNothing() public {
    MarketReport memory r = _deployMarket();
    LighterListingPayload listing = _fundedPayload(r);
    vm.prank(address(listing));
    IERC20(LIGHTER_USDC).transfer(makeAddr('elsewhere'), 1);
    vm.prank(deployer);
    ACLManager(r.aclManager).addPoolAdmin(address(listing));
    vm.prank(deployer);
    vm.expectRevert(bytes('LighterListingPayload: seeds not funded'));
    listing.execute();
    assertEq(IPool(r.poolProxy).getReserveData(LIGHTER_WETH9).aTokenAddress, address(0));
    assertEq(IPool(r.poolProxy).getReserveData(LIGHTER_USDC).aTokenAddress, address(0));
  }

  function test_capsPayloadThroughExecutor() public {
    MarketReport memory r = _deployMarket();
    ACLManager acl = ACLManager(r.aclManager);
    LighterListingPayload listing = _fundedPayload(r);
    vm.startPrank(deployer);
    acl.addPoolAdmin(address(listing));
    listing.execute();
    vm.stopPrank();

    // The Executor with POOL_ADMIN + RISK_ADMIN runs a queued caps payload after the delay.
    Executor executor = new Executor(safe, 1 days);
    vm.startPrank(deployer);
    acl.addPoolAdmin(address(executor));
    acl.addRiskAdmin(address(executor));
    vm.stopPrank();
    LighterCapsUpdatePayload caps = new LighterCapsUpdatePayload(
      IEngine(r.configEngine),
      LIGHTER_WETH9,
      40,
      EngineFlags.KEEP_CURRENT
    );
    AaveProtocolDataProvider dp = AaveProtocolDataProvider(r.protocolDataProvider);
    (uint256 borrowBefore, uint256 supplyBefore) = dp.getReserveCaps(LIGHTER_WETH9);
    assertEq(supplyBefore, 50);
    assertEq(borrowBefore, 25);
    vm.prank(safe);
    (bytes32 txHash, uint256 eta) = executor.queueTransaction(address(caps), '');
    assertEq(eta, block.timestamp + 1 days);
    assertTrue(executor.isQueued(txHash));
    vm.warp(eta - 1);
    vm.prank(safe);
    vm.expectRevert(abi.encodeWithSelector(Executor.NotReady.selector, eta));
    executor.execute(address(caps), '', eta);
    vm.warp(eta);
    vm.prank(safe);
    executor.execute(address(caps), '', eta);
    (uint256 borrowAfter, uint256 supplyAfter) = dp.getReserveCaps(LIGHTER_WETH9);
    assertEq(supplyAfter, 40, 'supply cap 50 -> 40');
    assertEq(borrowAfter, 25, 'borrow cap kept at 25');
    assertFalse(executor.isQueued(txHash));
  }
}
