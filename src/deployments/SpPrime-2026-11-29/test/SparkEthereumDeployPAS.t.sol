// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test, Vm } from "../../../../lib/forge-std/src/Test.sol";

import { Ethereum } from "../../../../lib/spark-address-registry/src/Ethereum.sol";

import { IAccessControl } from "../../../../lib/pas/lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";
import { Pausable }       from "../../../../lib/pas/lib/openzeppelin-contracts/contracts/utils/Pausable.sol";

import { TimelockController } from "../../../../lib/pas/lib/openzeppelin-contracts/contracts/governance/TimelockController.sol";

import { BeamState }    from "../../../../lib/pas/src/BeamState.sol";
import { Configurator } from "../../../../lib/pas/src/Configurator.sol";
import { PASMom }       from "../../../../lib/pas/src/PASMom.sol";
import { Timelock }     from "../../../../lib/pas/src/timelock/Timelock.sol";

import { SparkEthereumDeployPAS } from "../SparkEthereumDeployPAS.sol";

import { SparkDeployOrchestration } from "../SparkDeployOrchestration.sol";

interface IChiefLike {

    function hat() external view returns (address);

}

abstract contract SparkEthereumDeployPASTestBase is Test {

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    // BeamState roles set by PASInit.
    uint8 internal constant PAS_ROLE_DELAYED   = 1;
    uint8 internal constant PAS_ROLE_IMMEDIATE = 2;

    address internal constant PAS_OWNER = Ethereum.SPARK_PROXY;  // BeamState ward and Timelock admin

    address internal constant PAS_MOM_OWNER     = Ethereum.PAUSE_PROXY;  // PASMom owner
    address internal constant PAS_MOM_AUTHORITY = Ethereum.CHIEF;        // PASMom authority, its hat can stop and pause

    // TODO: Replace with the final addresses, must match the spell.
    address internal constant PAS_CORE_COUNCIL = address(1);  // aBEAM Multisig
    address internal constant PAS_CANCELLER1   = address(2);  // Spark Low Threshold Multisig
    address internal constant PAS_CANCELLER2   = address(3);  // Soter Labs Revoker Multisig

    uint256 internal constant PAS_MIN_DELAY = 5 days;

    SparkDeployOrchestration.Report internal report;

    address internal spell;

    address internal pasBeamState;
    address internal pasConfigurator;
    address internal pasTimelock;
    address internal pasMom;

    address internal user = makeAddr("user");

    Vm.Log[] internal deployLogs;

    function setUp() public virtual {
        vm.createSelectFork(getChain("mainnet").rpcUrl);

        vm.recordLogs();

        report = SparkDeployOrchestration.deploy();

        spell = report.deployPASPayload;

        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i; i < logs.length; ++i) {
            deployLogs.push(logs[i]);
        }

        pasBeamState    = report.pasDeploymentReport.beamState;
        pasConfigurator = report.pasDeploymentReport.configurator;
        pasTimelock     = report.pasDeploymentReport.timelock;
        pasMom          = report.pasDeploymentReport.mom;

        vm.label(spell,           "spell");
        vm.label(pasBeamState,    "pas.beamState");
        vm.label(pasConfigurator, "pas.configurator");
        vm.label(pasTimelock,     "pas.timelock");
        vm.label(pasMom,          "pas.mom");
        vm.label(PAS_OWNER,       "pas.owner");

        vm.label(PAS_MOM_OWNER,     "pas.mom.owner");
        vm.label(PAS_MOM_AUTHORITY, "pas.mom.authority");
    }

    /**********************************************************************************************/
    /*** Helper Functions                                                                       ***/
    /**********************************************************************************************/

    // Returns the logs emitted by `target` during deployment with the given `topic0`, in emission order.
    // A zero `topic0` returns all the logs emitted by `target`.
    function _getEvents(address target, bytes32 topic0) internal view returns (Vm.Log[] memory logs) {
        uint256 count;

        for (uint256 i; i < deployLogs.length; ++i) {
            if (_isEvent(deployLogs[i], target, topic0)) count++;
        }

        logs = new Vm.Log[](count);

        uint256 j;

        for (uint256 i; i < deployLogs.length; ++i) {
            if (_isEvent(deployLogs[i], target, topic0)) logs[j++] = deployLogs[i];
        }
    }

    function _isEvent(Vm.Log memory log, address target, bytes32 topic0) internal pure returns (bool) {
        return log.emitter == target && (topic0 == bytes32(0) || log.topics[0] == topic0);
    }

}

