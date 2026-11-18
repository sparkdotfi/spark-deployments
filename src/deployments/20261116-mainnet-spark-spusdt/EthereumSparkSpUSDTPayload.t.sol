// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "../../../lib/forge-std/src/Test.sol";

import { IAccessControl } from "../../../lib/diamond-pau/lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";

import { Ethereum } from "../../../lib/spark-address-registry/src/Ethereum.sol";

import { IAccessControls }         from "../../../lib/diamond-pau/src/interfaces/IAccessControls.sol";
import { IBeacon }                 from "../../../lib/diamond-pau/src/interfaces/IBeacon.sol";
import { IController }             from "../../../lib/diamond-pau/src/interfaces/IController.sol";
import { IEnumerableIntegrations } from "../../../lib/diamond-pau/src/interfaces/IEnumerableIntegrations.sol";
import { IPAUFactory }             from "../../../lib/diamond-pau/src/interfaces/IPAUFactory.sol";
import { IRateLimits }             from "../../../lib/diamond-pau/src/interfaces/IRateLimits.sol";

import { IERC4626Controller }       from "../../../lib/diamond-pau/src/facets/erc4626/IERC4626Controller.sol";
import { ISparkVaultController }    from "../../../lib/diamond-pau/src/facets/spark-vault/ISparkVaultController.sol";
import { ITransferAssetController } from "../../../lib/diamond-pau/src/facets/transfer-asset/ITransferAssetController.sol";

import { EthereumSparkSpUSDTPayload } from "./EthereumSparkSpUSDTPayload.sol";

interface IAdministeredAgentLike {

    error NotActor();

    error NotGrantor();

    function addActor(address account) external;

    function call(address target, bytes memory data) external payable returns (bytes memory result);

    function actorCount() external view returns (uint256);

    function adminCount() external view returns (uint256);

    function grantorCount() external view returns (uint256);

    function revokerCount() external view returns (uint256);

    function getIsActor(address account) external view returns (bool);

    function getIsAdmin(address account) external view returns (bool);

    function getIsGrantor(address account) external view returns (bool);

    function getIsRevoker(address account) external view returns (bool);

}

interface IERC20Like {

    function allowance(address owner, address spender) external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

}

interface ISparkVaultLike {

    function TAKER_ROLE() external view returns (bytes32);

    function grantRole(bytes32 role, address account) external;

    function hasRole(bytes32 role, address account) external view returns (bool);

    function totalAssets() external view returns (uint256);

    function totalSupply() external view returns (uint256);

}

interface ISUSDSLike is IERC20Like {

    function convertToShares(uint256 assets) external view returns (uint256);

    function previewDeposit(uint256 assets) external view returns (uint256);

    function previewRedeem(uint256 shares) external view returns (uint256);

    function previewWithdraw(uint256 assets) external view returns (uint256);

    function totalAssets() external view returns (uint256);

    function totalSupply() external view returns (uint256);

}

