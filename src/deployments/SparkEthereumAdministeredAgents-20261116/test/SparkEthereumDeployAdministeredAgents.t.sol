// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "../../../../lib/forge-std/src/Test.sol";

import { Ethereum } from "../../../../lib/spark-address-registry/src/Ethereum.sol";

import { SparkEthereumDeployAdministeredAgents } from "../SparkEthereumDeployAdministeredAgents.sol";

interface IAdministeredAgentLike {

    function actorCount() external view returns (uint256);

    function addActor(address account) external;

    function adminCount() external view returns (uint256);

    function call(address target, bytes memory data) external payable returns (bytes memory result);

    function getActor(uint256 index) external view returns (address);

    function getAdmin(uint256 index) external view returns (address);

    function getGrantor(uint256 index) external view returns (address);

    function getIsActor(address account) external view returns (bool);

    function getIsAdmin(address account) external view returns (bool);

    function getIsGrantor(address account) external view returns (bool);

    function getIsRevoker(address account) external view returns (bool);

    function getRevoker(uint256 index) external view returns (address);

    function grantorCount() external view returns (uint256);

    function removeActor(address account) external;

    function revokerCount() external view returns (uint256);

}

interface IAdministeredAgentFactoryLike {

    function isInstance(address account) external view returns (bool);

}

contract CallTarget {

    address public lastCaller;

    function ping() external returns (bool) {
        lastCaller = msg.sender;
        return true;
    }

}

abstract contract SparkEthereumDeployAdministeredAgentsTestBase is Test {

    // TODO: Replace with the final addresses, must match the payload.
    address internal constant SPARK_PLANNER_HOT_WALLET        = address(1);
    address internal constant SPARK_LOW_THRESHOLD_MULTISIG    = address(2);
    address internal constant SPARK_MEDIUM_THRESHOLD_MULTISIG = address(3);
    address internal constant SOTER_LABS_REVOKER_MULTISIG     = address(4);
    address internal constant SOTER_LABS_GRANTOR_MULTISIG     = address(5);

    SparkEthereumDeployAdministeredAgents.Report internal report;

    address internal payload;

    IAdministeredAgentLike internal plannerAgent;
    IAdministeredAgentLike internal sparkVaultsAgent;
    IAdministeredAgentLike internal sllAgent;

    function setUp() public virtual {
        vm.createSelectFork(getChain("mainnet").rpcUrl);

        SparkEthereumDeployAdministeredAgents deployment = new SparkEthereumDeployAdministeredAgents();

        payload = address(deployment);
        report  = deployment.report();

        plannerAgent     = IAdministeredAgentLike(report.plannerAgent);
        sparkVaultsAgent = IAdministeredAgentLike(report.sparkVaultsAgent);
        sllAgent         = IAdministeredAgentLike(report.sllAgent);

        vm.label(payload,                   "payload");
        vm.label(address(plannerAgent),     "plannerAgent");
        vm.label(address(sparkVaultsAgent), "sparkVaultsAgent");
        vm.label(address(sllAgent),         "sllAgent");
    }

    /**********************************************************************************************/
    /*** Helper Functions                                                                       ***/
    /**********************************************************************************************/

    function _deployedAgents() internal view returns (IAdministeredAgentLike[3] memory) {
        return [plannerAgent, sparkVaultsAgent, sllAgent];
    }

    /**********************************************************************************************/
    /*** Assertion Helpers                                                                      ***/
    /**********************************************************************************************/

    function _assertOnlyAdmin(IAdministeredAgentLike agent, address admin) internal view {
        assertEq(agent.adminCount(),      1);
        assertEq(agent.getAdmin(0),       admin);
        assertEq(agent.getIsAdmin(admin), true);
    }

    function _assertOnlyActor(IAdministeredAgentLike agent, address actor) internal view {
        assertEq(agent.actorCount(),      1);
        assertEq(agent.getActor(0),       actor);
        assertEq(agent.getIsActor(actor), true);
    }

    function _assertOnlyGrantor(IAdministeredAgentLike agent, address grantor) internal view {
        assertEq(agent.grantorCount(),        1);
        assertEq(agent.getGrantor(0),         grantor);
        assertEq(agent.getIsGrantor(grantor), true);
    }

    function _assertRevokers(IAdministeredAgentLike agent, address[] memory revokers) internal view {
        assertEq(agent.revokerCount(), revokers.length);

        for (uint256 i; i < revokers.length; ++i) {
            assertEq(agent.getRevoker(i),             revokers[i]);
            assertEq(agent.getIsRevoker(revokers[i]), true);
        }
    }

}

