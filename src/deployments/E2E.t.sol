// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "../../lib/forge-std/src/Test.sol";

import { Bridge }                 from "../../lib/xchain-helpers/src/testing/Bridge.sol";
import { Domain, DomainHelpers }  from "../../lib/xchain-helpers/src/testing/Domain.sol";
import { LZBridgeTesting }        from "../../lib/xchain-helpers/src/testing/bridges/LZBridgeTesting.sol";

import { Arbitrum }                from "../../lib/spark-address-registry/src/Arbitrum.sol";
import { Ethereum }                from "../../lib/spark-address-registry/src/Ethereum.sol";
import { Ethereum as SkyEthereum } from "../../lib/sky-pau-registry/src/Ethereum.sol";

import { IALMProxy }   from "../../lib/diamond-pau/src/interfaces/IALMProxy.sol";
import { IController } from "../../lib/diamond-pau/src/interfaces/IController.sol";
import { IPAUFactory } from "../../lib/diamond-pau/src/interfaces/IPAUFactory.sol";
import { IRateLimits } from "../../lib/diamond-pau/src/interfaces/IRateLimits.sol";

import { BeaconConfig } from "../../lib/diamond-pau/src/libraries/BeaconConfig.sol";

import { IERC4626Controller }       from "../../lib/diamond-pau/src/facets/erc4626/IERC4626Controller.sol";
import { ILayerZeroController }     from "../../lib/diamond-pau/src/facets/layer-zero/ILayerZeroController.sol";
import { ILayerZeroFacet }          from "../../lib/diamond-pau/src/facets/layer-zero/ILayerZeroFacet.sol";
import { ISparkVaultController }    from "../../lib/diamond-pau/src/facets/spark-vault/ISparkVaultController.sol";
import { ISwapAssetController }     from "../../lib/diamond-pau/src/facets/swap-asset/ISwapAssetController.sol";
import { ITransferAssetController } from "../../lib/diamond-pau/src/facets/transfer-asset/ITransferAssetController.sol";

import { EthereumSparkSpUSDTPayload } from "./20261116-mainnet-spark-spusdt/EthereumSparkSpUSDTPayload.sol";
import { ArbitrumSparkSpUSDTPayload } from "./20261117-arbitrum-spark-spUSDT/ArbitrumSparkSpUSDTPayload.sol";

interface IAdministeredAgentLike {

    function call(address target, bytes memory data) external payable returns (bytes memory result);

}

// No return value on approve, so it also works with USDT.
interface IERC20Like {

    function approve(address spender, uint256 amount) external;

    function balanceOf(address account) external view returns (uint256);

    function totalSupply() external view returns (uint256);

}

interface IERC4626Like is IERC20Like {

    function convertToAssets(uint256 shares) external view returns (uint256);

    function convertToShares(uint256 assets) external view returns (uint256);

    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    function totalAssets() external view returns (uint256);

}

interface ISparkVaultLike is IERC4626Like {

    function TAKER_ROLE() external view returns (bytes32);

    function grantRole(bytes32 role, address account) external;

}

interface IEthSllController is IController, ISwapAssetController {}

interface IEthSpUSDTController is
    IController,
    IERC4626Controller,
    ILayerZeroController,
    ISparkVaultController,
    ISwapAssetController,
    ITransferAssetController
{}

interface IArbSpUSDTController is IController, ILayerZeroController, ISparkVaultController, ITransferAssetController {}