contract SparkEthereumDeployPASTest_SpellPayload is SparkEthereumDeployPASTestBase {

    function test_spell_invalidChainId() external {
        vm.chainId(2);

        vm.expectRevert("SparkEthereumDeployPAS/invalid-chain-id");
        new SparkEthereumDeployPAS();
    }

    function test_spell_deployedAddresses() external view {
        address[4] memory deployed = [pasBeamState, pasConfigurator, pasTimelock, pasMom];

        for (uint256 i; i < deployed.length; ++i) {
            assertGt(deployed[i].code.length, 0);

            for (uint256 j = i + 1; j < deployed.length; ++j) {
                assertNotEq(deployed[i], deployed[j]);
            }
        }
    }

    function test_spell_holdsNoRoles() external view {
        Timelock timelock = Timelock(payable(pasTimelock));

        assertEq(timelock.hasRole(DEFAULT_ADMIN_ROLE,        spell), false);
        assertEq(timelock.hasRole(timelock.PROPOSER_ROLE(),  spell), false);
        assertEq(timelock.hasRole(timelock.CANCELLER_ROLE(), spell), false);
        assertEq(timelock.hasRole(timelock.EXECUTOR_ROLE(),  spell), false);
        assertEq(timelock.hasRole(timelock.PAUSER_ROLE(),    spell), false);

        assertEq(BeamState(pasBeamState).wards(spell),     0);
        assertEq(BeamState(pasBeamState).userRoles(spell), bytes32(0));

        assertTrue(PASMom(pasMom).owner() != spell);
    }

}