contract SparkEthereumDeployAdministeredAgentsTest_Payload is SparkEthereumDeployAdministeredAgentsTestBase {

    function test_payload_invalidChainId() external {
        vm.chainId(2);

        vm.expectRevert("SparkEthereumDeployAdministeredAgents/invalid-chain-id");
        new SparkEthereumDeployAdministeredAgents();
    }

    function test_payload_deployedAddresses() external view {
        IAdministeredAgentLike[3] memory agents = _deployedAgents();

        IAdministeredAgentFactoryLike factory = IAdministeredAgentFactoryLike(Ethereum.SPARK_ADMINISTERED_AGENT_FACTORY);

        for (uint256 i; i < agents.length; ++i) {
            assertGt(address(agents[i]).code.length, 0);

            assertEq(factory.isInstance(address(agents[i])), true);

            for (uint256 j = i + 1; j < agents.length; ++j) {
                assertNotEq(address(agents[i]), address(agents[j]));
            }
        }
    }

    function test_payload_holdsNoRoles() external view {
        IAdministeredAgentLike[3] memory agents = _deployedAgents();

        for (uint256 i; i < agents.length; ++i) {
            assertEq(agents[i].getIsAdmin(payload),   false);
            assertEq(agents[i].getIsActor(payload),   false);
            assertEq(agents[i].getIsGrantor(payload), false);
            assertEq(agents[i].getIsRevoker(payload), false);
        }
    }

}

contract SparkEthereumDeployAdministeredAgentsTest_PlannerAgent is SparkEthereumDeployAdministeredAgentsTestBase {

    function test_plannerAgent_roles() external view {
        _assertOnlyAdmin(plannerAgent,   Ethereum.SPARK_PROXY);
        _assertOnlyActor(plannerAgent,   SPARK_PLANNER_HOT_WALLET);
        _assertOnlyGrantor(plannerAgent, SPARK_MEDIUM_THRESHOLD_MULTISIG);

        address[] memory revokers = new address[](1);
        revokers[0] = SPARK_LOW_THRESHOLD_MULTISIG;

        _assertRevokers(plannerAgent, revokers);
    }

}

contract SparkEthereumDeployAdministeredAgentsTest_SparkVaultsAgent is SparkEthereumDeployAdministeredAgentsTestBase {

    function test_sparkVaultsAgent_roles() external view {
        _assertOnlyAdmin(sparkVaultsAgent,   Ethereum.SPARK_PROXY);
        _assertOnlyActor(sparkVaultsAgent,   address(plannerAgent));
        _assertOnlyGrantor(sparkVaultsAgent, SOTER_LABS_GRANTOR_MULTISIG);

        address[] memory revokers = new address[](2);
        revokers[0] = SPARK_LOW_THRESHOLD_MULTISIG;
        revokers[1] = SOTER_LABS_REVOKER_MULTISIG;

        _assertRevokers(sparkVaultsAgent, revokers);
    }

}

contract SparkEthereumDeployAdministeredAgentsTest_SLLAgent is SparkEthereumDeployAdministeredAgentsTestBase {

    function test_sllAgent_roles() external view {
        _assertOnlyAdmin(sllAgent,   Ethereum.SPARK_PROXY);
        _assertOnlyActor(sllAgent,   address(plannerAgent));
        _assertOnlyGrantor(sllAgent, SOTER_LABS_GRANTOR_MULTISIG);

        address[] memory revokers = new address[](2);
        revokers[0] = SPARK_LOW_THRESHOLD_MULTISIG;
        revokers[1] = SOTER_LABS_REVOKER_MULTISIG;

        _assertRevokers(sllAgent, revokers);
    }

}

