// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { SparkEthereumDeployPAS }     from "./SparkEthereumDeployPAS.sol";
import { SparkEthereumDeploySpPrime } from "./SparkEthereumDeploySpPrime.sol";

/**
 * @title  SparkDeployOrchestration
 * @author Phoenix Labs
 * @dev    Library which ensemble the deployment.
 */
library SparkDeployOrchestration {

    struct Report {
        address                                            pasDeployment;
        SparkEthereumDeployPAS.PASDeploymentReport         pasDeploymentReport;
        address                                            spPrimeDeployment;
        SparkEthereumDeploySpPrime.SpPrimeDeploymentReport spPrimeDeploymentReport;
    }

    function deploy() public returns (Report memory report) {
        // Deploy PAS
        SparkEthereumDeployPAS pas = new SparkEthereumDeployPAS();

        report.pasDeployment       = address(pas);
        report.pasDeploymentReport = pas.pasDeployment();

        // Deploy SpPrime.
        SparkEthereumDeploySpPrime spPrime = new SparkEthereumDeploySpPrime(report.pasDeploymentReport.configurator);

        report.spPrimeDeployment       = address(spPrime);
        report.spPrimeDeploymentReport = spPrime.spPrimeDeployment();
    }

}
