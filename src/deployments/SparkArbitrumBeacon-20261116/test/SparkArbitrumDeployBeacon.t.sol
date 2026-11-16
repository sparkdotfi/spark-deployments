// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test, Vm } from "../../../../lib/forge-std/src/Test.sol";

import { Arbitrum } from "../../../../lib/spark-address-registry/src/Arbitrum.sol";

import { IAccessControl } from "../../../../lib/diamond-pau/lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";

import { IBeacon }                 from "../../../../lib/diamond-pau/src/interfaces/IBeacon.sol";
import { IEnumerableIntegrations } from "../../../../lib/diamond-pau/src/interfaces/IEnumerableIntegrations.sol";

import { BeaconConfig } from "../../../../lib/diamond-pau/src/libraries/BeaconConfig.sol";

import { SparkArbitrumDeployBeacon } from "../SparkArbitrumDeployBeacon.sol";

abstract contract SparkArbitrumDeployBeaconTestBase is Test {

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    uint256 internal constant INTEGRATION_COUNT = 7;

    address internal deploymentPayload;
    address internal beacon;

    address internal user = makeAddr("user");

    Vm.Log[] internal deployLogs;

    function setUp() public virtual {
        vm.createSelectFork(getChain("arbitrum_one").rpcUrl);

        vm.recordLogs();

        deploymentPayload = address(new SparkArbitrumDeployBeacon());

        SparkArbitrumDeployBeacon.Report memory report
            =  SparkArbitrumDeployBeacon(deploymentPayload).report();

        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i; i < logs.length; ++i) {
            deployLogs.push(logs[i]);
        }

        beacon = report.beacon;

        vm.label(deploymentPayload,       "deploymentPayload");
        vm.label(beacon,                  "beacon");
        vm.label(Arbitrum.SPARK_EXECUTOR, "beacon.admin");
        vm.label(Arbitrum.CCTP_FACET,     "cctpFacet");
    }

    /**********************************************************************************************/
    /*** Helper Functions                                                                       ***/
    /**********************************************************************************************/

    // Integrations in the order the deploymentPayload configures them.
    function _expectedIntegrations()
        internal pure returns (IEnumerableIntegrations.Integration[] memory integrations)
    {
        integrations = new IEnumerableIntegrations.Integration[](INTEGRATION_COUNT);

        integrations[0] = BeaconConfig.buildSparkVaultIntegration(Arbitrum.SPARK_VAULT_FACET);
        integrations[1] = BeaconConfig.buildTransferAssetIntegration(Arbitrum.TRANSFER_ASSET_FACET);
        integrations[2] = BeaconConfig.buildERC4626Integration(Arbitrum.ERC4626_FACET);
        integrations[3] = BeaconConfig.buildAaveIntegration(Arbitrum.AAVE_FACET);
        integrations[4] = BeaconConfig.buildUniswapV4Integration(Arbitrum.UNISWAP_V4_FACET);
        integrations[5] = BeaconConfig.buildLayerZeroIntegration(Arbitrum.LAYER_ZERO_FACET);
        integrations[6] = BeaconConfig.buildCCTPIntegration(Arbitrum.CCTP_FACET);
    }

    // Returns the logs emitted by `target` during deployment with the given `topic0`, in emission order.
    // A zero `topic0` returns all the logs emitted by `target`.
    function _getEvents(address target, bytes32 topic0) internal view returns (Vm.Log[] memory logs) {
        uint256 count;

        for (uint256 i; i < deployLogs.length; ++i) {
            if (_isEvent(deployLogs[i], target, topic0)) count++;
        }

        logs = new Vm.Log[](count);

        uint256 j;

        for (uint256 i; i < deployLogs.length; ++i) {
            if (_isEvent(deployLogs[i], target, topic0)) logs[j++] = deployLogs[i];
        }
    }

    function _isEvent(Vm.Log memory log, address target, bytes32 topic0) internal pure returns (bool) {
        return log.emitter == target && (topic0 == bytes32(0) || log.topics[0] == topic0);
    }

    function _toAddress(bytes32 topic) internal pure returns (address) {
        return address(uint160(uint256(topic)));
    }

    // Integration ids are short ASCII strings, e.g. "CCTP_FACET".
    function _toString(bytes32 id) internal pure returns (string memory) {
        uint256 length;

        while (length < 32 && id[length] != 0) ++length;

        bytes memory result = new bytes(length);

        for (uint256 i; i < length; ++i) {
            result[i] = id[i];
        }

        return string(result);
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

contract TestDeploymentPayload is SparkArbitrumDeployBeaconTestBase {

    function test_deploymentPayload_invalidChainId() external {
        vm.chainId(1);

        vm.expectRevert("SparkArbitrumDeployBeacon/invalid-chain-id");
        new SparkArbitrumDeployBeacon();
    }

    function test_deploymentPayload_holdsNoRoles() external view {
        assertEq(IBeacon(beacon).hasRole(DEFAULT_ADMIN_ROLE, deploymentPayload), false);
    }

}

contract TestBeacon is SparkArbitrumDeployBeaconTestBase {

    function test_beacon_roles() external view {
        IBeacon beacon_ = IBeacon(beacon);

        assertEq(beacon_.getRoleMemberCount(DEFAULT_ADMIN_ROLE), 1);
        assertEq(beacon_.getRoleMember(DEFAULT_ADMIN_ROLE, 0),   Arbitrum.SPARK_EXECUTOR);
        assertEq(beacon_.getRoleAdmin(DEFAULT_ADMIN_ROLE),       DEFAULT_ADMIN_ROLE);

        assertEq(beacon_.hasRole(DEFAULT_ADMIN_ROLE, deploymentPayload), false);
    }

    function test_beacon_roleEvents() external view {
        Vm.Log[] memory grantLogs  = _getEvents(beacon, IAccessControl.RoleGranted.selector);
        Vm.Log[] memory revokeLogs = _getEvents(beacon, IAccessControl.RoleRevoked.selector);

        assertEq(grantLogs.length,  2);
        assertEq(revokeLogs.length, 1);

        // Beacon constructor makes the deploymentPayload the temporary admin
        assertEq(grantLogs[0].topics[1],             DEFAULT_ADMIN_ROLE);
        assertEq(_toAddress(grantLogs[0].topics[2]), deploymentPayload);
        assertEq(_toAddress(grantLogs[0].topics[3]), deploymentPayload);

        // Handoff to the Beacon admin
        assertEq(grantLogs[1].topics[1],             DEFAULT_ADMIN_ROLE);
        assertEq(_toAddress(grantLogs[1].topics[2]), Arbitrum.SPARK_EXECUTOR);
        assertEq(_toAddress(grantLogs[1].topics[3]), deploymentPayload);

        // The deploymentPayload removes itself
        assertEq(revokeLogs[0].topics[1],             DEFAULT_ADMIN_ROLE);
        assertEq(_toAddress(revokeLogs[0].topics[2]), deploymentPayload);
        assertEq(_toAddress(revokeLogs[0].topics[3]), deploymentPayload);
    }

    function test_beacon_integrations() external view {
        IEnumerableIntegrations.Integration[] memory expected = _expectedIntegrations();
        IEnumerableIntegrations.Integration[] memory actual   = IBeacon(beacon).integrations();

        assertEq(actual.length, expected.length);

        for (uint256 i; i < expected.length; ++i) {
            assertEq(actual[i].id, expected[i].id);

            _assertIntegration(beacon, expected[i]);
        }
    }

    function test_beacon_integrationEvents() external view {
        IEnumerableIntegrations.Integration[] memory expected = _expectedIntegrations();

        Vm.Log[] memory setLogs = _getEvents(beacon, IEnumerableIntegrations.IntegrationSet.selector);

        assertEq(setLogs.length, expected.length);

        for (uint256 i; i < expected.length; ++i) {
            assertEq(setLogs[i].topics[1], expected[i].id);
            assertEq(setLogs[i].data,      abi.encode(expected[i].config));
        }

        assertEq(_getEvents(beacon, IEnumerableIntegrations.IntegrationRemoved.selector).length, 0);
    }

}