abstract contract EthereumSparkSpUSDTPayloadTestBase is Test {

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant ALLOCATOR_ROLE     = keccak256("ALLOCATOR_ROLE");
    bytes32 internal constant CONTROLLER_ROLE    = keccak256("CONTROLLER");

    address internal constant PAU_BEACON = Ethereum.SPARK_BEACON;

    address internal constant SPUSDT = Ethereum.SPARK_VAULT_V2_SPUSDT;

    // TODO: Replace with the final addresses, must match the deploymentPayload.
    address internal constant SPARK_PLANNER_HOT_WALLET        = address(1);
    address internal constant SPARK_LOW_THRESHOLD_MULTISIG    = address(2);
    address internal constant SPARK_MEDIUM_THRESHOLD_MULTISIG = address(3);
    address internal constant SOTER_LABS_REVOKER_MULTISIG     = address(4);
    address internal constant SOTER_LABS_GRANTOR_MULTISIG     = address(5);

    address internal deploymentPayload;

    address internal plannerAgent;
    address internal sparkAgent;
    address internal sllAgent;

    address internal sllPAU_accessControls;
    address internal sllPAU_controller;
    address internal sllPAU_rateLimits;

    address internal spUSDTPAU_accessControls;
    address internal spUSDTPAU_almProxy;
    address internal spUSDTPAU_controller;
    address internal spUSDTPAU_rateLimits;

    address internal user = makeAddr("user");

    function setUp() public virtual {
        vm.createSelectFork(getChain("mainnet").rpcUrl, _getBlock());

        deploymentPayload = address(new EthereumSparkSpUSDTPayload());

        EthereumSparkSpUSDTPayload.Report memory report = EthereumSparkSpUSDTPayload(deploymentPayload).report();

        plannerAgent     = report.plannerAgent;
        sparkAgent       = report.sparkAgent;
        sllAgent         = report.sllAgent;

        sllPAU_accessControls = report.sllPAU_accessControls;
        sllPAU_controller     = report.sllPAU_controller;
        sllPAU_rateLimits     = report.sllPAU_rateLimits;

        spUSDTPAU_accessControls = report.spUSDTPAU_accessControls;
        spUSDTPAU_almProxy       = report.spUSDTPAU_almProxy;
        spUSDTPAU_controller     = report.spUSDTPAU_controller;
        spUSDTPAU_rateLimits     = report.spUSDTPAU_rateLimits;

        vm.label(deploymentPayload,        "deploymentPayload");
        vm.label(plannerAgent,             "plannerAgent");
        vm.label(sparkAgent,               "sparkAgent");
        vm.label(sllAgent,                 "sllAgent");
        vm.label(sllPAU_accessControls,    "sllPAU.accessControls");
        vm.label(sllPAU_controller,        "sllPAU.controller");
        vm.label(sllPAU_rateLimits,        "sllPAU.rateLimits");
        vm.label(spUSDTPAU_accessControls, "spUSDTPAU.accessControls");
        vm.label(spUSDTPAU_almProxy,       "spUSDTPAU.almProxy");
        vm.label(spUSDTPAU_controller,     "spUSDTPAU.controller");
        vm.label(spUSDTPAU_rateLimits,     "spUSDTPAU.rateLimits");
        vm.label(Ethereum.SPARK_PROXY,     "sparkProxy");
        vm.label(Ethereum.ALM_PROXY,       "almProxy");
        vm.label(SPUSDT,                   "spUSDT");
    }

    function _getBlock() internal pure returns (uint256) {
        return 26434139; // Nov-17-2026 10:22:35 AM +UTC
    }

    /**********************************************************************************************/
    /*** Helper Functions                                                                       ***/
    /**********************************************************************************************/

    function _deployedContracts() internal view returns (address[10] memory) {
        return [
            plannerAgent,
            sparkAgent,
            sllAgent,
            sllPAU_accessControls,
            sllPAU_controller,
            sllPAU_rateLimits,
            spUSDTPAU_accessControls,
            spUSDTPAU_almProxy,
            spUSDTPAU_controller,
            spUSDTPAU_rateLimits
        ];
    }

    function _agents() internal view returns (address[3] memory) {
        return [plannerAgent, sparkAgent, sllAgent];
    }

    // Role based access controlled contracts deployed by the deploymentPayload.
    function _accessControlled() internal view returns (address[5] memory) {
        return [
            sllPAU_accessControls,
            sllPAU_rateLimits,
            spUSDTPAU_accessControls,
            spUSDTPAU_almProxy,
            spUSDTPAU_rateLimits
        ];
    }

    /**********************************************************************************************/
    /*** Assertion Helpers                                                                      ***/
    /**********************************************************************************************/

    function _assertWiring(address controller, address accessControls, address almProxy, address rateLimits)
        internal view
    {
        assertEq(IController(controller).accessControls(), accessControls);
        assertEq(IController(controller).proxy(),          almProxy);
        assertEq(IController(controller).rateLimits(),     rateLimits);
        assertEq(IController(controller).beacon(),         PAU_BEACON);
    }

    // Asserts the Controller wires exactly `ids`, in order, with the Beacon's config for each.
    function _assertIntegrations(address controller, bytes32[] memory ids) internal view {
        IEnumerableIntegrations.Integration[] memory actual = IController(controller).integrations();

        assertEq(actual.length, ids.length);

        for (uint256 i; i < ids.length; ++i) {
            assertEq(actual[i].id, ids[i]);

            IEnumerableIntegrations.Config memory expected = IBeacon(PAU_BEACON).getConfig(ids[i]);

            assertNotEq(expected.facet, address(0));

            assertEq(actual[i].config.facet,        expected.facet);
            assertEq(actual[i].config.wires.length, expected.wires.length);

            for (uint256 j; j < expected.wires.length; ++j) {
                assertEq(actual[i].config.wires[j].callSelector,     expected.wires[j].callSelector);
                assertEq(actual[i].config.wires[j].delegateSelector, expected.wires[j].delegateSelector);

                IEnumerableIntegrations.Dispatch memory dispatch =
                    IController(controller).getDispatch(expected.wires[j].callSelector);

                assertEq(dispatch.facet,            expected.facet);
                assertEq(dispatch.delegateSelector, expected.wires[j].delegateSelector);
            }
        }
    }

    function _assertUnlimitedRateLimit(address rateLimits, bytes32 key) internal view {
        IRateLimits.RateLimitData memory data = IRateLimits(rateLimits).getRateLimitData(key);

        assertEq(data.maxAmount,   type(uint256).max);
        assertEq(data.slope,       0);
        assertEq(data.lastAmount,  type(uint256).max);
        assertEq(data.lastUpdated, block.timestamp);

        assertEq(IRateLimits(rateLimits).getCurrentRateLimit(key), type(uint256).max);
    }

    function _assertOnlyMember(address target, bytes32 role, address account) internal view {
        assertEq(IAccessControls(target).getRoleMemberCount(role), 1);
        assertEq(IAccessControls(target).getRoleMember(role, 0),   account);
    }

    function _assertAgent(address agent, address actor, address[] memory revokers, address grantor)
        internal view
    {
        IAdministeredAgentLike agent_ = IAdministeredAgentLike(agent);

        assertEq(agent_.adminCount(),                     1);
        assertEq(agent_.getIsAdmin(Ethereum.SPARK_PROXY), true);

        assertEq(agent_.actorCount(),      1);
        assertEq(agent_.getIsActor(actor), true);

        assertEq(agent_.revokerCount(), revokers.length);

        for (uint256 i; i < revokers.length; ++i) {
            assertEq(agent_.getIsRevoker(revokers[i]), true);
        }

        assertEq(agent_.grantorCount(),        1);
        assertEq(agent_.getIsGrantor(grantor), true);
    }

}

