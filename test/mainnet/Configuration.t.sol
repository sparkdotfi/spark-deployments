// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ScriptTools } from "../../lib/dss-test/src/ScriptTools.sol";

import { stdJson } from "../../lib/forge-std/src/StdJson.sol";
import { Test }    from "../../lib/forge-std/src/Test.sol";

import { IERC20 } from "../../lib/spark-prime-vault/lib/oz/contracts/token/ERC20/IERC20.sol";

import { SparkPrimeVault } from "../../lib/spark-prime-vault/src/SparkPrimeVault.sol";

import { DeployPASBase, PASInstance } from "../../lib/spark-pas-deploy/deploy/Deploy.sol";

import { DeploySparkPrimeVaultBase, IControllerLike, IERC20Like } from "../../deploy/Deploy.sol";

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
        pas = _deployAndConfigurePAS(deployer, pasCfg);
        vm.stopPrank();

        vm.label(pas.beamState,    "beamState");
        vm.label(pas.configurator, "configurator");
        vm.label(pas.timelock,     "timelock");
    }

    function _deploySparkPrimeVault(address deployer_) internal {
        SparkPrimeVaultConfig memory cfg = _loadConfig();

        vm.startPrank(deployer_);
        DeployedInstance memory deployed = _deploy(cfg, deployer_);
        vm.stopPrank();

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

    function _implementation(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }

}

contract SparkPrimeVaultConfigurationTests is ConfigurationTestBase {

    /**********************************************************************************************/
    /*** Proxy                                                                                  ***/
    /**********************************************************************************************/

    function test_proxy() external view {
        assertEq(_implementation(address(spPrime)), spPrimeImplementation);

        assertTrue(spPrimeImplementation.code.length > 0);
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

        assertEq(IERC20(asset).allowance(address(spPrime), vaultCfg.savingsVaultV2), type(uint256).max);
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
        assertEq(spPrime.getRoleMemberCount(spPrime.PAUSER_ROLE()), 1);
        assertTrue(spPrime.hasRole(spPrime.PAUSER_ROLE(),           vaultCfg.pauser));

        assertEq(spPrime.getRoleMemberCount(spPrime.UNPAUSER_ROLE()), 1);
        assertTrue(spPrime.hasRole(spPrime.UNPAUSER_ROLE(),           vaultCfg.unpauser));

        assertEq(spPrime.getRoleMemberCount(spPrime.OPERATOR_ROLE()), 1);
        assertTrue(spPrime.hasRole(spPrime.OPERATOR_ROLE(),           vaultCfg.operator));

        assertEq(spPrime.getRoleMemberCount(spPrime.REDEEM_FEE_SETTER_ROLE()), 1);
        assertTrue(spPrime.hasRole(spPrime.REDEEM_FEE_SETTER_ROLE(),           vaultCfg.redeemFeeSetter));

        assertEq(spPrime.getRoleMemberCount(spPrime.LOSS_MANAGER_ROLE()), 1);
        assertTrue(spPrime.hasRole(spPrime.LOSS_MANAGER_ROLE(),           vaultCfg.lossManager));
    }

    function test_takerRole() external view {
        assertEq(spPrime.getRoleMemberCount(spPrime.TAKER_ROLE()), 1);

        assertTrue(spPrime.hasRole(spPrime.TAKER_ROLE(), takerAlmProxy));
    }

    function test_adminHandoff() external view {
        assertEq(spPrime.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1);

        assertTrue(spPrime.hasRole(DEFAULT_ADMIN_ROLE,  vaultCfg.admin));
        assertFalse(spPrime.hasRole(DEFAULT_ADMIN_ROLE, deployer));
    }

    /**********************************************************************************************/
    /*** PAS                                                                                    ***/
    /**********************************************************************************************/

    function test_pasConfigurator() external view {
        assertEq(paus.length, 2);

        for (uint256 i; i < paus.length; ++i) {
            assertTrue(IAccessControlLike(paus[i].accessControls).hasRole(DEFAULT_ADMIN_ROLE, pas.configurator));
            assertTrue(IAccessControlLike(paus[i].rateLimits).hasRole(DEFAULT_ADMIN_ROLE,     pas.configurator));
        }
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
            assertTrue(almProxy.hasRole(controllerRole,   pau.controller));
            assertTrue(rateLimits.hasRole(controllerRole, pau.controller));

            // The allocator agent is the only allocator.
            assertEq(accessControls.getRoleMemberCount(ALLOCATOR_ROLE), 1);
            assertTrue(accessControls.hasRole(ALLOCATOR_ROLE,           allocatorAgent));

            // The PAU admin and the PAS configurator administer the AccessControls and RateLimits.
            assertEq(accessControls.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 2);
            assertTrue(accessControls.hasRole(DEFAULT_ADMIN_ROLE,           pauCfg.admin));
            assertTrue(accessControls.hasRole(DEFAULT_ADMIN_ROLE,           pas.configurator));

            assertTrue(rateLimits.hasRole(DEFAULT_ADMIN_ROLE, pauCfg.admin));
            assertTrue(rateLimits.hasRole(DEFAULT_ADMIN_ROLE, pas.configurator));

            // Only the PAU admin administers the ALMProxy.
            assertTrue(almProxy.hasRole(DEFAULT_ADMIN_ROLE,  pauCfg.admin));
            assertFalse(almProxy.hasRole(DEFAULT_ADMIN_ROLE, pas.configurator));

            // The deployer is stripped everywhere.
            assertFalse(accessControls.hasRole(DEFAULT_ADMIN_ROLE, deployer));
            assertFalse(almProxy.hasRole(DEFAULT_ADMIN_ROLE,       deployer));
            assertFalse(rateLimits.hasRole(DEFAULT_ADMIN_ROLE,     deployer));
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

                assertTrue(expected.facet != address(0));

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

}
