// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test, Vm } from "../lib/forge-std/src/Test.sol";

import { IAccessControl } from "../lib/pas/lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";
import { Pausable }       from "../lib/pas/lib/openzeppelin-contracts/contracts/utils/Pausable.sol";

import { TimelockController } from "../lib/pas/lib/openzeppelin-contracts/contracts/governance/TimelockController.sol";

import { BeamState }    from "../lib/pas/src/BeamState.sol";
import { Configurator } from "../lib/pas/src/Configurator.sol";
import { Timelock }     from "../lib/pas/src/timelock/Timelock.sol";

import { SparkDeploymentsEthereumPAS } from "../src/SparkDeploymentsEthereumPAS.sol";

abstract contract SparkDeploymentsEthereumPASTestBase is Test {

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    // BeamState roles set by PASInit.
    uint8 internal constant PAS_ROLE_DELAYED   = 1;
    uint8 internal constant PAS_ROLE_IMMEDIATE = 2;

    // TODO: Replace with the final PAS addresses, must match the spell.
    address internal constant PAS_OWNER        = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;
    address internal constant PAS_CORE_COUNCIL = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;
    address internal constant PAS_CANCELLER    = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;
    address internal constant PAS_PAUSER       = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    uint256 internal constant PAS_MIN_DELAY = 100_000;

    SparkDeploymentsEthereumPAS internal spell;

    address internal pasBeamState;
    address internal pasConfigurator;
    address internal pasTimelock;

    address internal user = makeAddr("user");

    Vm.Log[] internal deployLogs;

    function setUp() public virtual {
        vm.createSelectFork(getChain("mainnet").rpcUrl);

        vm.recordLogs();

        spell = new SparkDeploymentsEthereumPAS();

        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i; i < logs.length; ++i) {
            deployLogs.push(logs[i]);
        }

        pasBeamState    = spell.PAS_BEAM_STATE();
        pasConfigurator = spell.PAS_CONFIGURATOR();
        pasTimelock     = spell.PAS_TIMELOCK();

        vm.label(address(spell),  "spell");
        vm.label(pasBeamState,    "pas.beamState");
        vm.label(pasConfigurator, "pas.configurator");
        vm.label(pasTimelock,     "pas.timelock");
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

contract SparkDeploymentsEthereumPASTest_SpellPayload is SparkDeploymentsEthereumPASTestBase {

    function test_spell_invalidChainId() external {
        vm.chainId(2);

        vm.expectRevert("SparkDeploymentsEthereumPAS/invalid-chain-id");
        new SparkDeploymentsEthereumPAS();
    }

    function test_spell_deployedAddresses() external view {
        address[3] memory deployed = [pasBeamState, pasConfigurator, pasTimelock];

        for (uint256 i; i < deployed.length; ++i) {
            assertGt(deployed[i].code.length, 0);

            for (uint256 j = i + 1; j < deployed.length; ++j) {
                assertNotEq(deployed[i], deployed[j]);
            }
        }
    }

    function test_spell_holdsNoRoles() external view {
        Timelock timelock = Timelock(payable(pasTimelock));

        assertEq(timelock.hasRole(DEFAULT_ADMIN_ROLE,        address(spell)), false);
        assertEq(timelock.hasRole(timelock.PROPOSER_ROLE(),  address(spell)), false);
        assertEq(timelock.hasRole(timelock.CANCELLER_ROLE(), address(spell)), false);
        assertEq(timelock.hasRole(timelock.EXECUTOR_ROLE(),  address(spell)), false);
        assertEq(timelock.hasRole(timelock.PAUSER_ROLE(),    address(spell)), false);

        assertEq(BeamState(pasBeamState).wards(address(spell)),     0);
        assertEq(BeamState(pasBeamState).userRoles(address(spell)), bytes32(0));
    }

}

contract SparkDeploymentsEthereumPASTest_PAS is SparkDeploymentsEthereumPASTestBase {

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

        // BeamState admin: PAS owner only

        assertEq(beamState.wards(PAS_OWNER),      1);
        assertEq(beamState.wards(address(spell)), 0);

        Vm.Log[] memory relyLogs = _getEvents(pasBeamState, BeamState.Rely.selector);
        Vm.Log[] memory denyLogs = _getEvents(pasBeamState, BeamState.Deny.selector);

        assertEq(relyLogs.length, 2);
        assertEq(denyLogs.length, 1);

        assertEq(relyLogs[0].topics[0],                            BeamState.Rely.selector);
        assertEq(address(uint160(uint256(relyLogs[0].topics[1]))), address(spell));

        assertEq(relyLogs[1].topics[0],                            BeamState.Rely.selector);
        assertEq(address(uint160(uint256(relyLogs[1].topics[1]))), PAS_OWNER);

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

    // The spell does not run PASInit.initExtras, so nothing is onboarded to BeamState yet.
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

        assertEq(timelock.hasRole(timelock.PROPOSER_ROLE(),  PAS_CORE_COUNCIL), true);
        assertEq(timelock.hasRole(timelock.CANCELLER_ROLE(), PAS_CORE_COUNCIL), true);
        assertEq(timelock.hasRole(timelock.CANCELLER_ROLE(), PAS_CANCELLER),    true);
        assertEq(timelock.hasRole(timelock.PAUSER_ROLE(),    PAS_PAUSER),       true);
        assertEq(timelock.hasRole(timelock.EXECUTOR_ROLE(),  address(0)),       true);  // Anyone can execute
    }

    function test_timelock_events() external view {
        Timelock timelock = Timelock(payable(pasTimelock));

        Vm.Log[] memory allEvents = _getEvents(pasTimelock, bytes32(0));

        // TODO: The CANCELLER grant to PAS_CANCELLER emits no event while it shares the Core Council
        //       placeholder, add it once the addresses differ.
        assertEq(allEvents.length, 10);

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
        assertEq(allEvents[7].topics[1],                            timelock.PAUSER_ROLE());
        assertEq(address(uint160(uint256(allEvents[7].topics[2]))), PAS_PAUSER);
        assertEq(address(uint160(uint256(allEvents[7].topics[3]))), address(spell));

        assertEq(allEvents[8].topics[0],                            IAccessControl.RoleGranted.selector);
        assertEq(allEvents[8].topics[1],                            DEFAULT_ADMIN_ROLE);
        assertEq(address(uint160(uint256(allEvents[8].topics[2]))), PAS_OWNER);
        assertEq(address(uint160(uint256(allEvents[8].topics[3]))), address(spell));

        assertEq(allEvents[9].topics[0],                            IAccessControl.RoleRevoked.selector);
        assertEq(allEvents[9].topics[1],                            DEFAULT_ADMIN_ROLE);
        assertEq(address(uint160(uint256(allEvents[9].topics[2]))), address(spell));
        assertEq(address(uint160(uint256(allEvents[9].topics[3]))), address(spell));
    }

}
