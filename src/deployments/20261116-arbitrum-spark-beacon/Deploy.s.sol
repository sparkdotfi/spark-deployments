// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Script } from "../../../lib/forge-std/src/Script.sol";

import { ArbitrumSparkBeaconPayload } from "./ArbitrumSparkBeaconPayload.sol";

contract Deploy is Script {

    string internal constant OUTPUT_PATH =
        "/src/deployments/20261116-arbitrum-spark-beacon/deployments.json";

    function run() external {
        vm.startBroadcast();

        address deployment = address(new ArbitrumSparkBeaconPayload());

        vm.stopBroadcast();

        _writeReport(deployment);
    }

    function _writeReport(address deployment) internal {
        vm.writeJson(
            vm.serializeAddress("deployments", "deploymentPayload", deployment),
            string.concat(vm.projectRoot(), OUTPUT_PATH)
        );
    }

}
