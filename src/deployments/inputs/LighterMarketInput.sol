// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import './MarketInput.sol';
import {IAaveV3ConfigEngine as IEngine} from '../../contracts/extensions/v3-config-engine/IAaveV3ConfigEngine.sol';
import {EngineFlags} from '../../contracts/extensions/v3-config-engine/EngineFlags.sol';

interface ILighterDecimals {
  function decimals() external view returns (uint8);
}

/**
 * @title LighterMarketInput
 * @notice Reproducible market input for the Lumina core pool on Lighter EVM devnet (chain 19529),
 * CORE-05/09. Every external address is checked for code before use; nothing is inherited from
 * the HyperEVM `DefaultMarketInput`.
 *
 * Roles during the batch (CORE-02): the deployer is market owner and pool admin only for the
 * length of the deploy (`scripts/lighter/DeployLighterDevnet.s.sol`), which sets the sources, lists
 * and seeds, then hands every role to the Safe / Executor and revokes itself. EMERGENCY_ADMIN goes
 * to the Safe directly. The treasury / fee receiver is the Safe (spec 3.4): `config.treasury` is
 * set, so the batch deploys no Collector. The price guard is not a market input: it is deployed
 * after the market, against the real PoolAddressesProvider (plan.md, S4c deploy order).
 *
 * Risk parameters (spec 3.1) and the values chosen here (governance-tunable by the Safe):
 *
 * | Reserve | LTV | LT  | LB | RF  | Liq. protocol fee | Supply cap | Borrow cap |
 * |---------|-----|-----|----|-----|-------------------|------------|------------|
 * | WETH    | 75% | 80% | 5% | 15% | 10% of the bonus  | 50 WETH    | 25 WETH    |
 * | USDC    | 75% | 78% | 5% | 10% | 10% of the bonus  | 150,000    | 75,000     |
 *
 * Caps are small on purpose (devnet, thin liquidity, keeper-checked oracle). Interest rates are
 * conservative: the kink sits at 80% utilization (Aave mainnet uses 90%) so withdrawals keep a
 * liquidity buffer, and slope 2 is steep:
 *  - WETH: base 0%, slope1 3%, slope2 80%, optimal 80%;
 *  - USDC: base 0%, slope1 5%, slope2 60%, optimal 80%.
 * Flash loans are disabled on both reserves (no devnet use case; the liquidator uses inventory),
 * no isolation mode, no siloed borrowing, no eMode.
 */
