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

interface ISPUSDTPAUController is IController, ISparkVaultController, ITransferAssetController, ILayerZeroController {}

/**
 * @title  ArbitrumSparkSpUSDTPayload
 * @notice One-shot deployment payload for Arbitrum. In its constructor it deploys the planner and
 *         Spark AdministeredAgents and the spUSDT PAU, configures their roles, facets, rate limits
 *         and the LayerZero recipient on Ethereum, then hands all admin rights to the Spark
 *         Executor and revokes its own.
 */
contract ArbitrumSparkSpUSDTPayload {

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    uint256 internal constant ARBITRUM = 42161;

    // Roles

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant ALLOCATOR_ROLE     = keccak256("ALLOCATOR_ROLE");

    bytes32 internal constant SPARK_PLANNER_ADMINISTERED_AGENT_SALT = "SPARK_PLANNER_ADMINISTERED_AGENT";
    bytes32 internal constant SPARK_ADMINISTERED_AGENT_SALT         = "SPARK_ADMINISTERED_AGENT";

    address internal constant SPARK_PLANNER_HOT_WALLET        = Arbitrum.PLANNER_WALLET;
    address internal constant SPARK_LOW_THRESHOLD_MULTISIG    = Arbitrum.SPARK_LOW_THRESHOLD_MULTISIG;
    address internal constant SPARK_MEDIUM_THRESHOLD_MULTISIG = Arbitrum.SPARK_MEDIUM_THRESHOLD_MULTISIG;
    address internal constant SOTER_REVOKER_MULTISIG          = Arbitrum.SOTER_REVOKER_MULTISIG;
    address internal constant SOTER_GRANTOR_MULTISIG          = Arbitrum.SOTER_GRANTOR_MULTISIG;

    // spUSDT PAU Configuration

    bytes32 internal constant SPARK_SPUSDT_PAU_SALT = "SPARK_SPUSDT_PAU";

    // LayerZero configuration

    uint32 internal constant LZ_ETHEREUM_EID = 30101;

    bytes32 internal constant PEER = bytes32(uint256(uint160(Ethereum.USDT_OFT)));

    bytes32 internal constant ETHEREUM_SPUSDT_ALM_PROXY = bytes32(uint256(uint160(address(6)))); // TODO: Replace with the final address

    /**********************************************************************************************/
    /*** Deployed contracts                                                                     ***/
    /**********************************************************************************************/

    struct Report {
        address plannerAgent;
        address sparkAgent;
        address spUSDTPAU_controller;
        address spUSDTPAU_accessControls;
        address spUSDTPAU_almProxy;
        address spUSDTPAU_rateLimits;
    }

    Report internal _report;

    /**********************************************************************************************/
    /*** Constructor                                                                            ***/
    /**********************************************************************************************/

    constructor() {
        require(block.chainid == ARBITRUM, "ArbitrumSparkSpUSDTPayload/invalid-chain-id");

        // Step 1: Deploy the two AdministeredAgents with the payload as temporary admin

        IAdministeredAgentFactory administeredAgentFactory = IAdministeredAgentFactory(Arbitrum.SPARK_ADMINISTERED_AGENT_FACTORY);

        _report.plannerAgent = administeredAgentFactory.deploy(address(this), SPARK_PLANNER_ADMINISTERED_AGENT_SALT);
        _report.sparkAgent   = administeredAgentFactory.deploy(address(this), SPARK_ADMINISTERED_AGENT_SALT);

        // Step 2: Deploy spUSDT PAU

        IPAUFactory pauFactory = IPAUFactory(Arbitrum.SPARK_PAU_FACTORY);

        _report.spUSDTPAU_controller     = pauFactory.deployPAU(address(this), SPARK_SPUSDT_PAU_SALT);
        _report.spUSDTPAU_accessControls = IController(_report.spUSDTPAU_controller).accessControls();
        _report.spUSDTPAU_almProxy       = IController(_report.spUSDTPAU_controller).proxy();
        _report.spUSDTPAU_rateLimits     = IController(_report.spUSDTPAU_controller).rateLimits();

        // Step 3: Configure the AdministeredAgents

        _configureAdministeredAgents();

        // Step 4: Configure spUSDT PAU

        _configureSpUSDTPAU();

        // Step 5: Hand admin rights over to the Spark Executor and revoke the payload's admin role

        _handoffAdministeredAgents();

        _handoff(_report.spUSDTPAU_accessControls, Arbitrum.SPARK_EXECUTOR);
        _handoff(_report.spUSDTPAU_almProxy,       Arbitrum.SPARK_EXECUTOR);
        _handoff(_report.spUSDTPAU_rateLimits,     Arbitrum.SPARK_EXECUTOR);
    }

    function report() public view returns (Report memory) {
        return _report;
    }

    /**********************************************************************************************/
    /*** Configuration helpers                                                                  ***/
    /**********************************************************************************************/

    function _configureAdministeredAgents() internal {
        IAdministeredAgent plannerAgent     = IAdministeredAgent(_report.plannerAgent);
        IAdministeredAgent sparkAgent = IAdministeredAgent(_report.sparkAgent);

        plannerAgent.addAdmin(Arbitrum.SPARK_EXECUTOR);
        plannerAgent.addActor(SPARK_PLANNER_HOT_WALLET);
        plannerAgent.addRevoker(SPARK_LOW_THRESHOLD_MULTISIG);
        plannerAgent.addGrantor(SPARK_MEDIUM_THRESHOLD_MULTISIG);

        sparkAgent.addAdmin(Arbitrum.SPARK_EXECUTOR);
        sparkAgent.addActor(_report.plannerAgent);
        sparkAgent.addRevoker(SPARK_LOW_THRESHOLD_MULTISIG);
        sparkAgent.addRevoker(SOTER_REVOKER_MULTISIG);
        sparkAgent.addGrantor(SOTER_GRANTOR_MULTISIG);
    }

    function _configureSpUSDTPAU() internal {
        IAccessControls      accessControls = IAccessControls(_report.spUSDTPAU_accessControls);
        IALMProxy            almProxy       = IALMProxy(_report.spUSDTPAU_almProxy);
        ISPUSDTPAUController controller     = ISPUSDTPAUController(_report.spUSDTPAU_controller);
        IRateLimits          rateLimits     = IRateLimits(_report.spUSDTPAU_rateLimits);

        // Roles configuration

        almProxy.grantRole(almProxy.CONTROLLER(),     _report.spUSDTPAU_controller);
        rateLimits.grantRole(rateLimits.CONTROLLER(), _report.spUSDTPAU_controller);
        accessControls.grantRole(ALLOCATOR_ROLE,      _report.sparkAgent);

        // Onboarding facets

        bytes32[] memory integrationIds = new bytes32[](3);
        integrationIds[0] = "LAYER_ZERO_FACET";
        integrationIds[1] = "SPARK_VAULT_FACET";
        integrationIds[2] = "TRANSFER_ASSET_FACET";

        controller.updateIntegrations(integrationIds);

        // SparkVault rate limits configuration

        rateLimits.setUnlimitedRateLimitData(controller.sparkVault_getTakeRateLimitKey(Arbitrum.SPARK_VAULT_V2_SPUSDT));

        // TransferAsset rate limits configuration

        rateLimits.setUnlimitedRateLimitData(
            controller.transferAsset_getTransferRateLimitKey(Arbitrum.USDT0, Arbitrum.SPARK_VAULT_V2_SPUSDT)
        );

        // LayerZero rate limits configuration

        rateLimits.setUnlimitedRateLimitData(
            controller.layerZero_getTransferRateLimitKey(Arbitrum.USDT_OFT, PEER, LZ_ETHEREUM_EID, Arbitrum.USDT0)
        );

        // LayerZero set recipient
        controller.layerZero_setRecipient(LZ_ETHEREUM_EID, ETHEREUM_SPUSDT_ALM_PROXY);
    }

    function _handoffAdministeredAgents() internal {
        IAdministeredAgent plannerAgent = IAdministeredAgent(_report.plannerAgent);
        IAdministeredAgent sparkAgent   = IAdministeredAgent(_report.sparkAgent);

        plannerAgent.removeAdmin(address(this));

        require(plannerAgent.adminCount() == 1,                       "planner-agent-admin-count-not-one");
        require(plannerAgent.getAdmin(0)  == Arbitrum.SPARK_EXECUTOR, "planner-agent-admin-not-spark-executor");

        sparkAgent.removeAdmin(address(this));

        require(sparkAgent.adminCount() == 1,                       "spark-agent-admin-count-not-one");
        require(sparkAgent.getAdmin(0)  == Arbitrum.SPARK_EXECUTOR, "spark-agent-admin-not-spark-executor");
    }

    function _handoff(address target, address admin) internal {
        IAccessControls accessControls = IAccessControls(target);

        accessControls.grantRole(DEFAULT_ADMIN_ROLE,  admin);
        accessControls.revokeRole(DEFAULT_ADMIN_ROLE, address(this));

        require(accessControls.getRoleMemberCount(DEFAULT_ADMIN_ROLE) == 1, "default-admin-role-incorrect-count");
        require(accessControls.hasRole(DEFAULT_ADMIN_ROLE, admin),          "admin-not-set");
        require(!accessControls.hasRole(DEFAULT_ADMIN_ROLE, address(this)), "payload-still-admin");
    }

}
