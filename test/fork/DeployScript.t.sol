// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { console2 } from "forge-std/console2.sol";

import { DeploySparkPrimeVault } from "../../script/Deploy.s.sol";

import { SparkPrimeVaultDeploymentAssertions } from "../DeploymentAssertions.sol";

/// @dev The real broadcast script with file output disabled and its results exposed.
contract DeploySparkPrimeVaultHarness is DeploySparkPrimeVault {

    address public deployer;

    function run() public override {
        super.run();
    }

    function _export(Instance memory) internal override {
        ( , deployer, ) = vm.readCallers();
    }

    function getConfigJson() external view returns (string memory) { return configJson; }
    function getInstance()   external view returns (Instance memory) { return instance; }

}

/**
 * @notice Dry run of the actual deployment script against a mainnet fork: the real
 *         PAUFactory, Beacon, AdministeredAgent and spUSDC, followed by the same exact-value
 *         assertions the local configuration tests use. Skipped when MAINNET_RPC_URL is unset.
 *
 *         Run with: ENV=production forge test --match-contract DeployScriptForkTest -vvv
 */
contract DeployScriptForkTest is SparkPrimeVaultDeploymentAssertions {

    function test_mainnet_dryRunMatchesConfig() external {
        if (!vm.envExists("MAINNET_RPC_URL")) {
            console2.log("MAINNET_RPC_URL not set, skipping mainnet dry run");
            return;
        }

        vm.setEnv("ENV",   vm.envOr("ENV",   string("production")));
        vm.setEnv("CHAIN", vm.envOr("CHAIN", string("mainnet")));

        DeploySparkPrimeVaultHarness script = new DeploySparkPrimeVaultHarness();

        script.run();

        Instance memory inst = script.getInstance();
        Config   memory cfg  = _parseConfig(script.getConfigJson());

        _assertDeployment(cfg, inst, script.deployer());
    }

}
