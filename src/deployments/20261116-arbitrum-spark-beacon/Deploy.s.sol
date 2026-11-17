// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { DeployBase } from "../../DeployBase.sol";

import { ArbitrumSparkBeaconPayload } from "./ArbitrumSparkBeaconPayload.sol";

contract Deploy is DeployBase {

    function _deployPayload() internal override returns (address payload) {
        payload = address(new ArbitrumSparkBeaconPayload());
    }

    function _getOutputPath() internal pure override returns (string memory) {
        return "/src/deployments/20261116-arbitrum-spark-beacon/deployments.json";
    }

}
