// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "../../../../lib/forge-std/src/Test.sol";

import { IAccessControl } from "../../../../lib/spark-prime-vault/lib/oz/contracts/access/IAccessControl.sol";

import { Ethereum } from "../../../../lib/spark-address-registry/src/Ethereum.sol";

import { ISparkPrimeVault } from "../../../../lib/spark-prime-vault/src/ISparkPrimeVault.sol";
import { SparkPrimeVault }  from "../../../../lib/spark-prime-vault/src/SparkPrimeVault.sol";

import { IAccessControls }         from "../../../../lib/diamond-pau/src/interfaces/IAccessControls.sol";
import { IALMProxy }               from "../../../../lib/diamond-pau/src/interfaces/IALMProxy.sol";
import { IBeacon }                 from "../../../../lib/diamond-pau/src/interfaces/IBeacon.sol";
import { IController }             from "../../../../lib/diamond-pau/src/interfaces/IController.sol";
import { IEnumerableIntegrations } from "../../../../lib/diamond-pau/src/interfaces/IEnumerableIntegrations.sol";
import { IPAUFactory }             from "../../../../lib/diamond-pau/src/interfaces/IPAUFactory.sol";
import { IRateLimits }             from "../../../../lib/diamond-pau/src/interfaces/IRateLimits.sol";

import { IERC4626Controller }       from "../../../../lib/diamond-pau/src/facets/erc4626/IERC4626Controller.sol";
import { ISparkVaultController }    from "../../../../lib/diamond-pau/src/facets/spark-vault/ISparkVaultController.sol";
import { ITransferAssetController } from "../../../../lib/diamond-pau/src/facets/transfer-asset/ITransferAssetController.sol";

import { SparkEthereumDeploySpPrime } from "../SparkEthereumDeploySpPrime.sol";

import { SparkDeployOrchestration } from "../SparkDeployOrchestration.sol";

interface IERC20Like {

    function allowance(address owner, address spender) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    function balanceOf(address account) external view returns (uint256);

}

