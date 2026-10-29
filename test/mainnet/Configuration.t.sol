// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ScriptTools } from "../../lib/dss-test/src/ScriptTools.sol";

import { stdJson }  from "../../lib/forge-std/src/StdJson.sol";
import { Test, Vm } from "../../lib/forge-std/src/Test.sol";

import { IAccessControl } from "../../lib/spark-prime-vault/lib/oz/contracts/access/IAccessControl.sol";

import { SparkPrimeVault } from "../../lib/spark-prime-vault/src/SparkPrimeVault.sol";

import { DeployPASBase, PASInstance } from "../../lib/spark-pas-deploy/deploy/Deploy.sol";

import { DeploySparkPrimeVaultBase, IControllerLike } from "../../deploy/Deploy.sol";

interface IERC20Like {

    function allowance(address owner, address spender) external view returns (uint256);

    function decimals() external view returns (uint8);

}

interface IERC4626Like {

    function asset() external view returns (address);

}

interface IAccessControlLike {

    function hasRole(bytes32 role, address account) external view returns (bool);

    function getRoleMemberCount(bytes32 role) external view returns (uint256);

}

interface IControllerViewLike {

    struct Wire {
        bytes4 callSelector;
        bytes4 delegateSelector;
    }

    struct IntegrationConfig {
        address facet;
        Wire[]  wires;
    }

    struct Integration {
        bytes32           id;
        IntegrationConfig config;
    }

    struct Dispatch {
        address facet;
        bytes4  delegateSelector;
    }

    function accessControls() external view returns (address);

    function beacon() external view returns (address);

    function proxy() external view returns (address);

    function rateLimits() external view returns (address);

    function integrations() external view returns (Integration[] memory);

    function getConfig(bytes32 integrationId) external view returns (IntegrationConfig memory);

    function getDispatch(bytes4 callSelector) external view returns (Dispatch memory);

    function erc4626_getMaxExchangeRate(address token) external view returns (uint256);

}

interface IBeaconLike {

    function getConfig(bytes32 integrationId)
        external
        view
        returns (IControllerViewLike.IntegrationConfig memory);

}

interface IERC4626FacetLike {

    function EXCHANGE_RATE_PRECISION() external pure returns (uint256);

}

interface IPAUFactoryLike {

    function beacon() external view returns (address);

}

interface IRateLimitsLike {

    struct RateLimitData {
        uint256 maxAmount;
        uint256 slope;
        uint256 lastAmount;
        uint256 lastUpdated;
    }

    function CONTROLLER() external view returns (bytes32);

    function getRateLimitData(bytes32 key) external view returns (RateLimitData memory);

}