abstract contract E2ETestBase is Test {

    using DomainHelpers   for *;
    using LZBridgeTesting for *;

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    uint32 internal constant LZ_ETHEREUM_EID = 30101;
    uint32 internal constant LZ_ARBITRUM_EID = 30110;

    // Salts used by the Deploy scripts of each payload
    bytes32 internal constant ETH_PAYLOAD_SALT = keccak256("spark.eth.spUSDTPAUPayload");
    bytes32 internal constant ARB_PAYLOAD_SALT = keccak256("spark.arb.spUSDTPAUPayload");

    address internal constant EXPECTED_ETH_SPUSDT_PAYLOAD = 0xC88BB7CdB6AE8045b197F44c6DfDf038b564CC38;
    address internal constant EXPECTED_ARB_SPUSDT_PAYLOAD = 0x6Eb39C6c124033DcFe8Ce608C0565eE0c2dE3942;

    /**********************************************************************************************/
    /*** Domains and bridges                                                                    ***/
    /**********************************************************************************************/

    Domain internal mainnet;
    Domain internal arbitrum;

    // Source is Arbitrum, destination is Ethereum
    Bridge internal lzBridge;

    /**********************************************************************************************/
    /*** Ethereum deployments                                                                   ***/
    /**********************************************************************************************/

    IAdministeredAgentLike internal ethPlannerAgent;
    IAdministeredAgentLike internal ethSparkAgent;
    IAdministeredAgentLike internal ethSllAgent;

    address internal ethSllPAU_accessControls;

    IEthSllController internal ethSllPAU_controller;
    IRateLimits       internal ethSllPAU_rateLimits;

    address internal ethSpUSDTPAU_accessControls;
    address internal ethSpUSDTPAU_almProxy;

    IEthSpUSDTController internal ethSpUSDTPAU_controller;
    IRateLimits          internal ethSpUSDTPAU_rateLimits;

    /**********************************************************************************************/
    /*** Arbitrum deployments                                                                   ***/
    /**********************************************************************************************/

    IAdministeredAgentLike internal arbPlannerAgent;
    IAdministeredAgentLike internal arbSparkAgent;

    address internal arbSpUSDTPAU_accessControls;
    address internal arbSpUSDTPAU_almProxy;

    IArbSpUSDTController internal arbSpUSDTPAU_controller;
    IRateLimits          internal arbSpUSDTPAU_rateLimits;

    /**********************************************************************************************/
    /*** Test addresses and ratelimit keys                                                      ***/
    /**********************************************************************************************/

    address internal user = makeAddr("user");

    IERC20Like internal usdt  = IERC20Like(Ethereum.USDT);
    IERC20Like internal usds  = IERC20Like(Ethereum.USDS);
    IERC20Like internal usdt0 = IERC20Like(Arbitrum.USDT0);

    IERC4626Like internal susds = IERC4626Like(Ethereum.SUSDS);

    ISparkVaultLike internal ethSpUSDT = ISparkVaultLike(Ethereum.SPARK_VAULT_V2_SPUSDT);
    ISparkVaultLike internal arbSpUSDT = ISparkVaultLike(Arbitrum.SPARK_VAULT_V2_SPUSDT);

    bytes32 internal ethTakeKey;
    bytes32 internal ethTransferKey;
    bytes32 internal ethLayerZeroKey;
    bytes32 internal ethERC4626DepositKey;
    bytes32 internal ethERC4626WithdrawKey;
    bytes32 internal sllSwapInitiateUSDSKey;
    bytes32 internal sllSwapInitiateUSDTKey;
    bytes32 internal ethSwapCompleteUSDTKey;
    bytes32 internal ethSwapCompleteUSDSKey;

    bytes32 internal arbTakeKey;
    bytes32 internal arbTransferKey;
    bytes32 internal arbLayerZeroKey;

    /**********************************************************************************************/
    /*** Setup                                                                                  ***/
    /**********************************************************************************************/

    function setUp() public virtual {
        mainnet  = getChain("mainnet").createFork(26483696);       // Nov-24-2026 08:03:35 AM +UTC
        arbitrum = getChain("arbitrum_one").createFork(527055621); // Nov-24-2026 07:50:26 AM +UTC

        // Step 1: Deploy the Ethereum payload

        mainnet.selectFork();

        // Deployed through the CREATE2 factory with the Deploy script's salt, so the spUSDT ALM Proxy is the
        // Ethereum LayerZero recipient set by the Arbitrum payload.
        address ethPayload = _deployWithCreate2(ETH_PAYLOAD_SALT, type(EthereumSparkSpUSDTPayload).creationCode);

        assertEq(ethPayload, EXPECTED_ETH_SPUSDT_PAYLOAD, "E2ETestBase/EthereumSparkSpUSDTPayload-address-mismatch");

        EthereumSparkSpUSDTPayload.Report memory ethReport = EthereumSparkSpUSDTPayload(ethPayload).report();

        ethPlannerAgent = IAdministeredAgentLike(ethReport.plannerAgent);
        ethSparkAgent   = IAdministeredAgentLike(ethReport.sparkAgent);
        ethSllAgent     = IAdministeredAgentLike(ethReport.sllAgent);

        ethSllPAU_accessControls = ethReport.sllPAU_accessControls;
        ethSllPAU_controller     = IEthSllController(ethReport.sllPAU_controller);
        ethSllPAU_rateLimits     = IRateLimits(ethReport.sllPAU_rateLimits);

        ethSpUSDTPAU_accessControls = ethReport.spUSDTPAU_accessControls;
        ethSpUSDTPAU_almProxy       = ethReport.spUSDTPAU_almProxy;
        ethSpUSDTPAU_controller     = IEthSpUSDTController(ethReport.spUSDTPAU_controller);
        ethSpUSDTPAU_rateLimits     = IRateLimits(ethReport.spUSDTPAU_rateLimits);

        // Step 2: Deploy the Arbitrum payload. The Arbitrum Beacon payload already executed on-chain.

        arbitrum.selectFork();

        // Making sure the Arbitrum Beacon payload was already executed on-chain.
        assertEq(IPAUFactory(Arbitrum.SPARK_PAU_FACTORY).beacon(), Arbitrum.SPARK_BEACON);

        address arbPayload = _deployWithCreate2(ARB_PAYLOAD_SALT, type(ArbitrumSparkSpUSDTPayload).creationCode);

        assertEq(arbPayload, EXPECTED_ARB_SPUSDT_PAYLOAD, "E2ETestBase/ArbitrumSparkSpUSDTPayload-address-mismatch");

        ArbitrumSparkSpUSDTPayload.Report memory arbReport = ArbitrumSparkSpUSDTPayload(arbPayload).report();

        arbPlannerAgent = IAdministeredAgentLike(arbReport.plannerAgent);
        arbSparkAgent   = IAdministeredAgentLike(arbReport.sparkAgent);

        arbSpUSDTPAU_accessControls = arbReport.spUSDTPAU_accessControls;
        arbSpUSDTPAU_almProxy       = arbReport.spUSDTPAU_almProxy;
        arbSpUSDTPAU_controller     = IArbSpUSDTController(arbReport.spUSDTPAU_controller);
        arbSpUSDTPAU_rateLimits     = IRateLimits(arbReport.spUSDTPAU_rateLimits);

        // The Arbitrum payload sends USDT0 to the Ethereum spUSDT ALM Proxy deployed above.
        assertEq(
            arbSpUSDTPAU_controller.layerZero_getRecipient(LZ_ETHEREUM_EID),
            bytes32(uint256(uint160(ethSpUSDTPAU_almProxy)))
        );

        // Step 3: Create the LayerZero bridge

        lzBridge = LZBridgeTesting.createLZBridge(arbitrum, mainnet);

        // Step 4: Execute the Sky spell

        _skySpell20261203();

        // Step 5: Execute the Spark spell

        _sparkSpell20261203();

        // Step 6: Assign ratelimit keys

        _assignRatelimitKeys();

        // Step 7: Labels

        vm.label(address(ethPlannerAgent),         "eth.plannerAgent");
        vm.label(address(ethSparkAgent),           "eth.sparkAgent");
        vm.label(address(ethSllAgent),             "eth.sllAgent");
        vm.label(ethSllPAU_accessControls,         "eth.sllPAU.accessControls");
        vm.label(address(ethSllPAU_controller),    "eth.sllPAU.controller");
        vm.label(address(ethSllPAU_rateLimits),    "eth.sllPAU.rateLimits");
        vm.label(ethSpUSDTPAU_accessControls,      "eth.spUSDTPAU.accessControls");
        vm.label(ethSpUSDTPAU_almProxy,            "eth.spUSDTPAU.almProxy");
        vm.label(address(ethSpUSDTPAU_controller), "eth.spUSDTPAU.controller");
        vm.label(address(ethSpUSDTPAU_rateLimits), "eth.spUSDTPAU.rateLimits");
        vm.label(Ethereum.ALM_PROXY,               "eth.sllPAU.almProxy");
        vm.label(Ethereum.SPARK_PROXY,             "eth.sparkProxy");
        vm.label(Ethereum.SPARK_VAULT_V2_SPUSDT,   "eth.spUSDT");
        vm.label(Ethereum.USDT_OFT,                "eth.usdtOFT");
        vm.label(address(arbPlannerAgent),         "arb.plannerAgent");
        vm.label(address(arbSparkAgent),           "arb.sparkAgent");
        vm.label(arbSpUSDTPAU_accessControls,      "arb.spUSDTPAU.accessControls");
        vm.label(arbSpUSDTPAU_almProxy,            "arb.spUSDTPAU.almProxy");
        vm.label(address(arbSpUSDTPAU_controller), "arb.spUSDTPAU.controller");
        vm.label(address(arbSpUSDTPAU_rateLimits), "arb.spUSDTPAU.rateLimits");
        vm.label(Arbitrum.SPARK_EXECUTOR,          "arb.sparkExecutor");
        vm.label(Arbitrum.SPARK_VAULT_V2_SPUSDT,   "arb.spUSDT");
        vm.label(Arbitrum.USDT_OFT,                "arb.usdtOFT");

        mainnet.selectFork();
    }

    /**********************************************************************************************/
    /*** Internal helpers                                                                       ***/
    /**********************************************************************************************/

    // Deploys `creationCode` through the CREATE2 factory, as the Deploy scripts do when broadcasting.
    function _deployWithCreate2(bytes32 salt, bytes memory creationCode) internal returns (address deployed) {
        deployed = vm.computeCreate2Address(salt, keccak256(creationCode));

        ( bool success, ) = CREATE2_FACTORY.call(abi.encodePacked(salt, creationCode));

        assertTrue(success);
        assertGt(deployed.code.length, 0);
    }

    function _assignRatelimitKeys() internal {
        mainnet.selectFork();

        ethTakeKey = ethSpUSDTPAU_controller.sparkVault_getTakeRateLimitKey({ sparkVault: address(ethSpUSDT) });

        ethTransferKey = ethSpUSDTPAU_controller.transferAsset_getTransferRateLimitKey({
            asset       : Ethereum.USDT,
            destination : address(ethSpUSDT)
        });

        ethLayerZeroKey = ethSpUSDTPAU_controller.layerZero_getTransferRateLimitKey({
            oft                   : Ethereum.USDT_OFT,
            peer                  : bytes32(uint256(uint160(Arbitrum.USDT_OFT))),
            destinationEndpointId : LZ_ARBITRUM_EID,
            token                 : Ethereum.USDT
        });

        ethERC4626DepositKey = ethSpUSDTPAU_controller.erc4626_getDepositRateLimitKey({
            token : Ethereum.SUSDS,
            asset : Ethereum.USDS
        });
        ethERC4626WithdrawKey = ethSpUSDTPAU_controller.erc4626_getWithdrawRateLimitKey({ token: Ethereum.SUSDS });

        sllSwapInitiateUSDSKey = ethSllPAU_controller.swapAsset_getInitiateSwapRateLimitKey({
            assetOut               : Ethereum.USDS,
            counterpartyProxy      : ethSpUSDTPAU_almProxy,
            counterpartyController : address(ethSpUSDTPAU_controller),
            assetIn                : Ethereum.USDT
        });
        sllSwapInitiateUSDTKey = ethSllPAU_controller.swapAsset_getInitiateSwapRateLimitKey({
            assetOut               : Ethereum.USDT,
            counterpartyProxy      : ethSpUSDTPAU_almProxy,
            counterpartyController : address(ethSpUSDTPAU_controller),
            assetIn                : Ethereum.USDS
        });

        ethSwapCompleteUSDTKey = ethSpUSDTPAU_controller.swapAsset_getCompleteSwapRateLimitKey({
            assetOut          : Ethereum.USDT,
            counterpartyProxy : Ethereum.ALM_PROXY,
            assetIn           : Ethereum.USDS
        });
        ethSwapCompleteUSDSKey = ethSpUSDTPAU_controller.swapAsset_getCompleteSwapRateLimitKey({
            assetOut          : Ethereum.USDS,
            counterpartyProxy : Ethereum.ALM_PROXY,
            assetIn           : Ethereum.USDT
        });

        arbitrum.selectFork();

        arbTakeKey = arbSpUSDTPAU_controller.sparkVault_getTakeRateLimitKey({ sparkVault: address(arbSpUSDT) });

        arbTransferKey = arbSpUSDTPAU_controller.transferAsset_getTransferRateLimitKey({
            asset       : Arbitrum.USDT0,
            destination : address(arbSpUSDT)
        });

        arbLayerZeroKey = arbSpUSDTPAU_controller.layerZero_getTransferRateLimitKey({
            oft                   : Arbitrum.USDT_OFT,
            peer                  : bytes32(uint256(uint160(Ethereum.USDT_OFT))),
            destinationEndpointId : LZ_ETHEREUM_EID,
            token                 : Arbitrum.USDT0
        });
    }

    function _skySpell20261203() internal {
        mainnet.selectFork();

        // Onboard the SwapAssetFacet for SLL PAU

        vm.prank(Ethereum.PAUSE_PROXY);
        BeaconConfig.setSwapAssetIntegration(SkyEthereum.BEACON, SkyEthereum.SWAP_ASSET_FACET);
    }

    // NOTE: Executes only the subset of upcoming spell that is relevant to the E2E test.
    function _sparkSpell20261203() internal {
        // ETHEREUM

        mainnet.selectFork();
        vm.startPrank(Ethereum.SPARK_PROXY);

        // Step 1: Onboard the LayerZero and SwapAsset integrations on the Ethereum Beacon

        BeaconConfig.setLayerZeroIntegration(Ethereum.SPARK_BEACON, Ethereum.LAYERZERO_FACET);
        BeaconConfig.setSwapAssetIntegration(Ethereum.SPARK_BEACON, Ethereum.SWAP_ASSET_FACET);

        // Step 2: SLL PAU, grant CONTROLLER on the SLL ALM Proxy and onboard SwapAsset only

        IALMProxy(Ethereum.ALM_PROXY).grantRole(IALMProxy(Ethereum.ALM_PROXY).CONTROLLER(), address(ethSllPAU_controller));

        bytes32[] memory ethSllPAUIntegrationIds = new bytes32[](1);
        ethSllPAUIntegrationIds[0] = "SWAP_ASSET_FACET";

        ethSllPAU_controller.updateIntegrations(ethSllPAUIntegrationIds); // Consumes from Sky Beacon

        // Step 3: spUSDT PAU, onboard LayerZero and SwapAsset

        bytes32[] memory spUSDTIntegrationIds = new bytes32[](2);
        spUSDTIntegrationIds[0] = "LAYER_ZERO_FACET";
        spUSDTIntegrationIds[1] = "SWAP_ASSET_FACET";

        ethSpUSDTPAU_controller.updateIntegrations(spUSDTIntegrationIds);

        // Step 4: Set the LayerZero recipient on Ethereum to the Arbitrum spUSDT ALM Proxy

        ethSpUSDTPAU_controller.layerZero_setRecipient(
            LZ_ARBITRUM_EID,
            bytes32(uint256(uint160(arbSpUSDTPAU_almProxy)))
        );

        // Step 5: Grant spUSDT TAKER_ROLE to the Ethereum spUSDT ALM Proxy

        ISparkVaultLike(Ethereum.SPARK_VAULT_V2_SPUSDT).grantRole(
            ISparkVaultLike(Ethereum.SPARK_VAULT_V2_SPUSDT).TAKER_ROLE(),
            ethSpUSDTPAU_almProxy
        );

        vm.stopPrank();

        // ARBITRUM

        arbitrum.selectFork();
        vm.startPrank(Arbitrum.SPARK_EXECUTOR);

        // Step 6: Grant spUSDT TAKER_ROLE to the Arbitrum spUSDT ALM Proxy

        ISparkVaultLike(Arbitrum.SPARK_VAULT_V2_SPUSDT).grantRole(
            ISparkVaultLike(Arbitrum.SPARK_VAULT_V2_SPUSDT).TAKER_ROLE(),
            arbSpUSDTPAU_almProxy
        );

        vm.stopPrank();
    }

}

