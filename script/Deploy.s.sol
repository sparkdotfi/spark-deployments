// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Script, stdJson } from "../lib/forge-std/src/Script.sol";

import { ScriptTools } from "../lib/dss-test/src/ScriptTools.sol";

import { DeploySparkPrimeVaultBase } from "../deploy/Deploy.sol";

abstract contract DeploySparkPrimeVault is DeploySparkPrimeVaultBase, Script {

    using stdJson     for string;
    using ScriptTools for string;

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

        vm.startBroadcast();

        ( , address deployer, ) = vm.readCallers();

        DeployedInstance memory deployed = _deployAndConfigure(_parseConfig(config, paus), deployer);

        vm.stopBroadcast();

        ScriptTools.exportContract(fileSlug, string(abi.encodePacked("spPrime.proxy")),          deployed.spPrime);
        ScriptTools.exportContract(fileSlug, string(abi.encodePacked("spPrime.implementation")), deployed.spPrimeImplementation);

        for (uint16 i; i < deployed.paus.length; ++i) {
            ScriptTools.exportContract(fileSlug, string(abi.encodePacked(paus[i], ".proxy")),          deployed.paus[i].almProxy);
            ScriptTools.exportContract(fileSlug, string(abi.encodePacked(paus[i], ".controller")),     deployed.paus[i].controller);
            ScriptTools.exportContract(fileSlug, string(abi.encodePacked(paus[i], ".accessControls")), deployed.paus[i].accessControls);
            ScriptTools.exportContract(fileSlug, string(abi.encodePacked(paus[i], ".rateLimits")),     deployed.paus[i].rateLimits);
        }
    }

    /**********************************************************************************************/
    /*** Helper Functions                                                                       ***/
    /**********************************************************************************************/

    function _setRHChainFork() internal {
        setChain("robinhood_chain", ChainData({
            name    : "Robinhood Chain",
            rpcUrl  : vm.envString("RH_RPC_URL"),
            chainId : 4663
        }));
    }

}

contract DeploySparkPrimeVaultMainnet is DeploySparkPrimeVault {

    function run() public override {
        paus = new string[](2);
        paus[0] = "spPrimePAU";
        paus[1] = "flcPAU";

        super.run();
    }

}
