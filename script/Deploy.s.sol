// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { console2 }        from "lib/forge-std/src/console2.sol";
import { Script, stdJson } from "lib/forge-std/src/Script.sol";

import { ScriptTools } from "lib/dss-test/src/ScriptTools.sol";

import { ERC1967Proxy } from "lib/spark-prime-vault/lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { SparkPrimeVault } from "lib/spark-prime-vault/src/SparkPrimeVault.sol";

interface IDefaultPAUAssembler {

    struct AdminConfig {
        address[] accessControlAdmins;
        address[] proxyAdmins;
        address[] rateLimitsAdmins;
    }

    struct AdministeredAgentConfig {
        address[] admins;
        address[] actors;
        address[] grantors;
        address[] revokers;
    }

    function deploy(
        bytes32[]                 memory integrationIds,
        AdminConfig               memory adminConfig,
        AdministeredAgentConfig[] memory allocatorAgentConfigs
    )
        external
        returns (
            address          proxy,
            address          controller,
            address          accessControls,
            address          rateLimits,
            address[] memory allocatorAgents
        );

}

abstract contract DeploySparkPrimeVaultBase is Script {

    using stdJson     for string;
    using ScriptTools for string;

    IDefaultPAUAssembler defaultPAUAssembler;

    address[] internal admins;
    address[] internal relayers;
    address[] internal freezers;
    address[] internal grantors;

    string[] internal integrationIds;
    string[] internal paus;

    function run() public virtual {
        _setRHChainFork();

        string memory chain = vm.envOr("CHAIN", string("mainnet"));

        vm.createSelectFork(getChain(chain).rpcUrl);

        vm.setEnv("FOUNDRY_ROOT_CHAINID", vm.toString(block.chainid));

        string memory env      = vm.envString("ENV");
        string memory fileSlug = string(abi.encodePacked("deploy-spark-prime-vault-", env));
        string memory config   = ScriptTools.loadConfig(fileSlug);

        require(block.chainid == config.readUint(".chainId"), "DeploySparkPrimeVault/Invalid chain ID");

        defaultPAUAssembler = IDefaultPAUAssembler(config.readAddress(".defaultPAUAssembler"));

        // Deploy Spark Prime Vault

        vm.startBroadcast();

        address spPrimeImplementation = address(new SparkPrimeVault());

        SparkPrimeVault spPrime = SparkPrimeVault(
            address(new ERC1967Proxy(
                spPrimeImplementation,
                abi.encodeCall(
                    SparkPrimeVault.initialize,
                    (
                        config.readAddress(".spPrime.savingsVaultV2"),
                        config.readString(".spPrime.name"),
                        config.readString(".spPrime.symbol"),
                        config.readAddress(".spPrime.admin"),
                        config.readUint(".spPrime.minimumDeposit"),
                        config.readUint(".spPrime.minimumDepositCancellation"),
                        config.readUint(".spPrime.minimumRedeem")
                    )
                )
            ))
        );

        vm.stopBroadcast();

        console2.log("Deployed Spark Prime Vault");

        ScriptTools.exportContract(fileSlug, string(abi.encodePacked("spPrime.proxy")), address(spPrime));
        ScriptTools.exportContract(fileSlug, string(abi.encodePacked("spPrime.implementation")), address(spPrimeImplementation));

        // Deploy PAU's

        for (uint16 i; i < paus.length; ++i) {
            admins         = config.readAddressArray(string(abi.encodePacked(".", paus[i], ".admins")));
            relayers       = config.readAddressArray(string(abi.encodePacked(".", paus[i], ".relayers")));
            freezers       = config.readAddressArray(string(abi.encodePacked(".", paus[i], ".freezers")));
            grantors       = config.readAddressArray(string(abi.encodePacked(".", paus[i], ".grantors")));
            integrationIds = config.readStringArray(string(abi.encodePacked(".",  paus[i], ".integrationIds")));

            vm.startBroadcast();

            // Step 1: Prepare configs.

            bytes32[] memory integrationIdsBytes = new bytes32[](integrationIds.length);
            for (uint16 j; j < integrationIds.length; ++j) {
                integrationIdsBytes[j] = bytes32(abi.encodePacked(integrationIds[j]));
            }

            IDefaultPAUAssembler.AdminConfig               memory adminConfig    = _getAdminConfig(admins, admins, admins);
            IDefaultPAUAssembler.AdministeredAgentConfig[] memory agentConfigs   = _getAgentConfigs(admins, relayers, freezers, grantors);

            // Step 2: Deploy PAU with default PAUAssembler.

            (
                address          proxy,
                address          controller,
                address          accessControls,
                address          rateLimits,
                address[] memory allocatorAgents
            ) = defaultPAUAssembler.deploy(integrationIdsBytes, adminConfig, agentConfigs);

            vm.stopBroadcast();

            console2.log("Deployed", paus[i], "PAU with default PAUAssembler");

            ScriptTools.exportContract(fileSlug, string(abi.encodePacked(paus[i], ".proxy")),          address(proxy));
            ScriptTools.exportContract(fileSlug, string(abi.encodePacked(paus[i], ".controller")),     address(controller));
            ScriptTools.exportContract(fileSlug, string(abi.encodePacked(paus[i], ".accessControls")), address(accessControls));
            ScriptTools.exportContract(fileSlug, string(abi.encodePacked(paus[i], ".rateLimits")),     address(rateLimits));
            ScriptTools.exportContract(fileSlug, string(abi.encodePacked(paus[i], ".allocatorAgent")), allocatorAgents[0]);
        }
    }

    /**********************************************************************************************/
    /*** Helper Functions                                                                       ***/
    /**********************************************************************************************/

    function _getAdminConfig(
        address[] memory accessControlAdmins,
        address[] memory almProxyAdmins,
        address[] memory rateLimitsAdmins
    ) internal returns (IDefaultPAUAssembler.AdminConfig memory adminConfig) {
        adminConfig = IDefaultPAUAssembler.AdminConfig({
            accessControlAdmins : accessControlAdmins,
            proxyAdmins         : almProxyAdmins,
            rateLimitsAdmins    : rateLimitsAdmins
        });
    }

    function _getAgentConfigs(
        address[] memory agentAdmins,
        address[] memory agentActors,
        address[] memory agentGrantors,
        address[] memory agentRevokers
    ) internal returns (IDefaultPAUAssembler.AdministeredAgentConfig[] memory agentConfigs) {
        agentConfigs = new IDefaultPAUAssembler.AdministeredAgentConfig[](1);  // Only one allocator agent is deployed.

        agentConfigs[0] = IDefaultPAUAssembler.AdministeredAgentConfig({
            admins   : agentAdmins,
            actors   : agentActors,
            grantors : agentGrantors,
            revokers : agentRevokers
        });
    }

    function _setRHChainFork() internal {
        setChain("robinhood_chain", ChainData({
            name    : "Robinhood Chain",
            rpcUrl  : vm.envString("RH_RPC_URL"),
            chainId : 4663
        }));
    }

}

contract DeploySparkPrimeVaultMainnet is DeploySparkPrimeVaultBase {

    function run() public override {
        paus = new string[](2);
        paus[0] = "spPrimePAU";
        paus[1] = "flcPAU";

        super.run();
    }

}