abstract contract SparkEthereumDeploySpPrimeTestBase is Test {

    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant ALLOCATOR_ROLE     = keccak256("ALLOCATOR_ROLE");
    bytes32 internal constant CONTROLLER_ROLE    = keccak256("CONTROLLER");

    address internal constant PAU_BEACON = Ethereum.SPARK_BEACON;

    address internal constant SPUSDC = Ethereum.SPARK_VAULT_V2_SPUSDC;

    // TODO: Replace with the final addresses, must match the spell.
    address internal constant SPPRIME_ADMIN             = address(1);
    address internal constant SPPRIME_PAUSER            = address(2);
    address internal constant SPPRIME_UNPAUSER          = address(3);
    address internal constant SPPRIME_OPERATOR          = address(4);
    address internal constant SPPRIME_REDEEM_FEE_SETTER = address(5);
    address internal constant SPPRIME_PAU_ADMIN         = address(7);
    address internal constant FLC_PAU_ADMIN             = address(8);

    SparkDeployOrchestration.Report internal report;

    address internal spell;

    address internal pauFactory;
    address internal spPrimeImplementation;
    address internal pasConfigurator;
    address internal lossManagerTimelock;

    address internal sparkPlannerAdministeredAgent;
    address internal sparkVaultsAdministeredAgent;

    ISparkPrimeVault internal spPrime;

    address internal spPrimePAUAccessControls;
    address internal spPrimePAUAlmProxy;
    address internal spPrimePAUController;
    address internal spPrimePAURateLimits;

    address internal flcPAUAccessControls;
    address internal flcPAUAlmProxy;
    address internal flcPAUController;
    address internal flcPAURateLimits;

    address internal user = makeAddr("user");

    function setUp() public virtual {
        vm.createSelectFork(getChain("mainnet").rpcUrl);

        pauFactory            = Ethereum.SPARK_PAU_FACTORY;
        spPrimeImplementation = Ethereum.SPPRIME_IMPL;

        report = SparkDeployOrchestration.deploy();

        spell = address(report.deploySpPrimePayload);

        pasConfigurator     = report.pasDeploymentReport.configurator;
        lossManagerTimelock = report.lossManagerTimelockDeploymentReport.lossManagerTimelock;
        spPrime             = ISparkPrimeVault(report.spPrimeDeploymentReport.spPrime);

        sparkPlannerAdministeredAgent = report.spPrimeDeploymentReport.sparkPlannerAdministeredAgent;
        sparkVaultsAdministeredAgent  = report.spPrimeDeploymentReport.sparkVaultsAdministeredAgent;

        spPrimePAUAccessControls = report.spPrimeDeploymentReport.spPrimePAUAccessControls;
        spPrimePAUAlmProxy       = report.spPrimeDeploymentReport.spPrimePAUAlmProxy;
        spPrimePAUController     = report.spPrimeDeploymentReport.spPrimePAUController;
        spPrimePAURateLimits     = report.spPrimeDeploymentReport.spPrimePAURateLimits;

        flcPAUAccessControls = report.spPrimeDeploymentReport.flcPAUAccessControls;
        flcPAUAlmProxy       = report.spPrimeDeploymentReport.flcPAUAlmProxy;
        flcPAUController     = report.spPrimeDeploymentReport.flcPAUController;
        flcPAURateLimits     = report.spPrimeDeploymentReport.flcPAURateLimits;

        vm.label(address(spell),           "spell");
        vm.label(pauFactory,               "pauFactory");
        vm.label(spPrimeImplementation,    "spPrime.implementation");
        vm.label(pasConfigurator,          "pas.configurator");
        vm.label(address(spPrime),         "spPrime");
        vm.label(spPrimePAUAccessControls, "spPrimePAU.accessControls");
        vm.label(spPrimePAUAlmProxy,       "spPrimePAU.almProxy");
        vm.label(spPrimePAUController,     "spPrimePAU.controller");
        vm.label(spPrimePAURateLimits,     "spPrimePAU.rateLimits");
        vm.label(flcPAUAccessControls,     "flcPAU.accessControls");
        vm.label(flcPAUAlmProxy,           "flcPAU.almProxy");
        vm.label(flcPAUController,         "flcPAU.controller");
        vm.label(flcPAURateLimits,         "flcPAU.rateLimits");
    }

    /**********************************************************************************************/
    /*** Helper Functions                                                                       ***/
    /**********************************************************************************************/

    function _deployedContracts() internal view returns (address[9] memory) {
        return [
            address(spPrime),
            spPrimePAUAccessControls,
            spPrimePAUAlmProxy,
            spPrimePAUController,
            spPrimePAURateLimits,
            flcPAUAccessControls,
            flcPAUAlmProxy,
            flcPAUController,
            flcPAURateLimits
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

    function _assertPAURoles(
        address controller,
        address accessControls,
        address almProxy,
        address rateLimits,
        address admin
    )
        internal view
    {
        // The controller acts through the ALMProxy and the RateLimits
        _assertOnlyMember(almProxy,   CONTROLLER_ROLE, controller);
        _assertOnlyMember(rateLimits, CONTROLLER_ROLE, controller);

        // The AdministeredAgent is the only allocator
        _assertOnlyMember(accessControls, ALLOCATOR_ROLE, sparkVaultsAdministeredAgent);

        // The PAU admin and the PAS Configurator administer the AccessControls and the RateLimits
        assertEq(IAccessControls(accessControls).getRoleMemberCount(DEFAULT_ADMIN_ROLE),       2);
        assertEq(IAccessControls(accessControls).hasRole(DEFAULT_ADMIN_ROLE, admin),           true);
        assertEq(IAccessControls(accessControls).hasRole(DEFAULT_ADMIN_ROLE, pasConfigurator), true);

        assertEq(IAccessControls(rateLimits).getRoleMemberCount(DEFAULT_ADMIN_ROLE),       2);
        assertEq(IAccessControls(rateLimits).hasRole(DEFAULT_ADMIN_ROLE, admin),           true);
        assertEq(IAccessControls(rateLimits).hasRole(DEFAULT_ADMIN_ROLE, pasConfigurator), true);

        // Only the PAU admin administers the ALMProxy
        _assertOnlyMember(almProxy, DEFAULT_ADMIN_ROLE, admin);
    }

    function _assertIntegrations(address controller, bytes32[] memory ids) internal view {
        assertEq(IController(controller).integrations().length, ids.length);

        for (uint256 i; i < ids.length; ++i) {
            IEnumerableIntegrations.Config memory expected = IBeacon(PAU_BEACON).getConfig(ids[i]);
            IEnumerableIntegrations.Config memory actual   = IController(controller).getConfig(ids[i]);

            assertNotEq(expected.facet, address(0));

            assertEq(actual.facet,        expected.facet);
            assertEq(actual.wires.length, expected.wires.length);

            for (uint256 j; j < expected.wires.length; ++j) {
                assertEq(actual.wires[j].callSelector,     expected.wires[j].callSelector);
                assertEq(actual.wires[j].delegateSelector, expected.wires[j].delegateSelector);

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
    }

    function _assertOnlyMember(address target, bytes32 role, address account) internal view {
        assertEq(IAccessControls(target).getRoleMemberCount(role), 1);
        assertEq(IAccessControls(target).hasRole(role, account),   true);
    }

}

contract SparkEthereumDeploySpPrimeTest_SpellPayload is SparkEthereumDeploySpPrimeTestBase {

    function test_spell_invalidChainId() external {
        vm.chainId(2);

        vm.expectRevert("SparkEthereumDeploySpPrime/invalid-chain-id");
        new SparkEthereumDeploySpPrime(pasConfigurator, lossManagerTimelock);
    }

    function test_spell_noPASConfigurator() external {
        vm.expectRevert("SparkEthereumDeploySpPrime/no-pas-configurator");
        new SparkEthereumDeploySpPrime(makeAddr("pasConfigurator"), lossManagerTimelock);
    }

    function test_spell_noPAUBeacon() external {
        vm.etch(PAU_BEACON, "");

        vm.expectRevert("SparkEthereumDeploySpPrime/no-pau-beacon");
        new SparkEthereumDeploySpPrime(pasConfigurator, lossManagerTimelock);
    }

    function test_spell_deployedAddresses() external view {
        address[9] memory deployed = _deployedContracts();

        for (uint256 i; i < deployed.length; ++i) {
            assertGt(deployed[i].code.length, 0);

            for (uint256 j = i + 1; j < deployed.length; ++j) {
                assertNotEq(deployed[i], deployed[j]);
            }
        }

        IPAUFactory factory = IPAUFactory(pauFactory);

        assertEq(factory.isAccessControls(spPrimePAUAccessControls), true);
        assertEq(factory.isALMProxy(spPrimePAUAlmProxy),             true);
        assertEq(factory.isController(spPrimePAUController),         true);
        assertEq(factory.isRateLimits(spPrimePAURateLimits),         true);

        assertEq(factory.isAccessControls(flcPAUAccessControls), true);
        assertEq(factory.isALMProxy(flcPAUAlmProxy),             true);
        assertEq(factory.isController(flcPAUController),         true);
        assertEq(factory.isRateLimits(flcPAURateLimits),         true);
    }

    function test_spell_holdsNoRoles() external view {
        address[9] memory deployed = _deployedContracts();

        bytes32[9] memory roles = [
            DEFAULT_ADMIN_ROLE,
            ALLOCATOR_ROLE,
            CONTROLLER_ROLE,
            spPrime.PAUSER_ROLE(),
            spPrime.UNPAUSER_ROLE(),
            spPrime.OPERATOR_ROLE(),
            spPrime.REDEEM_FEE_SETTER_ROLE(),
            spPrime.LOSS_MANAGER_ROLE(),
            spPrime.TAKER_ROLE()
        ];

        for (uint256 i; i < deployed.length; ++i) {
            // Controllers are not role based access controlled
            if (deployed[i] == spPrimePAUController || deployed[i] == flcPAUController) continue;

            for (uint256 j; j < roles.length; ++j) {
                assertEq(IAccessControls(deployed[i]).hasRole(roles[j], address(spell)), false);
            }
        }
    }

}

contract SparkEthereumDeploySpPrime_spPrime is SparkEthereumDeploySpPrimeTestBase {

    function test_spPrime_proxy() external view {
        assertEq(address(uint160(uint256(vm.load(address(spPrime), IMPLEMENTATION_SLOT)))), spPrimeImplementation);
    }

    function test_spPrime_initialState() external view {
        assertEq(spPrime.savings(),  SPUSDC);
        assertEq(spPrime.asset(),    Ethereum.USDC);
        assertEq(spPrime.name(),     "Spark Prime USDC");
        assertEq(spPrime.symbol(),   "spPrime");
        assertEq(spPrime.decimals(), 6);

        assertEq(spPrime.minDeposit(),             1_000e6);
        assertEq(spPrime.minDepositCancellation(), 1_000e6);
        assertEq(spPrime.minRedeem(),              1_000e6);

        assertEq(spPrime.chi(), 1e27);
        assertEq(spPrime.rho(), block.timestamp);
        assertEq(spPrime.vsr(), 1e27);

        assertEq(spPrime.maxCapacity(),   0);
        assertEq(spPrime.redeemFeeRate(), 0);
        assertEq(spPrime.totalSupply(),   0);

        assertEq(spPrime.paused(), false);

        assertEq(IERC20Like(Ethereum.USDC).allowance(address(spPrime), SPUSDC), type(uint256).max);
    }

    function test_spPrime_configuration() external view {
        assertEq(spPrime.minVSR(),           1e27);
        assertEq(spPrime.maxVSR(),           1e27);
        assertEq(spPrime.maxRedeemFeeRate(), 1);
    }

    function test_spPrime_roles() external view {
        _assertOnlyMember(address(spPrime), DEFAULT_ADMIN_ROLE,               SPPRIME_ADMIN);
        _assertOnlyMember(address(spPrime), spPrime.PAUSER_ROLE(),            SPPRIME_PAUSER);
        _assertOnlyMember(address(spPrime), spPrime.UNPAUSER_ROLE(),          SPPRIME_UNPAUSER);
        _assertOnlyMember(address(spPrime), spPrime.OPERATOR_ROLE(),          SPPRIME_OPERATOR);
        _assertOnlyMember(address(spPrime), spPrime.REDEEM_FEE_SETTER_ROLE(), SPPRIME_REDEEM_FEE_SETTER);
        _assertOnlyMember(address(spPrime), spPrime.LOSS_MANAGER_ROLE(),      lossManagerTimelock);
        _assertOnlyMember(address(spPrime), spPrime.TAKER_ROLE(),             spPrimePAUAlmProxy);
    }

}

contract SparkEthereumDeploySpPrimeTest_spPrimePAU is SparkEthereumDeploySpPrimeTestBase {

    function test_spPrimePAU_wiring() external view {
        _assertWiring(spPrimePAUController, spPrimePAUAccessControls, spPrimePAUAlmProxy, spPrimePAURateLimits);
    }

    function test_spPrimePAU_roles() external view {
        _assertPAURoles(
            spPrimePAUController,
            spPrimePAUAccessControls,
            spPrimePAUAlmProxy,
            spPrimePAURateLimits,
            SPPRIME_PAU_ADMIN
        );
    }

    function test_spPrimePAU_integrations() external view {
        bytes32[] memory ids = new bytes32[](3);
        ids[0] = "TRANSFER_ASSET_FACET";
        ids[1] = "ERC4626_FACET";
        ids[2] = "SPARK_VAULT_FACET";

        _assertIntegrations(spPrimePAUController, ids);
    }

    function test_spPrimePAU_rateLimits() external view {
        _assertRateLimit(
            spPrimePAURateLimits,
            ITransferAssetController(spPrimePAUController).transferAsset_getTransferRateLimitKey(SPUSDC, address(spPrime)),
            100_000_000e6,
            0
        );
        _assertRateLimit(
            spPrimePAURateLimits,
            IERC4626Controller(spPrimePAUController).erc4626_getDepositRateLimitKey(SPUSDC, Ethereum.USDC),
            0,
            0
        );
        _assertRateLimit(
            spPrimePAURateLimits,
            IERC4626Controller(spPrimePAUController).erc4626_getWithdrawRateLimitKey(SPUSDC),
            0,
            0
        );
        _assertRateLimit(
            spPrimePAURateLimits,
            ISparkVaultController(spPrimePAUController).sparkVault_getTakeRateLimitKey(address(spPrime)),
            100_000_000e6,
            0
        );
    }

    function test_spPrimePAU_maxExchangeRate() external view {
        IERC4626Controller controller = IERC4626Controller(spPrimePAUController);

        // 1 spUSDC share (1e6) is worth at most 10 USDC (10e6)
        assertEq(
            controller.erc4626_getMaxExchangeRate(SPUSDC),
            10e6 * controller.erc4626_EXCHANGE_RATE_PRECISION() / 1e6
        );
    }

}

contract SparkDeploymentsEthereumSpPrimeTest_flcPAU is SparkEthereumDeploySpPrimeTestBase {

    function test_flcPAU_wiring() external view {
        _assertWiring(flcPAUController, flcPAUAccessControls, flcPAUAlmProxy, flcPAURateLimits);
    }

    function test_flcPAU_roles() external view {
        _assertPAURoles(flcPAUController, flcPAUAccessControls, flcPAUAlmProxy, flcPAURateLimits, FLC_PAU_ADMIN);
    }

    function test_flcPAU_integrations() external view {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = "TRANSFER_ASSET_FACET";

        _assertIntegrations(flcPAUController, ids);
    }

    function test_flcPAU_rateLimits() external view {
        _assertRateLimit(
            flcPAURateLimits,
            ITransferAssetController(flcPAUController).transferAsset_getTransferRateLimitKey(SPUSDC, spPrimePAUAlmProxy),
            100_000_000e6,
            0
        );
    }

}

contract SparkDeploymentsEthereumSpPrimeTest_E2E is SparkEthereumDeploySpPrimeTestBase {

    uint256 internal constant VAULT_CAPACITY = 100_000_000e6;

    function setUp() public override {
        super.setUp();

        vm.label(user, "user");

        _setCapacity(VAULT_CAPACITY);
    }

    function test_spPrime_depositAndRedeem() external {
        _requestDeposit(user, 10_000e6);

        uint256 shares = spPrime.balanceOf(user);

        assertGt(shares,                                         0);
        assertGt(IERC20Like(SPUSDC).balanceOf(address(spPrime)), 0);

        _requestRedeem(user, shares);

        _processPendingRedeems();

        assertApproxEqAbs(IERC20Like(Ethereum.USDC).balanceOf(user), 10_000e6, 2);

        assertEq(spPrime.balanceOf(user),         0);
        assertEq(spPrime.claimableAssetsOf(user), 0);
    }

    function _setCapacity(uint256 capacity) internal {
        vm.prank(SPPRIME_OPERATOR);
        spPrime.setCapacity(capacity);
    }

    function _requestDeposit(address account, uint256 assets) internal returns (uint256 requestId) {
        deal(Ethereum.USDC, account, assets);

        vm.startPrank(account);
        IERC20Like(Ethereum.USDC).approve(address(spPrime), assets);
        requestId = spPrime.requestDeposit(assets, account, 0);
        vm.stopPrank();
    }

    function _requestRedeem(address account, uint256 shares) internal returns (uint256 requestId) {
        vm.prank(account);
        return spPrime.requestRedeem(shares, account);
    }

    function _processPendingRedeems() internal {
        vm.prank(SPPRIME_OPERATOR);
        spPrime.processPendingRedeems(type(uint256).max, type(uint256).max);
    }

}
