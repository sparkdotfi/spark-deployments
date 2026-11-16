// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Ethereum } from "../../../lib/spark-address-registry/src/Ethereum.sol";

interface IAdministeredAgent {

    function addActor(address account) external;

    function addAdmin(address account) external;

    function addGrantor(address account) external;

    function addRevoker(address account) external;

    function adminCount() external view returns (uint256);

    function getAdmin(uint256 index) external view returns (address);

    function removeAdmin(address account) external;

}

interface IAdministeredAgentFactory {

    function deploy(address admin, bytes32 salt) external returns (address administeredAgent);

}

/**
 * @title  SparkEthereumDeployAdministeredAgents
 * @notice Single use deployment payload for the Spark Planner, Spark Vaults and SLL
 *         AdministeredAgents on Ethereum mainnet. The constructor deploys, configures and hands
 *         every agent over to the Spark Proxy. The payload holds no role afterwards.
 */
contract SparkEthereumDeployAdministeredAgents {

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    uint256 internal constant MAINNET = 1;

    bytes32 internal constant SPARK_PLANNER_ADMINISTERED_AGENT_SALT = "SPARK_PLANNER_ADMINISTERED_AGENT";
    bytes32 internal constant SPARK_VAULTS_ADMINISTERED_AGENT_SALT  = "SPARK_VAULTS_ADMINISTERED_AGENT";
    bytes32 internal constant SPARK_SLL_ADMINISTERED_AGENT_SALT     = "SPARK_SLL_ADMINISTERED_AGENT";

    // TODO: Replace with the final addresses.
    address internal constant SPARK_PLANNER_HOT_WALLET        = address(1);
    address internal constant SPARK_LOW_THRESHOLD_MULTISIG    = address(2);
    address internal constant SPARK_MEDIUM_THRESHOLD_MULTISIG = address(3);
    address internal constant SOTER_LABS_REVOKER_MULTISIG     = address(4);
    address internal constant SOTER_LABS_GRANTOR_MULTISIG     = address(5);

    /**********************************************************************************************/
    /*** Deployed contracts                                                                     ***/
    /**********************************************************************************************/

    struct Report {
        address plannerAgent;
        address sparkVaultsAgent;
        address sllAgent;
    }

    Report internal _report;

    function report() external view returns (Report memory) {
        return _report;
    }

    /**********************************************************************************************/
    /*** Constructor                                                                            ***/
    /**********************************************************************************************/

    constructor() {
        require(block.chainid == MAINNET, "SparkEthereumDeployAdministeredAgents/invalid-chain-id");

        // Step 1: Deploy the three AdministeredAgents with the payload as temporary admin

        IAdministeredAgentFactory administeredAgentFactory = IAdministeredAgentFactory(Ethereum.SPARK_ADMINISTERED_AGENT_FACTORY);

        _report.plannerAgent = administeredAgentFactory.deploy(
            address(this),
            SPARK_PLANNER_ADMINISTERED_AGENT_SALT
        );
        _report.sparkVaultsAgent = administeredAgentFactory.deploy(
            address(this),
            SPARK_VAULTS_ADMINISTERED_AGENT_SALT
        );
        _report.sllAgent = administeredAgentFactory.deploy(
            address(this),
            SPARK_SLL_ADMINISTERED_AGENT_SALT
        );

        // Step 2: Configure the AdministeredAgents

        _configureAdministeredAgents();

        // Step 3: Hand admin rights over to the Spark Proxy and revoke the payload's admin role

        _handoffAdministeredAgents();
    }

    /**********************************************************************************************/
    /*** Configuration helpers                                                                  ***/
    /**********************************************************************************************/

    function _configureAdministeredAgents() internal {
        IAdministeredAgent plannerAgent     = IAdministeredAgent(_report.plannerAgent);
        IAdministeredAgent sparkVaultsAgent = IAdministeredAgent(_report.sparkVaultsAgent);
        IAdministeredAgent sllAgent         = IAdministeredAgent(_report.sllAgent);

        plannerAgent.addAdmin(Ethereum.SPARK_PROXY);
        plannerAgent.addActor(SPARK_PLANNER_HOT_WALLET);
        plannerAgent.addRevoker(SPARK_LOW_THRESHOLD_MULTISIG);
        plannerAgent.addGrantor(SPARK_MEDIUM_THRESHOLD_MULTISIG);

        sparkVaultsAgent.addAdmin(Ethereum.SPARK_PROXY);
        sparkVaultsAgent.addActor(_report.plannerAgent);
        sparkVaultsAgent.addRevoker(SPARK_LOW_THRESHOLD_MULTISIG);
        sparkVaultsAgent.addRevoker(SOTER_LABS_REVOKER_MULTISIG);
        sparkVaultsAgent.addGrantor(SOTER_LABS_GRANTOR_MULTISIG);

        // TODO: Confirm the SLL AdministeredAgent configuration.
        sllAgent.addAdmin(Ethereum.SPARK_PROXY);
        sllAgent.addActor(_report.plannerAgent);
        sllAgent.addRevoker(SPARK_LOW_THRESHOLD_MULTISIG);
        sllAgent.addRevoker(SOTER_LABS_REVOKER_MULTISIG);
        sllAgent.addGrantor(SOTER_LABS_GRANTOR_MULTISIG);
    }

    function _handoffAdministeredAgents() internal {
        IAdministeredAgent plannerAgent     = IAdministeredAgent(_report.plannerAgent);
        IAdministeredAgent sparkVaultsAgent = IAdministeredAgent(_report.sparkVaultsAgent);
        IAdministeredAgent sllAgent         = IAdministeredAgent(_report.sllAgent);

        plannerAgent.removeAdmin(address(this));

        require(
            plannerAgent.adminCount() == 1,
            "SparkEthereumDeployAdministeredAgents/planner-agent-admin-count-not-one"
        );
        require(
            plannerAgent.getAdmin(0) == Ethereum.SPARK_PROXY,
            "SparkEthereumDeployAdministeredAgents/planner-agent-admin-not-spark-proxy"
        );

        sparkVaultsAgent.removeAdmin(address(this));

        require(
            sparkVaultsAgent.adminCount() == 1,
            "SparkEthereumDeployAdministeredAgents/spark-vaults-agent-admin-count-not-one"
        );
        require(
            sparkVaultsAgent.getAdmin(0) == Ethereum.SPARK_PROXY,
            "SparkEthereumDeployAdministeredAgents/spark-vaults-agent-admin-not-spark-proxy"
        );

        sllAgent.removeAdmin(address(this));

        require(
            sllAgent.adminCount() == 1,
            "SparkEthereumDeployAdministeredAgents/sll-agent-admin-count-not-one"
        );
        require(
            sllAgent.getAdmin(0) == Ethereum.SPARK_PROXY,
            "SparkEthereumDeployAdministeredAgents/sll-agent-admin-not-spark-proxy"
        );
    }

}