contract EthereumSparkSpUSDTPayloadTest_Payload is EthereumSparkSpUSDTPayloadTestBase {

    function test_deploymentPayload_invalidChainId() external {
        vm.chainId(2);

        vm.expectRevert("EthereumSparkSpUSDTPayload/invalid-chain-id");
        new EthereumSparkSpUSDTPayload();
    }

    function test_deploymentPayload_deployedAddresses() external view {
        address[10] memory deployed = _deployedContracts();

        for (uint256 i; i < deployed.length; ++i) {
            assertGt(deployed[i].code.length, 0);

            for (uint256 j = i + 1; j < deployed.length; ++j) {
                assertNotEq(deployed[i], deployed[j]);
            }
        }

        IPAUFactory factory = IPAUFactory(Ethereum.SPARK_PAU_FACTORY);

        assertEq(factory.isAccessControls(sllPAU_accessControls), true);
        assertEq(factory.isController(sllPAU_controller),         true);
        assertEq(factory.isRateLimits(sllPAU_rateLimits),         true);

        assertEq(factory.isAccessControls(spUSDTPAU_accessControls), true);
        assertEq(factory.isALMProxy(spUSDTPAU_almProxy),             true);
        assertEq(factory.isController(spUSDTPAU_controller),         true);
        assertEq(factory.isRateLimits(spUSDTPAU_rateLimits),         true);
    }

    function test_deploymentPayload_holdsNoRoles() external view {
        address[5] memory accessControlled = _accessControlled();

        bytes32[3] memory roles = [DEFAULT_ADMIN_ROLE, ALLOCATOR_ROLE, CONTROLLER_ROLE];

        for (uint256 i; i < accessControlled.length; ++i) {
            for (uint256 j; j < roles.length; ++j) {
                assertEq(IAccessControls(accessControlled[i]).hasRole(roles[j], deploymentPayload), false);
            }
        }

        address[3] memory agents = _agents();

        for (uint256 i; i < agents.length; ++i) {
            IAdministeredAgentLike agent = IAdministeredAgentLike(agents[i]);

            assertEq(agent.getIsAdmin(deploymentPayload),   false);
            assertEq(agent.getIsActor(deploymentPayload),   false);
            assertEq(agent.getIsRevoker(deploymentPayload), false);
            assertEq(agent.getIsGrantor(deploymentPayload), false);
        }
    }

}

