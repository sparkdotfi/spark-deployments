// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Script, stdJson } from "../../../../lib/forge-std/src/Script.sol";

import { SparkDeployOrchestration } from "../SparkDeployOrchestration.sol";

contract Deploy is Script {

    using stdJson for string;

    function run() external {
        vm.startBroadcast();
        SparkDeployOrchestration.Report memory report = SparkDeployOrchestration.deploy();
        vm.stopBroadcast();

        _writeReport(report);
    }

    function _writeReport(SparkDeployOrchestration.Report memory report) internal {
        string memory pasKey = "pasDeployment";

        pasKey.serialize("beamState",    report.pasDeploymentReport.beamState);
        pasKey.serialize("configurator", report.pasDeploymentReport.configurator);
        pasKey.serialize("timelock",     report.pasDeploymentReport.timelock);
        string memory pas = pasKey.serialize("mom", report.pasDeploymentReport.mom);

        string memory spPrimeKey = "spPrimeDeployment";

        spPrimeKey.serialize("spPrime",                  report.spPrimeDeploymentReport.spPrime);
        spPrimeKey.serialize("spPrimePAUAccessControls", report.spPrimeDeploymentReport.spPrimePAUAccessControls);
        spPrimeKey.serialize("spPrimePAUAlmProxy",       report.spPrimeDeploymentReport.spPrimePAUAlmProxy);
        spPrimeKey.serialize("spPrimePAUController",     report.spPrimeDeploymentReport.spPrimePAUController);
        spPrimeKey.serialize("spPrimePAURateLimits",     report.spPrimeDeploymentReport.spPrimePAURateLimits);
        spPrimeKey.serialize("flcPAUAccessControls",     report.spPrimeDeploymentReport.flcPAUAccessControls);
        spPrimeKey.serialize("flcPAUAlmProxy",           report.spPrimeDeploymentReport.flcPAUAlmProxy);
        spPrimeKey.serialize("flcPAUController",         report.spPrimeDeploymentReport.flcPAUController);
        string memory spPrime = spPrimeKey.serialize("flcPAURateLimits", report.spPrimeDeploymentReport.flcPAURateLimits);

        string memory administeredAgentsKey = "administeredAgents";

        administeredAgentsKey.serialize("sparkPlannerAdministeredAgent", report.spPrimeDeploymentReport.sparkPlannerAdministeredAgent);
        string memory administeredAgents = administeredAgentsKey.serialize(
            "sparkVaultsAdministeredAgent",
            report.spPrimeDeploymentReport.sparkVaultsAdministeredAgent
        );

        string memory reportKey = "report";

        reportKey.serialize("pasDeployment",     pas);
        reportKey.serialize("spPrimeDeployment", spPrime);
        string memory json = reportKey.serialize("administeredAgents", administeredAgents);

        json.write(string.concat(vm.projectRoot(), "/src/deployments/SpPrime-2026-11-29/report/report.json"));
    }

}
