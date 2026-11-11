// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Ethereum } from "../../../lib/spark-address-registry/src/Ethereum.sol";

import { BeamState }    from "../../../lib/pas/src/BeamState.sol";
import { Configurator } from "../../../lib/pas/src/Configurator.sol";
import { Timelock }     from "../../../lib/pas/src/timelock/Timelock.sol";

import { PASInit }     from "../../../lib/pas/deploy/PASInit.sol";
import { PASInstance } from "../../../lib/pas/deploy/PASInstance.sol";

/**
 * @title  PAS
 * @notice Single use deployment spell for PAS (BeamState, Configurator and Timelock) on Ethereum
 *         mainnet. The constructor deploys, configures and hands every contract over to its final
 *         owners. The spell holds no role afterwards.
 */
contract SparkEthereumDeployPAS {

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    uint256 internal constant MAINNET = 1;

    // ROLES

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    // PAS CONFIG

    // TODO: Replace with the final addresses.
    address internal constant ABEAM_MULTISIG = address(1);
    address internal constant PAS_CANCELLER1 = address(2);  // Spark Low Threshold Multisig
    address internal constant PAS_CANCELLER2 = address(3);  // Soter Labs Revoker Multisig

    uint256 internal constant PAS_MIN_DELAY = 5 days;

    /**********************************************************************************************/
    /*** Deployed contracts                                                                     ***/
    /**********************************************************************************************/

    struct PASDeploymentReport {
        address beamState;
        address configurator;
        address timelock;
        address mom;
    }

    PASDeploymentReport internal _pasDeployment;

    function pasDeployment() external view returns (PASDeploymentReport memory) {
        return _pasDeployment;
    }

    /**********************************************************************************************/
    /*** Constructor                                                                            ***/
    /**********************************************************************************************/

    constructor() {
        require(block.chainid == MAINNET, "SparkEthereumDeployPAS/invalid-chain-id");

        // Step 1: Deploy PAS with the spell as temporary owner

        _pasDeployment.beamState    = address(new BeamState());
        _pasDeployment.configurator = address(new Configurator(_pasDeployment.beamState));
        _pasDeployment.timelock     = address(new Timelock(PAS_MIN_DELAY, address(this)));

        // TODO: Deploy the Sky PAS Mom, placeholder address until then.
        _pasDeployment.mom = address(4); // use deployMom from PASDeploy.sol

        // Step 2: Configure PAS

        _configurePAS();

        // Step 3: Hand ownership over and remove the spell

        _handoffPAS();
    }

    /**********************************************************************************************/
    /*** Configuration helpers                                                                  ***/
    /**********************************************************************************************/

    function _configurePAS() internal {
        // The Core Council is also a canceller, PASInit.init grants it directly.
        address[] memory cancellers = new address[](2);
        cancellers[0] = PAS_CANCELLER1;
        cancellers[1] = PAS_CANCELLER2;

        address[] memory pausers = new address[](1);
        pausers[0] = _pasDeployment.mom;

        PASInit.init({
            pasInstance : PASInstance({
                beamState    : _pasDeployment.beamState,
                configurator : _pasDeployment.configurator,
                timelock     : _pasDeployment.timelock
            }),
            minDelay    : PAS_MIN_DELAY,
            coreCouncil : ABEAM_MULTISIG,
            cancellers  : cancellers,
            pausers     : pausers
        });

        // TODO: Configure the Sky PAS Mom. Use initMom from PASInit.sol
    }

    /**********************************************************************************************/
    /*** Handoff                                                                                ***/
    /**********************************************************************************************/

    function _handoffPAS() internal {
        BeamState(_pasDeployment.beamState).rely(Ethereum.SPARK_PROXY);
        BeamState(_pasDeployment.beamState).deny(address(this));

        require(
            BeamState(_pasDeployment.beamState).wards(Ethereum.SPARK_PROXY) == 1,
            "SparkEthereumDeployPAS/beam-state-owner-not-set"
        );
        require(
            BeamState(_pasDeployment.beamState).wards(address(this)) == 0,
            "SparkEthereumDeployPAS/spell-still-beam-state-ward"
        );

        Timelock timelock = Timelock(payable(_pasDeployment.timelock));

        timelock.grantRole(DEFAULT_ADMIN_ROLE,  Ethereum.SPARK_PROXY);
        timelock.revokeRole(DEFAULT_ADMIN_ROLE, address(this));

        require(
            timelock.hasRole(DEFAULT_ADMIN_ROLE, Ethereum.SPARK_PROXY),
            "SparkEthereumDeployPAS/admin-not-set"
        );
        require(
            !timelock.hasRole(DEFAULT_ADMIN_ROLE, address(this)),
            "SparkEthereumDeployPAS/spell-still-admin"
        );
    }

}