abstract contract LighterMarketInput is MarketInput {
  uint256 internal constant LIGHTER_DEVNET_CHAIN_ID = 19529;
  /// @dev Lighter preinstalls (spec 3.1, 4).
  address internal constant LIGHTER_WETH9 = 0x660000000000000000000000000000000000000c;
  address internal constant LIGHTER_USDC = 0xf2A5728d366c6d0f764Af612cD47F3608E2B4d5B;

  string internal constant LIGHTER_MARKET_ID = 'Lumina Lighter Devnet';
  /// @dev Base currency USD (AaveOracle base currency address(0)), 8 decimals.
  uint8 internal constant LIGHTER_ORACLE_DECIMALS = 8;
  /// @dev Upstream defaults (0.05% / 0.04%); flash loans are disabled per reserve anyway.
  uint128 internal constant LIGHTER_FLASH_LOAN_PREMIUM_TOTAL = 5;
  uint128 internal constant LIGHTER_FLASH_LOAN_PREMIUM_TO_PROTOCOL = 4;

  /// @dev Liquidation protocol fee: 10% of the liquidation bonus (same as the isolated pairs).
  uint256 internal constant LIGHTER_LIQ_PROTOCOL_FEE = 10_00;

  string internal constant LIGHTER_NETWORK_NAME = 'Lighter';
  string internal constant LIGHTER_NETWORK_ABBREVIATION = 'Lig';

  /// @notice Addresses the market needs from outside lumina-core (manifest values).
  struct LighterExternalAddresses {
    address safe; // Safe 2/3: EMERGENCY_ADMIN at the batch, treasury / fee receiver
    address ethPriceSource; // LighterCorePriceSource, Core market 0 (ETH perp), prices WETH
    address usdcPriceSource; // FixedPriceSource, $1.00, prices USDC
  }

  /// @notice Risk parameters of one reserve, in the config engine's units (bps, whole tokens).
  struct LighterReserveParams {
    address asset;
    string symbol;
    uint8 decimals;
    uint256 ltv;
    uint256 liqThreshold;
    uint256 liqBonus; // bonus above 100%, e.g. 5_00 = 5%
    uint256 reserveFactor;
    uint256 liqProtocolFee;
    uint256 supplyCap; // whole tokens
    uint256 borrowCap; // whole tokens
    IEngine.InterestRateInputData rates;
  }

  /// @dev The upstream entry point takes no external addresses; the Lighter market needs them.
  function _getMarketInput(
    address
  )
    internal
    pure
    virtual
    override
    returns (Roles memory, MarketConfig memory, DeployFlags memory, MarketReport memory)
  {
    revert('LighterMarketInput: use _getLighterMarketInput with the manifest addresses');
  }

  /**
   * @notice The batch input for chain 19529. Reverts unless every external address has code.
   * @param deployer the broadcasting deploy key (temporary market owner and pool admin)
   */
  function _getLighterMarketInput(
    address deployer,
    LighterExternalAddresses memory ext
  )
    internal
    view
    returns (
      Roles memory roles,
      MarketConfig memory config,
      DeployFlags memory flags,
      MarketReport memory deployedContracts
    )
  {
    _requireLighterAddresses(ext);
    require(deployer != address(0), 'LighterMarketInput: deployer');
    require(
      deployer != ext.safe && deployer.code.length == 0,
      'LighterMarketInput: deployer must be an EOA distinct from the Safe'
    );

    roles.marketOwner = deployer;
    roles.poolAdmin = deployer;
    roles.emergencyAdmin = ext.safe;

    config.marketId = LIGHTER_MARKET_ID;
    config.providerId = LIGHTER_DEVNET_CHAIN_ID;
    config.oracleDecimals = LIGHTER_ORACLE_DECIMALS;
    config.flashLoanPremiumTotal = LIGHTER_FLASH_LOAN_PREMIUM_TOTAL;
    config.flashLoanPremiumToProtocol = LIGHTER_FLASH_LOAN_PREMIUM_TO_PROTOCOL;
    // CORE-08: real feeds for UiPoolDataProviderV3 (network base token = ETH/USD from the Lighter
    // Core index; market reference currency = USD at $1).
    config.networkBaseTokenPriceInUsdProxyAggregator = ext.ethPriceSource;
    config.marketReferenceCurrencyPriceInUsdProxyAggregator = ext.usdcPriceSource;
    config.wrappedNativeToken = LIGHTER_WETH9;
    // Spec 3.4: the treasury / fee receiver is the Safe (no Collector is deployed).
    config.treasury = ext.safe;
    flags.l2 = false;

    return (roles, config, flags, deployedContracts);
  }

  /// @notice Spec 3.1 reserves: WETH (priced by the ETH perp index) and USDC ($1.00).
  function _lighterReserveParams() internal pure returns (LighterReserveParams[] memory params) {
    params = new LighterReserveParams[](2);
    params[0] = LighterReserveParams({
      asset: LIGHTER_WETH9,
      symbol: 'WETH',
      decimals: 18,
      ltv: 75_00,
      liqThreshold: 80_00,
      liqBonus: 5_00,
      reserveFactor: 15_00,
      liqProtocolFee: LIGHTER_LIQ_PROTOCOL_FEE,
      supplyCap: 50,
      borrowCap: 25,
      rates: IEngine.InterestRateInputData({
        optimalUsageRatio: 80_00,
        baseVariableBorrowRate: 0,
        variableRateSlope1: 3_00,
        variableRateSlope2: 80_00
      })
    });
    params[1] = LighterReserveParams({
      asset: LIGHTER_USDC,
      symbol: 'USDC',
      decimals: 6,
      ltv: 75_00,
      liqThreshold: 78_00,
      liqBonus: 5_00,
      reserveFactor: 10_00,
      liqProtocolFee: LIGHTER_LIQ_PROTOCOL_FEE,
      supplyCap: 150_000,
      borrowCap: 75_000,
      rates: IEngine.InterestRateInputData({
        optimalUsageRatio: 80_00,
        baseVariableBorrowRate: 0,
        variableRateSlope1: 5_00,
        variableRateSlope2: 60_00
      })
    });
  }

  /// @notice Config-engine listings for both reserves, priced by the given sources.
  function _lighterListings(
    address ethPriceSource,
    address usdcPriceSource
  ) internal pure returns (IEngine.Listing[] memory listings) {
    LighterReserveParams[] memory params = _lighterReserveParams();
    listings = new IEngine.Listing[](params.length);
    for (uint256 i = 0; i < params.length; i++) {
      LighterReserveParams memory p = params[i];
      listings[i] = IEngine.Listing({
        asset: p.asset,
        assetSymbol: p.symbol,
        priceFeed: p.asset == LIGHTER_WETH9 ? ethPriceSource : usdcPriceSource,
        rateStrategyParams: p.rates,
        enabledToBorrow: EngineFlags.ENABLED,
        borrowableInIsolation: EngineFlags.DISABLED,
        withSiloedBorrowing: EngineFlags.DISABLED,
        flashloanable: EngineFlags.DISABLED,
        ltv: p.ltv,
        liqThreshold: p.liqThreshold,
        liqBonus: p.liqBonus,
        reserveFactor: p.reserveFactor,
        supplyCap: p.supplyCap,
        borrowCap: p.borrowCap,
        debtCeiling: 0,
        liqProtocolFee: p.liqProtocolFee
      });
    }
  }

  function _lighterPoolContext() internal pure returns (IEngine.PoolContext memory) {
    return
      IEngine.PoolContext({
        networkName: LIGHTER_NETWORK_NAME,
        networkAbbreviation: LIGHTER_NETWORK_ABBREVIATION
      });
  }

  /// @notice CORE-09: refuse a wrong chain or any codeless external address.
  function _requireLighterAddresses(LighterExternalAddresses memory ext) internal view {
    require(block.chainid == LIGHTER_DEVNET_CHAIN_ID, 'LighterMarketInput: not chain 19529');
    _requireCode(LIGHTER_WETH9, 'WETH9');
    _requireCode(LIGHTER_USDC, 'USDC');
    _requireCode(ext.safe, 'Safe');
    _requireCode(ext.ethPriceSource, 'ETH price source');
    _requireCode(ext.usdcPriceSource, 'USDC price source');
    require(
      ILighterDecimals(LIGHTER_WETH9).decimals() == 18,
      'LighterMarketInput: WETH9 decimals != 18'
    );
    require(
      ILighterDecimals(LIGHTER_USDC).decimals() == 6,
      'LighterMarketInput: USDC decimals != 6'
    );
  }

  function _requireCode(address target, string memory label) internal view {
    require(
      target != address(0) && target.code.length > 0,
      string.concat('LighterMarketInput: no code at ', label)
    );
  }
}
