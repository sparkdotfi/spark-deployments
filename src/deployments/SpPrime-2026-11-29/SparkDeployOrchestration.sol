// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { SparkEthereumDeployLossManagerTimelock } from "./SparkEthereumDeployLossManagerTimelock.sol";
import { SparkEthereumDeployPAS }                 from "./SparkEthereumDeployPAS.sol";
import { SparkEthereumDeploySpPrime }             from "./SparkEthereumDeploySpPrime.sol";

/**
 * @title  SparkDeployOrchestration
 * @author Phoenix Labs
 * @dev    Library which ensemble the deployment.
 */
library SparkDeployOrchestration {

    struct Report {
        address                                                                    deployPASPayload;
        SparkEthereumDeployPAS.PASDeploymentReport                                 pasDeploymentReport;
        address                                                                    deploySpPrimePayload;
        SparkEthereumDeploySpPrime.SpPrimeDeploymentReport                         spPrimeDeploymentReport;
        address                                                                    deployLossManagerTimelockPayload;
        SparkEthereumDeployLossManagerTimelock.LossManagerTimelockDeploymentReport lossManagerTimelockDeploymentReport;
    }

    function deploy() internal returns (Report memory report) {
        // Deploy Loss Manager Timelock

        SparkEthereumDeployLossManagerTimelock deployLossManagerTimelockPayload = new SparkEthereumDeployLossManagerTimelock();

        report.deployLossManagerTimelockPayload    = address(deployLossManagerTimelockPayload);
        report.lossManagerTimelockDeploymentReport = deployLossManagerTimelockPayload.lossManagerTimelockDeployment();

        // Deploy PAS
        SparkEthereumDeployPAS deployPASPayload = new SparkEthereumDeployPAS();

        report.deployPASPayload    = address(deployPASPayload);
        report.pasDeploymentReport = deployPASPayload.pasDeployment();

        // Deploy SpPrime.
        SparkEthereumDeploySpPrime deploySpPrimePayload = new SparkEthereumDeploySpPrime(
            report.pasDeploymentReport.configurator,
            report.lossManagerTimelockDeploymentReport.lossManagerTimelock
        );

        report.deploySpPrimePayload    = address(deploySpPrimePayload);
        report.spPrimeDeploymentReport = deploySpPrimePayload.spPrimeDeployment();
    }

}