abstract contract ConfigurationTestBase is DeploySparkPrimeVaultBase, DeployPASBase, Test {

    using ScriptTools for string;
    using stdJson for string;

    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    bytes32 internal constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");
    bytes32 internal constant ERC4626_FACET  = "ERC4626_FACET";

    address internal deployer = makeAddr("deployer");

    PASConfig internal pasCfg;

    VaultConfig internal vaultCfg;

    SparkPrimeVault internal spPrime;

    PASInstance internal pas;

    address internal spPrimeImplementation;
    address internal takerAlmProxy;
    address internal pauFactory;
    address internal allocatorAgent;

    PAUInstance[] internal paus;

    Vm.Log[] internal _deployLogs;

    function setUp() public virtual {
        vm.createSelectFork(getChain("mainnet").rpcUrl);

        _deployPAS();
        _deploySparkPrimeVault(deployer);
    }

    function _deployPAS() internal {
        string memory config = vm.readFile(
            string(abi.encodePacked(vm.projectRoot(), "/script/input/1/deploy-spark-prime-vault-production.json"))
        );

        pasCfg = PASConfig({
            owner       : config.readAddress(".pas.owner"),
            minDelay    : config.readUint(".pas.minDelay"),
            coreCouncil : config.readAddress(".pas.coreCouncil"),
            cancellers  : config.readAddressArray(".pas.cancellers"),
            pausers     : config.readAddressArray(".pas.pausers")
        });

        vm.startPrank(deployer);
        pas = _deployAndConfigurePAS(pasCfg, deployer);
        vm.stopPrank();

        vm.label(pas.beamState,    "beamState");
        vm.label(pas.configurator, "configurator");
        vm.label(pas.timelock,     "timelock");
    }

    function _deploySparkPrimeVault(address deployer_) internal {
        SparkPrimeVaultConfig memory cfg = _loadConfig();

        vm.recordLogs();

        vm.startPrank(deployer_);
        DeployedInstance memory deployed = _deployAndConfigure(cfg, deployer_);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i; i < logs.length; ++i) {
            _deployLogs.push(logs[i]);
        }

        vaultCfg       = cfg.vault;
        pauFactory     = cfg.pauFactory;
        allocatorAgent = cfg.allocatorAgent;

        spPrime               = SparkPrimeVault(deployed.spPrime);
        spPrimeImplementation = deployed.spPrimeImplementation;
        takerAlmProxy         = deployed.paus[0].almProxy;

        for (uint256 i; i < deployed.paus.length; ++i) {
            paus.push(deployed.paus[i]);

            vm.label(deployed.paus[i].accessControls, string(abi.encodePacked(cfg.paus[i].name, ".accessControls")));
            vm.label(deployed.paus[i].almProxy,       string(abi.encodePacked(cfg.paus[i].name, ".almProxy")));
            vm.label(deployed.paus[i].controller,     string(abi.encodePacked(cfg.paus[i].name, ".controller")));
            vm.label(deployed.paus[i].rateLimits,     string(abi.encodePacked(cfg.paus[i].name, ".rateLimits")));
        }

        vm.label(deployed.spPrime,               "spPrime");
        vm.label(deployed.spPrimeImplementation, "spPrimeImplementation");
    }

    /**********************************************************************************************/
    /*** Helper Functions                                                                       ***/
    /**********************************************************************************************/

    function _loadConfig() internal view returns (SparkPrimeVaultConfig memory cfg) {
        string[] memory pauNames = new string[](2);
        pauNames[0] = "spPrimePAU";
        pauNames[1] = "flcPAU";

        string memory config = vm.readFile(
            string(abi.encodePacked(vm.projectRoot(), "/script/input/1/deploy-spark-prime-vault-production.json"))
        );

        cfg = _parseConfig(config, pauNames);

        // Use the PAS configurator deployed in this test instead of the configured one.
        cfg.configurator = pas.configurator;
    }

    function _deployed() internal view returns (DeployedInstance memory deployed) {
        deployed.spPrimeImplementation = spPrimeImplementation;
        deployed.spPrime               = address(spPrime);
        deployed.paus                  = paus;
    }

    // Returns the logs emitted by `target` during deployment, optionally filtered by `topic0`
    // (zero means all events), in emission order.
    function _getEvents(address target, bytes32 topic0) internal view returns (Vm.Log[] memory logs) {
        uint256 count;

        for (uint256 i; i < _deployLogs.length; ++i) {
            if (_matches(_deployLogs[i], target, topic0)) count++;
        }

        logs = new Vm.Log[](count);

        uint256 j;

        for (uint256 i; i < _deployLogs.length; ++i) {
            if (_matches(_deployLogs[i], target, topic0)) logs[j++] = _deployLogs[i];
        }
    }

    function _matches(Vm.Log storage log, address target, bytes32 topic0) internal view returns (bool) {
        return log.emitter == target && (topic0 == bytes32(0) || log.topics[0] == topic0);
    }

    function _assertRoleGrantedEvent(Vm.Log memory log, bytes32 role, address account, address sender) internal pure {
        assertEq(log.topics[0],             IAccessControl.RoleGranted.selector);
        assertEq(log.topics[1],             role);
        assertEq(_toAddress(log.topics[2]), account);
        assertEq(_toAddress(log.topics[3]), sender);
    }

    function _assertRoleRevokedEvent(Vm.Log memory log, bytes32 role, address account, address sender) internal pure {
        assertEq(log.topics[0],             IAccessControl.RoleRevoked.selector);
        assertEq(log.topics[1],             role);
        assertEq(_toAddress(log.topics[2]), account);
        assertEq(_toAddress(log.topics[3]), sender);
    }

    function _toAddress(bytes32 b) internal pure returns (address) {
        return address(uint160(uint256(b)));
    }

    function _implementation(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

}

