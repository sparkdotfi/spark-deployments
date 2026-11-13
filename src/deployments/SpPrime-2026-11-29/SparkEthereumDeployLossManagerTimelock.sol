// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Timelock } from "../../../lib/pas/src/timelock/Timelock.sol";

import { Ethereum } from "../../../lib/spark-address-registry/src/Ethereum.sol";

import { IAccessControls } from "../../../lib/diamond-pau/src/interfaces/IAccessControls.sol";

/**
 * @title  SparkEthereumDeployLossManagerTimelock
 * @notice Single use deployment spell for Loss Manager Timelock on Ethereum mainnet.
 *         The constructor deploys, configures and hands over the contract to its final owner.
 */
contract SparkEthereumDeployLossManagerTimelock {

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    uint256 internal constant MAINNET = 1;

    // Loss Manager Timelock

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    uint256 internal constant LOSS_MANAGER_TIMELOCK_MIN_DELAY = 1 days;

    address internal constant ADMINISTRATOR_MULTISIG         = address(12);
    address internal constant LOSS_MANAGER_PROPOSER_MULTISIG = address(13);
    address internal constant SOTER_LABS_REVOKER_MULTISIG    = address(8);
    address internal constant SPARK_LOW_THRESHOLD_MULTISIG   = address(10);

    /**********************************************************************************************/
    /*** Deployed contracts                                                                     ***/
    /**********************************************************************************************/

    struct LossManagerTimelockDeploymentReport {
        address lossManagerTimelock;
    }

    LossManagerTimelockDeploymentReport internal _lossManagerTimelockDeploymentReport;

    function lossManagerTimelockDeployment() external view returns (LossManagerTimelockDeploymentReport memory) {
        return _lossManagerTimelockDeploymentReport;
    }

    /**********************************************************************************************/
    /*** Constructor                                                                            ***/
    /**********************************************************************************************/

    constructor() {
        require(
            block.chainid == MAINNET,
            "SparkEthereumDeployLossManagerTimelock/invalid-chain-id"
        );

        _lossManagerTimelockDeploymentReport.lossManagerTimelock = address(
            new Timelock({
                minDelay : LOSS_MANAGER_TIMELOCK_MIN_DELAY,
                admin    : address(this)
            })
        );

        _configure();

        _handoff(_lossManagerTimelockDeploymentReport.lossManagerTimelock, Ethereum.SPARK_PROXY);
    }

    /**********************************************************************************************/
    /*** Configuration helpers                                                                  ***/
    /**********************************************************************************************/

    function _configure() internal {
        Timelock lossManagerTimelock = Timelock(
            payable(
                _lossManagerTimelockDeploymentReport.lossManagerTimelock
            )
        );

        lossManagerTimelock.grantRole(lossManagerTimelock.PROPOSER_ROLE(), LOSS_MANAGER_PROPOSER_MULTISIG);

        lossManagerTimelock.grantRole(lossManagerTimelock.CANCELLER_ROLE(), SPARK_LOW_THRESHOLD_MULTISIG);
        lossManagerTimelock.grantRole(lossManagerTimelock.CANCELLER_ROLE(), SOTER_LABS_REVOKER_MULTISIG);
        lossManagerTimelock.grantRole(lossManagerTimelock.CANCELLER_ROLE(), ADMINISTRATOR_MULTISIG);

        lossManagerTimelock.grantRole(lossManagerTimelock.PAUSER_ROLE(), SOTER_LABS_REVOKER_MULTISIG);
    }

    /**********************************************************************************************/
    /*** Handoff                                                                                ***/
    /**********************************************************************************************/

    function _handoff(address target, address admin) internal {
        IAccessControls(target).grantRole(DEFAULT_ADMIN_ROLE,  admin);
        IAccessControls(target).revokeRole(DEFAULT_ADMIN_ROLE, address(this));

        require(
            IAccessControls(target).hasRole(DEFAULT_ADMIN_ROLE, admin),
            "SparkEthereumDeployLossManagerTimelock/admin-not-set"
        );
        require(
            !IAccessControls(target).hasRole(DEFAULT_ADMIN_ROLE, address(this)),
            "SparkEthereumDeployLossManagerTimelock/spell-still-admin"
        );
    }

}
