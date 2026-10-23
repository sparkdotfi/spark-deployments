// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { Beacon }     from "diamond-pau/src/Beacon.sol";
import { PAUFactory } from "diamond-pau/src/PAUFactory.sol";

import { BeaconConfig } from "diamond-pau/src/libraries/BeaconConfig.sol";

import { ERC4626Facet }       from "diamond-pau/src/facets/erc4626/ERC4626Facet.sol";
import { SparkVaultFacet }    from "diamond-pau/src/facets/spark-vault/SparkVaultFacet.sol";
import { TransferAssetFacet } from "diamond-pau/src/facets/transfer-asset/TransferAssetFacet.sol";

import { AdministeredAgentFactory } from "pau-administered-agent/src/AdministeredAgentFactory.sol";
import { IAdministeredAgent }       from "pau-administered-agent/src/interfaces/IAdministeredAgent.sol";

import { SparkVault } from "spark-vaults-v2/src/SparkVault.sol";

import {
    ERC1967Proxy as SparkVaultProxy
} from "spark-vaults-v2/lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { SparkPrimeVaultDeployer } from "../deploy/SparkPrimeVaultDeployer.sol";

import { MockERC20 } from "./mocks/MockERC20.sol";

/**
 * @notice Runs the production deployment config against locally deployed stand-ins for every
 *         external dependency (USDC, spUSDC, Beacon + facets, PAUFactory, AdministeredAgent), so
 *         the exact `_deploy` code path the broadcast script uses can be exercised without a
 *         mainnet fork.
 *
 *         Only the dependency addresses are substituted; every parameter, role and rate limit
 *         comes straight from the JSON file the script will read.
 */