contract E2ETest is E2ETestBase {

    using DomainHelpers   for *;
    using LZBridgeTesting for *;

    function setUp() public override {
        super.setUp();

        mainnet.selectFork();

        // The SLL ALMProxy holds no idle USDS or USDT at the fork block, it needs both to complete the swaps.
        deal(Ethereum.USDS, Ethereum.ALM_PROXY, 2_000_000e18);
        deal(Ethereum.USDT, Ethereum.ALM_PROXY, 2_000_000e6);

        // spUSDT VSR (~4.25%) accrues faster than the sUSDS yield, so the strategy alone does not cover what
        // both users are owed after 1 day. This buffer funds the difference.
        deal(Ethereum.USDT, ethSpUSDTPAU_almProxy, 100e6);

        deal(Ethereum.USDT, user, 1_000_000e6);

        deal(Ethereum.PLANNER_WALLET, 1 ether); // For LayerZero fees

        arbitrum.selectFork();

        deal(Arbitrum.USDT0, user, 1_000_000e6);

        deal(Ethereum.PLANNER_WALLET, 1 ether); // For LayerZero fees
    }

    function test_e2e_ETHEREUM_ARBITRUM_full_flow() external {
        // Step 1: User deposits 1_000_000e6 USDT to the Ethereum spUSDT vault

        mainnet.selectFork();

        assertEq(usdt.balanceOf(user),               1_000_000e6);
        assertEq(usdt.balanceOf(address(ethSpUSDT)), 80_411_526.179333e6);

        assertEq(ethSpUSDT.totalAssets(),   274_809_487.118084e6);
        assertEq(ethSpUSDT.totalSupply(),   264_788_091.008152e6);
        assertEq(ethSpUSDT.balanceOf(user), 0);

        vm.startPrank(user);
        usdt.approve(address(ethSpUSDT), 1_000_000e6);
        ethSpUSDT.deposit(1_000_000e6, user);
        vm.stopPrank();

        assertEq(usdt.balanceOf(user),               0);
        assertEq(usdt.balanceOf(address(ethSpUSDT)), 81_411_526.179333e6);

        assertEq(ethSpUSDT.totalAssets(),   275_809_487.118083e6);
        assertEq(ethSpUSDT.totalSupply(),   265_751_624.304563e6);
        assertEq(ethSpUSDT.balanceOf(user), 963_533.296411e6);

        // Step 2: User deposits 1_000_000e6 USDT to the Arbitrum spUSDT vault

        arbitrum.selectFork();

        assertEq(usdt0.balanceOf(user),               1_000_000e6);
        assertEq(usdt0.balanceOf(address(arbSpUSDT)), 1_053_061.636344e6);

        assertEq(arbSpUSDT.totalAssets(),   1_055_060.177745e6);
        assertEq(arbSpUSDT.totalSupply(),   1_042_258.252025e6);
        assertEq(arbSpUSDT.balanceOf(user), 0);

        vm.startPrank(user);
        usdt0.approve(address(arbSpUSDT), 1_000_000e6);
        arbSpUSDT.deposit(1_000_000e6, user);
        vm.stopPrank();

        assertEq(usdt0.balanceOf(user),               0);
        assertEq(usdt0.balanceOf(address(arbSpUSDT)), 2_053_061.636344e6);

        assertEq(arbSpUSDT.totalAssets(),   2_055_060.177744e6);
        assertEq(arbSpUSDT.totalSupply(),   2_030_124.417396e6);
        assertEq(arbSpUSDT.balanceOf(user), 987_866.165371e6);

        // Step 3: ethSparkAgent (ethPlannerAgent) takes 1_000_000e6 USDT out of Ethereum spUSDT vault

        mainnet.selectFork();

        assertEq(ethSpUSDTPAU_rateLimits.getCurrentRateLimit(ethTakeKey), 10_000_000e6);

        assertEq(usdt.balanceOf(address(ethSpUSDT)),    81_411_526.179333e6);
        assertEq(usdt.balanceOf(ethSpUSDTPAU_almProxy), 100e6);

        vm.prank(Ethereum.PLANNER_WALLET);
        ethPlannerAgent.call(
            address(ethSparkAgent),
            abi.encodeCall(
                IAdministeredAgentLike.call,
                (
                    address(ethSpUSDTPAU_controller),
                    abi.encodeCall(ISparkVaultController.sparkVault_take, (address(ethSpUSDT), 1_000_000e6))
                )
            )
        );

        assertEq(ethSpUSDTPAU_rateLimits.getCurrentRateLimit(ethTakeKey), 10_000_000e6 - 1_000_000e6);

        assertEq(usdt.balanceOf(address(ethSpUSDT)),    80_411_526.179333e6);
        assertEq(usdt.balanceOf(ethSpUSDTPAU_almProxy), 1_000_100e6);

        // Taking moves idle liquidity out, it does not change the vault's accounting.
        assertEq(ethSpUSDT.totalAssets(), 275_809_487.118083e6);
        assertEq(ethSpUSDT.totalSupply(), 265_751_624.304563e6);

        // Step 4: arbSparkAgent (arbPlannerAgent) takes 1_000_000e6 USDT out of Arbitrum spUSDT vault

        arbitrum.selectFork();

        assertEq(arbSpUSDTPAU_rateLimits.getCurrentRateLimit(arbTakeKey), 10_000_000e6);

        assertEq(usdt0.balanceOf(address(arbSpUSDT)),    2_053_061.636344e6);
        assertEq(usdt0.balanceOf(arbSpUSDTPAU_almProxy), 0);

        vm.prank(Ethereum.PLANNER_WALLET);
        arbPlannerAgent.call(
            address(arbSparkAgent),
            abi.encodeCall(
                IAdministeredAgentLike.call,
                (
                    address(arbSpUSDTPAU_controller),
                    abi.encodeCall(ISparkVaultController.sparkVault_take, (address(arbSpUSDT), 1_000_000e6))
                )
            )
        );

        assertEq(arbSpUSDTPAU_rateLimits.getCurrentRateLimit(arbTakeKey), 10_000_000e6 - 1_000_000e6);

        assertEq(usdt0.balanceOf(address(arbSpUSDT)),    1_053_061.636344e6);
        assertEq(usdt0.balanceOf(arbSpUSDTPAU_almProxy), 1_000_000e6);

        assertEq(arbSpUSDT.totalAssets(), 2_055_060.177744e6);
        assertEq(arbSpUSDT.totalSupply(), 2_030_124.417396e6);

        // Step 5: arbSparkAgent (arbPlannerAgent) bridges 1_000_000e6 USDT to Ethereum spUSDT PAU using LayerZeroFacet

        assertEq(arbSpUSDTPAU_rateLimits.getCurrentRateLimit(arbLayerZeroKey), 5_000_000e6);

        assertEq(usdt0.balanceOf(arbSpUSDTPAU_almProxy), 1_000_000e6);
        assertEq(usdt0.totalSupply(),                    1_121_489_900.354792e6);

        ( , ILayerZeroFacet.MessagingFee memory arbFee ) = arbSpUSDTPAU_controller
            .layerZero_quoteTransfer(Arbitrum.USDT_OFT, 1_000_000e6, LZ_ETHEREUM_EID);

        vm.prank(Ethereum.PLANNER_WALLET);
        arbPlannerAgent.call{ value: arbFee.nativeFee }(
            address(arbSparkAgent),
            abi.encodeCall(
                IAdministeredAgentLike.call,
                (
                    address(arbSpUSDTPAU_controller),
                    abi.encodeCall(
                        ILayerZeroController.layerZero_transfer,
                        (Arbitrum.USDT_OFT, 1_000_000e6, LZ_ETHEREUM_EID)
                    )
                )
            )
        );

        assertEq(arbSpUSDTPAU_rateLimits.getCurrentRateLimit(arbLayerZeroKey), 5_000_000e6 - 1_000_000e6);

        // USDT0 is burned on Arbitrum.
        assertEq(usdt0.balanceOf(arbSpUSDTPAU_almProxy), 0);
        assertEq(usdt0.totalSupply(),                    1_120_489_900.354792e6);

        // Step 6: Relay the message to Ethereum

        mainnet.selectFork();

        assertEq(usdt.balanceOf(ethSpUSDTPAU_almProxy), 1_000_100e6);
        assertEq(usdt.balanceOf(Ethereum.USDT_OFT),     3_748_659_043.709524e6);

        lzBridge.relayMessagesToDestination(true, Arbitrum.USDT_OFT, Ethereum.USDT_OFT);

        // USDT is released from the OFT adapter on Ethereum.
        assertEq(usdt.balanceOf(ethSpUSDTPAU_almProxy), 2_000_100e6);
        assertEq(usdt.balanceOf(Ethereum.USDT_OFT),     3_747_659_043.709524e6);

        // Step 7: ethSllAgent (ethPlannerAgent) initiates a swap on the SLL PAU of 2_000_000e18 USDS for
        //         2_000_000e6 USDT, completed by the spUSDT PAU using SwapAssetFacet

        assertEq(ethSllPAU_rateLimits.getCurrentRateLimit(sllSwapInitiateUSDSKey), 10_000_000e18);
        assertEq(ethSllPAU_rateLimits.getCurrentRateLimit(sllSwapInitiateUSDTKey), 10_000_000e6);

        assertEq(ethSpUSDTPAU_rateLimits.getCurrentRateLimit(ethSwapCompleteUSDTKey), 10_000_000e6);
        assertEq(ethSpUSDTPAU_rateLimits.getCurrentRateLimit(ethSwapCompleteUSDSKey), 10_000_000e18);

        assertEq(usdt.balanceOf(ethSpUSDTPAU_almProxy), 2_000_100e6);
        assertEq(usds.balanceOf(ethSpUSDTPAU_almProxy), 0);
        assertEq(usdt.balanceOf(Ethereum.ALM_PROXY),    2_000_000e6);
        assertEq(usds.balanceOf(Ethereum.ALM_PROXY),    2_000_000e18);

        vm.prank(Ethereum.PLANNER_WALLET);
        ethPlannerAgent.call(
            address(ethSllAgent),
            abi.encodeCall(
                IAdministeredAgentLike.call,
                (
                    address(ethSllPAU_controller),
                    abi.encodeCall(
                        ISwapAssetController.swapAsset_initiateSwap,
                        (address(ethSpUSDTPAU_controller), Ethereum.USDS, Ethereum.USDT, 2_000_000e18)
                    )
                )
            )
        );

        // The reverse direction keys increase
        assertEq(ethSllPAU_rateLimits.getCurrentRateLimit(sllSwapInitiateUSDSKey), 8_000_000e18);
        assertEq(ethSllPAU_rateLimits.getCurrentRateLimit(sllSwapInitiateUSDTKey), 10_000_000e6);

        assertEq(ethSpUSDTPAU_rateLimits.getCurrentRateLimit(ethSwapCompleteUSDTKey), 8_000_000e6);
        assertEq(ethSpUSDTPAU_rateLimits.getCurrentRateLimit(ethSwapCompleteUSDSKey), 10_000_000e18);

        assertEq(usdt.balanceOf(ethSpUSDTPAU_almProxy), 100e6);
        assertEq(usds.balanceOf(ethSpUSDTPAU_almProxy), 2_000_000e18);
        assertEq(usdt.balanceOf(Ethereum.ALM_PROXY),    4_000_000e6);
        assertEq(usds.balanceOf(Ethereum.ALM_PROXY),    0);

        // Step 8: ethSparkAgent (ethPlannerAgent) deposits 2_000_000e18 USDS to sUSDS using ERC4626Facet

        assertEq(ethSpUSDTPAU_rateLimits.getCurrentRateLimit(ethERC4626DepositKey),  type(uint256).max);
        assertEq(ethSpUSDTPAU_rateLimits.getCurrentRateLimit(ethERC4626WithdrawKey), type(uint256).max);

        assertEq(usds.balanceOf(ethSpUSDTPAU_almProxy),  2_000_000e18);
        assertEq(susds.balanceOf(ethSpUSDTPAU_almProxy), 0);

        vm.prank(Ethereum.PLANNER_WALLET);
        ethPlannerAgent.call(
            address(ethSparkAgent),
            abi.encodeCall(
                IAdministeredAgentLike.call,
                (
                    address(ethSpUSDTPAU_controller),
                    abi.encodeCall(
                        IERC4626Controller.erc4626_deposit,
                        (Ethereum.SUSDS, 2_000_000e18, 1_789_818.827676846735622777e18)
                    )
                )
            )
        );

        assertEq(ethSpUSDTPAU_rateLimits.getCurrentRateLimit(ethERC4626DepositKey),  type(uint256).max);
        assertEq(ethSpUSDTPAU_rateLimits.getCurrentRateLimit(ethERC4626WithdrawKey), type(uint256).max);

        assertEq(usds.balanceOf(ethSpUSDTPAU_almProxy),  0);
        assertEq(susds.balanceOf(ethSpUSDTPAU_almProxy), 1_789_818.827676846735622777e18);

        assertEq(susds.convertToAssets(1_789_818.827676846735622777e18), 2_000_000e18 - 2);  // Rounding

        // Step 9: skip 1 day on Ethereum and Arbitrum to let the sUSDS and spUSDT on Arbitrum accrue yield

        skip(1 days);

        arbitrum.selectFork();
        skip(1 days);

        assertEq(arbSpUSDT.convertToAssets(987_866.165371e6), 1_000_114.038487e6); // 114.038487e6 is the interest owed to the user on Arbitrum

        mainnet.selectFork();

        assertEq(susds.convertToAssets(1_789_818.827676846735622777e18), 2_000_204.370905504494858258e18); // 204.370905504494858258e18 is the interest accrued
        assertEq(ethSpUSDT.convertToAssets(963_533.296411e6),            1_000_114.038486e6);              // 114.038486e6 is the interest owed to the user on Ethereum

        // Rate limits fully recharged
        assertEq(ethSllPAU_rateLimits.getCurrentRateLimit(sllSwapInitiateUSDSKey),    10_000_000e18);
        assertEq(ethSpUSDTPAU_rateLimits.getCurrentRateLimit(ethSwapCompleteUSDTKey), 10_000_000e6);

        // Step 10: ethSparkAgent (ethPlannerAgent) withdraws 2_000_000e18 + interest USDS from sUSDS using ERC4626Facet

        assertEq(ethSpUSDTPAU_rateLimits.getCurrentRateLimit(ethERC4626DepositKey),  type(uint256).max);
        assertEq(ethSpUSDTPAU_rateLimits.getCurrentRateLimit(ethERC4626WithdrawKey), type(uint256).max);

        assertEq(usds.balanceOf(ethSpUSDTPAU_almProxy),  0);
        assertEq(susds.balanceOf(ethSpUSDTPAU_almProxy), 1_789_818.827676846735622777e18);

        vm.prank(Ethereum.PLANNER_WALLET);
        ethPlannerAgent.call(
            address(ethSparkAgent),
            abi.encodeCall(
                IAdministeredAgentLike.call,
                (
                    address(ethSpUSDTPAU_controller),
                    abi.encodeCall(
                        IERC4626Controller.erc4626_redeem,
                        (Ethereum.SUSDS, 1_789_818.827676846735622777e18, 2_000_204.370905504494858258e18)
                    )
                )
            )
        );

        assertEq(ethSpUSDTPAU_rateLimits.getCurrentRateLimit(ethERC4626DepositKey),  type(uint256).max);
        assertEq(ethSpUSDTPAU_rateLimits.getCurrentRateLimit(ethERC4626WithdrawKey), type(uint256).max);

        assertEq(usds.balanceOf(ethSpUSDTPAU_almProxy),  2_000_204.370905504494858258e18);
        assertEq(susds.balanceOf(ethSpUSDTPAU_almProxy), 0);

        // Step 11: ethSllAgent (ethPlannerAgent) initiates a swap on the SLL PAU of 2_000_000e6 USDT + interest
        //          for the USDS + interest, completed by the spUSDT PAU using SwapAssetFacet

        assertEq(ethSllPAU_rateLimits.getCurrentRateLimit(sllSwapInitiateUSDSKey), 10_000_000e18);
        assertEq(ethSllPAU_rateLimits.getCurrentRateLimit(sllSwapInitiateUSDTKey), 10_000_000e6);

        assertEq(ethSpUSDTPAU_rateLimits.getCurrentRateLimit(ethSwapCompleteUSDTKey), 10_000_000e6);
        assertEq(ethSpUSDTPAU_rateLimits.getCurrentRateLimit(ethSwapCompleteUSDSKey), 10_000_000e18);

        assertEq(usdt.balanceOf(ethSpUSDTPAU_almProxy), 100e6);
        assertEq(usds.balanceOf(ethSpUSDTPAU_almProxy), 2_000_204.370905504494858258e18);
        assertEq(usdt.balanceOf(Ethereum.ALM_PROXY),    4_000_000e6);
        assertEq(usds.balanceOf(Ethereum.ALM_PROXY),    0);

        // The SLL sends USDT, so the spUSDT PAU sends amountOut * 1e12 USDS, the USDS dust below 1e12 stays
        // in the spUSDT ALMProxy.
        vm.prank(Ethereum.PLANNER_WALLET);
        ethPlannerAgent.call(
            address(ethSllAgent),
            abi.encodeCall(
                IAdministeredAgentLike.call,
                (
                    address(ethSllPAU_controller),
                    abi.encodeCall(
                        ISwapAssetController.swapAsset_initiateSwap,
                        (address(ethSpUSDTPAU_controller), Ethereum.USDT, Ethereum.USDS, 2_000_204.370905e6)
                    )
                )
            )
        );

        // The reverse direction keys increase
        assertEq(ethSllPAU_rateLimits.getCurrentRateLimit(sllSwapInitiateUSDSKey), 10_000_000e18);
        assertEq(ethSllPAU_rateLimits.getCurrentRateLimit(sllSwapInitiateUSDTKey), 7_999_795.629095e6);

        assertEq(ethSpUSDTPAU_rateLimits.getCurrentRateLimit(ethSwapCompleteUSDTKey), 10_000_000e6);
        assertEq(ethSpUSDTPAU_rateLimits.getCurrentRateLimit(ethSwapCompleteUSDSKey), 7_999_795.629095e18);

        assertEq(usdt.balanceOf(ethSpUSDTPAU_almProxy), 2_000_304.370905e6);
        assertEq(usds.balanceOf(ethSpUSDTPAU_almProxy), 0.000000504494858258e18);
        assertEq(usdt.balanceOf(Ethereum.ALM_PROXY),    1_999_795.629095e6);
        assertEq(usds.balanceOf(Ethereum.ALM_PROXY),    2_000_204.370905e18);

        // Step 12: ethSparkAgent (ethPlannerAgent) transfers 1_000_000e6 USDT + interest to Ethereum spUSDT vault using TransferAssetFacet

        assertEq(ethSpUSDTPAU_rateLimits.getCurrentRateLimit(ethTransferKey), 10_000_000e6);

        assertEq(usdt.balanceOf(ethSpUSDTPAU_almProxy), 2_000_304.370905e6);
        assertEq(usdt.balanceOf(address(ethSpUSDT)),    80_411_526.179333e6);

        vm.prank(Ethereum.PLANNER_WALLET);
        ethPlannerAgent.call(
            address(ethSparkAgent),
            abi.encodeCall(
                IAdministeredAgentLike.call,
                (
                    address(ethSpUSDTPAU_controller),
                    abi.encodeCall(
                        ITransferAssetController.transferAsset_transfer,
                        (Ethereum.USDT, address(ethSpUSDT), 1_000_114.038486e6) // 114.038486e6 is the interest owed to the user on Ethereum
                    )
                )
            )
        );

        assertEq(ethSpUSDTPAU_rateLimits.getCurrentRateLimit(ethTransferKey), 10_000_000e6 - 1_000_114.038486e6);

        assertEq(usdt.balanceOf(ethSpUSDTPAU_almProxy), 1_000_190.332419e6);
        assertEq(usdt.balanceOf(address(ethSpUSDT)),    81_411_640.217819e6);

        // Step 13: ethSparkAgent (ethPlannerAgent) bridges 1_000_000e6 USDT + interest to Arbitrum spUSDT PAU using LayerZeroFacet

        assertEq(ethSpUSDTPAU_rateLimits.getCurrentRateLimit(ethLayerZeroKey), 5_000_000e6);

        assertEq(usdt.balanceOf(ethSpUSDTPAU_almProxy), 1_000_190.332419e6);
        assertEq(usdt.balanceOf(Ethereum.USDT_OFT),     3_747_659_043.709524e6);

        ( , ILayerZeroFacet.MessagingFee memory ethFee ) = ethSpUSDTPAU_controller
            .layerZero_quoteTransfer(Ethereum.USDT_OFT, 1_000_114.038487e6, LZ_ARBITRUM_EID);

        vm.prank(Ethereum.PLANNER_WALLET);
        ethPlannerAgent.call{ value: ethFee.nativeFee }(
            address(ethSparkAgent),
            abi.encodeCall(
                IAdministeredAgentLike.call,
                (
                    address(ethSpUSDTPAU_controller),
                    abi.encodeCall(
                        ILayerZeroController.layerZero_transfer,
                        (Ethereum.USDT_OFT, 1_000_114.038487e6, LZ_ARBITRUM_EID) // 114.038487e6 is the interest owed to the user on Arbitrum
                    )
                )
            )
        );

        assertEq(ethSpUSDTPAU_rateLimits.getCurrentRateLimit(ethLayerZeroKey), 5_000_000e6 - 1_000_114.038487e6);

        // USDT is locked in the OFT adapter on Ethereum.
        assertEq(usdt.balanceOf(ethSpUSDTPAU_almProxy), 76.293932e6);
        assertEq(usdt.balanceOf(Ethereum.USDT_OFT),     3_748_659_157.748011e6);

        // Step 14: Relay the message to Arbitrum

        arbitrum.selectFork();

        assertEq(usdt0.balanceOf(arbSpUSDTPAU_almProxy), 0);
        assertEq(usdt0.totalSupply(),                    1_120_489_900.354792e6);

        lzBridge.relayMessagesToSource(true, Ethereum.USDT_OFT, Arbitrum.USDT_OFT);

        // USDT0 is minted on Arbitrum.
        assertEq(usdt0.balanceOf(arbSpUSDTPAU_almProxy), 1_000_114.038487e6);
        assertEq(usdt0.totalSupply(),                    1_121_490_014.393279e6);

        // Step 15: arbSparkAgent (arbPlannerAgent) transfers 1_000_000e6 USDT + interest to Arbitrum spUSDT vault using TransferAssetFacet

        assertEq(arbSpUSDTPAU_rateLimits.getCurrentRateLimit(arbTransferKey), 10_000_000e6);

        assertEq(usdt0.balanceOf(arbSpUSDTPAU_almProxy), 1_000_114.038487e6);
        assertEq(usdt0.balanceOf(address(arbSpUSDT)),    1_053_061.636344e6);

        vm.prank(Ethereum.PLANNER_WALLET);
        arbPlannerAgent.call(
            address(arbSparkAgent),
            abi.encodeCall(
                IAdministeredAgentLike.call,
                (
                    address(arbSpUSDTPAU_controller),
                    abi.encodeCall(
                        ITransferAssetController.transferAsset_transfer,
                        (Arbitrum.USDT0, address(arbSpUSDT), 1_000_114.038487e6) // 114.038487e6 is the interest owed to the user on Arbitrum
                    )
                )
            )
        );

        assertEq(arbSpUSDTPAU_rateLimits.getCurrentRateLimit(arbTransferKey), 10_000_000e6 - 1_000_114.038487e6);

        assertEq(usdt0.balanceOf(arbSpUSDTPAU_almProxy), 0);
        assertEq(usdt0.balanceOf(address(arbSpUSDT)),    2_053_175.674831e6);

        // Step 16: User redeems their Ethereum spUSDT deposit and receives the 1_000_000e6 USDT + interest

        mainnet.selectFork();

        assertEq(usdt.balanceOf(user),               0);
        assertEq(usdt.balanceOf(address(ethSpUSDT)), 81_411_640.217819e6);

        assertEq(ethSpUSDT.totalAssets(),   275_840_940.014790e6);
        assertEq(ethSpUSDT.totalSupply(),   265_751_624.304563e6);
        assertEq(ethSpUSDT.balanceOf(user), 963_533.296411e6);

        vm.prank(user);
        ethSpUSDT.redeem(963_533.296411e6, user, user);

        assertEq(usdt.balanceOf(user),               1_000_114.038486e6);
        assertEq(usdt.balanceOf(address(ethSpUSDT)), 80_411_526.179333e6);

        assertEq(ethSpUSDT.totalAssets(),   274_840_825.976304e6);
        assertEq(ethSpUSDT.totalSupply(),   264_788_091.008152e6);
        assertEq(ethSpUSDT.balanceOf(user), 0);

        // Step 17: User redeems their Arbitrum spUSDT deposit and receives the 1_000_000e6 USDT + interest

        arbitrum.selectFork();

        assertEq(usdt0.balanceOf(user),               0);
        assertEq(usdt0.balanceOf(address(arbSpUSDT)), 2_053_175.674831e6);

        assertEq(arbSpUSDT.totalAssets(),   2_055_294.533698e6);
        assertEq(arbSpUSDT.totalSupply(),   2_030_124.417396e6);
        assertEq(arbSpUSDT.balanceOf(user), 987_866.165371e6);

        vm.prank(user);
        arbSpUSDT.redeem(987_866.165371e6, user, user);

        assertEq(usdt0.balanceOf(user),               1_000_114.038487e6);
        assertEq(usdt0.balanceOf(address(arbSpUSDT)), 1_053_061.636344e6);

        assertEq(arbSpUSDT.totalAssets(),   1_055_180.495211e6);
        assertEq(arbSpUSDT.totalSupply(),   1_042_258.252025e6);
        assertEq(arbSpUSDT.balanceOf(user), 0);

        // The unused buffer and the USDS swap dust on Ethereum, nothing on Arbitrum.
        assertEq(usdt0.balanceOf(arbSpUSDTPAU_almProxy), 0);

        mainnet.selectFork();

        assertEq(usdt.balanceOf(ethSpUSDTPAU_almProxy), 76.293932e6);             // Remaining dust from the buffer deal of 100e6
        assertEq(usds.balanceOf(ethSpUSDTPAU_almProxy), 0.000000504494858258e18); // Remaining USDS swap dust
    }

}