contract SparkEthereumDeployPASTest_PAS is SparkEthereumDeployPASTestBase {

    function test_pasConfigurator_state() external view {
        assertEq(address(Configurator(pasConfigurator).beamState()), pasBeamState);
    }

    function test_beamState_stopped() external view {
        assertEq(BeamState(pasBeamState).stopped(), false);

        Vm.Log[] memory startLogs = _getEvents(pasBeamState, BeamState.Start.selector);
        Vm.Log[] memory stopLogs  = _getEvents(pasBeamState, BeamState.Stop.selector);

        assertEq(startLogs.length, 0);
        assertEq(stopLogs.length,  0);
    }

    function test_beamState_wards() external view {
        BeamState beamState = BeamState(pasBeamState);

        // BeamState wards: PAS owner and PAS Mom (to call stop())

        assertEq(beamState.wards(PAS_OWNER),        1);
        assertEq(beamState.wards(pasMom),           1);
        assertEq(beamState.wards(PAS_CORE_COUNCIL), 0);
        assertEq(beamState.wards(address(spell)),   0);

        Vm.Log[] memory relyLogs = _getEvents(pasBeamState, BeamState.Rely.selector);
        Vm.Log[] memory denyLogs = _getEvents(pasBeamState, BeamState.Deny.selector);

        assertEq(relyLogs.length, 3);
        assertEq(denyLogs.length, 1);

        assertEq(relyLogs[0].topics[0],                            BeamState.Rely.selector);
        assertEq(address(uint160(uint256(relyLogs[0].topics[1]))), address(spell));

        assertEq(relyLogs[1].topics[0],                            BeamState.Rely.selector);
        assertEq(address(uint160(uint256(relyLogs[1].topics[1]))), pasMom);

        assertEq(relyLogs[2].topics[0],                            BeamState.Rely.selector);
        assertEq(address(uint160(uint256(relyLogs[2].topics[1]))), PAS_OWNER);

        assertEq(denyLogs[0].topics[0],                            BeamState.Deny.selector);
        assertEq(address(uint160(uint256(denyLogs[0].topics[1]))), address(spell));
    }

    function test_beamState_userRoles() external view {
        BeamState beamState = BeamState(pasBeamState);

        // BeamState user roles: Timelock has delayed role, Core Council has immediate role.

        assertEq(beamState.hasUserRole(pasTimelock,      PAS_ROLE_DELAYED),   true);
        assertEq(beamState.hasUserRole(PAS_CORE_COUNCIL, PAS_ROLE_DELAYED),   false);

        assertEq(beamState.hasUserRole(pasTimelock,      PAS_ROLE_IMMEDIATE), false);
        assertEq(beamState.hasUserRole(PAS_CORE_COUNCIL, PAS_ROLE_IMMEDIATE), true);

        Vm.Log[] memory userRoleLogs = _getEvents(pasBeamState, BeamState.SetUserRole.selector);

        assertEq(userRoleLogs.length, 2);

        assertEq(userRoleLogs[0].topics[0],                            BeamState.SetUserRole.selector);
        assertEq(address(uint160(uint256(userRoleLogs[0].topics[1]))), pasTimelock);
        assertEq(uint8(uint256(userRoleLogs[0].topics[2])),            PAS_ROLE_DELAYED);
        assertEq(abi.decode(userRoleLogs[0].data, (bool)),             true);

        assertEq(userRoleLogs[1].topics[0],                            BeamState.SetUserRole.selector);
        assertEq(address(uint160(uint256(userRoleLogs[1].topics[1]))), PAS_CORE_COUNCIL);
        assertEq(uint8(uint256(userRoleLogs[1].topics[2])),            PAS_ROLE_IMMEDIATE);
        assertEq(abi.decode(userRoleLogs[1].data, (bool)),             true);
    }

    function test_beamState_actionRoles() external view {
        BeamState beamState = BeamState(pasBeamState);

        // BeamState action roles

        bytes4[18] memory actionSigs = [  // First 8 are for DELAYED role, next 10 are for IMMEDIATE role.
            BeamState.start.selector,
            BeamState.setHop.selector,
            BeamState.setMaxChange.selector,
            BeamState.addRateLimits.selector,
            BeamState.addController.selector,
            BeamState.addCBeam.selector,
            BeamState.addInitRateLimits.selector,
            BeamState.addInitControllerActions.selector,
            BeamState.stop.selector,
            BeamState.delRateLimits.selector,
            BeamState.delController.selector,
            BeamState.delCBeam.selector,
            BeamState.setCBeamForRateLimits.selector,
            BeamState.unsetCBeamForRateLimits.selector,
            BeamState.setCBeamForController.selector,
            BeamState.unsetCBeamForController.selector,
            BeamState.delInitRateLimits.selector,
            BeamState.delInitControllerActions.selector
        ];

        Vm.Log[] memory roleActionLogs = _getEvents(pasBeamState, BeamState.SetRoleAction.selector);

        assertEq(roleActionLogs.length, 18);

        // First 8 actions are for DELAYED role
        for (uint256 i = 0; i < 8; i++) {
            assertEq(beamState.actionsRoles(actionSigs[i]), bytes32(uint256(1) << PAS_ROLE_DELAYED));

            assertEq(roleActionLogs[i].topics[0],                 BeamState.SetRoleAction.selector);
            assertEq(uint8(uint256(roleActionLogs[i].topics[1])), PAS_ROLE_DELAYED);
            assertEq(roleActionLogs[i].topics[2],                 bytes32(actionSigs[i]));
            assertEq(abi.decode(roleActionLogs[i].data, (bool)),  true);
        }

        // Next 10 actions are for IMMEDIATE role
        for (uint256 i = 8; i < 18; i++) {
            assertEq(beamState.actionsRoles(actionSigs[i]), bytes32(uint256(1) << PAS_ROLE_IMMEDIATE));

            assertEq(roleActionLogs[i].topics[0],                 BeamState.SetRoleAction.selector);
            assertEq(uint8(uint256(roleActionLogs[i].topics[1])), PAS_ROLE_IMMEDIATE);
            assertEq(roleActionLogs[i].topics[2],                 bytes32(actionSigs[i]));
            assertEq(abi.decode(roleActionLogs[i].data, (bool)),  true);
        }
    }

    // No BeamState configuration at launch: the spell does not run PASInit.initExtras.
    function test_beamState_extras() external view {
        BeamState beamState = BeamState(pasBeamState);

        assertEq(beamState.hop(address(0)),       0);
        assertEq(beamState.maxChange(address(0)), 0);

        bytes32[9] memory extrasEvents = [
            BeamState.SetHop.selector,
            BeamState.SetMaxChange.selector,
            BeamState.AddRateLimits.selector,
            BeamState.AddController.selector,
            BeamState.AddCBeam.selector,
            BeamState.SetCBeamForRateLimits.selector,
            BeamState.SetCBeamForController.selector,
            BeamState.AddInitRateLimits.selector,
            BeamState.AddInitControllerActions.selector
        ];

        for (uint256 i; i < extrasEvents.length; ++i) {
            assertEq(_getEvents(pasBeamState, extrasEvents[i]).length, 0);
        }
    }

    function test_timelock_state() external view {
        Timelock timelock = Timelock(payable(pasTimelock));

        assertEq(timelock.getMinDelay(),        PAS_MIN_DELAY);
        assertEq(timelock.paused(),             false);
        assertEq(timelock.getOperationsCount(), 0);

        assertEq(timelock.hasRole(DEFAULT_ADMIN_ROLE, PAS_OWNER),      true);
        assertEq(timelock.hasRole(DEFAULT_ADMIN_ROLE, address(spell)), false);
        assertEq(timelock.hasRole(DEFAULT_ADMIN_ROLE, pasTimelock),    false);  // Proposers cannot change admin-only configurations

        assertEq(timelock.hasRole(timelock.PROPOSER_ROLE(), PAS_CORE_COUNCIL), true);
        assertEq(timelock.hasRole(timelock.PROPOSER_ROLE(), PAS_CANCELLER1),   false);
        assertEq(timelock.hasRole(timelock.PROPOSER_ROLE(), PAS_CANCELLER2),   false);

        assertEq(timelock.hasRole(timelock.CANCELLER_ROLE(), PAS_CORE_COUNCIL), true);
        assertEq(timelock.hasRole(timelock.CANCELLER_ROLE(), PAS_CANCELLER1),   true);
        assertEq(timelock.hasRole(timelock.CANCELLER_ROLE(), PAS_CANCELLER2),   true);

        assertEq(timelock.hasRole(timelock.PAUSER_ROLE(),   pasMom),     true);
        assertEq(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)), true);  // Anyone can execute
    }

    function test_timelock_events() external view {
        Timelock timelock = Timelock(payable(pasTimelock));

        Vm.Log[] memory allEvents = _getEvents(pasTimelock, bytes32(0));

        assertEq(allEvents.length, 12);

        assertEq(allEvents[0].topics[0],                            IAccessControl.RoleGranted.selector);
        assertEq(allEvents[0].topics[1],                            DEFAULT_ADMIN_ROLE);
        assertEq(address(uint160(uint256(allEvents[0].topics[2]))), pasTimelock);
        assertEq(address(uint160(uint256(allEvents[0].topics[3]))), address(spell));

        assertEq(allEvents[1].topics[0],                            IAccessControl.RoleGranted.selector);
        assertEq(allEvents[1].topics[1],                            DEFAULT_ADMIN_ROLE);
        assertEq(address(uint160(uint256(allEvents[1].topics[2]))), address(spell));
        assertEq(address(uint160(uint256(allEvents[1].topics[3]))), address(spell));

        ( uint256 oldDuration, uint256 newDuration ) = abi.decode(allEvents[2].data, (uint256, uint256));

        assertEq(allEvents[2].topics[0], TimelockController.MinDelayChange.selector);
        assertEq(oldDuration,            0);
        assertEq(newDuration,            PAS_MIN_DELAY);

        assertEq(allEvents[3].topics[0],                            IAccessControl.RoleRevoked.selector);
        assertEq(allEvents[3].topics[1],                            DEFAULT_ADMIN_ROLE);
        assertEq(address(uint160(uint256(allEvents[3].topics[2]))), pasTimelock);
        assertEq(address(uint160(uint256(allEvents[3].topics[3]))), address(spell));

        assertEq(allEvents[4].topics[0],                            IAccessControl.RoleGranted.selector);
        assertEq(allEvents[4].topics[1],                            timelock.EXECUTOR_ROLE());
        assertEq(address(uint160(uint256(allEvents[4].topics[2]))), address(0));  // Anyone can execute
        assertEq(address(uint160(uint256(allEvents[4].topics[3]))), address(spell));

        assertEq(allEvents[5].topics[0],                            IAccessControl.RoleGranted.selector);
        assertEq(allEvents[5].topics[1],                            timelock.PROPOSER_ROLE());
        assertEq(address(uint160(uint256(allEvents[5].topics[2]))), PAS_CORE_COUNCIL);
        assertEq(address(uint160(uint256(allEvents[5].topics[3]))), address(spell));

        assertEq(allEvents[6].topics[0],                            IAccessControl.RoleGranted.selector);
        assertEq(allEvents[6].topics[1],                            timelock.CANCELLER_ROLE());
        assertEq(address(uint160(uint256(allEvents[6].topics[2]))), PAS_CORE_COUNCIL);
        assertEq(address(uint160(uint256(allEvents[6].topics[3]))), address(spell));

        assertEq(allEvents[7].topics[0],                            IAccessControl.RoleGranted.selector);
        assertEq(allEvents[7].topics[1],                            timelock.CANCELLER_ROLE());
        assertEq(address(uint160(uint256(allEvents[7].topics[2]))), PAS_CANCELLER1);
        assertEq(address(uint160(uint256(allEvents[7].topics[3]))), address(spell));

        assertEq(allEvents[8].topics[0],                            IAccessControl.RoleGranted.selector);
        assertEq(allEvents[8].topics[1],                            timelock.CANCELLER_ROLE());
        assertEq(address(uint160(uint256(allEvents[8].topics[2]))), PAS_CANCELLER2);
        assertEq(address(uint160(uint256(allEvents[8].topics[3]))), address(spell));

        assertEq(allEvents[9].topics[0],                            IAccessControl.RoleGranted.selector);
        assertEq(allEvents[9].topics[1],                            timelock.PAUSER_ROLE());
        assertEq(address(uint160(uint256(allEvents[9].topics[2]))), pasMom);
        assertEq(address(uint160(uint256(allEvents[9].topics[3]))), address(spell));

        assertEq(allEvents[10].topics[0],                            IAccessControl.RoleGranted.selector);
        assertEq(allEvents[10].topics[1],                            DEFAULT_ADMIN_ROLE);
        assertEq(address(uint160(uint256(allEvents[10].topics[2]))), PAS_OWNER);
        assertEq(address(uint160(uint256(allEvents[10].topics[3]))), address(spell));

        assertEq(allEvents[11].topics[0],                            IAccessControl.RoleRevoked.selector);
        assertEq(allEvents[11].topics[1],                            DEFAULT_ADMIN_ROLE);
        assertEq(address(uint160(uint256(allEvents[11].topics[2]))), address(spell));
        assertEq(address(uint160(uint256(allEvents[11].topics[3]))), address(spell));
    }

    function test_pasMom_state() external view {
        PASMom mom = PASMom(pasMom);

        assertEq(address(mom.beamState()), pasBeamState);
        assertEq(address(mom.timelock()),  pasTimelock);
        assertEq(mom.owner(),              PAS_MOM_OWNER);
        assertEq(mom.authority(),          PAS_MOM_AUTHORITY);
    }

    // The Mom only holds what it needs: a BeamState ward to stop() it and the Timelock PAUSER_ROLE to pause() it.
    function test_pasMom_permissions() external view {
        BeamState beamState = BeamState(pasBeamState);
        Timelock  timelock  = Timelock(payable(pasTimelock));

        assertEq(beamState.wards(pasMom),     1);
        assertEq(beamState.userRoles(pasMom), bytes32(0));

        assertEq(timelock.hasRole(timelock.PAUSER_ROLE(),    pasMom), true);
        assertEq(timelock.hasRole(DEFAULT_ADMIN_ROLE,        pasMom), false);
        assertEq(timelock.hasRole(timelock.PROPOSER_ROLE(),  pasMom), false);
        assertEq(timelock.hasRole(timelock.CANCELLER_ROLE(), pasMom), false);
        assertEq(timelock.hasRole(timelock.EXECUTOR_ROLE(),  pasMom), false);
    }

    function test_pasMom_events() external view {
        Vm.Log[] memory allEvents = _getEvents(pasMom, bytes32(0));

        // No StopBeamState or PauseTimelock: the Mom is never used during deployment.
        assertEq(allEvents.length, 4);

        // PASMom constructor sets the deployer (spell) as owner
        assertEq(allEvents[0].topics[0],                            PASMom.SetOwner.selector);
        assertEq(address(uint160(uint256(allEvents[0].topics[1]))), address(spell));

        // PASDeploy.deployMom sets the spell as owner again
        assertEq(allEvents[1].topics[0],                            PASMom.SetOwner.selector);
        assertEq(address(uint160(uint256(allEvents[1].topics[1]))), address(spell));

        assertEq(allEvents[2].topics[0],                            PASMom.SetAuthority.selector);
        assertEq(address(uint160(uint256(allEvents[2].topics[1]))), PAS_MOM_AUTHORITY);

        assertEq(allEvents[3].topics[0],                            PASMom.SetOwner.selector);
        assertEq(address(uint160(uint256(allEvents[3].topics[1]))), PAS_MOM_OWNER);
    }

}

