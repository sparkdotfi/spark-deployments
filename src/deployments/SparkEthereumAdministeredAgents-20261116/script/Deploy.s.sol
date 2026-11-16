// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Script, stdJson } from "../../../../lib/forge-std/src/Script.sol";

import { SparkEthereumDeployAdministeredAgents } from "../SparkEthereumDeployAdministeredAgents.sol";

contract Deploy is Script {

    using stdJson for string;

    function run() external {
        vm.startBroadcast();

        SparkEthereumDeployAdministeredAgents payload = new SparkEthereumDeployAdministeredAgents();

        vm.stopBroadcast();

        _writeReport(address(payload), payload.report());
    }

    function _writeReport(
        address                                             payload,
        SparkEthereumDeployAdministeredAgents.Report memory report
    )
        internal
    {
        string memory administeredAgentsKey = "administeredAgents";

        administeredAgentsKey.serialize("sparkPlannerAdministeredAgent", report.plannerAgent);
        administeredAgentsKey.serialize("sparkVaultsAdministeredAgent",  report.sparkVaultsAgent);
        string memory administeredAgents = administeredAgentsKey.serialize("sllAdministeredAgent", report.sllAgent);

        string memory reportKey = "report";

        reportKey.serialize("deployAdministeredAgentsPayload", payload);

        string memory json = reportKey.serialize("administeredAgents", administeredAgents);

        json.write(
            string.concat(
                vm.projectRoot(),
                "/src/deployments/SparkEthereumAdministeredAgents-20261116/report/report.json"
            )
        );
    }

}
