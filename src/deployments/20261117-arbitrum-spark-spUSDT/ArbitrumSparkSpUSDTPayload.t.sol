// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "../../../lib/forge-std/src/Test.sol";

import { Arbitrum } from "../../../lib/spark-address-registry/src/Arbitrum.sol";
import { Ethereum } from "../../../lib/spark-address-registry/src/Ethereum.sol";

import { IAccessControls }         from "../../../lib/diamond-pau/src/interfaces/IAccessControls.sol";
import { IBeacon }                 from "../../../lib/diamond-pau/src/interfaces/IBeacon.sol";
import { IController }             from "../../../lib/diamond-pau/src/interfaces/IController.sol";
import { IEnumerableIntegrations } from "../../../lib/diamond-pau/src/interfaces/IEnumerableIntegrations.sol";
import { IPAUFactory }             from "../../../lib/diamond-pau/src/interfaces/IPAUFactory.sol";
import { IRateLimits }             from "../../../lib/diamond-pau/src/interfaces/IRateLimits.sol";

import { IFacet } from "../../../lib/diamond-pau/src/facets/IFacet.sol";

import { ILayerZeroController }     from "../../../lib/diamond-pau/src/facets/layer-zero/ILayerZeroController.sol";
import { ILayerZeroFacet }          from "../../../lib/diamond-pau/src/facets/layer-zero/ILayerZeroFacet.sol";
import { ISparkVaultController }    from "../../../lib/diamond-pau/src/facets/spark-vault/ISparkVaultController.sol";
import { ITransferAssetController } from "../../../lib/diamond-pau/src/facets/transfer-asset/ITransferAssetController.sol";

import { ArbitrumSparkSpUSDTPayload } from "./ArbitrumSparkSpUSDTPayload.sol";

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

    function totalSupply() external view returns (uint256);

}

interface IOFTLike {

    function approvalRequired() external view returns (bool);

    function peers(uint32 eid) external view returns (bytes32);

    function token() external view returns (address);

}

interface ISparkVaultLike {

    function TAKER_ROLE() external view returns (bytes32);

    function grantRole(bytes32 role, address account) external;

    function hasRole(bytes32 role, address account) external view returns (bool);

    function totalAssets() external view returns (uint256);

    function totalSupply() external view returns (uint256);

}