contract SparkPrimeVaultConfigurationTests is ConfigurationTestBase {

    function test_parseConfig() external view {
        string memory config = vm.readFile(
            string(abi.encodePacked(vm.projectRoot(), "/script/input/1/deploy-spark-prime-vault-production.json"))
        );

        string[] memory pauNames = new string[](2);
        pauNames[0] = "spPrimePAU";
        pauNames[1] = "flcPAU";

        SparkPrimeVaultConfig memory cfg = _parseConfig(config, pauNames);

        assertEq(cfg.chainId,        1);
        assertEq(cfg.pauFactory,     0x60eB26db57bD058B6D742a1f6350A7FFeAb0681E);
        assertEq(cfg.allocatorAgent, 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38);
        assertEq(cfg.configurator,   0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38);

        assertEq(cfg.vault.savingsVaultV2,         0x28B3a8fb53B741A8Fd78c0fb9A6B2393d896a43d);
        assertEq(cfg.vault.name,                   "Spark Prime USDC");
        assertEq(cfg.vault.symbol,                 "spPrime");
        assertEq(cfg.vault.admin,                  0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38);
        assertEq(cfg.vault.minDeposit,             1e18);
        assertEq(cfg.vault.minDepositCancellation, 1e18);
        assertEq(cfg.vault.minRedeem,              1e18);
        assertEq(cfg.vault.minVSR,                 1e27);
        assertEq(cfg.vault.maxVSR,                 1e27);
        assertEq(cfg.vault.maxRedeemFeeRate,       1);
        assertEq(cfg.vault.pauser,                 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38);
        assertEq(cfg.vault.unpauser,               0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38);
        assertEq(cfg.vault.operator,               0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38);
        assertEq(cfg.vault.redeemFeeSetter,        0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38);
        assertEq(cfg.vault.lossManager,            0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38);

        assertEq(cfg.paus[0].admin,                                    0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38);
        assertEq(cfg.paus[0].integrationIds.length,                    3);
        assertEq(cfg.paus[0].integrationIds[0],                        "TRANSFER_ASSET_FACET");
        assertEq(cfg.paus[0].integrationIds[1],                        "ERC4626_FACET");
        assertEq(cfg.paus[0].integrationIds[2],                        "SPARK_VAULT_FACET");
        assertEq(cfg.paus[0].transferAssetRateLimits.length,           1);
        assertEq(cfg.paus[0].erc4626RateLimits.length,                 2);
        assertEq(cfg.paus[0].sparkVaultRateLimits.length,              1);
        assertEq(cfg.paus[0].transferAssetRateLimits[0].asset,         0x28B3a8fb53B741A8Fd78c0fb9A6B2393d896a43d);
        assertEq(cfg.paus[0].transferAssetRateLimits[0].destination,   "spPrime");
        assertEq(cfg.paus[0].transferAssetRateLimits[0].maxAmount,     1e18);
        assertEq(cfg.paus[0].transferAssetRateLimits[0].slopePerDay,   0);
        assertEq(cfg.paus[0].erc4626RateLimits[0].token,              "0x28B3a8fb53B741A8Fd78c0fb9A6B2393d896a43d");
        assertEq(cfg.paus[0].erc4626RateLimits[0].asset,               0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        assertEq(cfg.paus[0].erc4626RateLimits[0].depositMaxAmount,    0);
        assertEq(cfg.paus[0].erc4626RateLimits[0].depositSlopePerDay,  0);
        assertEq(cfg.paus[0].erc4626RateLimits[0].withdrawMaxAmount,   0);
        assertEq(cfg.paus[0].erc4626RateLimits[0].withdrawSlopePerDay, 0);
        assertEq(cfg.paus[0].erc4626RateLimits[0].maxExchangeRate,     10);
        assertEq(cfg.paus[0].erc4626RateLimits[1].token,              "0x28B3a8fb53B741A8Fd78c0fb9A6B2393d896a43d");
        assertEq(cfg.paus[0].erc4626RateLimits[1].asset,               0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        assertEq(cfg.paus[0].erc4626RateLimits[1].depositMaxAmount,    0);
        assertEq(cfg.paus[0].erc4626RateLimits[1].depositSlopePerDay,  0);
        assertEq(cfg.paus[0].erc4626RateLimits[1].withdrawMaxAmount,   0);
        assertEq(cfg.paus[0].erc4626RateLimits[1].withdrawSlopePerDay, 0);
        assertEq(cfg.paus[0].erc4626RateLimits[1].maxExchangeRate,     10);
        assertEq(cfg.paus[0].sparkVaultRateLimits[0].sparkVault,       "spPrime");
        assertEq(cfg.paus[0].sparkVaultRateLimits[0].maxAmount,        1000000000000000000);
        assertEq(cfg.paus[0].sparkVaultRateLimits[0].slopePerDay,      0);

        assertEq(cfg.paus[1].admin,                                  0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38);
        assertEq(cfg.paus[1].integrationIds.length,                  1);
        assertEq(cfg.paus[1].integrationIds[0],                      "TRANSFER_ASSET_FACET");
        assertEq(cfg.paus[1].transferAssetRateLimits.length,         1);
        assertEq(cfg.paus[1].transferAssetRateLimits[0].asset,       0x28B3a8fb53B741A8Fd78c0fb9A6B2393d896a43d);
        assertEq(cfg.paus[1].transferAssetRateLimits[0].destination, "spPrimePAUAlmProxy");
        assertEq(cfg.paus[1].transferAssetRateLimits[0].maxAmount,   1e18);
        assertEq(cfg.paus[1].transferAssetRateLimits[0].slopePerDay, 0);
    }

    /**********************************************************************************************/
    /*** Proxy                                                                                  ***/
    /**********************************************************************************************/

    function test_proxy() external view {
        assertEq(_implementation(address(spPrime)), spPrimeImplementation);

        assertEq(spPrimeImplementation.code.length > 0, true);
    }

    /**********************************************************************************************/
    /*** Initialization                                                                         ***/
    /**********************************************************************************************/

    function test_initialState() external view {
        address asset = IERC4626Like(vaultCfg.savingsVaultV2).asset();

        assertEq(spPrime.savings(),  vaultCfg.savingsVaultV2);
        assertEq(spPrime.asset(),    asset);
        assertEq(spPrime.name(),     vaultCfg.name);
        assertEq(spPrime.symbol(),   vaultCfg.symbol);
        assertEq(spPrime.decimals(), 6);

        assertEq(spPrime.minDeposit(),             vaultCfg.minDeposit);
        assertEq(spPrime.minDepositCancellation(), vaultCfg.minDepositCancellation);
        assertEq(spPrime.minRedeem(),              vaultCfg.minRedeem);

        assertEq(spPrime.chi(), spPrime.RAY());
        assertEq(spPrime.rho(), block.timestamp);
        assertEq(spPrime.vsr(), spPrime.RAY());

        assertEq(spPrime.maxCapacity(),   0);
        assertEq(spPrime.redeemFeeRate(), 0);
        assertEq(spPrime.totalSupply(),   0);

        assertEq(spPrime.paused(), false);

        assertEq(IERC20Like(asset).allowance(address(spPrime), vaultCfg.savingsVaultV2), type(uint256).max);
    }

    /**********************************************************************************************/
    /*** Configuration                                                                          ***/
    /**********************************************************************************************/

    function test_vsrBounds() external view {
        assertEq(spPrime.minVSR(), vaultCfg.minVSR);
        assertEq(spPrime.maxVSR(), vaultCfg.maxVSR);
    }

    function test_maxRedeemFeeRate() external view {
        assertEq(spPrime.maxRedeemFeeRate(), vaultCfg.maxRedeemFeeRate);
    }

    /**********************************************************************************************/
    /*** Roles                                                                                  ***/
    /**********************************************************************************************/

    function test_roles() external view {
        assertEq(spPrime.getRoleMemberCount(spPrime.PAUSER_ROLE()),       1);
        assertEq(spPrime.hasRole(spPrime.PAUSER_ROLE(), vaultCfg.pauser), true);

        assertEq(spPrime.getRoleMemberCount(spPrime.UNPAUSER_ROLE()),         1);
        assertEq(spPrime.hasRole(spPrime.UNPAUSER_ROLE(), vaultCfg.unpauser), true);

        assertEq(spPrime.getRoleMemberCount(spPrime.OPERATOR_ROLE()),         1);
        assertEq(spPrime.hasRole(spPrime.OPERATOR_ROLE(), vaultCfg.operator), true);

        assertEq(spPrime.getRoleMemberCount(spPrime.REDEEM_FEE_SETTER_ROLE()),                1);
        assertEq(spPrime.hasRole(spPrime.REDEEM_FEE_SETTER_ROLE(), vaultCfg.redeemFeeSetter), true);

        assertEq(spPrime.getRoleMemberCount(spPrime.LOSS_MANAGER_ROLE()),            1);
        assertEq(spPrime.hasRole(spPrime.LOSS_MANAGER_ROLE(), vaultCfg.lossManager), true);
    }

    function test_takerRole() external view {
        assertEq(spPrime.getRoleMemberCount(spPrime.TAKER_ROLE()), 1);

        assertEq(spPrime.hasRole(spPrime.TAKER_ROLE(), takerAlmProxy), true);
    }

    function test_adminHandoff() external view {
        assertEq(spPrime.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1);

        assertEq(spPrime.hasRole(DEFAULT_ADMIN_ROLE,  vaultCfg.admin), true);
        assertEq(spPrime.hasRole(DEFAULT_ADMIN_ROLE, deployer),        false);
    }

}

contract PAUConfigurationTests is ConfigurationTestBase {

    /**********************************************************************************************/
    /*** Wiring                                                                                 ***/
    /**********************************************************************************************/

    function test_pau_wiring() external view {
        assertEq(paus.length, 2);

        for (uint256 i; i < paus.length; ++i) {
            IControllerViewLike controller = IControllerViewLike(paus[i].controller);

            assertEq(controller.accessControls(), paus[i].accessControls);
            assertEq(controller.proxy(),          paus[i].almProxy);
            assertEq(controller.rateLimits(),     paus[i].rateLimits);
            assertEq(controller.beacon(),         IPAUFactoryLike(pauFactory).beacon());
        }
    }

    /**********************************************************************************************/
    /*** Roles                                                                                  ***/
    /**********************************************************************************************/

    function test_pau_roles() external view {
        SparkPrimeVaultConfig memory cfg = _loadConfig();

        for (uint256 i; i < paus.length; ++i) {
            PAUInstance memory pau    = paus[i];
            PAUConfig   memory pauCfg = cfg.paus[i];

            IAccessControlLike accessControls = IAccessControlLike(pau.accessControls);
            IAccessControlLike almProxy       = IAccessControlLike(pau.almProxy);
            IAccessControlLike rateLimits     = IAccessControlLike(pau.rateLimits);

            bytes32 controllerRole = IRateLimitsLike(pau.rateLimits).CONTROLLER();

            // The controller acts through the ALMProxy and the RateLimits.
            assertEq(almProxy.hasRole(controllerRole,   pau.controller), true);
            assertEq(rateLimits.hasRole(controllerRole, pau.controller), true);

            // The allocator agent is the only allocator.
            assertEq(accessControls.getRoleMemberCount(ALLOCATOR_ROLE),      1);
            assertEq(accessControls.hasRole(ALLOCATOR_ROLE, allocatorAgent), true);

            // The PAU admin and the PAS configurator administer the AccessControls and RateLimits.
            assertEq(accessControls.getRoleMemberCount(DEFAULT_ADMIN_ROLE),        2);
            assertEq(accessControls.hasRole(DEFAULT_ADMIN_ROLE, pauCfg.admin),     true);
            assertEq(accessControls.hasRole(DEFAULT_ADMIN_ROLE, pas.configurator), true);

            assertEq(rateLimits.hasRole(DEFAULT_ADMIN_ROLE, pauCfg.admin),     true);
            assertEq(rateLimits.hasRole(DEFAULT_ADMIN_ROLE, pas.configurator), true);

            // Only the PAU admin administers the ALMProxy.
            assertEq(almProxy.hasRole(DEFAULT_ADMIN_ROLE,  pauCfg.admin),    true);
            assertEq(almProxy.hasRole(DEFAULT_ADMIN_ROLE, pas.configurator), false);

            // The deployer is stripped everywhere.
            assertEq(accessControls.hasRole(DEFAULT_ADMIN_ROLE, deployer), false);
            assertEq(almProxy.hasRole(DEFAULT_ADMIN_ROLE,       deployer), false);
            assertEq(rateLimits.hasRole(DEFAULT_ADMIN_ROLE,     deployer), false);
        }
    }

    function test_pau_roleEvents() external view {
        SparkPrimeVaultConfig memory cfg = _loadConfig();

        for (uint256 i; i < paus.length; ++i) {
            PAUInstance memory pau    = paus[i];
            PAUConfig   memory pauCfg = cfg.paus[i];

            bytes32 controllerRole = IRateLimitsLike(pau.rateLimits).CONTROLLER();

            // ALMProxy

            Vm.Log[] memory grantedLogs = _getEvents(pau.almProxy, IAccessControl.RoleGranted.selector);
            Vm.Log[] memory revokedLogs = _getEvents(pau.almProxy, IAccessControl.RoleRevoked.selector);

            assertEq(grantedLogs.length, 3);
            assertEq(revokedLogs.length, 1);

            _assertRoleGrantedEvent(grantedLogs[0], DEFAULT_ADMIN_ROLE, deployer,       pauFactory);  // Constructor
            _assertRoleGrantedEvent(grantedLogs[1], controllerRole,     pau.controller, deployer);
            _assertRoleGrantedEvent(grantedLogs[2], DEFAULT_ADMIN_ROLE, pauCfg.admin,   deployer);

            _assertRoleRevokedEvent(revokedLogs[0], DEFAULT_ADMIN_ROLE, deployer, deployer);

            // RateLimits

            grantedLogs = _getEvents(pau.rateLimits, IAccessControl.RoleGranted.selector);
            revokedLogs = _getEvents(pau.rateLimits, IAccessControl.RoleRevoked.selector);

            assertEq(grantedLogs.length, 4);
            assertEq(revokedLogs.length, 1);

            _assertRoleGrantedEvent(grantedLogs[0], DEFAULT_ADMIN_ROLE, deployer,         pauFactory);  // Constructor
            _assertRoleGrantedEvent(grantedLogs[1], controllerRole,     pau.controller,   deployer);
            _assertRoleGrantedEvent(grantedLogs[2], DEFAULT_ADMIN_ROLE, pas.configurator, deployer);
            _assertRoleGrantedEvent(grantedLogs[3], DEFAULT_ADMIN_ROLE, pauCfg.admin,     deployer);

            _assertRoleRevokedEvent(revokedLogs[0], DEFAULT_ADMIN_ROLE, deployer, deployer);
        }
    }

    /**********************************************************************************************/
    /*** Integrations                                                                           ***/
    /**********************************************************************************************/

    function test_pau_integrations() external view {
        SparkPrimeVaultConfig memory cfg = _loadConfig();

        IBeaconLike beacon = IBeaconLike(IPAUFactoryLike(pauFactory).beacon());

        for (uint256 i; i < paus.length; ++i) {
            IControllerViewLike controller = IControllerViewLike(paus[i].controller);

            bytes32[] memory ids = cfg.paus[i].integrationIds;

            assertEq(controller.integrations().length, ids.length);

            for (uint256 j; j < ids.length; ++j) {
                IControllerViewLike.IntegrationConfig memory expected = beacon.getConfig(ids[j]);
                IControllerViewLike.IntegrationConfig memory actual   = controller.getConfig(ids[j]);

                assertEq(expected.facet != address(0), true);

                assertEq(actual.facet,        expected.facet);
                assertEq(actual.wires.length, expected.wires.length);

                for (uint256 k; k < expected.wires.length; ++k) {
                    assertEq(actual.wires[k].callSelector,     expected.wires[k].callSelector);
                    assertEq(actual.wires[k].delegateSelector, expected.wires[k].delegateSelector);

                    IControllerViewLike.Dispatch memory dispatch = controller.getDispatch(expected.wires[k].callSelector);

                    assertEq(dispatch.facet,            expected.facet);
                    assertEq(dispatch.delegateSelector, expected.wires[k].delegateSelector);
                }
            }
        }
    }

    /**********************************************************************************************/
    /*** Rate Limits                                                                            ***/
    /**********************************************************************************************/

    function test_pau_transferAssetRateLimits() external view {
        SparkPrimeVaultConfig memory cfg      = _loadConfig();
        DeployedInstance      memory deployed = _deployed();

        for (uint256 i; i < paus.length; ++i) {
            IControllerLike controller = IControllerLike(paus[i].controller);

            TransferAssetRateLimit[] memory rateLimits = cfg.paus[i].transferAssetRateLimits;

            for (uint256 j; j < rateLimits.length; ++j) {
                TransferAssetRateLimit memory rl = rateLimits[j];

                _assertRateLimit(
                    paus[i].rateLimits,
                    controller.transferAsset_getTransferRateLimitKey(rl.asset, _resolve(rl.destination, deployed)),
                    rl.maxAmount,
                    rl.slopePerDay / 1 days
                );
            }
        }
    }

    function test_pau_erc4626RateLimits() external view {
        SparkPrimeVaultConfig memory cfg      = _loadConfig();
        DeployedInstance      memory deployed = _deployed();

        for (uint256 i; i < paus.length; ++i) {
            IControllerLike controller = IControllerLike(paus[i].controller);

            ERC4626RateLimit[] memory rateLimits = cfg.paus[i].erc4626RateLimits;

            for (uint256 j; j < rateLimits.length; ++j) {
                ERC4626RateLimit memory rl = rateLimits[j];

                address token = _resolve(rl.token, deployed);

                _assertRateLimit(
                    paus[i].rateLimits,
                    controller.erc4626_getDepositRateLimitKey(token, rl.asset),
                    rl.depositMaxAmount,
                    rl.depositSlopePerDay / 1 days
                );
                _assertRateLimit(
                    paus[i].rateLimits,
                    controller.erc4626_getWithdrawRateLimitKey(token),
                    rl.withdrawMaxAmount,
                    rl.withdrawSlopePerDay / 1 days
                );
            }
        }
    }

    function test_pau_erc4626MaxExchangeRates() external view {
        SparkPrimeVaultConfig memory cfg      = _loadConfig();
        DeployedInstance      memory deployed = _deployed();

        for (uint256 i; i < paus.length; ++i) {
            IControllerViewLike controller = IControllerViewLike(paus[i].controller);

            ERC4626RateLimit[] memory rateLimits = cfg.paus[i].erc4626RateLimits;

            if (rateLimits.length == 0) continue;

            uint256 precision = IERC4626FacetLike(controller.getConfig(ERC4626_FACET).facet).EXCHANGE_RATE_PRECISION();

            for (uint256 j; j < rateLimits.length; ++j) {
                ERC4626RateLimit memory rl = rateLimits[j];

                address token = _resolve(rl.token, deployed);

                uint256 shares            = 10 ** IERC20Like(token).decimals();
                uint256 maxExpectedAssets = rl.maxExchangeRate * 10 ** IERC20Like(rl.asset).decimals();

                assertEq(controller.erc4626_getMaxExchangeRate(token), maxExpectedAssets * precision / shares);
            }
        }
    }

    function test_pau_sparkVaultRateLimits() external view {
        SparkPrimeVaultConfig memory cfg      = _loadConfig();
        DeployedInstance      memory deployed = _deployed();

        for (uint256 i; i < paus.length; ++i) {
            IControllerLike controller = IControllerLike(paus[i].controller);

            SparkVaultRateLimit[] memory rateLimits = cfg.paus[i].sparkVaultRateLimits;

            for (uint256 j; j < rateLimits.length; ++j) {
                SparkVaultRateLimit memory rl = rateLimits[j];

                _assertRateLimit(
                    paus[i].rateLimits,
                    controller.sparkVault_getTakeRateLimitKey(_resolve(rl.sparkVault, deployed)),
                    rl.maxAmount,
                    rl.slopePerDay / 1 days
                );
            }
        }
    }

    function _assertRateLimit(address rateLimits, bytes32 key, uint256 maxAmount, uint256 slope) internal view {
        IRateLimitsLike.RateLimitData memory data = IRateLimitsLike(rateLimits).getRateLimitData(key);

        assertEq(data.maxAmount,   maxAmount);
        assertEq(data.slope,       slope);
        assertEq(data.lastAmount,  maxAmount);
        assertEq(data.lastUpdated, block.timestamp);
    }

    /**********************************************************************************************/
    /*** PAS                                                                                    ***/
    /**********************************************************************************************/

    function test_pasConfigurator() external view {
        assertEq(paus.length, 2);

        for (uint256 i; i < paus.length; ++i) {
            assertEq(IAccessControlLike(paus[i].accessControls).hasRole(DEFAULT_ADMIN_ROLE, pas.configurator), true);
            assertEq(IAccessControlLike(paus[i].rateLimits).hasRole(DEFAULT_ADMIN_ROLE,     pas.configurator), true);
        }
    }

}
