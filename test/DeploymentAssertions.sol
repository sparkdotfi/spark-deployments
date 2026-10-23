// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";

import { PAUInstance } from "diamond-pau/deploy/PAUInit.sol";

import { PASInstance } from "pas/deploy/PASInstance.sol";

import { SparkPrimeVaultDeployer } from "../deploy/SparkPrimeVaultDeployer.sol";

interface IAccessControlEnumerableLike {
    function getRoleMember(bytes32 role, uint256 index) external view returns (address);
    function getRoleMemberCount(bytes32 role) external view returns (uint256);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface IAccessControlLike {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

interface ISparkPrimeVaultLike {
    function LOSS_MANAGER_ROLE() external view returns (bytes32);
    function OPERATOR_ROLE() external view returns (bytes32);
    function PAUSER_ROLE() external view returns (bytes32);
    function REDEEM_FEE_SETTER_ROLE() external view returns (bytes32);
    function TAKER_ROLE() external view returns (bytes32);
    function UNPAUSER_ROLE() external view returns (bytes32);

    function asset() external view returns (address);
    function decimals() external view returns (uint8);
    function implementation() external view returns (address);
    function maxRedeemFeeRate() external view returns (uint256);
    function maxVSR() external view returns (uint256);
    function minDeposit() external view returns (uint256);
    function minDepositCancellation() external view returns (uint256);
    function minRedeem() external view returns (uint256);
    function minVSR() external view returns (uint256);
    function name() external view returns (string memory);
    function paused() external view returns (bool);
    function savings() external view returns (address);
    function symbol() external view returns (string memory);
    function vsr() external view returns (uint256);
}

interface IControllerLike {
    struct Wire        { bytes4 callSelector; bytes4 delegateSelector; }
    struct Config      { address facet; Wire[] wires; }
    struct Integration { bytes32 id; Config config; }

    function accessControls() external view returns (address);
    function beacon() external view returns (address);
    function proxy() external view returns (address);
    function rateLimits() external view returns (address);
    function integrations() external view returns (Integration[] memory);

    function erc4626_EXCHANGE_RATE_PRECISION() external pure returns (uint256);
    function erc4626_getDepositRateLimitKey(address token, address asset) external pure returns (bytes32);
    function erc4626_getMaxExchangeRate(address token) external view returns (uint256);
    function erc4626_getWithdrawRateLimitKey(address token) external pure returns (bytes32);
    function sparkVault_getTakeRateLimitKey(address sparkVault) external pure returns (bytes32);
    function transferAsset_getTransferRateLimitKey(address asset, address destination) external view returns (bytes32);
}

interface IRateLimitsLike {
    struct RateLimitData { uint256 maxAmount; uint256 slope; uint256 lastAmount; uint256 lastUpdated; }

    function CONTROLLER() external view returns (bytes32);
    function getRateLimitData(bytes32 key) external view returns (RateLimitData memory);
}

interface IALMProxyLike {
    function CONTROLLER() external view returns (bytes32);
}

interface IERC20Like {
    function decimals() external view returns (uint8);
}

interface IWardsLike {
    function wards(address usr) external view returns (uint256);
}

interface IConfiguratorLike {
    function beamState() external view returns (address);
}

interface ITimelockLike {
    function CANCELLER_ROLE() external view returns (bytes32);
    function EXECUTOR_ROLE() external view returns (bytes32);
    function PAUSER_ROLE() external view returns (bytes32);
    function PROPOSER_ROLE() external view returns (bytes32);
    function getMinDelay() external view returns (uint256);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function paused() external view returns (bool);
}

/**
 * @notice Exact-value assertions that a deployed `Instance` matches its `Config`. Shared by the
 *         local configuration tests and the mainnet-fork dry run of the broadcast script, so the
 *         same checks run against the real dependencies before the deployment is sent.
 */
abstract contract SparkPrimeVaultDeploymentAssertions is Test, SparkPrimeVaultDeployer {

    bytes32 internal constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");

    uint256 internal constant RAY = 1e27;

    /**********************************************************************************************/
    /*** Entry point                                                                            ***/
    /**********************************************************************************************/

    function _assertDeployment(Config memory cfg, Instance memory inst, address deployer_) internal view {
        _assertVault(cfg, inst, deployer_);
        _assertPAU("spPrimePAU", cfg.spPrimePAU, inst.spPrimePAU, cfg, inst, deployer_);
        _assertPAU("flcPAU",     cfg.flcPAU,     inst.flcPAU,     cfg, inst, deployer_);
        _assertPAS(cfg.pas, inst.pas, deployer_);
    }

    /**********************************************************************************************/
    /*** Spark Prime Vault                                                                      ***/
    /**********************************************************************************************/

    function _assertVault(Config memory cfg, Instance memory inst, address deployer_) internal view {
        ISparkPrimeVaultLike vault = ISparkPrimeVaultLike(inst.spPrime);
        VaultConfig memory v = cfg.vault;

        assertEq(vault.implementation(), inst.spPrimeImplementation, "spPrime/implementation");

        assertEq(vault.savings(),  v.savings,                             "spPrime/savings");
        assertEq(vault.asset(),    ISparkPrimeVaultLike(v.savings).asset(), "spPrime/asset");
        assertEq(vault.name(),     v.name,                                "spPrime/name");
        assertEq(vault.symbol(),   v.symbol,                              "spPrime/symbol");
        assertEq(vault.decimals(), IERC20Like(vault.asset()).decimals(),  "spPrime/decimals");

        assertEq(vault.minDeposit(),             v.minDeposit,             "spPrime/minDeposit");
        assertEq(vault.minDepositCancellation(), v.minDepositCancellation, "spPrime/minDepositCancellation");
        assertEq(vault.minRedeem(),              v.minRedeem,              "spPrime/minRedeem");
        assertEq(vault.minVSR(),                 v.minVSR,                 "spPrime/minVSR");
        assertEq(vault.maxVSR(),                 v.maxVSR,                 "spPrime/maxVSR");
        assertEq(vault.vsr(),                    RAY,                      "spPrime/vsr");
        assertEq(vault.maxRedeemFeeRate(),       v.maxRedeemFeeRate,       "spPrime/maxRedeemFeeRate");
        assertEq(vault.paused(),                 false,                    "spPrime/paused");

        _assertSoleMember(inst.spPrime, DEFAULT_ADMIN_ROLE,            v.admin,                   "spPrime/admin");
        _assertSoleMember(inst.spPrime, vault.PAUSER_ROLE(),           v.pauser,                  "spPrime/pauser");
        _assertSoleMember(inst.spPrime, vault.UNPAUSER_ROLE(),         v.unpauser,                "spPrime/unpauser");
        _assertSoleMember(inst.spPrime, vault.OPERATOR_ROLE(),         v.operator,                "spPrime/operator");
        _assertSoleMember(inst.spPrime, vault.REDEEM_FEE_SETTER_ROLE(), v.redeemFeeSetter,        "spPrime/redeemFeeSetter");
        _assertSoleMember(inst.spPrime, vault.LOSS_MANAGER_ROLE(),     v.lossManager,             "spPrime/lossManager");
        _assertSoleMember(inst.spPrime, vault.TAKER_ROLE(),            inst.spPrimePAU.almProxy,  "spPrime/taker");

        if (deployer_ != v.admin) {
            assertFalse(IAccessControlLike(inst.spPrime).hasRole(DEFAULT_ADMIN_ROLE, deployer_), "spPrime/deployer-admin");
        }
    }

    /**********************************************************************************************/
    /*** PAU                                                                                    ***/
    /**********************************************************************************************/

    function _assertPAU(
        string      memory name,
        PAUConfig   memory cfg,
        PAUInstance memory pau,
        Config      memory fullCfg,
        Instance    memory inst,
        address            deployer_
    ) internal view {
        IControllerLike controller = IControllerLike(pau.controller);

        // Immutable wiring.
        assertEq(controller.accessControls(), pau.accessControls, _m(name, "controller.accessControls"));
        assertEq(controller.proxy(),          pau.almProxy,       _m(name, "controller.proxy"));
        assertEq(controller.rateLimits(),     pau.rateLimits,     _m(name, "controller.rateLimits"));
        assertEq(controller.beacon(),         pau.beacon,         _m(name, "controller.beacon"));
        assertEq(pau.beacon, IControllerLike(fullCfg.pauFactory).beacon(), _m(name, "factory.beacon"));

        // CONTROLLER role on ALMProxy and RateLimits.
        assertTrue(IAccessControlLike(pau.almProxy).hasRole(IALMProxyLike(pau.almProxy).CONTROLLER(),       pau.controller), _m(name, "proxy.CONTROLLER"));
        assertTrue(IAccessControlLike(pau.rateLimits).hasRole(IRateLimitsLike(pau.rateLimits).CONTROLLER(), pau.controller), _m(name, "rateLimits.CONTROLLER"));

        // Integrations synced from the beacon, in config order.
        IControllerLike.Integration[] memory integrations = controller.integrations();

        assertEq(integrations.length, cfg.integrationIds.length, _m(name, "integrations.length"));

        for (uint256 i; i < integrations.length; ++i) {
            assertEq(integrations[i].id, cfg.integrationIds[i], _m(name, "integrations.id"));
            assertTrue(integrations[i].config.facet != address(0), _m(name, "integrations.facet"));
            assertTrue(integrations[i].config.wires.length > 0,    _m(name, "integrations.wires"));
        }

        // The shared allocator agent is the one and only allocator.
        _assertSoleMember(pau.accessControls, ALLOCATOR_ROLE, fullCfg.allocatorAgent, _m(name, "allocator"));

        // Admins: configured admins plus the PAS configurator on AccessControls and RateLimits.
        _assertAdmins(pau.accessControls, cfg.admins, inst.pas.configurator, deployer_, _m(name, "accessControls.admins"));
        _assertAdmins(pau.rateLimits,     cfg.admins, inst.pas.configurator, deployer_, _m(name, "rateLimits.admins"));
        _assertAdmins(pau.almProxy,       cfg.admins, address(0),            deployer_, _m(name, "almProxy.admins"));

        assertEq(
            IAccessControlEnumerableLike(pau.accessControls).getRoleMemberCount(DEFAULT_ADMIN_ROLE),
            cfg.admins.length + 1,
            _m(name, "accessControls.adminCount")
        );

        // Rate limits.
        for (uint256 i; i < cfg.transferAssetRateLimits.length; ++i) {
            TransferAssetRateLimit memory rl = cfg.transferAssetRateLimits[i];

            _assertRateLimit(
                pau.rateLimits,
                controller.transferAsset_getTransferRateLimitKey(rl.asset, _resolve(rl.destination, inst)),
                rl.maxAmount,
                rl.slopePerDay / 1 days,
                _m(name, "transferAsset")
            );
        }

        for (uint256 i; i < cfg.erc4626RateLimits.length; ++i) {
            ERC4626RateLimit memory rl = cfg.erc4626RateLimits[i];

            _assertRateLimit(
                pau.rateLimits,
                controller.erc4626_getDepositRateLimitKey(rl.token, rl.asset),
                rl.depositMaxAmount,
                rl.depositSlopePerDay / 1 days,
                _m(name, "erc4626.deposit")
            );
            _assertRateLimit(
                pau.rateLimits,
                controller.erc4626_getWithdrawRateLimitKey(rl.token),
                rl.withdrawMaxAmount,
                rl.withdrawSlopePerDay / 1 days,
                _m(name, "erc4626.withdraw")
            );

            uint256 shares   = 10 ** IERC20Like(rl.token).decimals();
            uint256 expected = rl.maxExchangeRate * 10 ** IERC20Like(rl.asset).decimals();

            assertEq(
                controller.erc4626_getMaxExchangeRate(rl.token),
                expected * controller.erc4626_EXCHANGE_RATE_PRECISION() / shares,
                _m(name, "erc4626.maxExchangeRate")
            );
        }

        for (uint256 i; i < cfg.sparkVaultRateLimits.length; ++i) {
            SparkVaultRateLimit memory rl = cfg.sparkVaultRateLimits[i];

            _assertRateLimit(
                pau.rateLimits,
                controller.sparkVault_getTakeRateLimitKey(_resolve(rl.sparkVault, inst)),
                rl.maxAmount,
                rl.slopePerDay / 1 days,
                _m(name, "sparkVault.take")
            );
        }
    }

    /**********************************************************************************************/
    /*** PAS                                                                                    ***/
    /**********************************************************************************************/

    function _assertPAS(PASConfig memory cfg, PASInstance memory pas, address deployer_) internal view {
        ITimelockLike timelock = ITimelockLike(pas.timelock);

        assertEq(IConfiguratorLike(pas.configurator).beamState(), pas.beamState, "pas/configurator.beamState");

        assertEq(IWardsLike(pas.beamState).wards(cfg.owner), 1, "pas/beamState.owner");
        if (deployer_ != cfg.owner) {
            assertEq(IWardsLike(pas.beamState).wards(deployer_), 0, "pas/beamState.deployer");
        }

        assertEq(timelock.getMinDelay(), cfg.minDelay, "pas/timelock.minDelay");
        assertEq(timelock.paused(),      false,        "pas/timelock.paused");

        assertTrue(timelock.hasRole(DEFAULT_ADMIN_ROLE, cfg.owner), "pas/timelock.admin");
        if (deployer_ != cfg.owner) {
            assertFalse(timelock.hasRole(DEFAULT_ADMIN_ROLE, deployer_), "pas/timelock.deployer-admin");
        }
        assertFalse(timelock.hasRole(DEFAULT_ADMIN_ROLE, pas.timelock), "pas/timelock.self-admin");

        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(),  cfg.coreCouncil), "pas/timelock.proposer");
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), cfg.coreCouncil), "pas/timelock.canceller");
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(),  address(0)),      "pas/timelock.open-executor");

        for (uint256 i; i < cfg.cancellers.length; ++i) {
            assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), cfg.cancellers[i]), "pas/timelock.cancellers");
        }
        for (uint256 i; i < cfg.pausers.length; ++i) {
            assertTrue(timelock.hasRole(timelock.PAUSER_ROLE(), cfg.pausers[i]), "pas/timelock.pausers");
        }
    }

    /**********************************************************************************************/
    /*** Helpers                                                                                ***/
    /**********************************************************************************************/

    function _assertSoleMember(address target, bytes32 role, address member, string memory label) internal view {
        IAccessControlEnumerableLike ac = IAccessControlEnumerableLike(target);

        assertEq(ac.getRoleMemberCount(role), 1,      string(abi.encodePacked(label, ".count")));
        assertEq(ac.getRoleMember(role, 0),   member, string(abi.encodePacked(label, ".member")));
    }

    /// @dev Non-enumerable targets: check every expected admin holds the role and the deployer does not.
    function _assertAdmins(
        address          target,
        address[] memory admins,
        address          extraAdmin,
        address          deployer_,
        string    memory label
    ) internal view {
        bool deployerIsAdmin;

        for (uint256 i; i < admins.length; ++i) {
            assertTrue(IAccessControlLike(target).hasRole(DEFAULT_ADMIN_ROLE, admins[i]), label);
            if (admins[i] == deployer_) deployerIsAdmin = true;
        }

        if (extraAdmin != address(0)) {
            assertTrue(IAccessControlLike(target).hasRole(DEFAULT_ADMIN_ROLE, extraAdmin), string(abi.encodePacked(label, ".extra")));
        }

        if (!deployerIsAdmin) {
            assertFalse(IAccessControlLike(target).hasRole(DEFAULT_ADMIN_ROLE, deployer_), string(abi.encodePacked(label, ".deployer")));
        }
    }

    function _assertRateLimit(address rateLimits, bytes32 key, uint256 maxAmount, uint256 slope, string memory label) internal view {
        IRateLimitsLike.RateLimitData memory data = IRateLimitsLike(rateLimits).getRateLimitData(key);

        assertEq(data.maxAmount,   maxAmount,       string(abi.encodePacked(label, ".maxAmount")));
        assertEq(data.slope,       slope,           string(abi.encodePacked(label, ".slope")));
        assertEq(data.lastAmount,  maxAmount,       string(abi.encodePacked(label, ".lastAmount")));
        assertEq(data.lastUpdated, block.timestamp, string(abi.encodePacked(label, ".lastUpdated")));
    }

    function _m(string memory name, string memory what) internal pure returns (string memory) {
        return string(abi.encodePacked(name, "/", what));
    }

}