contract SparkEthereumDeployPASTest_E2E is SparkEthereumDeployPASTestBase {

    function setUp() public override {
        super.setUp();

        vm.label(user, "user");
    }

    // stop is an IMMEDIATE action: the Core Council calls it directly
    function test_beamState_stop_onlyCouncil() external {
        BeamState beamState = BeamState(pasBeamState);

        assertEq(beamState.actionsRoles(BeamState.stop.selector), bytes32(uint256(1) << PAS_ROLE_IMMEDIATE));

        // The Timelock only holds the DELAYED role, so it cannot call it
        vm.prank(pasTimelock);
        vm.expectRevert("BeamState/role-not-authorized");
        beamState.stop();

        vm.prank(user);
        vm.expectRevert("BeamState/role-not-authorized");
        beamState.stop();

        assertEq(beamState.stopped(), false);

        vm.prank(PAS_CORE_COUNCIL);
        beamState.stop();

        assertEq(beamState.stopped(), true);
    }

    // setHop is a DELAYED action: it has to go through the Timelock
    function test_beamState_setHop_onlyTimelock() external {
        BeamState beamState = BeamState(pasBeamState);
        Timelock  timelock  = Timelock(payable(pasTimelock));

        assertEq(beamState.actionsRoles(BeamState.setHop.selector), bytes32(uint256(1) << PAS_ROLE_DELAYED));

        // The Core Council only holds the IMMEDIATE role, so it cannot call it directly
        vm.prank(PAS_CORE_COUNCIL);
        vm.expectRevert("BeamState/role-not-authorized");
        beamState.setHop(address(0), 1 hours);

        vm.prank(user);
        vm.expectRevert("BeamState/role-not-authorized");
        beamState.setHop(address(0), 1 hours);

        assertEq(beamState.getHop(address(0)), 0);

        // The Core Council proposes the call through the Timelock

        ( address[] memory targets, uint256[] memory values, bytes[] memory payloads ) =
            _singleCall(pasBeamState, abi.encodeCall(beamState.setHop, (address(0), 1 hours)));

        bytes32 id = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), bytes32(0));

        vm.prank(PAS_CORE_COUNCIL);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), PAS_MIN_DELAY);

        assertEq(timelock.isOperationReady(id), false);

        // The call can not be executed before the delay
        skip(PAS_MIN_DELAY - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector,
                id,
                bytes32(1 << uint8(TimelockController.OperationState.Ready))
            )
        );
        timelock.executeBatch(targets, values, payloads, bytes32(0), bytes32(0));

        skip(1);

        assertEq(timelock.isOperationReady(id), true);

        assertEq(beamState.getHop(address(0)), 0);

        // Execution is permissionless, the Timelock is the caller into BeamState
        vm.prank(user);
        timelock.executeBatch(targets, values, payloads, bytes32(0), bytes32(0));

        assertEq(beamState.getHop(address(0)), 1 hours);
    }

    // start is a DELAYED action: after an immediate stop it has to go through the Timelock
    function test_beamState_start_onlyTimelock() external {
        BeamState beamState = BeamState(pasBeamState);
        Timelock  timelock  = Timelock(payable(pasTimelock));

        vm.prank(PAS_CORE_COUNCIL);
        beamState.stop();

        assertEq(beamState.stopped(), true);

        ( address[] memory targets, uint256[] memory values, bytes[] memory payloads ) =
            _singleCall(pasBeamState, abi.encodeCall(beamState.start, ()));

        vm.prank(PAS_CORE_COUNCIL);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), PAS_MIN_DELAY);

        skip(PAS_MIN_DELAY);

        vm.prank(user);
        timelock.executeBatch(targets, values, payloads, bytes32(0), bytes32(0));

        assertEq(beamState.stopped(), false);
    }

    // delCBeam is an IMMEDIATE action: the Core Council calls it directly, the Timelock is not authorized
    function test_beamState_delCBeam_onlyCouncil() external {
        BeamState beamState = BeamState(pasBeamState);
        Timelock  timelock  = Timelock(payable(pasTimelock));

        address cBeam = makeAddr("cBeam");

        assertEq(beamState.actionsRoles(BeamState.addCBeam.selector), bytes32(uint256(1) << PAS_ROLE_DELAYED));
        assertEq(beamState.actionsRoles(BeamState.delCBeam.selector), bytes32(uint256(1) << PAS_ROLE_IMMEDIATE));

        // The cBeam is onboarded through the Timelock

        ( address[] memory targets, uint256[] memory values, bytes[] memory payloads ) =
            _singleCall(pasBeamState, abi.encodeCall(beamState.addCBeam, (cBeam)));

        vm.prank(PAS_CORE_COUNCIL);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), PAS_MIN_DELAY);

        skip(PAS_MIN_DELAY);

        timelock.executeBatch(targets, values, payloads, bytes32(0), bytes32(0));

        assertEq(beamState.cBeams(cBeam), 1);

        // The Timelock only holds the DELAYED role, so it cannot remove it

        vm.prank(pasTimelock);
        vm.expectRevert("BeamState/role-not-authorized");
        beamState.delCBeam(cBeam);

        assertEq(beamState.cBeams(cBeam), 1);

        vm.prank(PAS_CORE_COUNCIL);
        beamState.delCBeam(cBeam);

        assertEq(beamState.cBeams(cBeam), 0);
    }

    function test_timelock_pauserPauses() external {
        Timelock timelock = Timelock(payable(pasTimelock));

        bytes32 pauserRole = timelock.PAUSER_ROLE();

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, pauserRole)
        );
        timelock.pause();

        vm.prank(pasMom);
        timelock.pause();

        assertEq(timelock.paused(), true);

        // Scheduling is blocked while paused

        ( address[] memory targets, uint256[] memory values, bytes[] memory payloads ) =
            _singleCall(pasBeamState, abi.encodeCall(BeamState.start, ()));

        vm.prank(PAS_CORE_COUNCIL);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), PAS_MIN_DELAY);

        // Only the PAS owner unpauses

        vm.prank(PAS_OWNER);
        timelock.unpause();

        assertEq(timelock.paused(), false);
    }

    function test_timelock_cancellersCancel() external {
        Timelock timelock = Timelock(payable(pasTimelock));

        bytes32 cancellerRole = timelock.CANCELLER_ROLE();

        address[3] memory cancellers = [PAS_CORE_COUNCIL, PAS_CANCELLER1, PAS_CANCELLER2];

        for (uint256 i; i < cancellers.length; ++i) {
            // A distinct payload per canceller, so each operation id differs
            ( address[] memory targets, uint256[] memory values, bytes[] memory payloads ) =
                _singleCall(pasBeamState, abi.encodeCall(BeamState.setHop, (address(0), (i + 1) * 1 hours)));

            bytes32 id = timelock.hashOperationBatch(targets, values, payloads, bytes32(0), bytes32(0));

            vm.prank(PAS_CORE_COUNCIL);
            timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), PAS_MIN_DELAY);

            assertEq(timelock.isOperationPending(id), true);

            vm.prank(user);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user, cancellerRole)
            );
            timelock.cancel(id);

            vm.prank(cancellers[i]);
            timelock.cancel(id);

            assertEq(timelock.isOperation(id), false);
        }
    }

    function test_beamState_ownerAdministers() external {
        vm.prank(PAS_OWNER);
        BeamState(pasBeamState).rely(user);

        assertEq(BeamState(pasBeamState).wards(user), 1);
    }

    // The Chief hat stops BeamState through the Mom, bypassing the Timelock delay
    function test_pasMom_hatStops() external {
        BeamState beamState = BeamState(pasBeamState);
        PASMom    mom       = PASMom(pasMom);

        address hat = IChiefLike(PAS_MOM_AUTHORITY).hat();

        // The PAS owner and the Core Council act on BeamState directly, not through the Mom
        address[4] memory unauthorized = [user, PAS_OWNER, PAS_CORE_COUNCIL, address(spell)];

        for (uint256 i; i < unauthorized.length; ++i) {
            vm.prank(unauthorized[i]);
            vm.expectRevert("PASMom/not-authorized");
            mom.stop();
        }

        assertEq(beamState.stopped(), false);

        vm.expectEmit(pasBeamState);
        emit BeamState.Stop();
        vm.expectEmit(pasMom);
        emit PASMom.StopBeamState();

        vm.prank(hat);
        mom.stop();

        assertEq(beamState.stopped(), true);
    }

    // The Chief hat pauses the Timelock through the Mom
    function test_pasMom_hatPauses() external {
        Timelock timelock = Timelock(payable(pasTimelock));
        PASMom   mom      = PASMom(pasMom);

        address hat = IChiefLike(PAS_MOM_AUTHORITY).hat();

        address[4] memory unauthorized = [user, PAS_OWNER, PAS_CORE_COUNCIL, address(spell)];

        for (uint256 i; i < unauthorized.length; ++i) {
            vm.prank(unauthorized[i]);
            vm.expectRevert("PASMom/not-authorized");
            mom.pause();
        }

        assertEq(timelock.paused(), false);

        vm.expectEmit(pasTimelock);
        emit Pausable.Paused(pasMom);
        vm.expectEmit(pasMom);
        emit PASMom.PauseTimelock();

        vm.prank(hat);
        mom.pause();

        assertEq(timelock.paused(), true);
    }

    // The Mom owner is authorized on its own, without going through the Chief
    function test_pasMom_ownerStopsAndPauses() external {
        assertEq(BeamState(pasBeamState).stopped(),       false);
        assertEq(Timelock(payable(pasTimelock)).paused(), false);

        vm.startPrank(PAS_MOM_OWNER);
        PASMom(pasMom).stop();
        PASMom(pasMom).pause();
        vm.stopPrank();

        assertEq(BeamState(pasBeamState).stopped(),       true);
        assertEq(Timelock(payable(pasTimelock)).paused(), true);
    }

    // Only the Mom owner administers it: neither the PAS owner nor the hat can change its owner or authority
    function test_pasMom_onlyOwnerAdministers() external {
        PASMom mom = PASMom(pasMom);

        address hat = IChiefLike(PAS_MOM_AUTHORITY).hat();

        address[4] memory notOwners = [PAS_OWNER, hat, address(spell), user];

        for (uint256 i; i < notOwners.length; ++i) {
            vm.startPrank(notOwners[i]);

            vm.expectRevert("PASMom/not-owner");
            mom.setOwner(notOwners[i]);

            vm.expectRevert("PASMom/not-owner");
            mom.setAuthority(notOwners[i]);

            vm.stopPrank();
        }

        assertEq(mom.owner(),     PAS_MOM_OWNER);
        assertEq(mom.authority(), PAS_MOM_AUTHORITY);

        // Removing the authority takes the emergency powers away from the hat

        vm.prank(PAS_MOM_OWNER);
        mom.setAuthority(address(0));

        vm.prank(hat);
        vm.expectRevert("PASMom/not-authorized");
        mom.stop();

        vm.prank(hat);
        vm.expectRevert("PASMom/not-authorized");
        mom.pause();
    }

    // The hat halts PAS through the Mom, then the PAS owner unpauses and the Core Council restarts BeamState
    function test_pasMom_emergencyAndRecovery() external {
        BeamState beamState = BeamState(pasBeamState);
        Timelock  timelock  = Timelock(payable(pasTimelock));
        PASMom    mom       = PASMom(pasMom);

        address hat = IChiefLike(PAS_MOM_AUTHORITY).hat();

        assertEq(beamState.stopped(), false);
        assertEq(timelock.paused(),   false);

        vm.startPrank(hat);
        mom.stop();
        mom.pause();
        vm.stopPrank();

        assertEq(beamState.stopped(), true);
        assertEq(timelock.paused(),   true);

        // While the Timelock is paused, the Core Council cannot schedule the restart

        ( address[] memory targets, uint256[] memory values, bytes[] memory payloads ) =
            _singleCall(pasBeamState, abi.encodeCall(beamState.start, ()));

        vm.prank(PAS_CORE_COUNCIL);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), PAS_MIN_DELAY);

        // The hat cannot unpause, only the PAS owner can

        vm.prank(hat);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, hat, DEFAULT_ADMIN_ROLE)
        );
        timelock.unpause();

        vm.prank(PAS_OWNER);
        timelock.unpause();

        // The restart goes through the Timelock delay

        vm.prank(PAS_CORE_COUNCIL);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), PAS_MIN_DELAY);

        skip(PAS_MIN_DELAY);

        vm.prank(user);
        timelock.executeBatch(targets, values, payloads, bytes32(0), bytes32(0));

        assertEq(beamState.stopped(), false);
        assertEq(timelock.paused(),   false);
    }

    function _singleCall(address target, bytes memory payload)
        internal pure returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets  = new address[](1);
        values   = new uint256[](1);
        payloads = new bytes[](1);

        targets[0]  = target;
        payloads[0] = payload;
    }

}