contract EthereumSparkSpUSDTPayloadTest_AdministeredAgents is EthereumSparkSpUSDTPayloadTestBase {

    function test_plannerAgent_roles() external view {
        address[] memory revokers = new address[](1);
        revokers[0] = SPARK_LOW_THRESHOLD_MULTISIG;

        _assertAgent(plannerAgent, SPARK_PLANNER_HOT_WALLET, revokers, SPARK_MEDIUM_THRESHOLD_MULTISIG);
    }

    function test_sparkVaultsAgent_roles() external view {
        address[] memory revokers = new address[](2);
        revokers[0] = SPARK_LOW_THRESHOLD_MULTISIG;
        revokers[1] = SOTER_LABS_REVOKER_MULTISIG;

        _assertAgent(sparkAgent, plannerAgent, revokers, SOTER_LABS_GRANTOR_MULTISIG);
    }

    function test_sllAgent_roles() external view {
        address[] memory revokers = new address[](2);
        revokers[0] = SPARK_LOW_THRESHOLD_MULTISIG;
        revokers[1] = SOTER_LABS_REVOKER_MULTISIG;

        _assertAgent(sllAgent, plannerAgent, revokers, SOTER_LABS_GRANTOR_MULTISIG);
    }

    function test_agents_onlySparkProxyAdministers() external {
        address[3] memory agents = _agents();

        address account = makeAddr("account");

        for (uint256 i; i < agents.length; ++i) {
            IAdministeredAgentLike agent = IAdministeredAgentLike(agents[i]);

            vm.prank(user);
            vm.expectRevert(IAdministeredAgentLike.NotGrantor.selector);
            agent.addActor(account);

            vm.prank(Ethereum.SPARK_PROXY);
            agent.addActor(account);

            assertEq(agent.getIsActor(account), true);
        }
    }

}

contract EthereumSparkSpUSDTPayloadTest_SLLPAU is EthereumSparkSpUSDTPayloadTestBase {

    function test_sllPAU_wiring() external view {
        _assertWiring(sllPAU_controller, sllPAU_accessControls, Ethereum.ALM_PROXY, sllPAU_rateLimits);
    }

    function test_sllPAU_roles() external view {
        _assertOnlyMember(sllPAU_accessControls, DEFAULT_ADMIN_ROLE, Ethereum.SPARK_PROXY);
        _assertOnlyMember(sllPAU_accessControls, ALLOCATOR_ROLE,     sllAgent);

        _assertOnlyMember(sllPAU_rateLimits, DEFAULT_ADMIN_ROLE, Ethereum.SPARK_PROXY);
        _assertOnlyMember(sllPAU_rateLimits, CONTROLLER_ROLE,    sllPAU_controller);

        assertEq(IAccessControls(sllPAU_accessControls).getRoleAdmin(DEFAULT_ADMIN_ROLE), DEFAULT_ADMIN_ROLE);
        assertEq(IAccessControls(sllPAU_rateLimits).getRoleAdmin(DEFAULT_ADMIN_ROLE),     DEFAULT_ADMIN_ROLE);
    }

    function test_sllPAU_integrations() external view {
        _assertIntegrations(sllPAU_controller, new bytes32[](0));
    }

}

