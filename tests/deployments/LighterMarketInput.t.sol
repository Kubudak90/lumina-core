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
import {WETH9} from '../../src/contracts/dependencies/weth/WETH9.sol';
import {MockAggregator} from '../../src/contracts/mocks/oracle/CLAggregators/MockAggregator.sol';
import {LighterListingPayload} from '../../scripts/lighter/payloads/LighterListingPayload.sol';
import {LighterCapsUpdatePayload} from '../../scripts/lighter/payloads/LighterCapsUpdatePayload.sol';

/// @dev Six-decimal token etched at the Lighter USDC address (decimals are code, not storage).
contract LighterTestUsdc {
  function decimals() external pure returns (uint8) {
    return 6;
  }

  function symbol() external pure returns (string memory) {
    return 'USDC';
  }

  function name() external pure returns (string memory) {
    return 'USD Coin';
  }

  function totalSupply() external pure returns (uint256) {
    return 0;
  }

  function balanceOf(address) external pure returns (uint256) {
    return 0;
  }
}

contract CodeHolder {}

/// @notice LighterMarketInput (CORE-05/09) and the Lighter listing / caps payloads, on a local EVM
/// with chain id 19529 and the Lighter WETH9 / USDC addresses etched.
contract LighterMarketInputTest is Test, LighterMarketInput {
  address internal constant SAFE_SINGLETON_FACTORY = 0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7;

  address internal deployer = makeAddr('deployer');
  address internal safe;
  address internal ethSource;
  address internal usdcSource;
  address internal guard;

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
    guard = address(new CodeHolder());
  }

  function _ext() internal view returns (LighterExternalAddresses memory) {
    return
      LighterExternalAddresses({
        safe: safe,
        ethPriceSource: ethSource,
        usdcPriceSource: usdcSource,
        priceGuard: guard
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

    ext = _ext();
    ext.priceGuard = makeAddr('noGuard');
    vm.expectRevert(bytes('LighterMarketInput: no code at price guard'));
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

  function test_deployListAndCapsPayloadThroughExecutor() public {
    (
      Roles memory roles,
      MarketConfig memory config,
      DeployFlags memory flags,
      MarketReport memory empty
    ) = this.getLighterMarketInput(deployer, _ext());
    vm.startPrank(deployer);
    MarketReport memory r = AaveV3BatchOrchestration.deployAaveV3(
      deployer,
      roles,
      config,
      flags,
      empty
    );
    vm.stopPrank();
    assertEq(r.treasury, safe, 'treasury');
    assertEq(r.treasuryImplementation, address(0), 'no Collector');
    assertTrue(r.wrappedTokenGateway != address(0), 'gateway for WETH9');
    assertTrue(r.uiPoolDataProvider != address(0), 'UI data provider with real feeds');

    ACLManager acl = ACLManager(r.aclManager);
    assertTrue(acl.isEmergencyAdmin(safe), 'Safe is EMERGENCY_ADMIN from the batch');
    assertFalse(acl.isEmergencyAdmin(deployer), 'deployer never EMERGENCY_ADMIN');

    // Listing payload: only its CALLER may run it.
    LighterListingPayload listing = new LighterListingPayload(
      IEngine(r.configEngine),
      deployer,
      ethSource,
      usdcSource
    );
    vm.startPrank(deployer);
    acl.addPoolAdmin(address(listing));
    vm.stopPrank();
    vm.expectRevert(bytes('LighterListingPayload: only CALLER'));
    listing.execute();
    vm.startPrank(deployer);
    listing.execute();
    acl.removePoolAdmin(address(listing));
    vm.stopPrank();
    assertFalse(acl.isPoolAdmin(address(listing)));

    AaveProtocolDataProvider dp = AaveProtocolDataProvider(r.protocolDataProvider);
    LighterReserveParams[] memory p = _lighterReserveParams();
    for (uint256 i = 0; i < p.length; i++) {
      (
        ,
        uint256 ltv,
        uint256 lt,
        uint256 lb,
        uint256 rf,
        bool collateral,
        bool borrowing,
        ,
        ,

      ) = dp.getReserveConfigurationData(p[i].asset);
      assertEq(ltv, p[i].ltv);
      assertEq(lt, p[i].liqThreshold);
      assertEq(lb, 100_00 + p[i].liqBonus);
      assertEq(rf, p[i].reserveFactor);
      assertTrue(collateral && borrowing);
      (uint256 borrowCap, uint256 supplyCap) = dp.getReserveCaps(p[i].asset);
      assertEq(borrowCap, p[i].borrowCap);
      assertEq(supplyCap, p[i].supplyCap);
      assertEq(dp.getLiquidationProtocolFee(p[i].asset), p[i].liqProtocolFee);
      assertFalse(dp.getFlashLoanEnabled(p[i].asset), 'flash loans disabled');
      address aToken = IPool(r.poolProxy).getReserveData(p[i].asset).aTokenAddress;
      assertEq(IAToken(aToken).RESERVE_TREASURY_ADDRESS(), safe, 'aToken treasury');
    }
    assertEq(IAaveOracle(r.aaveOracle).getSourceOfAsset(LIGHTER_WETH9), ethSource);
    assertEq(IAaveOracle(r.aaveOracle).getSourceOfAsset(LIGHTER_USDC), usdcSource);

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
    vm.prank(safe);
    (bytes32 txHash, uint256 eta) = executor.queueTransaction(address(caps), '');
    assertTrue(executor.isQueued(txHash));
    vm.prank(safe);
    vm.expectRevert(abi.encodeWithSelector(Executor.NotReady.selector, eta));
    executor.execute(address(caps), '', eta);
    vm.warp(eta);
    vm.prank(safe);
    executor.execute(address(caps), '', eta);
    (uint256 wethBorrowCap, uint256 wethSupplyCap) = dp.getReserveCaps(LIGHTER_WETH9);
    assertEq(wethSupplyCap, 40, 'supply cap lowered by the payload');
    assertEq(wethBorrowCap, 25, 'borrow cap kept');
    assertFalse(executor.isQueued(txHash));
  }
}