abstract contract SparkPrimeVaultDeploymentTestBase is Test, SparkPrimeVaultDeployer {

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    /// @dev Relative to the Foundry project root; a consumer repo overrides `_configPath()`.
    string internal constant CONFIG_PATH = "script/input/1/deploy-spark-prime-vault-production.json";

    // Mainnet addresses referenced by the config that are substituted with local deployments.
    address internal constant MAINNET_USDC   = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant MAINNET_SPUSDC = 0x28B3a8fb53B741A8Fd78c0fb9A6B2393d896a43d;

    /**********************************************************************************************/
    /*** Actors                                                                                 ***/
    /**********************************************************************************************/

    address internal deployer    = makeAddr("deployer");
    address internal beaconAdmin = makeAddr("beaconAdmin");
    address internal agentAdmin  = makeAddr("agentAdmin");
    address internal spUsdcAdmin = makeAddr("spUsdcAdmin");
    address internal relayer     = makeAddr("relayer");
    address internal freezer     = makeAddr("freezer");
    address internal grantor     = makeAddr("grantor");

    /**********************************************************************************************/
    /*** Local stand-ins for the mainnet dependencies                                           ***/
    /**********************************************************************************************/

    MockERC20  internal usdc;
    SparkVault internal spUsdc;

    Beacon     internal beacon;
    PAUFactory internal pauFactory;

    AdministeredAgentFactory internal agentFactory;
    IAdministeredAgent       internal allocatorAgent;

    /**********************************************************************************************/
    /*** Deployment under test                                                                  ***/
    /**********************************************************************************************/

    Config   internal config;
    Instance internal instance;

    /**********************************************************************************************/
    /*** Setup                                                                                  ***/
    /**********************************************************************************************/

    function setUp() public virtual {
        _deployDependencies();

        _loadConfig();

        // The config is a mainnet config; deploy under the mainnet chain id.
        vm.chainId(config.chainId);

        vm.startPrank(deployer, deployer);
        instance = _deploy(deployer, config);
        vm.stopPrank();

        _label();
    }

    function _deployDependencies() internal {
        // USDC and spUSDC (Spark Savings Vault V2).
        usdc = new MockERC20("USD Coin", "USDC", 6);

        spUsdc = SparkVault(address(new SparkVaultProxy(
            address(new SparkVault()),
            abi.encodeCall(SparkVault.initialize, (address(usdc), "Spark Savings USDC", "spUSDC", spUsdcAdmin))
        )));

        // Beacon with the three facets the PAUs integrate, and the factory bound to it.
        beacon = new Beacon(beaconAdmin);

        vm.startPrank(beaconAdmin);
        BeaconConfig.setERC4626Integration(address(beacon),       address(new ERC4626Facet()));
        BeaconConfig.setSparkVaultIntegration(address(beacon),    address(new SparkVaultFacet()));
        BeaconConfig.setTransferAssetIntegration(address(beacon), address(new TransferAssetFacet()));
        vm.stopPrank();

        pauFactory = new PAUFactory(address(beacon));

        // Existing AdministeredAgent, configured like the live spUSDC PAU agent.
        agentFactory   = new AdministeredAgentFactory();
        allocatorAgent = IAdministeredAgent(agentFactory.deploy(agentAdmin));

        vm.startPrank(agentAdmin);
        allocatorAgent.addActor(relayer);
        allocatorAgent.addRevoker(freezer);
        allocatorAgent.addGrantor(grantor);
        vm.stopPrank();
    }

    function _loadConfig() internal {
        Config memory cfg = _parseConfig(vm.readFile(_configPath()));

        cfg.pauFactory     = address(pauFactory);
        cfg.allocatorAgent = address(allocatorAgent);

        _substitute(cfg, MAINNET_USDC,   address(usdc));
        _substitute(cfg, MAINNET_SPUSDC, address(spUsdc));

        _storeConfig(cfg);
    }

    function _configPath() internal view virtual returns (string memory) {
        return CONFIG_PATH;
    }

    /// @dev Replaces every occurrence of `from` in the config's dependency addresses with `to`.
    function _substitute(Config memory cfg, address from, address to) internal pure {
        if (cfg.vault.savings == from) cfg.vault.savings = to;

        _substitute(cfg.spPrimePAU, from, to);
        _substitute(cfg.flcPAU,     from, to);
    }

    function _substitute(PAUConfig memory pau, address from, address to) internal pure {
        for (uint256 i; i < pau.transferAssetRateLimits.length; ++i) {
            TransferAssetRateLimit memory rl = pau.transferAssetRateLimits[i];

            if (rl.asset == from) rl.asset = to;
            if (rl.destination.ref == Ref.Literal && rl.destination.value == from) rl.destination.value = to;
        }

        for (uint256 i; i < pau.erc4626RateLimits.length; ++i) {
            ERC4626RateLimit memory rl = pau.erc4626RateLimits[i];

            if (rl.token == from) rl.token = to;
            if (rl.asset == from) rl.asset = to;
        }

        for (uint256 i; i < pau.sparkVaultRateLimits.length; ++i) {
            SparkVaultRateLimit memory rl = pau.sparkVaultRateLimits[i];

            if (rl.sparkVault.ref == Ref.Literal && rl.sparkVault.value == from) rl.sparkVault.value = to;
        }
    }

    /// @dev Solidity cannot copy memory arrays of structs into storage in one assignment.
    function _storeConfig(Config memory cfg) internal {
        config.chainId        = cfg.chainId;
        config.pauFactory     = cfg.pauFactory;
        config.allocatorAgent = cfg.allocatorAgent;
        config.vault          = cfg.vault;
        config.pas            = cfg.pas;

        _storePAU(config.spPrimePAU, cfg.spPrimePAU);
        _storePAU(config.flcPAU,     cfg.flcPAU);
    }

    function _storePAU(PAUConfig storage dst, PAUConfig memory src) internal {
        dst.admins         = src.admins;
        dst.integrationIds = src.integrationIds;

        delete dst.transferAssetRateLimits;
        delete dst.erc4626RateLimits;
        delete dst.sparkVaultRateLimits;

        for (uint256 i; i < src.transferAssetRateLimits.length; ++i) dst.transferAssetRateLimits.push(src.transferAssetRateLimits[i]);
        for (uint256 i; i < src.erc4626RateLimits.length;       ++i) dst.erc4626RateLimits.push(src.erc4626RateLimits[i]);
        for (uint256 i; i < src.sparkVaultRateLimits.length;    ++i) dst.sparkVaultRateLimits.push(src.sparkVaultRateLimits[i]);
    }

    function _label() internal {
        vm.label(address(usdc),           "USDC");
        vm.label(address(spUsdc),         "spUSDC");
        vm.label(address(beacon),         "Beacon");
        vm.label(address(pauFactory),     "PAUFactory");
        vm.label(address(allocatorAgent), "AllocatorAgent");

        vm.label(instance.spPrime,                   "spPrime");
        vm.label(instance.spPrimePAU.accessControls, "spPrimePAU.AccessControls");
        vm.label(instance.spPrimePAU.almProxy,       "spPrimePAU.ALMProxy");
        vm.label(instance.spPrimePAU.controller,     "spPrimePAU.Controller");
        vm.label(instance.spPrimePAU.rateLimits,     "spPrimePAU.RateLimits");
        vm.label(instance.flcPAU.accessControls,     "flcPAU.AccessControls");
        vm.label(instance.flcPAU.almProxy,           "flcPAU.ALMProxy");
        vm.label(instance.flcPAU.controller,         "flcPAU.Controller");
        vm.label(instance.flcPAU.rateLimits,         "flcPAU.RateLimits");
        vm.label(instance.pas.beamState,             "PAS.BeamState");
        vm.label(instance.pas.configurator,          "PAS.Configurator");
        vm.label(instance.pas.timelock,              "PAS.Timelock");
    }

}
