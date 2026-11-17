// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test, Vm } from "../../../lib/forge-std/src/Test.sol";

import { IAccessControl } from "../../../lib/diamond-pau/lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";

import { IBeacon }                 from "../../../lib/diamond-pau/src/interfaces/IBeacon.sol";
import { IEnumerableIntegrations } from "../../../lib/diamond-pau/src/interfaces/IEnumerableIntegrations.sol";

import { BeaconConfig } from "../../../lib/diamond-pau/src/libraries/BeaconConfig.sol";

import { Arbitrum } from "../../../lib/spark-address-registry/src/Arbitrum.sol";

import { ArbitrumSparkBeaconPayload } from "./ArbitrumSparkBeaconPayload.sol";

abstract contract ArbitrumSparkBeaconPayloadTestBase is Test {

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    uint256 internal constant INTEGRATION_COUNT = 7;

    // ControllerSharedStorage.SHARED_CONTROLLER_STORAGE_LOCATION, where `accessControls` is the
    // first field. Used by _hasSelector.
    bytes32 internal constant SHARED_CONTROLLER_STORAGE_LOCATION =
        0x77adf60bdbfedf206f8b8310f3d364080b7f61dcc0e46caac13c29bb1eb5cc00;

    address internal deploymentPayload;
    address internal beacon;

    address internal user = makeAddr("user");

    function setUp() public virtual {
        vm.createSelectFork(getChain("arbitrum_one").rpcUrl);

        deploymentPayload = address(new ArbitrumSparkBeaconPayload());

        beacon = ArbitrumSparkBeaconPayload(deploymentPayload).report();

        vm.label(deploymentPayload,             "deploymentPayload");
        vm.label(beacon,                        "beacon");
        vm.label(Arbitrum.SPARK_EXECUTOR,       "beacon.admin");
        vm.label(Arbitrum.AAVE_FACET,           "aaveFacet");
        vm.label(Arbitrum.CCTP_FACET,           "cctpFacet");
        vm.label(Arbitrum.ERC4626_FACET,        "erc4626Facet");
        vm.label(Arbitrum.LAYER_ZERO_FACET,     "layerZeroFacet");
        vm.label(Arbitrum.SPARK_VAULT_FACET,    "sparkVaultFacet");
        vm.label(Arbitrum.TRANSFER_ASSET_FACET, "transferAssetFacet");
        vm.label(Arbitrum.UNISWAP_V4_FACET,     "uniswapV4Facet");
    }

    /**********************************************************************************************/
    /*** Helper Functions                                                                       ***/
    /**********************************************************************************************/

    // Integrations in the order the deploymentPayload configures them.
    function _expectedIntegrations()
        internal pure returns (IEnumerableIntegrations.Integration[] memory integrations)
    {
        integrations = new IEnumerableIntegrations.Integration[](INTEGRATION_COUNT);

        integrations[0] = BeaconConfig.buildAaveIntegration(Arbitrum.AAVE_FACET);
        integrations[1] = BeaconConfig.buildCCTPIntegration(Arbitrum.CCTP_FACET);
        integrations[2] = BeaconConfig.buildERC4626Integration(Arbitrum.ERC4626_FACET);
        integrations[3] = BeaconConfig.buildLayerZeroIntegration(Arbitrum.LAYER_ZERO_FACET);
        integrations[4] = BeaconConfig.buildSparkVaultIntegration(Arbitrum.SPARK_VAULT_FACET);
        integrations[5] = BeaconConfig.buildTransferAssetIntegration(Arbitrum.TRANSFER_ASSET_FACET);
        integrations[6] = BeaconConfig.buildUniswapV4Integration(Arbitrum.UNISWAP_V4_FACET);
    }

    function _hasSelector(address facet, bytes4 selector) internal returns (bool) {
        assertGt(facet.code.length, 0, "facet has no code");

        vm.store(facet, SHARED_CONTROLLER_STORAGE_LOCATION, bytes32(uint256(uint160(Arbitrum.PAU_ACCESS_CONTROLS))));

        // Pad so the ABI decoder does not empty-revert on missing arguments.
        bytes memory payload = abi.encodePacked(selector, new bytes(1024));

        ( bool success, bytes memory revertData ) = facet.call(payload);

        return success || revertData.length > 0;
    }

    /**********************************************************************************************/
    /*** Assertion Helpers                                                                      ***/
    /**********************************************************************************************/

    // Asserts the config and the dispatch entries of `expected` on a Beacon or a Controller.
    function _assertIntegration(address target, IEnumerableIntegrations.Integration memory expected)
        internal view
    {
        IEnumerableIntegrations.Config memory actual = IEnumerableIntegrations(target).getConfig(expected.id);

        assertEq(actual.facet,        expected.config.facet);
        assertEq(actual.wires.length, expected.config.wires.length);

        for (uint256 i; i < expected.config.wires.length; ++i) {
            IEnumerableIntegrations.Wire memory wire = expected.config.wires[i];

            assertEq(actual.wires[i].callSelector,     wire.callSelector);
            assertEq(actual.wires[i].delegateSelector, wire.delegateSelector);

            IEnumerableIntegrations.Dispatch memory dispatch =
                IEnumerableIntegrations(target).getDispatch(wire.callSelector);

            assertEq(dispatch.facet,            expected.config.facet);
            assertEq(dispatch.delegateSelector, wire.delegateSelector);
        }
    }

}

contract ArbitrumSparkBeaconPayloadTest_Payload is ArbitrumSparkBeaconPayloadTestBase {

    function test_deploymentPayload_invalidChainId() external {
        vm.chainId(1);

        vm.expectRevert("ArbitrumSparkBeaconPayload/invalid-chain-id");
        new ArbitrumSparkBeaconPayload();
    }

    function test_deploymentPayload_holdsNoRoles() external view {
        assertEq(IBeacon(beacon).hasRole(DEFAULT_ADMIN_ROLE, deploymentPayload), false);
    }

}

contract ArbitrumSparkBeaconPayloadTest_Beacon is ArbitrumSparkBeaconPayloadTestBase {

    function test_beacon_roles() external view {
        IBeacon beacon_ = IBeacon(beacon);

        assertEq(beacon_.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1);
        assertEq(beacon_.getRoleMember(DEFAULT_ADMIN_ROLE, 0),   Arbitrum.SPARK_EXECUTOR);
        assertEq(beacon_.getRoleAdmin(DEFAULT_ADMIN_ROLE),       DEFAULT_ADMIN_ROLE);

        assertEq(beacon_.hasRole(DEFAULT_ADMIN_ROLE, deploymentPayload), false);
    }

    function test_beacon_integrations() external {
        IEnumerableIntegrations.Integration[] memory expected = _expectedIntegrations();
        IEnumerableIntegrations.Integration[] memory actual   = IBeacon(beacon).integrations();

        assertEq(actual.length, expected.length);

        for (uint256 i; i < expected.length; ++i) {
            assertEq(actual[i].id,                  expected[i].id);
            assertEq(actual[i].config.facet,        expected[i].config.facet);
            assertEq(actual[i].config.wires.length, expected[i].config.wires.length);

            _assertIntegration(beacon, expected[i]);

            address facet = actual[i].config.facet;

            // Every wired delegate selector must be implemented by the facet it dispatches to.
            for (uint256 j; j < actual[i].config.wires.length; ++j) {
                bytes4 delegateSelector = actual[i].config.wires[j].delegateSelector;

                assertTrue(
                    _hasSelector(facet, delegateSelector),
                    string.concat(vm.toString(facet), ": missing delegate selector ", vm.toString(abi.encodePacked(delegateSelector)))
                );
            }
        }
    }

}
