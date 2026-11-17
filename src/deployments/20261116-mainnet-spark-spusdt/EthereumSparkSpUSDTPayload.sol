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
    bytes32 internal constant SPARK_VAULTS_ADMINISTERED_AGENT_SALT  = "SPARK_VAULTS_ADMINISTERED_AGENT";
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
        address sparkVaultsAgent;
        address sllAgent;
        address sllPAUAccessControls;
        address sllPAUController;
        address sllPAURateLimits;
        address spUSDTPAUAccessControls;
        address spUSDTPAUALMProxy;
        address spUSDTPAUController;
        address spUSDTPAURateLimits;
    }

    Report internal _report;

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

        // Step 2: Deploy SLL PAU

        IPAUFactory pauFactory = IPAUFactory(Ethereum.SPARK_PAU_FACTORY);

        _report.sllPAUAccessControls = pauFactory.deployAccessControls(
            address(this),
            SPARK_SLL_PAU_ACCESS_CONTROLS_SALT
        );
        _report.sllPAURateLimits = pauFactory.deployRateLimits(
            address(this),
            SPARK_SLL_PAU_RATE_LIMITS_SALT
        );
        _report.sllPAUController = pauFactory.deployController(
            _report.sllPAUAccessControls,
            Ethereum.ALM_PROXY,
            _report.sllPAURateLimits,
            SPARK_SLL_PAU_CONTROLLER_SALT
        );

        // Step 3: Deploy spUSDT PAU

        _report.spUSDTPAUController     = pauFactory.deployPAU(address(this), SPARK_SPUSDT_PAU_SALT);
        _report.spUSDTPAUAccessControls = IController(_report.spUSDTPAUController).accessControls();
        _report.spUSDTPAUALMProxy       = IController(_report.spUSDTPAUController).proxy();
        _report.spUSDTPAURateLimits     = IController(_report.spUSDTPAUController).rateLimits();

        // Step 2: Configure the AdministeredAgents

        _configureAdministeredAgents();

        // Step 4: Configure the SLL and spUSDT PAUs

        _configureSLLPAU();
        _configureSpUSDTPAU();

        // Step 5: Hand admin rights over to the Spark Proxy and revoke the payload's admin role

        _handoffAdministeredAgents();

        _handoff(_report.sllPAUAccessControls, Ethereum.SPARK_PROXY);
        _handoff(_report.sllPAURateLimits,     Ethereum.SPARK_PROXY);

        _handoff(_report.spUSDTPAUAccessControls, Ethereum.SPARK_PROXY);
        _handoff(_report.spUSDTPAUALMProxy,       Ethereum.SPARK_PROXY);
        _handoff(_report.spUSDTPAURateLimits,     Ethereum.SPARK_PROXY);
    }

    function report() public view returns (Report memory) {
        return _report;
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

    function _configureSLLPAU() internal {
        IAccessControls accessControls = IAccessControls(_report.sllPAUAccessControls);
        IRateLimits     rateLimits     = IRateLimits(_report.sllPAURateLimits);

        // Roles configuration

        rateLimits.grantRole(rateLimits.CONTROLLER(), _report.sllPAUController);
        accessControls.grantRole(ALLOCATOR_ROLE,      _report.sllAgent);
    }

    function _configureSpUSDTPAU() internal {
        IAccessControls accessControls = IAccessControls(_report.spUSDTPAUAccessControls);
        IALMProxy       almProxy       = IALMProxy(_report.spUSDTPAUALMProxy);
        IController     controller     = IController(_report.spUSDTPAUController);
        IRateLimits     rateLimits     = IRateLimits(_report.spUSDTPAURateLimits);

        // Roles configuration

        almProxy.grantRole(almProxy.CONTROLLER(),     _report.spUSDTPAUController);
        rateLimits.grantRole(rateLimits.CONTROLLER(), _report.spUSDTPAUController);
        accessControls.grantRole(ALLOCATOR_ROLE,      _report.sparkVaultsAgent);

        // Onboaring facets

        bytes32[] memory integrationIds = new bytes32[](3);
        integrationIds[0] = "ERC4626_FACET";
        integrationIds[1] = "SPARK_VAULT_FACET";
        integrationIds[2] = "TRANSFER_ASSET_FACET";

        controller.updateIntegrations(integrationIds);

        // ERC4626 rate limits configuration
        rateLimits.setUnlimitedRateLimitData(
            IERC4626Controller(_report.spUSDTPAUController)
                .erc4626_getDepositRateLimitKey(Ethereum.SUSDS, Ethereum.USDS)
        );
        rateLimits.setUnlimitedRateLimitData(
            IERC4626Controller(_report.spUSDTPAUController)
                .erc4626_getWithdrawRateLimitKey(Ethereum.SUSDS)
        );

        // SparkVault rate limits configuration

        rateLimits.setUnlimitedRateLimitData(
            ISparkVaultController(_report.spUSDTPAUController)
                .sparkVault_getTakeRateLimitKey(Ethereum.SPARK_VAULT_V2_SPUSDT)
        );

        // TransferAsset rate limits configuration

        rateLimits.setUnlimitedRateLimitData(
            ITransferAssetController(_report.spUSDTPAUController)
                .transferAsset_getTransferRateLimitKey(Ethereum.USDT, Ethereum.SPARK_VAULT_V2_SPUSDT)
        );

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