contract SparkEthereumDeployAdministeredAgentsTest_E2E is SparkEthereumDeployAdministeredAgentsTestBase {

    CallTarget internal target;

    function setUp() public override {
        super.setUp();

        target = new CallTarget();
    }

    function test_e2e_hotWalletCallsThroughSparkVaultsAgent() external {
        _callThroughPlanner(sparkVaultsAgent);

        assertEq(target.lastCaller(), address(sparkVaultsAgent));
    }

    function test_e2e_hotWalletCallsThroughSLLAgent() external {
        _callThroughPlanner(sllAgent);

        assertEq(target.lastCaller(), address(sllAgent));
    }

    function test_e2e_revokeAndGrantPlannerOnSparkVaultsAgent() external {
        _assertRevokeAndGrant(sparkVaultsAgent, SOTER_LABS_REVOKER_MULTISIG,  SOTER_LABS_GRANTOR_MULTISIG);
        _assertRevokeAndGrant(sparkVaultsAgent, SPARK_LOW_THRESHOLD_MULTISIG, SOTER_LABS_GRANTOR_MULTISIG);
    }

    function test_e2e_revokeAndGrantPlannerOnSLLAgent() external {
        _assertRevokeAndGrant(sllAgent, SOTER_LABS_REVOKER_MULTISIG,  SOTER_LABS_GRANTOR_MULTISIG);
        _assertRevokeAndGrant(sllAgent, SPARK_LOW_THRESHOLD_MULTISIG, SOTER_LABS_GRANTOR_MULTISIG);
    }

    function test_e2e_revokeAndGrantHotWalletOnPlannerAgent() external {
        vm.prank(SPARK_LOW_THRESHOLD_MULTISIG);
        plannerAgent.removeActor(SPARK_PLANNER_HOT_WALLET);

        assertEq(plannerAgent.getIsActor(SPARK_PLANNER_HOT_WALLET), false);

        vm.prank(SPARK_PLANNER_HOT_WALLET);
        vm.expectRevert(abi.encodeWithSignature("NotActor()"));
        plannerAgent.call(address(target), abi.encodeCall(CallTarget.ping, ()));

        vm.prank(SPARK_MEDIUM_THRESHOLD_MULTISIG);
        plannerAgent.addActor(SPARK_PLANNER_HOT_WALLET);

        assertEq(plannerAgent.getIsActor(SPARK_PLANNER_HOT_WALLET), true);
    }

    function test_e2e_sparkProxyCanManageActors() external {
        IAdministeredAgentLike[3] memory agents = _deployedAgents();

        address newActor = makeAddr("newActor");

        for (uint256 i; i < agents.length; ++i) {
            vm.prank(Ethereum.SPARK_PROXY);
            agents[i].addActor(newActor);

            assertEq(agents[i].getIsActor(newActor), true);

            vm.prank(Ethereum.SPARK_PROXY);
            agents[i].removeActor(newActor);

            assertEq(agents[i].getIsActor(newActor), false);
        }
    }

    function _callThroughPlanner(IAdministeredAgentLike agent) internal {
        bytes memory innerCall = abi.encodeCall(
            IAdministeredAgentLike.call,
            (address(target), abi.encodeCall(CallTarget.ping, ()))
        );

        vm.prank(SPARK_PLANNER_HOT_WALLET);
        plannerAgent.call(address(agent), innerCall);
    }

    function _assertRevokeAndGrant(IAdministeredAgentLike agent, address revoker, address grantor) internal {
        vm.prank(revoker);
        agent.removeActor(address(plannerAgent));

        assertEq(agent.getIsActor(address(plannerAgent)), false);

        vm.prank(SPARK_PLANNER_HOT_WALLET);
        vm.expectRevert(abi.encodeWithSignature("NotActor()"));
        plannerAgent.call(
            address(agent),
            abi.encodeCall(IAdministeredAgentLike.call, (address(target), abi.encodeCall(CallTarget.ping, ())))
        );

        vm.prank(grantor);
        agent.addActor(address(plannerAgent));

        assertEq(agent.getIsActor(address(plannerAgent)), true);
    }

}
