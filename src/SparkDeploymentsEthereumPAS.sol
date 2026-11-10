// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Ethereum } from "../lib/spark-address-registry/src/Ethereum.sol";

import { BeamState }    from "../lib/pas/src/BeamState.sol";
import { Configurator } from "../lib/pas/src/Configurator.sol";
import { Timelock }     from "../lib/pas/src/timelock/Timelock.sol";

import { PASInit }     from "../lib/pas/deploy/PASInit.sol";
import { PASInstance } from "../lib/pas/deploy/PASInstance.sol";

/**
 * @title  SparkDeploymentsEthereumPAS
 * @notice Single use deployment spell for PAS (BeamState, Configurator and Timelock) on Ethereum
 *         mainnet. The constructor deploys, configures and hands every contract over to its final
 *         owners. The spell holds no role afterwards.
 */
contract SparkDeploymentsEthereumPAS {

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    uint256 internal constant ETHEREUM_MAINNET = 1;

    // ROLES

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    // PAS CONFIG

    address internal constant PAS_OWNER = Ethereum.SPARK_PROXY;  // BeamState ward and Timelock admin

    // TODO: Replace with the final addresses.
    address internal constant PAS_CORE_COUNCIL = address(1);  // aBEAM Multisig
    address internal constant PAS_CANCELLER1   = address(2);  // Spark Low Threshold Multisig
    address internal constant PAS_CANCELLER2   = address(3);  // Soter Labs Revoker Multisig

    uint256 internal constant PAS_MIN_DELAY = 5 days;

    /**********************************************************************************************/
    /*** Deployed contracts                                                                     ***/
    /**********************************************************************************************/

    address public immutable PAS_BEAM_STATE;
    address public immutable PAS_CONFIGURATOR;
    address public immutable PAS_TIMELOCK;
    address public immutable PAS_MOM;

    /**********************************************************************************************/
    /*** Constructor                                                                            ***/
    /**********************************************************************************************/

    constructor() {
        require(block.chainid == ETHEREUM_MAINNET, "SparkDeploymentsEthereumPAS/invalid-chain-id");

        // Step 1: Deploy PAS with the spell as temporary owner

        PAS_BEAM_STATE   = address(new BeamState());
        PAS_CONFIGURATOR = address(new Configurator(PAS_BEAM_STATE));
        PAS_TIMELOCK     = address(new Timelock(PAS_MIN_DELAY, address(this)));

        // TODO: Deploy the Sky PAS Mom, placeholder address until then.
        PAS_MOM = address(4); // use deployMom from PASDeploy.sol

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
        pausers[0] = PAS_MOM;

        PASInit.init({
            pasInstance : PASInstance({
                beamState    : PAS_BEAM_STATE,
                configurator : PAS_CONFIGURATOR,
                timelock     : PAS_TIMELOCK
            }),
            minDelay    : PAS_MIN_DELAY,
            coreCouncil : PAS_CORE_COUNCIL,
            cancellers  : cancellers,
            pausers     : pausers
        });

        // TODO: Configure the Sky PAS Mom. Use initMom from PASInit.sol
    }

    /**********************************************************************************************/
    /*** Handoff                                                                                ***/
    /**********************************************************************************************/

    function _handoffPAS() internal {
        BeamState(PAS_BEAM_STATE).rely(PAS_OWNER);
        BeamState(PAS_BEAM_STATE).deny(address(this));

        require(BeamState(PAS_BEAM_STATE).wards(PAS_OWNER)     == 1, "SparkDeploymentsEthereumPAS/beam-state-owner-not-set");
        require(BeamState(PAS_BEAM_STATE).wards(address(this)) == 0, "SparkDeploymentsEthereumPAS/spell-still-beam-state-ward");

        Timelock timelock = Timelock(payable(PAS_TIMELOCK));

        timelock.grantRole(DEFAULT_ADMIN_ROLE,  PAS_OWNER);
        timelock.revokeRole(DEFAULT_ADMIN_ROLE, address(this));

        require(
            timelock.hasRole(DEFAULT_ADMIN_ROLE, PAS_OWNER),
            "SparkDeploymentsEthereumPAS/admin-not-set"
        );
        require(
            !timelock.hasRole(DEFAULT_ADMIN_ROLE, address(this)),
            "SparkDeploymentsEthereumPAS/spell-still-admin"
        );
    }

}
