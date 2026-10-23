// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { console2 }        from "forge-std/console2.sol";
import { Script, stdJson } from "forge-std/Script.sol";

import { ScriptTools } from "dss-test/ScriptTools.sol";

import { SparkPrimeVaultDeployer } from "../deploy/SparkPrimeVaultDeployer.sol";

/**
 * @notice Thin broadcast wrapper around `SparkPrimeVaultDeployer`. Everything environment
 *         specific (fork selection, env vars, JSON input, output files) lives here; the
 *         deployment itself is `_deploy`, shared with the configuration tests.
 *
 *         Usage: ENV=production CHAIN=mainnet forge script script/Deploy.s.sol:DeploySparkPrimeVault \
 *                    --rpc-url $MAINNET_RPC_URL --broadcast --sender <deployer> ...
 */
contract DeploySparkPrimeVault is Script, SparkPrimeVaultDeployer {

    using stdJson for string;

    string   internal configJson;
    string   internal fileSlug;
    Instance internal instance;

    function run() public virtual {
        string memory chain = vm.envOr("CHAIN", string("mainnet"));

        vm.createSelectFork(getChain(chain).rpcUrl);

        vm.setEnv("FOUNDRY_ROOT_CHAINID", vm.toString(block.chainid));

        string memory env = vm.envString("ENV");

        fileSlug   = string(abi.encodePacked("deploy-spark-prime-vault-", env));
        configJson = ScriptTools.loadConfig(fileSlug);

        Config memory config = _parseConfig(configJson);

        require(block.chainid == config.chainId, "DeploySparkPrimeVault/invalid-chain-id");

        vm.startBroadcast();

        ( , address deployer, ) = vm.readCallers();

        instance = _deploy(deployer, config);

        vm.stopBroadcast();

        console2.log("Deployed Spark Prime Vault at", instance.spPrime);
        console2.log("Deployed spPrime PAU controller at", instance.spPrimePAU.controller);
        console2.log("Deployed FLC PAU controller at", instance.flcPAU.controller);
        console2.log("Deployed PAS configurator at", instance.pas.configurator);

        _export(instance);
    }

    function _export(Instance memory inst) internal virtual {
        ScriptTools.exportContract(fileSlug, "spPrime.implementation", inst.spPrimeImplementation);
        ScriptTools.exportContract(fileSlug, "spPrime.proxy",          inst.spPrime);

        _exportPAU("spPrimePAU", inst.spPrimePAU.accessControls, inst.spPrimePAU.almProxy, inst.spPrimePAU.controller, inst.spPrimePAU.rateLimits);
        _exportPAU("flcPAU",     inst.flcPAU.accessControls,     inst.flcPAU.almProxy,     inst.flcPAU.controller,     inst.flcPAU.rateLimits);

        ScriptTools.exportContract(fileSlug, "pas.beamState",    inst.pas.beamState);
        ScriptTools.exportContract(fileSlug, "pas.configurator", inst.pas.configurator);
        ScriptTools.exportContract(fileSlug, "pas.timelock",     inst.pas.timelock);
    }

    function _exportPAU(string memory name, address accessControls, address almProxy, address controller, address rateLimits) internal {
        ScriptTools.exportContract(fileSlug, string(abi.encodePacked(name, ".accessControls")), accessControls);
        ScriptTools.exportContract(fileSlug, string(abi.encodePacked(name, ".proxy")),          almProxy);
        ScriptTools.exportContract(fileSlug, string(abi.encodePacked(name, ".controller")),     controller);
        ScriptTools.exportContract(fileSlug, string(abi.encodePacked(name, ".rateLimits")),     rateLimits);
    }

}