contract EthereumSparkSpUSDTPayloadTest_SpUSDTPAU is EthereumSparkSpUSDTPayloadTestBase {

    function test_spUSDTPAU_wiring() external view {
        _assertWiring(spUSDTPAU_controller, spUSDTPAU_accessControls, spUSDTPAU_almProxy, spUSDTPAU_rateLimits);
    }

    function test_spUSDTPAU_roles() external view {
        _assertOnlyMember(spUSDTPAU_accessControls, DEFAULT_ADMIN_ROLE, Ethereum.SPARK_PROXY);
        _assertOnlyMember(spUSDTPAU_accessControls, ALLOCATOR_ROLE,     sparkAgent);

        _assertOnlyMember(spUSDTPAU_almProxy, DEFAULT_ADMIN_ROLE, Ethereum.SPARK_PROXY);
        _assertOnlyMember(spUSDTPAU_almProxy, CONTROLLER_ROLE,    spUSDTPAU_controller);

        _assertOnlyMember(spUSDTPAU_rateLimits, DEFAULT_ADMIN_ROLE, Ethereum.SPARK_PROXY);
        _assertOnlyMember(spUSDTPAU_rateLimits, CONTROLLER_ROLE,    spUSDTPAU_controller);

        assertEq(IAccessControls(spUSDTPAU_accessControls).getRoleAdmin(DEFAULT_ADMIN_ROLE), DEFAULT_ADMIN_ROLE);
        assertEq(IAccessControls(spUSDTPAU_almProxy).getRoleAdmin(DEFAULT_ADMIN_ROLE),       DEFAULT_ADMIN_ROLE);
        assertEq(IAccessControls(spUSDTPAU_rateLimits).getRoleAdmin(DEFAULT_ADMIN_ROLE),     DEFAULT_ADMIN_ROLE);
    }

    function test_spUSDTPAU_integrations() external view {
        bytes32[] memory ids = new bytes32[](3);
        ids[0] = "ERC4626_FACET";
        ids[1] = "SPARK_VAULT_FACET";
        ids[2] = "TRANSFER_ASSET_FACET";

        _assertIntegrations(spUSDTPAU_controller, ids);
    }

    function test_spUSDTPAU_rateLimits() external view {
        _assertUnlimitedRateLimit(
            spUSDTPAU_rateLimits,
            IERC4626Controller(spUSDTPAU_controller).erc4626_getDepositRateLimitKey(Ethereum.SUSDS, Ethereum.USDS)
        );
        _assertUnlimitedRateLimit(
            spUSDTPAU_rateLimits,
            IERC4626Controller(spUSDTPAU_controller).erc4626_getWithdrawRateLimitKey(Ethereum.SUSDS)
        );
        _assertUnlimitedRateLimit(
            spUSDTPAU_rateLimits,
            ISparkVaultController(spUSDTPAU_controller).sparkVault_getTakeRateLimitKey(SPUSDT)
        );
        _assertUnlimitedRateLimit(
            spUSDTPAU_rateLimits,
            ITransferAssetController(spUSDTPAU_controller).transferAsset_getTransferRateLimitKey(Ethereum.USDT, SPUSDT)
        );
    }

}

