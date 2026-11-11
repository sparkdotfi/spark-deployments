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
        string memory pas = "pasDeployment";

        pas = pas.serialize("beamState",    report.pasDeploymentReport.beamState);
        pas = pas.serialize("configurator", report.pasDeploymentReport.configurator);
        pas = pas.serialize("timelock",     report.pasDeploymentReport.timelock);
        pas = pas.serialize("mom",          report.pasDeploymentReport.mom);

        string memory spPrime = "spPrimeDeployment";

        spPrime = spPrime.serialize("spPrime",                  report.spPrimeDeploymentReport.spPrime);
        spPrime = spPrime.serialize("spPrimePAUAccessControls", report.spPrimeDeploymentReport.spPrimePAUAccessControls);
        spPrime = spPrime.serialize("spPrimePAUAlmProxy",       report.spPrimeDeploymentReport.spPrimePAUAlmProxy);
        spPrime = spPrime.serialize("spPrimePAUController",     report.spPrimeDeploymentReport.spPrimePAUController);
        spPrime = spPrime.serialize("spPrimePAURateLimits",     report.spPrimeDeploymentReport.spPrimePAURateLimits);
        spPrime = spPrime.serialize("flcPAUAccessControls",     report.spPrimeDeploymentReport.flcPAUAccessControls);
        spPrime = spPrime.serialize("flcPAUAlmProxy",           report.spPrimeDeploymentReport.flcPAUAlmProxy);
        spPrime = spPrime.serialize("flcPAUController",         report.spPrimeDeploymentReport.flcPAUController);
        spPrime = spPrime.serialize("flcPAURateLimits",         report.spPrimeDeploymentReport.flcPAURateLimits);

        string memory json = "report";

        json = json.serialize("pasDeployment",     pas);
        json = json.serialize("spPrimeDeployment", spPrime);

        json.write(string.concat(vm.projectRoot(), "/src/deployments/SpPrime-2026-11-29/report/report.json"));
    }

}