abstract contract ArbitrumSparkSpUSDTPayloadTestBase is Test {

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant ALLOCATOR_ROLE     = keccak256("ALLOCATOR_ROLE");
    bytes32 internal constant CONTROLLER_ROLE    = keccak256("CONTROLLER");

    address internal constant PAU_BEACON = Arbitrum.SPARK_BEACON;

    address internal constant SPUSDT   = Arbitrum.SPARK_VAULT_V2_SPUSDT;
    address internal constant USDT0    = Arbitrum.USDT0;
    address internal constant USDT_OFT = Arbitrum.USDT_OFT;

    uint32 internal constant LZ_ARBITRUM_EID = 30110;
    uint32 internal constant LZ_ETHEREUM_EID = 30101;

    bytes32 internal constant PEER = bytes32(uint256(uint160(Ethereum.USDT_OFT)));

    bytes32 internal constant ETHEREUM_SPUSDT_ALM_PROXY = bytes32(uint256(uint160(0x9174264F5E0dFDa8C7a096E11a740b7b613Cf7C4)));

    address internal deploymentPayload;

    address internal plannerAgent;
    address internal sparkAgent;

    address internal spUSDTPAU_accessControls;
    address internal spUSDTPAU_almProxy;
    address internal spUSDTPAU_controller;
    address internal spUSDTPAU_rateLimits;

    address internal user = makeAddr("user");

    function setUp() public virtual {
        vm.createSelectFork(getChain("arbitrum_one").rpcUrl, _getBlock());

        deploymentPayload = address(new ArbitrumSparkSpUSDTPayload());

        ArbitrumSparkSpUSDTPayload.Report memory report = ArbitrumSparkSpUSDTPayload(deploymentPayload).report();

        plannerAgent = report.plannerAgent;
        sparkAgent   = report.sparkAgent;

        spUSDTPAU_accessControls = report.spUSDTPAU_accessControls;
        spUSDTPAU_almProxy       = report.spUSDTPAU_almProxy;
        spUSDTPAU_controller     = report.spUSDTPAU_controller;
        spUSDTPAU_rateLimits     = report.spUSDTPAU_rateLimits;

        vm.label(deploymentPayload,        "deploymentPayload");
        vm.label(plannerAgent,             "plannerAgent");
        vm.label(sparkAgent,               "sparkAgent");
        vm.label(spUSDTPAU_accessControls, "spUSDTPAU.accessControls");
        vm.label(spUSDTPAU_almProxy,       "spUSDTPAU.almProxy");
        vm.label(spUSDTPAU_controller,     "spUSDTPAU.controller");
        vm.label(spUSDTPAU_rateLimits,     "spUSDTPAU.rateLimits");
        vm.label(Arbitrum.SPARK_EXECUTOR,  "sparkExecutor");
        vm.label(PAU_BEACON,               "beacon");
        vm.label(SPUSDT,                   "spUSDT");
        vm.label(USDT0,                    "usdt0");
        vm.label(USDT_OFT,                 "usdtOFT");
    }

    function _getBlock() internal pure returns (uint256) {
        return 527058331; // Nov-24-2026 08:03:30 AM +UTC
    }

    /**********************************************************************************************/
    /*** Helper Functions                                                                       ***/
    /**********************************************************************************************/

    function _deployedContracts() internal view returns (address[6] memory) {
        return [
            plannerAgent,
            sparkAgent,
            spUSDTPAU_accessControls,
            spUSDTPAU_almProxy,
            spUSDTPAU_controller,
            spUSDTPAU_rateLimits
        ];
    }

    function _agents() internal view returns (address[2] memory) {
        return [plannerAgent, sparkAgent];
    }

    // Role based access controlled contracts deployed by the deploymentPayload.
    function _accessControlled() internal view returns (address[3] memory) {
        return [spUSDTPAU_accessControls, spUSDTPAU_almProxy, spUSDTPAU_rateLimits];
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

    function _assertRateLimit(address rateLimits, bytes32 key, uint256 maxAmount, uint256 slope) internal view {
        IRateLimits.RateLimitData memory data = IRateLimits(rateLimits).getRateLimitData(key);

        assertEq(data.maxAmount,   maxAmount);
        assertEq(data.slope,       slope);
        assertEq(data.lastAmount,  maxAmount);
        assertEq(data.lastUpdated, block.timestamp);

        assertEq(IRateLimits(rateLimits).getCurrentRateLimit(key), maxAmount);
    }

    function _assertOnlyMember(address target, bytes32 role, address account) internal view {
        assertEq(IAccessControls(target).getRoleMemberCount(role), 1);
        assertEq(IAccessControls(target).getRoleMember(role, 0),   account);
    }

    function _assertAgent(address agent, address[] memory actors, address[] memory revokers, address grantor)
        internal view
    {
        IAdministeredAgentLike agent_ = IAdministeredAgentLike(agent);

        assertEq(agent_.adminCount(),                        1);
        assertEq(agent_.getIsAdmin(Arbitrum.SPARK_EXECUTOR), true);

        assertEq(agent_.actorCount(), actors.length);

        for (uint256 i; i < actors.length; ++i) {
            assertEq(agent_.getIsActor(actors[i]), true);
        }

        assertEq(agent_.revokerCount(), revokers.length);

        for (uint256 i; i < revokers.length; ++i) {
            assertEq(agent_.getIsRevoker(revokers[i]), true);
        }

        assertEq(agent_.grantorCount(),        1);
        assertEq(agent_.getIsGrantor(grantor), true);
    }

}

contract ArbitrumSparkSpUSDTPayloadTest_Payload is ArbitrumSparkSpUSDTPayloadTestBase {

    function test_deploymentPayload_invalidChainId() external {
        vm.chainId(1);

        vm.expectRevert("ArbitrumSparkSpUSDTPayload/invalid-chain-id");
        new ArbitrumSparkSpUSDTPayload();
    }

    function test_deploymentPayload_deployedAddresses() external view {
        address[6] memory deployed = _deployedContracts();

        for (uint256 i; i < deployed.length; ++i) {
            assertGt(deployed[i].code.length, 0);

            for (uint256 j = i + 1; j < deployed.length; ++j) {
                assertNotEq(deployed[i], deployed[j]);
            }
        }

        IPAUFactory factory = IPAUFactory(Arbitrum.SPARK_PAU_FACTORY);

        assertEq(factory.isAccessControls(spUSDTPAU_accessControls), true);
        assertEq(factory.isALMProxy(spUSDTPAU_almProxy),             true);
        assertEq(factory.isController(spUSDTPAU_controller),         true);
        assertEq(factory.isRateLimits(spUSDTPAU_rateLimits),         true);
    }

    function test_deploymentPayload_holdsNoRoles() external view {
        address[3] memory accessControlled = _accessControlled();

        bytes32[3] memory roles = [DEFAULT_ADMIN_ROLE, ALLOCATOR_ROLE, CONTROLLER_ROLE];

        for (uint256 i; i < accessControlled.length; ++i) {
            for (uint256 j; j < roles.length; ++j) {
                assertEq(IAccessControls(accessControlled[i]).hasRole(roles[j], deploymentPayload), false);
            }
        }

        address[2] memory agents = _agents();

        for (uint256 i; i < agents.length; ++i) {
            IAdministeredAgentLike agent = IAdministeredAgentLike(agents[i]);

            assertEq(agent.getIsAdmin(deploymentPayload),   false);
            assertEq(agent.getIsActor(deploymentPayload),   false);
            assertEq(agent.getIsRevoker(deploymentPayload), false);
            assertEq(agent.getIsGrantor(deploymentPayload), false);
        }
    }

}

contract ArbitrumSparkSpUSDTPayloadTest_AdministeredAgents is ArbitrumSparkSpUSDTPayloadTestBase {

    function test_plannerAgent_roles() external view {
        address[] memory actors = new address[](2);
        actors[0] = Arbitrum.PLANNER_WALLET;
        actors[1] = Arbitrum.ALM_RELAYER_MULTISIG;

        address[] memory revokers = new address[](1);
        revokers[0] = Arbitrum.SPARK_LOW_THRESHOLD_MULTISIG;

        _assertAgent(plannerAgent, actors, revokers, Arbitrum.SPARK_MEDIUM_THRESHOLD_MULTISIG);
    }

    function test_sparkAgent_roles() external view {
        address[] memory actors = new address[](1);
        actors[0] = plannerAgent;

        address[] memory revokers = new address[](2);
        revokers[0] = Arbitrum.SPARK_LOW_THRESHOLD_MULTISIG;
        revokers[1] = Arbitrum.SOTER_REVOKER_MULTISIG;

        _assertAgent(sparkAgent, actors, revokers, Arbitrum.SOTER_GRANTOR_MULTISIG);
    }

    function test_agents_onlySparkExecutorAdministers() external {
        address[2] memory agents = _agents();

        address account = makeAddr("account");

        for (uint256 i; i < agents.length; ++i) {
            IAdministeredAgentLike agent = IAdministeredAgentLike(agents[i]);

            vm.prank(user);
            vm.expectRevert(IAdministeredAgentLike.NotGrantor.selector);
            agent.addActor(account);

            vm.prank(Arbitrum.SPARK_EXECUTOR);
            agent.addActor(account);

            assertEq(agent.getIsActor(account), true);
        }
    }

}

contract ArbitrumSparkSpUSDTPayloadTest_SpUSDTPAU is ArbitrumSparkSpUSDTPayloadTestBase {

    function test_spUSDTPAU_wiring() external view {
        _assertWiring(spUSDTPAU_controller, spUSDTPAU_accessControls, spUSDTPAU_almProxy, spUSDTPAU_rateLimits);
    }

    function test_spUSDTPAU_roles() external view {
        _assertOnlyMember(spUSDTPAU_accessControls, DEFAULT_ADMIN_ROLE, Arbitrum.SPARK_EXECUTOR);
        _assertOnlyMember(spUSDTPAU_accessControls, ALLOCATOR_ROLE,     sparkAgent);

        _assertOnlyMember(spUSDTPAU_almProxy, DEFAULT_ADMIN_ROLE, Arbitrum.SPARK_EXECUTOR);
        _assertOnlyMember(spUSDTPAU_almProxy, CONTROLLER_ROLE,    spUSDTPAU_controller);

        _assertOnlyMember(spUSDTPAU_rateLimits, DEFAULT_ADMIN_ROLE, Arbitrum.SPARK_EXECUTOR);
        _assertOnlyMember(spUSDTPAU_rateLimits, CONTROLLER_ROLE,    spUSDTPAU_controller);

        assertEq(IAccessControls(spUSDTPAU_accessControls).getRoleAdmin(DEFAULT_ADMIN_ROLE), DEFAULT_ADMIN_ROLE);
        assertEq(IAccessControls(spUSDTPAU_almProxy).getRoleAdmin(DEFAULT_ADMIN_ROLE),       DEFAULT_ADMIN_ROLE);
        assertEq(IAccessControls(spUSDTPAU_rateLimits).getRoleAdmin(DEFAULT_ADMIN_ROLE),     DEFAULT_ADMIN_ROLE);
    }

    function test_spUSDTPAU_integrations() external view {
        bytes32[] memory ids = new bytes32[](3);
        ids[0] = "LAYER_ZERO_FACET";
        ids[1] = "SPARK_VAULT_FACET";
        ids[2] = "TRANSFER_ASSET_FACET";

        _assertIntegrations(spUSDTPAU_controller, ids);
    }

    function test_spUSDTPAU_rateLimits() external view {
        _assertRateLimit(
            spUSDTPAU_rateLimits,
            ISparkVaultController(spUSDTPAU_controller).sparkVault_getTakeRateLimitKey(SPUSDT),
            10_000_000e6,
            uint256(200_000_000e6) / 1 days
        );
        _assertRateLimit(
            spUSDTPAU_rateLimits,
            ITransferAssetController(spUSDTPAU_controller).transferAsset_getTransferRateLimitKey(USDT0, SPUSDT),
            10_000_000e6,
            uint256(200_000_000e6) / 1 days
        );
        _assertRateLimit(
            spUSDTPAU_rateLimits,
            ILayerZeroController(spUSDTPAU_controller).layerZero_getTransferRateLimitKey(
                USDT_OFT, PEER, LZ_ETHEREUM_EID, USDT0
            ),
            5_000_000e6,
            uint256(25_000_000e6) / 1 days
        );
    }

    function test_spUSDTPAU_layerZero_rateLimitKeyMatchesOFT() external view {
        IOFTLike oft = IOFTLike(USDT_OFT);

        assertEq(oft.token(),                USDT0);
        assertEq(oft.peers(LZ_ETHEREUM_EID), PEER);
        assertEq(oft.approvalRequired(),     false);

        ILayerZeroController controller = ILayerZeroController(spUSDTPAU_controller);

        assertEq(
            controller.layerZero_getTransferRateLimitKey(USDT_OFT, PEER, LZ_ETHEREUM_EID, USDT0),
            controller.layerZero_getTransferRateLimitKey(
                USDT_OFT, oft.peers(LZ_ETHEREUM_EID), LZ_ETHEREUM_EID, oft.token()
            )
        );
    }

    function test_spUSDTPAU_layerZero_recipient() external view {
        ILayerZeroController controller = ILayerZeroController(spUSDTPAU_controller);

        assertEq(controller.layerZero_getRecipient(LZ_ETHEREUM_EID), ETHEREUM_SPUSDT_ALM_PROXY);
        assertEq(controller.layerZero_getRecipient(LZ_ARBITRUM_EID), bytes32(0));
    }

}

contract ArbitrumSparkSpUSDTPayloadTest_E2E is ArbitrumSparkSpUSDTPayloadTestBase {

    function setUp() public override {
        super.setUp();

        deal(USDT0, spUSDTPAU_almProxy, 1_000_000e6);
    }

    // The planner hot wallet reaches the spUSDT PAU only through plannerAgent -> sparkAgent.
    function test_e2e_planner_cannotBypassAgents() external {
        bytes memory transferCall = abi.encodeCall(
            ITransferAssetController.transferAsset_transfer,
            (USDT0, SPUSDT, 1_000_000e6)
        );

        // Not an allocator of the spUSDT PAU.
        vm.prank(Arbitrum.PLANNER_WALLET);
        vm.expectRevert(
            abi.encodeWithSelector(
                IFacet.AccessControlUnauthorizedAccount.selector, Arbitrum.PLANNER_WALLET, ALLOCATOR_ROLE
            )
        );
        ITransferAssetController(spUSDTPAU_controller).transferAsset_transfer(USDT0, SPUSDT, 1_000_000e6);

        // Not an actor of sparkAgent.
        vm.prank(Arbitrum.PLANNER_WALLET);
        vm.expectRevert(IAdministeredAgentLike.NotActor.selector);
        IAdministeredAgentLike(sparkAgent).call(spUSDTPAU_controller, transferCall);

        // plannerAgent is not an allocator of the spUSDT PAU either.
        vm.prank(Arbitrum.PLANNER_WALLET);
        vm.expectRevert(
            abi.encodeWithSelector(IFacet.AccessControlUnauthorizedAccount.selector, plannerAgent, ALLOCATOR_ROLE)
        );
        IAdministeredAgentLike(plannerAgent).call(spUSDTPAU_controller, transferCall);

        assertEq(IERC20Like(USDT0).balanceOf(spUSDTPAU_almProxy), 1_000_000e6);
    }

    function test_e2e_planner_transfersUSDT0ToSpUSDT() external {
        IERC20Like usdt0 = IERC20Like(USDT0);

        bytes32 transferKey = ITransferAssetController(spUSDTPAU_controller)
            .transferAsset_getTransferRateLimitKey(USDT0, SPUSDT);

        uint256 vaultBalance = usdt0.balanceOf(SPUSDT);

        assertEq(usdt0.balanceOf(spUSDTPAU_almProxy), 1_000_000e6);

        _callThroughPlannerAgent(
            abi.encodeCall(ITransferAssetController.transferAsset_transfer, (USDT0, SPUSDT, 1_000_000e6))
        );

        assertEq(usdt0.balanceOf(spUSDTPAU_almProxy), 0);
        assertEq(usdt0.balanceOf(SPUSDT),             vaultBalance + 1_000_000e6);

        // The rate limit is consumed by the transferred amount.
        assertEq(IRateLimits(spUSDTPAU_rateLimits).getCurrentRateLimit(transferKey), 10_000_000e6 - 1_000_000e6);
    }

    function test_e2e_planner_sparkVaultTake() external {
        ISparkVaultLike spUSDT = ISparkVaultLike(SPUSDT);
        IERC20Like      usdt0  = IERC20Like(USDT0);

        bytes32 takeKey = ISparkVaultController(spUSDTPAU_controller).sparkVault_getTakeRateLimitKey(SPUSDT);

        // The deploymentPayload does not grant the TAKER_ROLE, so the spUSDT admin has to.
        vm.startPrank(Arbitrum.SPARK_EXECUTOR);
        spUSDT.grantRole(spUSDT.TAKER_ROLE(), spUSDTPAU_almProxy);
        vm.stopPrank();

        // Top up spUSDT so the take does not depend on its current idle liquidity.
        uint256 vaultBalance = usdt0.balanceOf(SPUSDT) + 1_000_000e6;
        uint256 almBalance   = usdt0.balanceOf(spUSDTPAU_almProxy);

        deal(USDT0, SPUSDT, vaultBalance);

        uint256 totalAssets = spUSDT.totalAssets();
        uint256 totalSupply = spUSDT.totalSupply();

        _callThroughPlannerAgent(abi.encodeCall(ISparkVaultController.sparkVault_take, (SPUSDT, 1_000_000e6)));

        assertEq(usdt0.balanceOf(SPUSDT),             vaultBalance - 1_000_000e6);
        assertEq(usdt0.balanceOf(spUSDTPAU_almProxy), almBalance   + 1_000_000e6);

        // Taking moves idle liquidity out, it does not change the vault's accounting.
        assertEq(spUSDT.totalAssets(), totalAssets);
        assertEq(spUSDT.totalSupply(), totalSupply);

        // The rate limit is consumed by the taken amount.
        assertEq(IRateLimits(spUSDTPAU_rateLimits).getCurrentRateLimit(takeKey), 10_000_000e6 - 1_000_000e6);
    }

    function test_e2e_planner_layerZeroTransferToEthereum() external {
        IERC20Like usdt0 = IERC20Like(USDT0);

        ILayerZeroController controller = ILayerZeroController(spUSDTPAU_controller);

        bytes32 transferKey = controller.layerZero_getTransferRateLimitKey(USDT_OFT, PEER, LZ_ETHEREUM_EID, USDT0);

        (
            ILayerZeroFacet.SendParam    memory sendParams,
            ILayerZeroFacet.MessagingFee memory fee
        ) = controller.layerZero_quoteTransfer(USDT_OFT, 1_000_000e6, LZ_ETHEREUM_EID);

        assertEq(sendParams.dstEid,      LZ_ETHEREUM_EID);
        assertEq(sendParams.to,          ETHEREUM_SPUSDT_ALM_PROXY);
        assertEq(sendParams.amountLD,    1_000_000e6);
        assertEq(sendParams.minAmountLD, 1_000_000e6);

        assertGt(fee.nativeFee,  0);
        assertEq(fee.lzTokenFee, 0);

        uint256 totalSupply = usdt0.totalSupply();

        // Overpay so the sweep of excess ETH to the ALMProxy is exercised.
        vm.deal(Arbitrum.PLANNER_WALLET, fee.nativeFee + 1 ether);

        assertEq(spUSDTPAU_controller.balance, 0);
        assertEq(spUSDTPAU_almProxy.balance,   0);

        vm.expectEmit(spUSDTPAU_controller);
        emit ILayerZeroFacet.LayerZeroTransfer(USDT_OFT, LZ_ETHEREUM_EID, 1_000_000e6, fee.nativeFee);

        _callThroughPlannerAgent(
            abi.encodeCall(ILayerZeroController.layerZero_transfer, (USDT_OFT, 1_000_000e6, LZ_ETHEREUM_EID)),
            fee.nativeFee + 1 ether
        );

        // USDT0 is burned on Arbitrum, to be minted on Ethereum.
        assertEq(usdt0.balanceOf(spUSDTPAU_almProxy), 0);
        assertEq(usdt0.totalSupply(),                 totalSupply - 1_000_000e6);

        // The OFT does not require approval, so none is left behind.
        assertEq(usdt0.allowance(spUSDTPAU_almProxy, USDT_OFT), 0);

        // Excess ETH is swept from the Controller to the ALMProxy.
        assertEq(spUSDTPAU_controller.balance, 0);
        assertEq(spUSDTPAU_almProxy.balance,   1 ether);

        // The rate limit is consumed by the bridged amount.
        assertEq(IRateLimits(spUSDTPAU_rateLimits).getCurrentRateLimit(transferKey), 5_000_000e6 - 1_000_000e6);
    }

    /**********************************************************************************************/
    /*** Helper Functions                                                                       ***/
    /**********************************************************************************************/

    function _callThroughPlannerAgent(bytes memory controllerCall) internal returns (bytes memory) {
        return _callThroughPlannerAgent(controllerCall, 0);
    }

    // Calls the spUSDT PAU Controller as the planner hot wallet through plannerAgent -> sparkAgent,
    // forwarding `value`, and returns the Controller's return data.
    function _callThroughPlannerAgent(bytes memory controllerCall, uint256 value)
        internal returns (bytes memory)
    {
        bytes memory agentCall = abi.encodeCall(IAdministeredAgentLike.call, (spUSDTPAU_controller, controllerCall));

        vm.prank(Arbitrum.PLANNER_WALLET);
        bytes memory result = IAdministeredAgentLike(plannerAgent).call{ value: value }(sparkAgent, agentCall);

        // The planner agent returns the spark agent's return data, which wraps the Controller's.
        return abi.decode(result, (bytes));
    }

}