contract EthereumSparkSpUSDTPayloadTest_E2E is EthereumSparkSpUSDTPayloadTestBase {

    function setUp() public override {
        super.setUp();

        deal(Ethereum.USDT, spUSDTPAU_almProxy, 1_000_000e6);
    }

    // The planner hot wallet reaches the spUSDT PAU only through plannerAgent -> sparkAgent.
    function test_e2e_planner_transfersUSDTToSpUSDT() external {
        bytes memory transferCall = abi.encodeCall(
            ITransferAssetController.transferAsset_transfer,
            (Ethereum.USDT, SPUSDT, 1_000_000e6)
        );
        bytes memory agentCall = abi.encodeCall(
            IAdministeredAgentLike.call,
            (spUSDTPAU_controller, transferCall)
        );

        uint256 vaultBalance = IERC20Like(Ethereum.USDT).balanceOf(SPUSDT);

        assertEq(IERC20Like(Ethereum.USDT).balanceOf(spUSDTPAU_almProxy), 1_000_000e6);

        vm.prank(SPARK_PLANNER_HOT_WALLET);
        IAdministeredAgentLike(plannerAgent).call(sparkAgent, agentCall);

        assertEq(IERC20Like(Ethereum.USDT).balanceOf(spUSDTPAU_almProxy), 0);
        assertEq(IERC20Like(Ethereum.USDT).balanceOf(SPUSDT),             vaultBalance + 1_000_000e6);
    }

    function test_e2e_planner_erc4626DepositWithdrawRedeemCycle() external {
        ISUSDSLike susds = ISUSDSLike(Ethereum.SUSDS);
        IERC20Like usds  = IERC20Like(Ethereum.USDS);

        bytes32 depositKey  = IERC4626Controller(spUSDTPAU_controller).erc4626_getDepositRateLimitKey(Ethereum.SUSDS, Ethereum.USDS);
        bytes32 withdrawKey = IERC4626Controller(spUSDTPAU_controller).erc4626_getWithdrawRateLimitKey(Ethereum.SUSDS);

        // The deploymentPayload does not set a max exchange rate
        vm.startPrank(Ethereum.SPARK_PROXY);
        IERC4626Controller(spUSDTPAU_controller).erc4626_setMaxExchangeRate(
            Ethereum.SUSDS,
            susds.convertToShares(1e18),
            1.2e18
        );
        vm.stopPrank();

        deal(Ethereum.USDS, spUSDTPAU_almProxy, 1_000_000e18);

        uint256 totalAssets = susds.totalAssets();
        uint256 totalSupply = susds.totalSupply();

        assertEq(susds.balanceOf(spUSDTPAU_almProxy), 0);

        // Deposit

        uint256 expectedShares = susds.previewDeposit(1_000_000e18);

        uint256 shares = abi.decode(
            _callThroughPannerAgent(
                abi.encodeCall(IERC4626Controller.erc4626_deposit, (Ethereum.SUSDS, 1_000_000e18, expectedShares))
            ),
            (uint256)
        );

        assertEq(shares, expectedShares);

        assertEq(usds.balanceOf(spUSDTPAU_almProxy),  0);
        assertEq(susds.balanceOf(spUSDTPAU_almProxy), shares);

        assertEq(usds.allowance(spUSDTPAU_almProxy, Ethereum.SUSDS), 0);

        assertEq(susds.totalSupply(), totalSupply + shares);
        assertEq(susds.totalAssets(), totalAssets + 1_000_000e18 - 1);

        // Withdraw

        uint256 expectedSharesBurned = susds.previewWithdraw(400_000e18);

        uint256 sharesBurned = abi.decode(
            _callThroughPannerAgent(
                abi.encodeCall(IERC4626Controller.erc4626_withdraw, (Ethereum.SUSDS, 400_000e18, expectedSharesBurned))
            ),
            (uint256)
        );

        assertEq(sharesBurned, expectedSharesBurned);

        assertEq(usds.balanceOf(spUSDTPAU_almProxy),  400_000e18);
        assertEq(susds.balanceOf(spUSDTPAU_almProxy), shares - sharesBurned);

        // Redeem the remaining shares

        uint256 remainingShares = susds.balanceOf(spUSDTPAU_almProxy);
        uint256 expectedAssets  = susds.previewRedeem(remainingShares);

        uint256 assets = abi.decode(
            _callThroughPannerAgent(
                abi.encodeCall(IERC4626Controller.erc4626_redeem, (Ethereum.SUSDS, remainingShares, expectedAssets))
            ),
            (uint256)
        );

        assertEq(assets, expectedAssets);

        assertEq(usds.balanceOf(spUSDTPAU_almProxy),  400_000e18 + assets);
        assertEq(susds.balanceOf(spUSDTPAU_almProxy), 0);

        assertEq(susds.totalSupply(), totalSupply);

        // Same block, so no yield accrues and only rounding is lost.
        assertEq(usds.balanceOf(spUSDTPAU_almProxy), 1_000_000e18 - 2);

        // Unlimited rate limits are not consumed.
        assertEq(IRateLimits(spUSDTPAU_rateLimits).getCurrentRateLimit(depositKey),  type(uint256).max);
        assertEq(IRateLimits(spUSDTPAU_rateLimits).getCurrentRateLimit(withdrawKey), type(uint256).max);
    }

    function test_e2e_planner_sparkVaultTake() external {
        ISparkVaultLike spUSDT = ISparkVaultLike(SPUSDT);
        IERC20Like      usdt   = IERC20Like(Ethereum.USDT);

        bytes32 takeKey = ISparkVaultController(spUSDTPAU_controller).sparkVault_getTakeRateLimitKey(SPUSDT);

        // The deploymentPayload does not grant the TAKER_ROLE, so the spUSDT admin has to.
        vm.startPrank(Ethereum.SPARK_PROXY);
        spUSDT.grantRole(spUSDT.TAKER_ROLE(), spUSDTPAU_almProxy);
        vm.stopPrank();

        // Top up spUSDT so the take does not depend on its current idle liquidity.
        uint256 vaultBalance = usdt.balanceOf(SPUSDT) + 1_000_000e6;
        uint256 almBalance   = usdt.balanceOf(spUSDTPAU_almProxy);

        deal(Ethereum.USDT, SPUSDT, vaultBalance);

        uint256 totalAssets = spUSDT.totalAssets();
        uint256 totalSupply = spUSDT.totalSupply();

        _callThroughPannerAgent(abi.encodeCall(ISparkVaultController.sparkVault_take, (SPUSDT, 1_000_000e6)));

        assertEq(usdt.balanceOf(SPUSDT),            vaultBalance - 1_000_000e6);
        assertEq(usdt.balanceOf(spUSDTPAU_almProxy), almBalance   + 1_000_000e6);

        // Taking moves idle liquidity out, it does not change the vault's accounting.
        assertEq(spUSDT.totalAssets(), totalAssets);
        assertEq(spUSDT.totalSupply(), totalSupply);

        // Unlimited rate limits are not consumed.
        assertEq(IRateLimits(spUSDTPAU_rateLimits).getCurrentRateLimit(takeKey), type(uint256).max);
    }

    /**********************************************************************************************/
    /*** Helper Functions                                                                       ***/
    /**********************************************************************************************/

    // Calls the spUSDT PAU Controller as the planner hot wallet through plannerAgent -> sparkAgent,
    // and returns the Controller's return data.
    function _callThroughPannerAgent(bytes memory controllerCall) internal returns (bytes memory) {
        bytes memory agentCall = abi.encodeCall(IAdministeredAgentLike.call, (spUSDTPAU_controller, controllerCall));

        vm.prank(SPARK_PLANNER_HOT_WALLET);
        bytes memory result = IAdministeredAgentLike(plannerAgent).call(sparkAgent, agentCall);

        // The planner agent returns the sparkVaults agent's return data, which wraps the Controller's.
        return abi.decode(result, (bytes));
    }

}
