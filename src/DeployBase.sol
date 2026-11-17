// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Script } from "../lib/forge-std/src/Script.sol";

abstract contract DeployBase is Script {

    function run() external {
        vm.startBroadcast();

        address deployment = _deployPayload();

        vm.stopBroadcast();

        _writeReport(deployment);
    }

    function _deployPayload() internal virtual returns (address payload);

    function _getOutputPath() internal pure virtual returns (string memory path);

    function _writeReport(address deployment) internal virtual {
        vm.writeJson(
            vm.serializeAddress("deployments", "deploymentPayload", deployment),
            string.concat(vm.projectRoot(), _getOutputPath())
        );
    }

}
