// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Ethereum } from "../../../lib/spark-address-registry/src/Ethereum.sol";

import { IALMProxy }       from "../../../lib/diamond-pau/src/interfaces/IALMProxy.sol";
import { IPAUFactory }     from "../../../lib/diamond-pau/src/interfaces/IPAUFactory.sol";
import { IController }     from "../../../lib/diamond-pau/src/interfaces/IController.sol";
import { IRateLimits }     from "../../../lib/diamond-pau/src/interfaces/IRateLimits.sol";
import { IAccessControls } from "../../../lib/diamond-pau/src/interfaces/IAccessControls.sol";

import { IERC4626Controller }       from "../../../lib/diamond-pau/src/facets/erc4626/IERC4626Controller.sol";
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

interface ISPUSDTController is IController, IERC4626Controller, ISparkVaultController, ITransferAssetController {}

/**
 * @title  EthereumSparkSpUSDTPayload
 * @notice One-shot deployment payload for Ethereum mainnet. In its constructor it deploys the
 *         planner, Spark Vaults and SLL AdministeredAgents, the SLL PAU and the spUSDT PAU,
 *         configures their roles, facets and rate limits, then hands all admin rights to the
 *         Spark Proxy and revokes its own.
 */
contract EthereumSparkSpUSDTPayload {

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    uint256 internal constant MAINNET = 1;

    // Roles

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant ALLOCATOR_ROLE     = keccak256("ALLOCATOR_ROLE");

    bytes32 internal constant SPARK_PLANNER_ADMINISTERED_AGENT_SALT = "SPARK_PLANNER_ADMINISTERED_AGENT";
    bytes32 internal constant SPARK_ADMINISTERED_AGENT_SALT         = "SPARK_VAULTS_ADMINISTERED_AGENT";
    bytes32 internal constant SPARK_SLL_ADMINISTERED_AGENT_SALT     = "SPARK_SLL_ADMINISTERED_AGENT";

    // TODO: Replace with the final addresses.
    address internal constant SPARK_PLANNER_HOT_WALLET        = address(1);
    address internal constant SPARK_LOW_THRESHOLD_MULTISIG    = address(2);
    address internal constant SPARK_MEDIUM_THRESHOLD_MULTISIG = address(3);
    address internal constant SOTER_LABS_REVOKER_MULTISIG     = address(4);
    address internal constant SOTER_LABS_GRANTOR_MULTISIG     = address(5);

    // SLL PAU Configuration
    bytes32 internal constant SPARK_SLL_PAU_ACCESS_CONTROLS_SALT = "SPARK_SLL_PAU_ACCESS_CONTROLS";
    bytes32 internal constant SPARK_SLL_PAU_RATE_LIMITS_SALT     = "SPARK_SLL_PAU_RATE_LIMITS";
    bytes32 internal constant SPARK_SLL_PAU_CONTROLLER_SALT      = "SPARK_SLL_PAU_CONTROLLER";

    // spUSDT PAU Configuration
    bytes32 internal constant SPARK_SPUSDT_PAU_SALT = "SPARK_SPUSDT_PAU";

    /**********************************************************************************************/
    /*** Deployed contracts                                                                     ***/
    /**********************************************************************************************/

    struct Report {
        address plannerAgent;
        address sparkAgent;
        address sllAgent;
        address sllPAU_accessControls;
        address sllPAU_controller;
        address sllPAU_rateLimits;
        address spUSDTPAU_accessControls;
        address spUSDTPAU_almProxy;
        address spUSDTPAU_controller;
        address spUSDTPAU_rateLimits;
    }

    Report internal _report;

    /**********************************************************************************************/
    /*** Constructor                                                                            ***/
    /**********************************************************************************************/

    constructor() {
        require(block.chainid == MAINNET, "EthereumSparkSpUSDTPayload/invalid-chain-id");

        // Step 1: Deploy the three AdministeredAgents with the payload as temporary admin

        IAdministeredAgentFactory administeredAgentFactory = IAdministeredAgentFactory(Ethereum.SPARK_ADMINISTERED_AGENT_FACTORY);

        _report.plannerAgent = administeredAgentFactory.deploy(address(this), SPARK_PLANNER_ADMINISTERED_AGENT_SALT);
        _report.sparkAgent   = administeredAgentFactory.deploy(address(this), SPARK_ADMINISTERED_AGENT_SALT);
        _report.sllAgent     = administeredAgentFactory.deploy(address(this), SPARK_SLL_ADMINISTERED_AGENT_SALT);

        // Step 2: Deploy SLL PAU

        IPAUFactory pauFactory = IPAUFactory(Ethereum.SPARK_PAU_FACTORY);

        _report.sllPAU_accessControls = pauFactory.deployAccessControls(
            address(this),
            SPARK_SLL_PAU_ACCESS_CONTROLS_SALT
        );
        _report.sllPAU_rateLimits = pauFactory.deployRateLimits(
            address(this),
            SPARK_SLL_PAU_RATE_LIMITS_SALT
        );
        _report.sllPAU_controller = pauFactory.deployController(
            _report.sllPAU_accessControls,
            Ethereum.ALM_PROXY,
            _report.sllPAU_rateLimits,
            SPARK_SLL_PAU_CONTROLLER_SALT
        );

        // Step 3: Deploy spUSDT PAU

        _report.spUSDTPAU_controller     = pauFactory.deployPAU(address(this), SPARK_SPUSDT_PAU_SALT);
        _report.spUSDTPAU_accessControls = IController(_report.spUSDTPAU_controller).accessControls();
        _report.spUSDTPAU_almProxy       = IController(_report.spUSDTPAU_controller).proxy();
        _report.spUSDTPAU_rateLimits     = IController(_report.spUSDTPAU_controller).rateLimits();

        // Step 2: Configure the AdministeredAgents

        _configureAdministeredAgents();

        // Step 4: Configure the SLL and spUSDT PAUs

        _configureSLLPAU();
        _configureSpUSDTPAU();

        // Step 5: Hand admin rights over to the Spark Proxy and revoke the payload's admin role

        _handoffAdministeredAgents();

        _handoff(_report.sllPAU_accessControls, Ethereum.SPARK_PROXY);
        _handoff(_report.sllPAU_rateLimits,     Ethereum.SPARK_PROXY);

        _handoff(_report.spUSDTPAU_accessControls, Ethereum.SPARK_PROXY);
        _handoff(_report.spUSDTPAU_almProxy,       Ethereum.SPARK_PROXY);
        _handoff(_report.spUSDTPAU_rateLimits,     Ethereum.SPARK_PROXY);
    }

    function report() external view returns (Report memory) {
        return _report;
    }

    /**********************************************************************************************/
    /*** Configuration helpers                                                                  ***/
    /**********************************************************************************************/

    function _configureAdministeredAgents() internal {
        IAdministeredAgent plannerAgent = IAdministeredAgent(_report.plannerAgent);
        IAdministeredAgent sparkAgent   = IAdministeredAgent(_report.sparkAgent);
        IAdministeredAgent sllAgent     = IAdministeredAgent(_report.sllAgent);

        plannerAgent.addAdmin(Ethereum.SPARK_PROXY);
        plannerAgent.addActor(SPARK_PLANNER_HOT_WALLET);
        plannerAgent.addRevoker(SPARK_LOW_THRESHOLD_MULTISIG);
        plannerAgent.addGrantor(SPARK_MEDIUM_THRESHOLD_MULTISIG);

        sparkAgent.addAdmin(Ethereum.SPARK_PROXY);
        sparkAgent.addActor(_report.plannerAgent);
        sparkAgent.addRevoker(SPARK_LOW_THRESHOLD_MULTISIG);
        sparkAgent.addRevoker(SOTER_LABS_REVOKER_MULTISIG);
        sparkAgent.addGrantor(SOTER_LABS_GRANTOR_MULTISIG);

        // TODO: Confirm the SLL AdministeredAgent configuration.
        sllAgent.addAdmin(Ethereum.SPARK_PROXY);
        sllAgent.addActor(_report.plannerAgent);
        sllAgent.addRevoker(SPARK_LOW_THRESHOLD_MULTISIG);
        sllAgent.addRevoker(SOTER_LABS_REVOKER_MULTISIG);
        sllAgent.addGrantor(SOTER_LABS_GRANTOR_MULTISIG);
    }

    function _configureSLLPAU() internal {
        IAccessControls accessControls = IAccessControls(_report.sllPAU_accessControls);
        IRateLimits     rateLimits     = IRateLimits(_report.sllPAU_rateLimits);

        // Roles configuration

        rateLimits.grantRole(rateLimits.CONTROLLER(), _report.sllPAU_controller);
        accessControls.grantRole(ALLOCATOR_ROLE,      _report.sllAgent);
    }

    function _configureSpUSDTPAU() internal {
        IAccessControls   accessControls = IAccessControls(_report.spUSDTPAU_accessControls);
        IALMProxy         almProxy       = IALMProxy(_report.spUSDTPAU_almProxy);
        ISPUSDTController controller     = ISPUSDTController(_report.spUSDTPAU_controller);
        IRateLimits       rateLimits     = IRateLimits(_report.spUSDTPAU_rateLimits);

        // Roles configuration

        almProxy.grantRole(almProxy.CONTROLLER(),     _report.spUSDTPAU_controller);
        rateLimits.grantRole(rateLimits.CONTROLLER(), _report.spUSDTPAU_controller);
        accessControls.grantRole(ALLOCATOR_ROLE,      _report.sparkAgent);

        // Onboaring facets

        bytes32[] memory integrationIds = new bytes32[](3);
        integrationIds[0] = "ERC4626_FACET";
        integrationIds[1] = "SPARK_VAULT_FACET";
        integrationIds[2] = "TRANSFER_ASSET_FACET";

        controller.updateIntegrations(integrationIds);

        // ERC4626 rate limits configuration
        rateLimits.setUnlimitedRateLimitData(controller.erc4626_getDepositRateLimitKey(Ethereum.SUSDS, Ethereum.USDS));
        rateLimits.setUnlimitedRateLimitData(controller.erc4626_getWithdrawRateLimitKey(Ethereum.SUSDS));

        // Set max exchange rate
        controller.erc4626_setMaxExchangeRate(Ethereum.SUSDS, 1e18, 1e19);  // TODO: set correct values

        // SparkVault rate limits configuration

        rateLimits.setUnlimitedRateLimitData(controller.sparkVault_getTakeRateLimitKey(Ethereum.SPARK_VAULT_V2_SPUSDT));

        // TransferAsset rate limits configuration

        rateLimits.setUnlimitedRateLimitData(
            controller.transferAsset_getTransferRateLimitKey(Ethereum.USDT, Ethereum.SPARK_VAULT_V2_SPUSDT)
        );

    }

    function _handoffAdministeredAgents() internal {
        IAdministeredAgent plannerAgent     = IAdministeredAgent(_report.plannerAgent);
        IAdministeredAgent sparkAgent       = IAdministeredAgent(_report.sparkAgent);
        IAdministeredAgent sllAgent         = IAdministeredAgent(_report.sllAgent);

        plannerAgent.removeAdmin(address(this));

        require(plannerAgent.adminCount() == 1,                    "planner-agent-admin-count-not-one");
        require(plannerAgent.getAdmin(0)  == Ethereum.SPARK_PROXY, "planner-agent-admin-not-spark-proxy");

        sparkAgent.removeAdmin(address(this));

        require(sparkAgent.adminCount() == 1,                    "spark-agent-admin-count-not-one");
        require(sparkAgent.getAdmin(0)  == Ethereum.SPARK_PROXY, "spark-agent-admin-not-spark-proxy");

        sllAgent.removeAdmin(address(this));

        require(sllAgent.adminCount() == 1,                    "sll-agent-admin-count-not-one");
        require(sllAgent.getAdmin(0)  == Ethereum.SPARK_PROXY, "sll-agent-admin-not-spark-proxy");
    }

    function _handoff(address target_, address admin_) internal {
        IAccessControls target = IAccessControls(target_);

        target.grantRole(DEFAULT_ADMIN_ROLE,  admin_);
        target.revokeRole(DEFAULT_ADMIN_ROLE, address(this));

        require(target.getRoleMemberCount(DEFAULT_ADMIN_ROLE)     == 1,     "default-admin-role-incorrect-count");
        require(target.hasRole(DEFAULT_ADMIN_ROLE, admin_)        == true,  "admin-not-set");
        require(target.hasRole(DEFAULT_ADMIN_ROLE, address(this)) == false, "payload-still-admin");
    }

}
