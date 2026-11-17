// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Arbitrum } from "../../../lib/spark-address-registry/src/Arbitrum.sol";
import { Ethereum } from "../../../lib/spark-address-registry/src/Ethereum.sol";

import { IALMProxy }       from "../../../lib/diamond-pau/src/interfaces/IALMProxy.sol";
import { IPAUFactory }     from "../../../lib/diamond-pau/src/interfaces/IPAUFactory.sol";
import { IController }     from "../../../lib/diamond-pau/src/interfaces/IController.sol";
import { IRateLimits }     from "../../../lib/diamond-pau/src/interfaces/IRateLimits.sol";
import { IAccessControls } from "../../../lib/diamond-pau/src/interfaces/IAccessControls.sol";

import { ILayerZeroController }     from "../../../lib/diamond-pau/src/facets/layer-zero/ILayerZeroController.sol";
import { ISparkVaultController }    from "../../../lib/diamond-pau/src/facets/spark-vault/ISparkVaultController.sol";
import { ITransferAssetController } from "../../../lib/diamond-pau/src/facets/transfer-asset/ITransferAssetController.sol";

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

contract ArbitrumSparkSpUSDTPayload {

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    uint256 internal constant ARBITRUM = 42161;

    // Roles

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant ALLOCATOR_ROLE     = keccak256("ALLOCATOR_ROLE");

    bytes32 internal constant SPARK_PLANNER_ADMINISTERED_AGENT_SALT = "SPARK_PLANNER_ADMINISTERED_AGENT";
    bytes32 internal constant SPARK_VAULTS_ADMINISTERED_AGENT_SALT  = "SPARK_VAULTS_ADMINISTERED_AGENT";

    // TODO: Replace with the final addresses.
    address internal constant SPARK_PLANNER_HOT_WALLET        = address(1);
    address internal constant SPARK_LOW_THRESHOLD_MULTISIG    = address(2);
    address internal constant SPARK_MEDIUM_THRESHOLD_MULTISIG = address(3);
    address internal constant SOTER_LABS_REVOKER_MULTISIG     = address(4);
    address internal constant SOTER_LABS_GRANTOR_MULTISIG     = address(5);

    // spUSDT PAU Configuration
    bytes32 internal constant SPARK_SPUSDT_PAU_SALT = "SPARK_SPUSDT_PAU";

    // LayerZero configuration
    uint32 internal constant LZ_ETHEREUM_EID = 30101;

    bytes32 internal constant PEER = bytes32(uint256(uint160(Ethereum.USDT_OFT)));

    bytes32 internal constant ETHEREUM_SPUSDT_ALM_PROXY = bytes32(uint256(uint160(address(6))));

    /**********************************************************************************************/
    /*** Deployed contracts                                                                     ***/
    /**********************************************************************************************/

    struct Report {
        address plannerAgent;
        address sparkVaultsAgent;
        address spUSDTPAUController;
        address spUSDTPAUAccessControls;
        address spUSDTPAUALMProxy;
        address spUSDTPAURateLimits;
    }

    Report public report;

    /**********************************************************************************************/
    /*** Constructor                                                                            ***/
    /**********************************************************************************************/

    constructor() {
        require(block.chainid == ARBITRUM, "SparkEthereumDeployAdministeredAgents/invalid-chain-id");

        // Step 1: Deploy the two AdministeredAgents with the payload as temporary admin

        IAdministeredAgentFactory administeredAgentFactory = IAdministeredAgentFactory(Arbitrum.SPARK_ADMINISTERED_AGENT_FACTORY);

        report.plannerAgent = administeredAgentFactory.deploy(
            address(this),
            SPARK_PLANNER_ADMINISTERED_AGENT_SALT
        );
        report.sparkVaultsAgent = administeredAgentFactory.deploy(
            address(this),
            SPARK_VAULTS_ADMINISTERED_AGENT_SALT
        );

        // Step 2: Deploy spUSDT PAU

        IPAUFactory pauFactory = IPAUFactory(Arbitrum.SPARK_PAU_FACTORY);

        report.spUSDTPAUController     = pauFactory.deployPAU(address(this), SPARK_SPUSDT_PAU_SALT);
        report.spUSDTPAUAccessControls = IController(report.spUSDTPAUController).accessControls();
        report.spUSDTPAUALMProxy       = IController(report.spUSDTPAUController).proxy();
        report.spUSDTPAURateLimits     = IController(report.spUSDTPAUController).rateLimits();

        // Step 2: Configure the AdministeredAgents

        _configureAdministeredAgents();

        // Step 4: Configure spUSDT PAU

        _configureSpUSDTPAU();

        // Step 5: Hand admin rights over to the Spark Executor and revoke the payload's admin role

        _handoffAdministeredAgents();

        _handoff(report.spUSDTPAUAccessControls, Arbitrum.SPARK_EXECUTOR);
        _handoff(report.spUSDTPAUALMProxy,       Arbitrum.SPARK_EXECUTOR);
        _handoff(report.spUSDTPAURateLimits,     Arbitrum.SPARK_EXECUTOR);
    }

    /**********************************************************************************************/
    /*** Configuration helpers                                                                  ***/
    /**********************************************************************************************/

    function _configureAdministeredAgents() internal {
        IAdministeredAgent plannerAgent     = IAdministeredAgent(report.plannerAgent);
        IAdministeredAgent sparkVaultsAgent = IAdministeredAgent(report.sparkVaultsAgent);

        // TODO: change this accordingly.
        plannerAgent.addAdmin(Arbitrum.SPARK_EXECUTOR);
        plannerAgent.addActor(SPARK_PLANNER_HOT_WALLET);
        plannerAgent.addRevoker(SPARK_LOW_THRESHOLD_MULTISIG);
        plannerAgent.addGrantor(SPARK_MEDIUM_THRESHOLD_MULTISIG);

        sparkVaultsAgent.addAdmin(Arbitrum.SPARK_EXECUTOR);
        sparkVaultsAgent.addActor(report.plannerAgent);
        sparkVaultsAgent.addRevoker(SPARK_LOW_THRESHOLD_MULTISIG);
        sparkVaultsAgent.addRevoker(SOTER_LABS_REVOKER_MULTISIG);
        sparkVaultsAgent.addGrantor(SOTER_LABS_GRANTOR_MULTISIG);
    }

    function _configureSpUSDTPAU() internal {
        IAccessControls accessControls = IAccessControls(report.spUSDTPAUAccessControls);
        IALMProxy       almProxy       = IALMProxy(report.spUSDTPAUALMProxy);
        IController     controller     = IController(report.spUSDTPAUController);
        IRateLimits     rateLimits     = IRateLimits(report.spUSDTPAURateLimits);

        // Roles configuration

        almProxy.grantRole(almProxy.CONTROLLER(),     report.spUSDTPAUController);
        rateLimits.grantRole(rateLimits.CONTROLLER(), report.spUSDTPAUController);
        accessControls.grantRole(ALLOCATOR_ROLE,      report.sparkVaultsAgent);

        // Onboaring facets

        bytes32[] memory integrationIds = new bytes32[](7);
        integrationIds[0] = "AAVE_FACET";
        integrationIds[1] = "CCTP_FACET";
        integrationIds[2] = "ERC4626_FACET";
        integrationIds[3] = "LAYER_ZERO_FACET";
        integrationIds[4] = "SPARK_VAULT_FACET";
        integrationIds[5] = "TRANSFER_ASSET_FACET";
        integrationIds[6] = "UNISWAP_V4_FACET";

        controller.updateIntegrations(integrationIds);

        // SparkVault rate limits configuration

        rateLimits.setUnlimitedRateLimitData(
            ISparkVaultController(report.spUSDTPAUController)
                .sparkVault_getTakeRateLimitKey(Arbitrum.SPARK_VAULT_V2_SPUSDT)
        );

        // TransferAsset rate limits configuration

        rateLimits.setUnlimitedRateLimitData(
            ITransferAssetController(report.spUSDTPAUController)
                .transferAsset_getTransferRateLimitKey(Arbitrum.USDT0, Arbitrum.SPARK_VAULT_V2_SPUSDT)
        );

        // LayerZero rate limits configuration

        rateLimits.setUnlimitedRateLimitData(
            ILayerZeroController(report.spUSDTPAUController)
                .layerZero_getTransferRateLimitKey(Arbitrum.USDT_OFT, PEER, LZ_ETHEREUM_EID, Arbitrum.USDT0)
        );

        // LayerZero set receipient
        ILayerZeroController(report.spUSDTPAUController).layerZero_setRecipient(LZ_ETHEREUM_EID, ETHEREUM_SPUSDT_ALM_PROXY);
    }

    function _handoffAdministeredAgents() internal {
        IAdministeredAgent plannerAgent     = IAdministeredAgent(report.plannerAgent);
        IAdministeredAgent sparkVaultsAgent = IAdministeredAgent(report.sparkVaultsAgent);

        plannerAgent.removeAdmin(address(this));

        require(
            plannerAgent.adminCount() == 1,
            "ArbitrumSparkSpUSDTPayload/planner-agent-admin-count-not-one"
        );
        require(
            plannerAgent.getAdmin(0) == Arbitrum.SPARK_EXECUTOR,
            "ArbitrumSparkSpUSDTPayload/planner-agent-admin-not-spark-proxy"
        );

        sparkVaultsAgent.removeAdmin(address(this));

        require(
            sparkVaultsAgent.adminCount() == 1,
            "ArbitrumSparkSpUSDTPayload/spark-vaults-agent-admin-count-not-one"
        );
        require(
            sparkVaultsAgent.getAdmin(0) == Arbitrum.SPARK_EXECUTOR,
            "ArbitrumSparkSpUSDTPayload/spark-vaults-agent-admin-not-spark-proxy"
        );
    }

    function _handoff(address target, address admin) internal {
        IAccessControls(target).grantRole(DEFAULT_ADMIN_ROLE,  admin);
        IAccessControls(target).revokeRole(DEFAULT_ADMIN_ROLE, address(this));

        require(
            IAccessControls(target).getRoleMemberCount(DEFAULT_ADMIN_ROLE) == 1,
            "SparkEthereumDeployAdministeredAgents/default-admin-role-incorrect-count"
        );
        require(
            IAccessControls(target).hasRole(DEFAULT_ADMIN_ROLE, admin),
            "SparkEthereumDeployAdministeredAgents/admin-not-set"
        );
        require(
            !IAccessControls(target).hasRole(DEFAULT_ADMIN_ROLE, address(this)),
            "SparkEthereumDeployAdministeredAgents/payload-still-admin"
        );
    }

}
