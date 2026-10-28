// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ScriptTools } from "../../lib/dss-test/src/ScriptTools.sol";

import { stdJson } from "../../lib/forge-std/src/StdJson.sol";
import { Test }    from "../../lib/forge-std/src/Test.sol";

import { IERC20 } from "../../lib/spark-prime-vault/lib/oz/contracts/token/ERC20/IERC20.sol";

import { SparkPrimeVault } from "../../lib/spark-prime-vault/src/SparkPrimeVault.sol";

import { DeployPASBase, PASInstance } from "../../lib/spark-pas-deploy/deploy/Deploy.sol";

import { DeploySparkPrimeVaultBase } from "../../deploy/Deploy.sol";

interface IERC4626Like {

    function asset() external view returns (address);

}

interface IAccessControlLike {

    function hasRole(bytes32 role, address account) external view returns (bool);

}

abstract contract ConfigurationTestBase is DeploySparkPrimeVaultBase, DeployPASBase, Test {

    using ScriptTools for string;
    using stdJson for string;

    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address internal deployer = makeAddr("deployer");

    PASConfig internal pasCfg;

    VaultConfig internal vaultCfg;

    SparkPrimeVault internal spPrime;

    PASInstance internal pas;

    address internal spPrimeImplementation;
    address internal takerAlmProxy;

    address[] internal pauAccessControls;
    address[] internal pauRateLimits;

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

        vaultCfg = cfg.vault;

        spPrime               = SparkPrimeVault(deployed.spPrime);
        spPrimeImplementation = deployed.spPrimeImplementation;
        takerAlmProxy         = deployed.paus[0].almProxy;

        delete pauAccessControls;
        delete pauRateLimits;

        for (uint256 i; i < deployed.paus.length; ++i) {
            pauAccessControls.push(deployed.paus[i].accessControls);
            pauRateLimits.push(deployed.paus[i].rateLimits);
        }

        vm.label(deployed.spPrime,               "spPrime");
        vm.label(deployed.spPrimeImplementation, "spPrimeImplementation");
    }

    /**********************************************************************************************/
    /*** Helper Functions                                                                       ***/
    /**********************************************************************************************/

    function _loadConfig() internal view returns (SparkPrimeVaultConfig memory cfg) {
        string[] memory paus = new string[](2);
        paus[0] = "spPrimePAU";
        paus[1] = "flcPAU";

        string memory config = vm.readFile(
            string(abi.encodePacked(vm.projectRoot(), "/script/input/1/deploy-spark-prime-vault-production.json"))
        );

        cfg = _parseConfig(config, paus);

        // Use the PAS configurator deployed in this test instead of the configured one.
        cfg.configurator = pas.configurator;
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
        assertEq(pauAccessControls.length, 2);

        for (uint256 i; i < pauAccessControls.length; ++i) {
            assertTrue(IAccessControlLike(pauAccessControls[i]).hasRole(DEFAULT_ADMIN_ROLE, pas.configurator));
            assertTrue(IAccessControlLike(pauRateLimits[i]).hasRole(DEFAULT_ADMIN_ROLE,     pas.configurator));
        }
    }

}
