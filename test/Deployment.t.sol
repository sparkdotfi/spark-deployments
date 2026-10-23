// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { SparkPrimeVaultDeploymentAssertions } from "./DeploymentAssertions.sol";
import { SparkPrimeVaultDeploymentTestBase }   from "./TestBase.t.sol";

interface IRateLimitsLike {
    function getCurrentRateLimit(bytes32 key) external view returns (uint256);
}

interface IControllerLike {
    function transferAsset_getTransferRateLimitKey(address asset, address destination) external view returns (bytes32);
}

contract SparkPrimeVaultDeploymentTests is SparkPrimeVaultDeploymentTestBase, SparkPrimeVaultDeploymentAssertions {

    /**********************************************************************************************/
    /*** Full configuration check                                                               ***/
    /**********************************************************************************************/

    function test_deployment_matchesProductionConfig() external view {
        _assertDeployment(config, instance, deployer);
    }

    /**********************************************************************************************/
    /*** Config parsing                                                                         ***/
    /**********************************************************************************************/

    function test_parseConfig_productionFile() external view {
        assertEq(config.chainId, 1);

        assertEq(config.spPrimePAU.integrationIds.length, 3);
        assertEq(config.spPrimePAU.integrationIds[0], bytes32("TRANSFER_ASSET_FACET"));
        assertEq(config.spPrimePAU.integrationIds[1], bytes32("ERC4626_FACET"));
        assertEq(config.spPrimePAU.integrationIds[2], bytes32("SPARK_VAULT_FACET"));

        assertEq(config.spPrimePAU.transferAssetRateLimits.length, 1);
        assertEq(config.spPrimePAU.erc4626RateLimits.length,       1);
        assertEq(config.spPrimePAU.sparkVaultRateLimits.length,    1);

        assertEq(uint8(config.spPrimePAU.transferAssetRateLimits[0].destination.ref), uint8(Ref.SpPrime));
        assertEq(config.spPrimePAU.transferAssetRateLimits[0].asset, address(spUsdc));
        assertEq(uint8(config.spPrimePAU.sparkVaultRateLimits[0].sparkVault.ref), uint8(Ref.SpPrime));
        assertEq(config.spPrimePAU.erc4626RateLimits[0].token, address(spUsdc));
        assertEq(config.spPrimePAU.erc4626RateLimits[0].asset, address(usdc));

        assertEq(config.flcPAU.integrationIds.length, 1);
        assertEq(config.flcPAU.integrationIds[0], bytes32("TRANSFER_ASSET_FACET"));

        assertEq(config.flcPAU.transferAssetRateLimits.length, 1);
        assertEq(config.flcPAU.erc4626RateLimits.length,       0);
        assertEq(config.flcPAU.sparkVaultRateLimits.length,    0);

        assertEq(uint8(config.flcPAU.transferAssetRateLimits[0].destination.ref), uint8(Ref.SpPrimePAUAlmProxy));
        assertEq(config.flcPAU.transferAssetRateLimits[0].asset, address(usdc));

        assertEq(config.vault.savings, address(spUsdc));
    }

    function test_parseConfig_unknownRateLimitReverts() external {
        string memory json = string(abi.encodePacked(
            '{"admins":[],"integrationIds":[],"rateLimits":[{"integrationId":"CCTP_FACET"}]}'
        ));

        vm.expectRevert("SparkPrimeVaultDeployer/unknown-rate-limit: CCTP_FACET");
        this.parsePAU(json);
    }

    function parsePAU(string memory json) external view returns (PAUConfig memory) {
        return _parsePAU(json, "");
    }

    /**********************************************************************************************/
    /*** Symbolic references                                                                    ***/
    /**********************************************************************************************/

    function test_symbolicReferences_resolveToDeployedAddresses() external view {
        // FLC PAU: USDC -> taker PAU ALMProxy.
        bytes32 flcKey = IControllerLike(instance.flcPAU.controller)
            .transferAsset_getTransferRateLimitKey(address(usdc), instance.spPrimePAU.almProxy);

        assertEq(IRateLimitsLike(instance.flcPAU.rateLimits).getCurrentRateLimit(flcKey), 1e18);

        // Taker PAU: spUSDC -> spPrime.
        bytes32 takerKey = IControllerLike(instance.spPrimePAU.controller)
            .transferAsset_getTransferRateLimitKey(address(spUsdc), instance.spPrime);

        assertEq(IRateLimitsLike(instance.spPrimePAU.rateLimits).getCurrentRateLimit(takerKey), 1e18);
    }

    /**********************************************************************************************/
    /*** Determinism                                                                            ***/
    /**********************************************************************************************/

    function test_deploy_addressesDependOnlyOnDeployerNonce() external {
        address deployer2 = makeAddr("deployer2");

        uint64 factoryNonce = vm.getNonce(address(pauFactory));

        vm.startPrank(deployer2, deployer2);
        Instance memory inst = _deploy(deployer2, config);
        vm.stopPrank();

        // Deployer creations, in order. With `tx.origin` pranked, forge bumps the deployer's
        // nonce on every external call, which is exactly what each broadcast transaction does on
        // chain: the eight PAUFactory calls sit between the vault proxy and the PAS contracts.
        assertEq(inst.spPrimeImplementation, vm.computeCreateAddress(deployer2, 0));
        assertEq(inst.spPrime,               vm.computeCreateAddress(deployer2, 1));
        assertEq(inst.pas.beamState,         vm.computeCreateAddress(deployer2, 10));
        assertEq(inst.pas.configurator,      vm.computeCreateAddress(deployer2, 11));
        assertEq(inst.pas.timelock,          vm.computeCreateAddress(deployer2, 12));

        // Factory creations, in order.
        assertEq(inst.spPrimePAU.accessControls, vm.computeCreateAddress(address(pauFactory), factoryNonce));
        assertEq(inst.spPrimePAU.almProxy,       vm.computeCreateAddress(address(pauFactory), factoryNonce + 1));
        assertEq(inst.spPrimePAU.rateLimits,     vm.computeCreateAddress(address(pauFactory), factoryNonce + 2));
        assertEq(inst.spPrimePAU.controller,     vm.computeCreateAddress(address(pauFactory), factoryNonce + 3));
        assertEq(inst.flcPAU.accessControls,     vm.computeCreateAddress(address(pauFactory), factoryNonce + 4));
        assertEq(inst.flcPAU.almProxy,           vm.computeCreateAddress(address(pauFactory), factoryNonce + 5));
        assertEq(inst.flcPAU.rateLimits,         vm.computeCreateAddress(address(pauFactory), factoryNonce + 6));
        assertEq(inst.flcPAU.controller,         vm.computeCreateAddress(address(pauFactory), factoryNonce + 7));

        // And the second deployment is just as correct as the first.
        _assertDeployment(config, inst, deployer2);
    }

    /**********************************************************************************************/
    /*** Deployer hand-off                                                                      ***/
    /**********************************************************************************************/

    function test_deploy_deployerKeepsAdminWhenConfiguredAsAdmin() external {
        address deployer2 = makeAddr("deployer2");

        config.vault.admin         = deployer2;
        config.spPrimePAU.admins   = _single(deployer2);
        config.flcPAU.admins       = _single(deployer2);
        config.pas.owner           = deployer2;

        vm.startPrank(deployer2, deployer2);
        Instance memory inst = _deploy(deployer2, config);
        vm.stopPrank();

        _assertDeployment(config, inst, deployer2);
    }

    function test_deploy_wrongChainIdReverts() external {
        vm.chainId(config.chainId + 1);

        vm.startPrank(deployer, deployer);
        vm.expectRevert("SparkPrimeVaultDeployer/invalid-chain-id");
        this.deployExternal(deployer);
        vm.stopPrank();
    }

    function deployExternal(address deployer_) external returns (Instance memory) {
        return _deploy(deployer_, config);
    }

    function _single(address a) internal pure returns (address[] memory arr) {
        arr    = new address[](1);
        arr[0] = a;
    }

}
