// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { DeployBase } from "../../DeployBase.sol";

import { EthereumSparkSpUSDTPayload } from "./EthereumSparkSpUSDTPayload.sol";

contract Deploy is DeployBase {

    function _deployPayload() internal override returns (address payload) {
        payload = address(new EthereumSparkSpUSDTPayload());
    }

    function _getOutputPath() internal pure override returns (string memory) {
        return "/src/deployments/20261116-mainnet-spark-spusdt/deployments.json";
    }

}
