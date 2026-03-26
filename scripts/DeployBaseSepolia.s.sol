// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Script} from 'forge-std/Script.sol';
import 'forge-std/console.sol';

import {DeployAaveV3MarketBatchedBase} from './misc/DeployAaveV3MarketBatchedBase.sol';
import '../src/deployments/interfaces/IMarketReportTypes.sol';
import {MockAggregator} from '../src/contracts/mocks/oracle/CLAggregators/MockAggregator.sol';
import {TestnetERC20} from '../src/contracts/mocks/testnet-helpers/TestnetERC20.sol';

/**
 * @title DeployBaseSepolia
 * @notice LightLend full deployment on Base Sepolia testnet.
 *
 * Deploy:
 *   source .env && forge script scripts/DeployBaseSepolia.s.sol:DeployBaseSepolia \
 *     --rpc-url https://sepolia.base.org --broadcast -vvv
 */
contract DeployBaseSepolia is DeployAaveV3MarketBatchedBase {
  string  constant MARKET_ID   = 'LightLend Base Sepolia';
  uint256 constant PROVIDER_ID = 84532;
  uint8   constant ORACLE_DECIMALS = 8;

  uint128 constant FLASH_LOAN_PREMIUM_TOTAL       = 5;  // 5 bps
  uint128 constant FLASH_LOAN_PREMIUM_TO_PROTOCOL  = 4;  // 4 bps

  function _getMarketInput(
    address deployer
  )
    internal
    pure
    override
    returns (
      Roles memory roles,
      MarketConfig memory config,
      DeployFlags memory flags,
      MarketReport memory deployedContracts
    )
  {
    // ⚠ SECURITY: All roles assigned to deployer for initial setup ONLY.
    // POST-DEPLOYMENT OWNERSHIP TRANSFER REQUIRED:
    //   1. Deploy a multisig (e.g., Gnosis Safe) or governance timelock
    //   2. Transfer marketOwner:    PoolAddressesProvider.transferOwnership(multisig)
    //   3. Transfer poolAdmin:      ACLManager.addPoolAdmin(multisig) then ACLManager.removePoolAdmin(deployer)
    //   4. Transfer emergencyAdmin: ACLManager.addEmergencyAdmin(multisig) then ACLManager.removeEmergencyAdmin(deployer)
    //   5. Renounce DEFAULT_ADMIN_ROLE from deployer on ACLManager
    //   6. Verify no roles remain on deployer address
    // DO NOT operate in production with a single EOA holding all roles.
    roles.marketOwner    = deployer;
    roles.emergencyAdmin = deployer;
    roles.poolAdmin      = deployer;

    config.marketId   = MARKET_ID;
    config.providerId = PROVIDER_ID;
    config.oracleDecimals = ORACLE_DECIMALS;

    config.flashLoanPremiumTotal      = FLASH_LOAN_PREMIUM_TOTAL;
    config.flashLoanPremiumToProtocol = FLASH_LOAN_PREMIUM_TO_PROTOCOL;

    // These will be deployed in the pre-deploy step
    // but we must set placeholder non-zero addresses for UiPoolDataProvider
    config.networkBaseTokenPriceInUsdProxyAggregator        = address(1);
    config.marketReferenceCurrencyPriceInUsdProxyAggregator = address(1);

    // Skip wrapped native token gateway (we use WETH ERC20 directly)
    config.wrappedNativeToken = address(0);

    return (roles, config, flags, deployedContracts);
  }
}
