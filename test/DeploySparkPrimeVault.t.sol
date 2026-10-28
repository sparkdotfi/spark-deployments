// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "../lib/forge-std/src/Test.sol";

import { SparkPrimeVault } from "../lib/spark-prime-vault/src/SparkPrimeVault.sol";

import { DeployAndConfigSparkPrimeVault, DeploySparkPrimeVaultMainnet } from "../script/DeployAndConfigSparkPrimeVault.s.sol";

contract DeploySparkPrimeVaultTest is Test {

    address internal constant ADMIN = 0x3300f198988e4C9C63F75dF86De36421f06af8c4;

    function setUp() public {
        vm.createSelectFork(getChain("mainnet").rpcUrl);
    }

    function test_deployAndConfigure() public {
        string memory config = vm.readFile("script/input/1/deploy-spark-prime-vault-production.json");

        DeployAndConfigSparkPrimeVault.DeployedInstance memory deployed
            = new DeploySparkPrimeVaultMainnet().deployAndConfigure(config);

        SparkPrimeVault vault = SparkPrimeVault(deployed.spPrime);

        assertEq(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), ADMIN),                     true);
        assertEq(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), DEFAULT_SENDER),            false);
        assertEq(vault.hasRole(vault.TAKER_ROLE(),         deployed.paus[0].almProxy), true);
    }

}
