// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { DeployBase } from "../../DeployBase.sol";

import { ArbitrumSparkSpUSDTPayload } from "./ArbitrumSparkSpUSDTPayload.sol";

contract Deploy is DeployBase {

    function _deployPayload() internal override returns (address payload) {
        payload = address(new ArbitrumSparkSpUSDTPayload{salt: keccak256("spark.arb.spUSDTPAUPayload")}());
    }

    function _getOutputPath() internal pure override returns (string memory) {
        return "/src/deployments/20261117-arbitrum-spark-spUSDT/deployments.json";
    }

}
