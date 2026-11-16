// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Script, stdJson } from "../../../../lib/forge-std/src/Script.sol";

import { SparkArbitrumDeployBeacon } from "../SparkArbitrumDeployBeacon.sol";

contract Deploy is Script {

    using stdJson for string;

    function run() external {
        vm.startBroadcast();
        address deployment = address(new SparkArbitrumDeployBeacon());
        SparkArbitrumDeployBeacon.Report memory report = SparkArbitrumDeployBeacon(deployment).report();
        vm.stopBroadcast();

        _writeReport(deployment, report);
    }

    function _writeReport(address deployment, SparkArbitrumDeployBeacon.Report memory report) internal {
        string memory beaconKey = "beacon";

        beaconKey.serialize("deploymentPayload", deployment);
        string memory beacon = beaconKey.serialize("beacon", report.beacon);

        beacon.write(string.concat(vm.projectRoot(), "/src/deployments/SparkArbitrumBeacon-20261116/report/report.json"));
    }

}
