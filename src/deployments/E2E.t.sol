// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Test } from "../../lib/forge-std/src/Test.sol";

import { Bridge }                 from "../../lib/xchain-helpers/src/testing/Bridge.sol";
import { Domain, DomainHelpers }  from "../../lib/xchain-helpers/src/testing/Domain.sol";
import { LZBridgeTesting }        from "../../lib/xchain-helpers/src/testing/bridges/LZBridgeTesting.sol";

import { Arbitrum } from "../../lib/spark-address-registry/src/Arbitrum.sol";
import { Ethereum } from "../../lib/spark-address-registry/src/Ethereum.sol";

import { IALMProxy }   from "../../lib/diamond-pau/src/interfaces/IALMProxy.sol";
import { IController } from "../../lib/diamond-pau/src/interfaces/IController.sol";
import { IPAUFactory } from "../../lib/diamond-pau/src/interfaces/IPAUFactory.sol";
import { IRateLimits } from "../../lib/diamond-pau/src/interfaces/IRateLimits.sol";

import { BeaconConfig } from "../../lib/diamond-pau/src/libraries/BeaconConfig.sol";

import { IAaveController }          from "../../lib/diamond-pau/src/facets/aave/IAaveController.sol";
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
    IAaveController,
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

    // Aave v3 Core Pool, not in the address registry.
    address internal constant AAVE_CORE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    // TODO: Replace with the final address, must match the deployment payloads.
    address internal constant SPARK_PLANNER_HOT_WALLET = address(1);

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

    address internal ethPlannerAgent;
    address internal ethSparkAgent;
    address internal ethSllAgent;

    address internal ethSllPAU_accessControls;
    address internal ethSllPAU_controller;
    address internal ethSllPAU_rateLimits;

    address internal ethSpUSDTPAU_accessControls;
    address internal ethSpUSDTPAU_almProxy;
    address internal ethSpUSDTPAU_controller;
    address internal ethSpUSDTPAU_rateLimits;

    /**********************************************************************************************/
    /*** Arbitrum deployments                                                                   ***/
    /**********************************************************************************************/

    address internal arbPlannerAgent;
    address internal arbSparkAgent;

    address internal arbSpUSDTPAU_accessControls;
    address internal arbSpUSDTPAU_almProxy;
    address internal arbSpUSDTPAU_controller;
    address internal arbSpUSDTPAU_rateLimits;

    /**********************************************************************************************/
    /*** Setup                                                                                  ***/
    /**********************************************************************************************/

    function setUp() public virtual {
        mainnet  = getChain("mainnet").createFork(26436548);       // Nov-17-2026 06:26:11 PM +UTC
        arbitrum = getChain("arbitrum_one").createFork(525109927); // Nov-17-2026 06:23:08 PM +UTC

        // Step 1: Deploy the Ethereum payload

        mainnet.selectFork();

        EthereumSparkSpUSDTPayload.Report memory ethReport 
            = EthereumSparkSpUSDTPayload(address(new EthereumSparkSpUSDTPayload())).report();

        ethPlannerAgent = ethReport.plannerAgent;
        ethSparkAgent   = ethReport.sparkAgent;
        ethSllAgent     = ethReport.sllAgent;

        ethSllPAU_accessControls = ethReport.sllPAU_accessControls;
        ethSllPAU_controller     = ethReport.sllPAU_controller;
        ethSllPAU_rateLimits     = ethReport.sllPAU_rateLimits;

        ethSpUSDTPAU_accessControls = ethReport.spUSDTPAU_accessControls;
        ethSpUSDTPAU_almProxy       = ethReport.spUSDTPAU_almProxy;
        ethSpUSDTPAU_controller     = ethReport.spUSDTPAU_controller;
        ethSpUSDTPAU_rateLimits     = ethReport.spUSDTPAU_rateLimits;

        // Step 2: Deploy the Arbitrum payload. The Arbitrum Beacon payload already executed on-chain.

        arbitrum.selectFork();

        // Making sure the Arbitrum Beacon payload was already executed on-chain.
        assertEq(IPAUFactory(Arbitrum.SPARK_PAU_FACTORY).beacon(), Arbitrum.SPARK_BEACON);

        ArbitrumSparkSpUSDTPayload.Report memory arbReport 
            = ArbitrumSparkSpUSDTPayload(address(new ArbitrumSparkSpUSDTPayload())).report();

        arbPlannerAgent = arbReport.plannerAgent;
        arbSparkAgent   = arbReport.sparkAgent;

        arbSpUSDTPAU_accessControls = arbReport.spUSDTPAU_accessControls;
        arbSpUSDTPAU_almProxy       = arbReport.spUSDTPAU_almProxy;
        arbSpUSDTPAU_controller     = arbReport.spUSDTPAU_controller;
        arbSpUSDTPAU_rateLimits     = arbReport.spUSDTPAU_rateLimits;

        // Step 3: Create the LayerZero bridge

        lzBridge = LZBridgeTesting.createLZBridge(arbitrum, mainnet);

        // Step 4: Execute the governance spell

        _sparkSpell20261203();

        // Step 5: Labels

        vm.label(ethPlannerAgent,                "eth.plannerAgent");
        vm.label(ethSparkAgent,                  "eth.sparkAgent");
        vm.label(ethSllAgent,                    "eth.sllAgent");
        vm.label(ethSllPAU_accessControls,       "eth.sllPAU.accessControls");
        vm.label(ethSllPAU_controller,           "eth.sllPAU.controller");
        vm.label(ethSllPAU_rateLimits,           "eth.sllPAU.rateLimits");
        vm.label(ethSpUSDTPAU_accessControls,    "eth.spUSDTPAU.accessControls");
        vm.label(ethSpUSDTPAU_almProxy,          "eth.spUSDTPAU.almProxy");
        vm.label(ethSpUSDTPAU_controller,        "eth.spUSDTPAU.controller");
        vm.label(ethSpUSDTPAU_rateLimits,        "eth.spUSDTPAU.rateLimits");
        vm.label(Ethereum.ALM_PROXY,             "eth.sllPAU.almProxy");
        vm.label(Ethereum.SPARK_PROXY,           "eth.sparkProxy");
        vm.label(Ethereum.SPARK_VAULT_V2_SPUSDT, "eth.spUSDT");
        vm.label(Ethereum.USDT_OFT,              "eth.usdtOFT");
        vm.label(arbPlannerAgent,                "arb.plannerAgent");
        vm.label(arbSparkAgent,                  "arb.sparkAgent");
        vm.label(arbSpUSDTPAU_accessControls,    "arb.spUSDTPAU.accessControls");
        vm.label(arbSpUSDTPAU_almProxy,          "arb.spUSDTPAU.almProxy");
        vm.label(arbSpUSDTPAU_controller,        "arb.spUSDTPAU.controller");
        vm.label(arbSpUSDTPAU_rateLimits,        "arb.spUSDTPAU.rateLimits");
        vm.label(Arbitrum.SPARK_EXECUTOR,        "arb.sparkExecutor");
        vm.label(Arbitrum.SPARK_VAULT_V2_SPUSDT, "arb.spUSDT");
        vm.label(Arbitrum.USDT_OFT,              "arb.usdtOFT");

        mainnet.selectFork();
    }

    /**********************************************************************************************/
    /*** Spark Spell                                                                            ***/
    /**********************************************************************************************/

    // NOTE: Executes only the subset of upcoming spell that is relevant to the E2E test.
    function _sparkSpell20261203() internal {
        // ETHEREUM

        mainnet.selectFork();
        vm.startPrank(Ethereum.SPARK_PROXY);

        // Step 1: Onboard the Aave, LayerZero and SwapAsset integrations on the Ethereum Beacon

        BeaconConfig.setAaveIntegration(Ethereum.SPARK_BEACON,      Ethereum.AAVE_FACET);
        BeaconConfig.setLayerZeroIntegration(Ethereum.SPARK_BEACON, Ethereum.LAYERZERO_FACET);
        BeaconConfig.setSwapAssetIntegration(Ethereum.SPARK_BEACON, Ethereum.SWAP_ASSET_FACET);

        // Step 2: SLL PAU, grant CONTROLLER on the SLL ALM Proxy and onboard SwapAsset only

        IALMProxy(Ethereum.ALM_PROXY).grantRole(IALMProxy(Ethereum.ALM_PROXY).CONTROLLER(), ethSllPAU_controller);

        bytes32[] memory ethSllPAUIntegrationIds = new bytes32[](1);
        ethSllPAUIntegrationIds[0] = "SWAP_ASSET_FACET";

        IEthSllController(ethSllPAU_controller).updateIntegrations(ethSllPAUIntegrationIds);

        // Step 3: SLL PAU SwapAsset complete rate limits

        IRateLimits(ethSllPAU_rateLimits).setRateLimitData(
            IEthSllController(ethSllPAU_controller).swapAsset_getCompleteSwapRateLimitKey(
                Ethereum.USDT,
                ethSpUSDTPAU_almProxy,
                Ethereum.USDS
            ),
            100_000_000e6,
            500_000_000e6 / uint256(1 days)
        );
        IRateLimits(ethSllPAU_rateLimits).setRateLimitData(
            IEthSllController(ethSllPAU_controller).swapAsset_getCompleteSwapRateLimitKey(
                Ethereum.USDS,
                ethSpUSDTPAU_almProxy,
                Ethereum.USDT
            ),
            100_000_000e18,
            500_000_000e18 / uint256(1 days)
        );

        // Step 4: spUSDT PAU, onboard Aave, LayerZero and SwapAsset

        bytes32[] memory spUSDTIntegrationIds = new bytes32[](3);
        spUSDTIntegrationIds[0] = "AAVE_FACET";
        spUSDTIntegrationIds[1] = "LAYER_ZERO_FACET";
        spUSDTIntegrationIds[2] = "SWAP_ASSET_FACET";

        IEthSpUSDTController(ethSpUSDTPAU_controller).updateIntegrations(spUSDTIntegrationIds);

        // Step 5: spUSDT PAU ratelimits configurations

        // SwapAsset initiate rate limits
        IRateLimits(ethSpUSDTPAU_rateLimits).setRateLimitData(
            IEthSpUSDTController(ethSpUSDTPAU_controller).swapAsset_getInitiateSwapRateLimitKey(
                Ethereum.USDT,
                Ethereum.ALM_PROXY,
                ethSllPAU_controller,
                Ethereum.USDS
            ),
            100_000_000e6,
            1_000_000_000e6 / uint256(1 days)
        );
        IRateLimits(ethSpUSDTPAU_rateLimits).setRateLimitData(
            IEthSpUSDTController(ethSpUSDTPAU_controller).swapAsset_getInitiateSwapRateLimitKey(
                Ethereum.USDS,
                Ethereum.ALM_PROXY,
                ethSllPAU_controller,
                Ethereum.USDT
            ),
            100_000_000e18,
            1_000_000_000e18 / uint256(1 days)
        );

        // Aave v3 Core USDT rate limits
        IEthSpUSDTController(ethSpUSDTPAU_controller).aave_setMaxSlippage(Ethereum.ATOKEN_CORE_USDT, 0.99999e18);

        IRateLimits(ethSpUSDTPAU_rateLimits).setRateLimitData(
            IEthSpUSDTController(ethSpUSDTPAU_controller).aave_getDepositRateLimitKey(
                Ethereum.ATOKEN_CORE_USDT,
                AAVE_CORE_POOL,
                Ethereum.USDT
            ),
            100_000_000e6,
            500_000_000e6 / uint256(1 days)
        );
        IRateLimits(ethSpUSDTPAU_rateLimits).setUnlimitedRateLimitData(
            IEthSpUSDTController(ethSpUSDTPAU_controller).aave_getWithdrawRateLimitKey(
                Ethereum.ATOKEN_CORE_USDT,
                AAVE_CORE_POOL
            )
        );

        // LayerZero USDT to Arbitrum rate limits
        IEthSpUSDTController(ethSpUSDTPAU_controller).layerZero_setRecipient(
            LZ_ARBITRUM_EID,
            bytes32(uint256(uint160(arbSpUSDTPAU_almProxy)))
        );

        IRateLimits(ethSpUSDTPAU_rateLimits).setRateLimitData(
            IEthSpUSDTController(ethSpUSDTPAU_controller).layerZero_getTransferRateLimitKey(
                Ethereum.USDT_OFT,
                bytes32(uint256(uint160(Arbitrum.USDT_OFT))),
                LZ_ARBITRUM_EID,
                Ethereum.USDT
            ),
            5_000_000e6,
            50_000_000e6 / uint256(1 days)
        );

        // Step 6: Grant spUSDT TAKER_ROLE to the Ethereum spUSDT ALM Proxy

        ISparkVaultLike(Ethereum.SPARK_VAULT_V2_SPUSDT).grantRole(
            ISparkVaultLike(Ethereum.SPARK_VAULT_V2_SPUSDT).TAKER_ROLE(),
            ethSpUSDTPAU_almProxy
        );

        vm.stopPrank();

        // ARBITRUM

        arbitrum.selectFork();
        vm.startPrank(Arbitrum.SPARK_EXECUTOR);

        // Step 7: Set the LayerZero recipient on Ethereum to the Ethereum spUSDT ALM Proxy,
        //         replacing the placeholder set by the deployment payload
        //         (TODO: Remove this step once the deployment payload is updated)

        IArbSpUSDTController(arbSpUSDTPAU_controller).layerZero_setRecipient(
            LZ_ETHEREUM_EID,
            bytes32(uint256(uint160(ethSpUSDTPAU_almProxy)))
        );

        // Step 8: Grant spUSDT TAKER_ROLE to the Arbitrum spUSDT ALM Proxy

        ISparkVaultLike(Arbitrum.SPARK_VAULT_V2_SPUSDT).grantRole(
            ISparkVaultLike(Arbitrum.SPARK_VAULT_V2_SPUSDT).TAKER_ROLE(),
            arbSpUSDTPAU_almProxy
        );

        vm.stopPrank();
    }

}

contract E2ETest is E2ETestBase {

    using DomainHelpers   for *;
    using LZBridgeTesting for Bridge;

    address internal user = makeAddr("user");

    IERC20Like internal usdt  = IERC20Like(Ethereum.USDT);
    IERC20Like internal usds  = IERC20Like(Ethereum.USDS);
    IERC20Like internal aUsdt = IERC20Like(Ethereum.ATOKEN_CORE_USDT);
    IERC20Like internal usdt0 = IERC20Like(Arbitrum.USDT0);

    IERC4626Like internal susds = IERC4626Like(Ethereum.SUSDS);

    ISparkVaultLike internal ethSpUSDT = ISparkVaultLike(Ethereum.SPARK_VAULT_V2_SPUSDT);
    ISparkVaultLike internal arbSpUSDT = ISparkVaultLike(Arbitrum.SPARK_VAULT_V2_SPUSDT);

    bytes32 internal ethTakeKey;
    bytes32 internal ethTransferKey;
    bytes32 internal ethLayerZeroKey;
    bytes32 internal ethAaveDepositKey;
    bytes32 internal ethAaveWithdrawKey;
    bytes32 internal ethERC4626DepositKey;
    bytes32 internal ethERC4626WithdrawKey;
    bytes32 internal ethSwapInitiateUSDTKey;
    bytes32 internal ethSwapInitiateUSDSKey;
    bytes32 internal sllSwapCompleteUSDTKey;
    bytes32 internal sllSwapCompleteUSDSKey;

    bytes32 internal arbTakeKey;
    bytes32 internal arbTransferKey;
    bytes32 internal arbLayerZeroKey;

    function setUp() public override {
        super.setUp();

        mainnet.selectFork();

        // TODO: Remove once the deployment payload sets the sUSDS max exchange rate.
        vm.startPrank(Ethereum.SPARK_PROXY);
        IEthSpUSDTController(ethSpUSDTPAU_controller).erc4626_setMaxExchangeRate(
            Ethereum.SUSDS,
            susds.convertToShares(1e18),
            1.2e18
        );
        vm.stopPrank();

        // The SLL ALMProxy holds no idle USDS or USDT at the fork block, it needs both to complete the swaps.
        deal(Ethereum.USDS, Ethereum.ALM_PROXY, 1_000_000e18);
        deal(Ethereum.USDT, Ethereum.ALM_PROXY, 1_000_000e6);

        // spUSDT VSR (~4.25%) accrues faster than the sUSDS and Aave yield, so the strategy alone does not
        // cover what both users are owed after 1 day. This buffer funds the difference.
        deal(Ethereum.USDT, ethSpUSDTPAU_almProxy, 100e6);

        deal(Ethereum.USDT, user, 1_000_000e6);

        deal(SPARK_PLANNER_HOT_WALLET, 1 ether); // For LayerZero fees

        ethTakeKey      = IEthSpUSDTController(ethSpUSDTPAU_controller).sparkVault_getTakeRateLimitKey(address(ethSpUSDT));
        ethTransferKey  = IEthSpUSDTController(ethSpUSDTPAU_controller).transferAsset_getTransferRateLimitKey(Ethereum.USDT, address(ethSpUSDT));
        ethLayerZeroKey = IEthSpUSDTController(ethSpUSDTPAU_controller).layerZero_getTransferRateLimitKey(
            Ethereum.USDT_OFT,
            bytes32(uint256(uint160(Arbitrum.USDT_OFT))),
            LZ_ARBITRUM_EID,
            Ethereum.USDT
        );

        ethAaveDepositKey  = IEthSpUSDTController(ethSpUSDTPAU_controller).aave_getDepositRateLimitKey(Ethereum.ATOKEN_CORE_USDT, AAVE_CORE_POOL, Ethereum.USDT);
        ethAaveWithdrawKey = IEthSpUSDTController(ethSpUSDTPAU_controller).aave_getWithdrawRateLimitKey(Ethereum.ATOKEN_CORE_USDT, AAVE_CORE_POOL);

        ethERC4626DepositKey  = IEthSpUSDTController(ethSpUSDTPAU_controller).erc4626_getDepositRateLimitKey(Ethereum.SUSDS, Ethereum.USDS);
        ethERC4626WithdrawKey = IEthSpUSDTController(ethSpUSDTPAU_controller).erc4626_getWithdrawRateLimitKey(Ethereum.SUSDS);

        ethSwapInitiateUSDTKey = IEthSpUSDTController(ethSpUSDTPAU_controller).swapAsset_getInitiateSwapRateLimitKey(
            Ethereum.USDT,
            Ethereum.ALM_PROXY,
            ethSllPAU_controller,
            Ethereum.USDS
        );
        ethSwapInitiateUSDSKey = IEthSpUSDTController(ethSpUSDTPAU_controller).swapAsset_getInitiateSwapRateLimitKey(
            Ethereum.USDS,
            Ethereum.ALM_PROXY,
            ethSllPAU_controller,
            Ethereum.USDT
        );

        sllSwapCompleteUSDTKey = IEthSllController(ethSllPAU_controller).swapAsset_getCompleteSwapRateLimitKey(
            Ethereum.USDT,
            ethSpUSDTPAU_almProxy,
            Ethereum.USDS
        );
        sllSwapCompleteUSDSKey = IEthSllController(ethSllPAU_controller).swapAsset_getCompleteSwapRateLimitKey(
            Ethereum.USDS,
            ethSpUSDTPAU_almProxy,
            Ethereum.USDT
        );

        arbitrum.selectFork();

        deal(Arbitrum.USDT0, user, 1_000_000e6);

        deal(SPARK_PLANNER_HOT_WALLET, 1 ether); // For LayerZero fees

        arbTakeKey      = IArbSpUSDTController(arbSpUSDTPAU_controller).sparkVault_getTakeRateLimitKey(address(arbSpUSDT));
        arbTransferKey  = IArbSpUSDTController(arbSpUSDTPAU_controller).transferAsset_getTransferRateLimitKey(Arbitrum.USDT0, address(arbSpUSDT));
        arbLayerZeroKey = IArbSpUSDTController(arbSpUSDTPAU_controller).layerZero_getTransferRateLimitKey(
            Arbitrum.USDT_OFT,
            bytes32(uint256(uint160(Ethereum.USDT_OFT))),
            LZ_ETHEREUM_EID,
            Arbitrum.USDT0
        );
    }

    function test_e2e_ETHEREUM_ARBITRUM_full_flow() external {
        // Step 1: User deposits 1_000_000e6 USDT to the Ethereum spUSDT vault

        mainnet.selectFork();

        assertEq(usdt.balanceOf(user),               1_000_000e6);
        assertEq(usdt.balanceOf(address(ethSpUSDT)), 66_176_872.510365e6);

        assertEq(ethSpUSDT.totalAssets(),   295_356_260.639578e6);
        assertEq(ethSpUSDT.totalSupply(),   284_798_803.357315e6);
        assertEq(ethSpUSDT.balanceOf(user), 0);

        vm.startPrank(user);
        usdt.approve(address(ethSpUSDT), 1_000_000e6);
        ethSpUSDT.deposit(1_000_000e6, user);
        vm.stopPrank();

        assertEq(usdt.balanceOf(user),               0);
        assertEq(usdt.balanceOf(address(ethSpUSDT)), 67_176_872.510365e6);

        assertEq(ethSpUSDT.totalAssets(),   296_356_260.639577e6);
        assertEq(ethSpUSDT.totalSupply(),   285_763_058.534234e6);
        assertEq(ethSpUSDT.balanceOf(user), 964_255.176919e6);

        // Step 2: User deposits 1_000_000e6 USDT to the Arbitrum spUSDT vault

        arbitrum.selectFork();

        assertEq(usdt0.balanceOf(user),               1_000_000e6);
        assertEq(usdt0.balanceOf(address(arbSpUSDT)), 1_053_682.977823e6);

        assertEq(arbSpUSDT.totalAssets(),   1_054_892.406793e6);
        assertEq(arbSpUSDT.totalSupply(),   1_042_872.419867e6);
        assertEq(arbSpUSDT.balanceOf(user), 0);

        vm.startPrank(user);
        usdt0.approve(address(arbSpUSDT), 1_000_000e6);
        arbSpUSDT.deposit(1_000_000e6, user);
        vm.stopPrank();

        assertEq(usdt0.balanceOf(user),               0);
        assertEq(usdt0.balanceOf(address(arbSpUSDT)), 2_053_682.977823e6);

        assertEq(arbSpUSDT.totalAssets(),   2_054_892.406793e6);
        assertEq(arbSpUSDT.totalSupply(),   2_031_477.905271e6);
        assertEq(arbSpUSDT.balanceOf(user), 988_605.485404e6);

        // Step 3: ethSparkAgent (ethPlannerAgent) takes 1_000_000e6 USDT out of Ethereum spUSDT vault

        mainnet.selectFork();

        assertEq(IRateLimits(ethSpUSDTPAU_rateLimits).getCurrentRateLimit(ethTakeKey), type(uint256).max);

        assertEq(usdt.balanceOf(address(ethSpUSDT)),    67_176_872.510365e6);
        assertEq(usdt.balanceOf(ethSpUSDTPAU_almProxy), 100e6);

        vm.prank(SPARK_PLANNER_HOT_WALLET);
        IAdministeredAgentLike(ethPlannerAgent).call(
            ethSparkAgent,
            abi.encodeCall(
                IAdministeredAgentLike.call,
                (
                    ethSpUSDTPAU_controller,
                    abi.encodeCall(ISparkVaultController.sparkVault_take, (address(ethSpUSDT), 1_000_000e6))
                )
            )
        );

        assertEq(IRateLimits(ethSpUSDTPAU_rateLimits).getCurrentRateLimit(ethTakeKey), type(uint256).max);

        assertEq(usdt.balanceOf(address(ethSpUSDT)),    66_176_872.510365e6);
        assertEq(usdt.balanceOf(ethSpUSDTPAU_almProxy), 1_000_100e6);

        // Taking moves idle liquidity out, it does not change the vault's accounting.
        assertEq(ethSpUSDT.totalAssets(), 296_356_260.639577e6);
        assertEq(ethSpUSDT.totalSupply(), 285_763_058.534234e6);

        // Step 4: arbSparkAgent (arbPlannerAgent) takes 1_000_000e6 USDT out of Arbitrum spUSDT vault

        arbitrum.selectFork();

        assertEq(IRateLimits(arbSpUSDTPAU_rateLimits).getCurrentRateLimit(arbTakeKey), type(uint256).max);

        assertEq(usdt0.balanceOf(address(arbSpUSDT)),    2_053_682.977823e6);
        assertEq(usdt0.balanceOf(arbSpUSDTPAU_almProxy), 0);

        vm.prank(SPARK_PLANNER_HOT_WALLET);
        IAdministeredAgentLike(arbPlannerAgent).call(
            arbSparkAgent,
            abi.encodeCall(
                IAdministeredAgentLike.call,
                (
                    arbSpUSDTPAU_controller,
                    abi.encodeCall(ISparkVaultController.sparkVault_take, (address(arbSpUSDT), 1_000_000e6))
                )
            )
        );

        assertEq(IRateLimits(arbSpUSDTPAU_rateLimits).getCurrentRateLimit(arbTakeKey), type(uint256).max);

        assertEq(usdt0.balanceOf(address(arbSpUSDT)),    1_053_682.977823e6);
        assertEq(usdt0.balanceOf(arbSpUSDTPAU_almProxy), 1_000_000e6);

        assertEq(arbSpUSDT.totalAssets(), 2_054_892.406793e6);
        assertEq(arbSpUSDT.totalSupply(), 2_031_477.905271e6);

        // Step 5: arbSparkAgent (arbPlannerAgent) bridges 1_000_000e6 USDT to Ethereum spUSDT PAU using LayerZeroFacet

        assertEq(IRateLimits(arbSpUSDTPAU_rateLimits).getCurrentRateLimit(arbLayerZeroKey), type(uint256).max);

        assertEq(usdt0.balanceOf(arbSpUSDTPAU_almProxy), 1_000_000e6);
        assertEq(usdt0.totalSupply(),                    895_730_435.701070e6);

        ( , ILayerZeroFacet.MessagingFee memory arbFee ) = IArbSpUSDTController(arbSpUSDTPAU_controller)
            .layerZero_quoteTransfer(Arbitrum.USDT_OFT, 1_000_000e6, LZ_ETHEREUM_EID);

        vm.prank(SPARK_PLANNER_HOT_WALLET);
        IAdministeredAgentLike(arbPlannerAgent).call{ value: arbFee.nativeFee }(
            arbSparkAgent,
            abi.encodeCall(
                IAdministeredAgentLike.call,
                (
                    arbSpUSDTPAU_controller,
                    abi.encodeCall(
                        ILayerZeroController.layerZero_transfer,
                        (Arbitrum.USDT_OFT, 1_000_000e6, LZ_ETHEREUM_EID)
                    )
                )
            )
        );

        assertEq(IRateLimits(arbSpUSDTPAU_rateLimits).getCurrentRateLimit(arbLayerZeroKey), type(uint256).max);

        // USDT0 is burned on Arbitrum.
        assertEq(usdt0.balanceOf(arbSpUSDTPAU_almProxy), 0);
        assertEq(usdt0.totalSupply(),                    894_730_435.701070e6);

        // Step 6: Relay the message to Ethereum

        mainnet.selectFork();

        assertEq(usdt.balanceOf(ethSpUSDTPAU_almProxy), 1_000_100e6);
        assertEq(usdt.balanceOf(Ethereum.USDT_OFT),     3_669_379_157.913483e6);

        lzBridge.relayMessagesToDestination(true, Arbitrum.USDT_OFT, Ethereum.USDT_OFT);

        // USDT is released from the OFT adapter on Ethereum.
        assertEq(usdt.balanceOf(ethSpUSDTPAU_almProxy), 2_000_100e6);
        assertEq(usdt.balanceOf(Ethereum.USDT_OFT),     3_668_379_157.913483e6);

        // Step 7: ethSparkAgent (ethPlannerAgent) deposits 1_000_000e6 USDT to Aave v3 using AaveFacet

        assertEq(IRateLimits(ethSpUSDTPAU_rateLimits).getCurrentRateLimit(ethAaveDepositKey),  100_000_000e6);
        assertEq(IRateLimits(ethSpUSDTPAU_rateLimits).getCurrentRateLimit(ethAaveWithdrawKey), type(uint256).max);

        assertEq(usdt.balanceOf(ethSpUSDTPAU_almProxy),  2_000_100e6);
        assertEq(aUsdt.balanceOf(ethSpUSDTPAU_almProxy), 0);

        vm.prank(SPARK_PLANNER_HOT_WALLET);
        IAdministeredAgentLike(ethPlannerAgent).call(
            ethSparkAgent,
            abi.encodeCall(
                IAdministeredAgentLike.call,
                (
                    ethSpUSDTPAU_controller,
                    abi.encodeCall(IAaveController.aave_deposit, (Ethereum.ATOKEN_CORE_USDT, 1_000_000e6))
                )
            )
        );

        assertEq(IRateLimits(ethSpUSDTPAU_rateLimits).getCurrentRateLimit(ethAaveDepositKey),  99_000_000e6);
        assertEq(IRateLimits(ethSpUSDTPAU_rateLimits).getCurrentRateLimit(ethAaveWithdrawKey), type(uint256).max);

        assertEq(usdt.balanceOf(ethSpUSDTPAU_almProxy),  1_000_100e6);
        assertEq(aUsdt.balanceOf(ethSpUSDTPAU_almProxy), 1_000_000e6 - 1);  // aToken rounding

        // Step 8: ethSparkAgent (ethPlannerAgent) swaps 1_000_000e6 USDT to USDS using SwapAssetFacet

        assertEq(IRateLimits(ethSpUSDTPAU_rateLimits).getCurrentRateLimit(ethSwapInitiateUSDTKey), 100_000_000e6);
        assertEq(IRateLimits(ethSpUSDTPAU_rateLimits).getCurrentRateLimit(ethSwapInitiateUSDSKey), 100_000_000e18);

        assertEq(IRateLimits(ethSllPAU_rateLimits).getCurrentRateLimit(sllSwapCompleteUSDTKey), 100_000_000e6);
        assertEq(IRateLimits(ethSllPAU_rateLimits).getCurrentRateLimit(sllSwapCompleteUSDSKey), 100_000_000e18);

        assertEq(usdt.balanceOf(ethSpUSDTPAU_almProxy), 1_000_100e6);
        assertEq(usds.balanceOf(ethSpUSDTPAU_almProxy), 0);
        assertEq(usdt.balanceOf(Ethereum.ALM_PROXY),    1_000_000e6);
        assertEq(usds.balanceOf(Ethereum.ALM_PROXY),    1_000_000e18);

        vm.prank(SPARK_PLANNER_HOT_WALLET);
        IAdministeredAgentLike(ethPlannerAgent).call(
            ethSparkAgent,
            abi.encodeCall(
                IAdministeredAgentLike.call,
                (
                    ethSpUSDTPAU_controller,
                    abi.encodeCall(
                        ISwapAssetController.swapAsset_initiateSwap,
                        (ethSllPAU_controller, Ethereum.USDT, Ethereum.USDS, 1_000_000e6)
                    )
                )
            )
        );

        // The reverse direction keys increase, already at max so they stay at max.
        assertEq(IRateLimits(ethSpUSDTPAU_rateLimits).getCurrentRateLimit(ethSwapInitiateUSDTKey), 99_000_000e6);
        assertEq(IRateLimits(ethSpUSDTPAU_rateLimits).getCurrentRateLimit(ethSwapInitiateUSDSKey), 100_000_000e18);

        assertEq(IRateLimits(ethSllPAU_rateLimits).getCurrentRateLimit(sllSwapCompleteUSDTKey), 100_000_000e6);
        assertEq(IRateLimits(ethSllPAU_rateLimits).getCurrentRateLimit(sllSwapCompleteUSDSKey), 99_000_000e18);

        assertEq(usdt.balanceOf(ethSpUSDTPAU_almProxy), 100e6);
        assertEq(usds.balanceOf(ethSpUSDTPAU_almProxy), 1_000_000e18);
        assertEq(usdt.balanceOf(Ethereum.ALM_PROXY),    2_000_000e6);
        assertEq(usds.balanceOf(Ethereum.ALM_PROXY),    0);

        // Step 9: ethSparkAgent (ethPlannerAgent) deposits 1_000_000e6 USDS to sUSDS using ERC4626Facet

        assertEq(IRateLimits(ethSpUSDTPAU_rateLimits).getCurrentRateLimit(ethERC4626DepositKey),  type(uint256).max);
        assertEq(IRateLimits(ethSpUSDTPAU_rateLimits).getCurrentRateLimit(ethERC4626WithdrawKey), type(uint256).max);

        assertEq(usds.balanceOf(ethSpUSDTPAU_almProxy),  1_000_000e18);
        assertEq(susds.balanceOf(ethSpUSDTPAU_almProxy), 0);

        vm.prank(SPARK_PLANNER_HOT_WALLET);
        IAdministeredAgentLike(ethPlannerAgent).call(
            ethSparkAgent,
            abi.encodeCall(
                IAdministeredAgentLike.call,
                (
                    ethSpUSDTPAU_controller,
                    abi.encodeCall(
                        IERC4626Controller.erc4626_deposit,
                        (Ethereum.SUSDS, 1_000_000e18, 895_510.173770426879912595e18)
                    )
                )
            )
        );

        assertEq(IRateLimits(ethSpUSDTPAU_rateLimits).getCurrentRateLimit(ethERC4626DepositKey),  type(uint256).max);
        assertEq(IRateLimits(ethSpUSDTPAU_rateLimits).getCurrentRateLimit(ethERC4626WithdrawKey), type(uint256).max);

        assertEq(usds.balanceOf(ethSpUSDTPAU_almProxy),  0);
        assertEq(susds.balanceOf(ethSpUSDTPAU_almProxy), 895_510.173770426879912595e18);

        assertEq(susds.convertToAssets(895_510.173770426879912595e18), 1_000_000e18 - 2);  // Rounding

        // Step 10: skip 1 day on Ethereum and Arbitrum to let the aUSDT, sUSDS and spUSDT on Arbitrum accrue yield

        skip(1 days);

        arbitrum.selectFork();
        skip(1 days);

        assertEq(arbSpUSDT.convertToAssets(988_605.485404e6), 1_000_114.038487e6); // 114.038487e6 is the interest owed to the user on Arbitrum

        mainnet.selectFork();

        assertEq(aUsdt.balanceOf(ethSpUSDTPAU_almProxy),               1_000_085.180538e6);              // 85.180538e6 is the interest accrued
        assertEq(susds.convertToAssets(895_510.173770426879912595e18), 1_000_102.185452752247429128e18); // 102.185452752247429128e18 is the interest accrued
        assertEq(ethSpUSDT.convertToAssets(964_255.176919e6),          1_000_114.038486e6);              // 114.038486e6 is the interest owed to the user on Ethereum

        // Rate limits fully recharged
        assertEq(IRateLimits(ethSpUSDTPAU_rateLimits).getCurrentRateLimit(ethAaveDepositKey),      100_000_000e6);
        assertEq(IRateLimits(ethSpUSDTPAU_rateLimits).getCurrentRateLimit(ethSwapInitiateUSDTKey), 100_000_000e6);
        assertEq(IRateLimits(ethSllPAU_rateLimits).getCurrentRateLimit(sllSwapCompleteUSDSKey),    100_000_000e18);

        // Step 11: ethSparkAgent (ethPlannerAgent) withdraws 1_000_000e6 + interest USDT from Aave v3 using AaveFacet

        assertEq(IRateLimits(ethSpUSDTPAU_rateLimits).getCurrentRateLimit(ethAaveDepositKey),  100_000_000e6);
        assertEq(IRateLimits(ethSpUSDTPAU_rateLimits).getCurrentRateLimit(ethAaveWithdrawKey), type(uint256).max);

        assertEq(usdt.balanceOf(ethSpUSDTPAU_almProxy),  100e6);
        assertEq(aUsdt.balanceOf(ethSpUSDTPAU_almProxy), 1_000_085.180538e6);

        vm.prank(SPARK_PLANNER_HOT_WALLET);
        IAdministeredAgentLike(ethPlannerAgent).call(
            ethSparkAgent,
            abi.encodeCall(
                IAdministeredAgentLike.call,
                (
                    ethSpUSDTPAU_controller,
                    abi.encodeCall(IAaveController.aave_withdraw, (Ethereum.ATOKEN_CORE_USDT, 1_000_085.180538e6))
                )
            )
        );

        // The deposit key increases on withdraw, already at max so it stays at max.
        assertEq(IRateLimits(ethSpUSDTPAU_rateLimits).getCurrentRateLimit(ethAaveDepositKey),  100_000_000e6);
        assertEq(IRateLimits(ethSpUSDTPAU_rateLimits).getCurrentRateLimit(ethAaveWithdrawKey), type(uint256).max);

        assertEq(usdt.balanceOf(ethSpUSDTPAU_almProxy),  1_000_185.180538e6);
        assertEq(aUsdt.balanceOf(ethSpUSDTPAU_almProxy), 0);

        // Step 12: ethSparkAgent (ethPlannerAgent) withdraws 1_000_000e6 + interest USDS from sUSDS using ERC4626Facet

        assertEq(IRateLimits(ethSpUSDTPAU_rateLimits).getCurrentRateLimit(ethERC4626DepositKey),  type(uint256).max);
        assertEq(IRateLimits(ethSpUSDTPAU_rateLimits).getCurrentRateLimit(ethERC4626WithdrawKey), type(uint256).max);

        assertEq(usds.balanceOf(ethSpUSDTPAU_almProxy),  0);
        assertEq(susds.balanceOf(ethSpUSDTPAU_almProxy), 895_510.173770426879912595e18);

        vm.prank(SPARK_PLANNER_HOT_WALLET);
        IAdministeredAgentLike(ethPlannerAgent).call(
            ethSparkAgent,
            abi.encodeCall(
                IAdministeredAgentLike.call,
                (
                    ethSpUSDTPAU_controller,
                    abi.encodeCall(
                        IERC4626Controller.erc4626_redeem,
                        (Ethereum.SUSDS, 895_510.173770426879912595e18, 1_000_102.185452752247429128e18)
                    )
                )
            )
        );

        assertEq(IRateLimits(ethSpUSDTPAU_rateLimits).getCurrentRateLimit(ethERC4626DepositKey),  type(uint256).max);
        assertEq(IRateLimits(ethSpUSDTPAU_rateLimits).getCurrentRateLimit(ethERC4626WithdrawKey), type(uint256).max);

        assertEq(usds.balanceOf(ethSpUSDTPAU_almProxy),  1_000_102.185452752247429128e18);
        assertEq(susds.balanceOf(ethSpUSDTPAU_almProxy), 0);

        // Step 13: ethSparkAgent (ethPlannerAgent) swaps 1_000_000e6 USDS + interest to USDT using SwapAssetFacet

        assertEq(IRateLimits(ethSpUSDTPAU_rateLimits).getCurrentRateLimit(ethSwapInitiateUSDTKey), 100_000_000e6);
        assertEq(IRateLimits(ethSpUSDTPAU_rateLimits).getCurrentRateLimit(ethSwapInitiateUSDSKey), 100_000_000e18);

        assertEq(IRateLimits(ethSllPAU_rateLimits).getCurrentRateLimit(sllSwapCompleteUSDTKey), 100_000_000e6);
        assertEq(IRateLimits(ethSllPAU_rateLimits).getCurrentRateLimit(sllSwapCompleteUSDSKey), 100_000_000e18);

        assertEq(usdt.balanceOf(ethSpUSDTPAU_almProxy), 1_000_185.180538e6);
        assertEq(usds.balanceOf(ethSpUSDTPAU_almProxy), 1_000_102.185452752247429128e18);
        assertEq(usdt.balanceOf(Ethereum.ALM_PROXY),    2_000_000e6);
        assertEq(usds.balanceOf(Ethereum.ALM_PROXY),    0);

        // Swapping USDS to USDT requires a multiple of 1e12, the remaining USDS dust stays in the ALMProxy.
        vm.prank(SPARK_PLANNER_HOT_WALLET);
        IAdministeredAgentLike(ethPlannerAgent).call(
            ethSparkAgent,
            abi.encodeCall(
                IAdministeredAgentLike.call,
                (
                    ethSpUSDTPAU_controller,
                    abi.encodeCall(
                        ISwapAssetController.swapAsset_initiateSwap,
                        (ethSllPAU_controller, Ethereum.USDS, Ethereum.USDT, 1_000_102.185452e18)
                    )
                )
            )
        );

        assertEq(IRateLimits(ethSpUSDTPAU_rateLimits).getCurrentRateLimit(ethSwapInitiateUSDTKey), 100_000_000e6);
        assertEq(IRateLimits(ethSpUSDTPAU_rateLimits).getCurrentRateLimit(ethSwapInitiateUSDSKey), 98_999_897.814548e18);

        assertEq(IRateLimits(ethSllPAU_rateLimits).getCurrentRateLimit(sllSwapCompleteUSDTKey), 98_999_897.814548e6);
        assertEq(IRateLimits(ethSllPAU_rateLimits).getCurrentRateLimit(sllSwapCompleteUSDSKey), 100_000_000e18);

        assertEq(usdt.balanceOf(ethSpUSDTPAU_almProxy), 2_000_287.365990e6);
        assertEq(usds.balanceOf(ethSpUSDTPAU_almProxy), 0.000000752247429128e18);
        assertEq(usdt.balanceOf(Ethereum.ALM_PROXY),    999_897.814548e6);
        assertEq(usds.balanceOf(Ethereum.ALM_PROXY),    1_000_102.185452e18);

        // Step 14: ethSparkAgent (ethPlannerAgent) transfers 1_000_000e6 USDT + interest to Ethereum spUSDT vault using TransferAssetFacet

        assertEq(IRateLimits(ethSpUSDTPAU_rateLimits).getCurrentRateLimit(ethTransferKey), type(uint256).max);

        assertEq(usdt.balanceOf(ethSpUSDTPAU_almProxy), 2_000_287.365990e6);
        assertEq(usdt.balanceOf(address(ethSpUSDT)),    66_176_872.510365e6);

        vm.prank(SPARK_PLANNER_HOT_WALLET);
        IAdministeredAgentLike(ethPlannerAgent).call(
            ethSparkAgent,
            abi.encodeCall(
                IAdministeredAgentLike.call,
                (
                    ethSpUSDTPAU_controller,
                    abi.encodeCall(
                        ITransferAssetController.transferAsset_transfer,
                        (Ethereum.USDT, address(ethSpUSDT), 1_000_114.038486e6) // 114.038486e6 is the interest owed to the user on Ethereum
                    )
                )
            )
        );

        assertEq(IRateLimits(ethSpUSDTPAU_rateLimits).getCurrentRateLimit(ethTransferKey), type(uint256).max);

        assertEq(usdt.balanceOf(ethSpUSDTPAU_almProxy), 1_000_173.327504e6);
        assertEq(usdt.balanceOf(address(ethSpUSDT)),    67_176_986.548851e6);

        // Step 15: ethSparkAgent (ethPlannerAgent) bridges 1_000_000e6 USDT + interest to Arbitrum spUSDT PAU using LayerZeroFacet

        assertEq(IRateLimits(ethSpUSDTPAU_rateLimits).getCurrentRateLimit(ethLayerZeroKey), 5_000_000e6);

        assertEq(usdt.balanceOf(ethSpUSDTPAU_almProxy), 1_000_173.327504e6);
        assertEq(usdt.balanceOf(Ethereum.USDT_OFT),     3_668_379_157.913483e6);

        ( , ILayerZeroFacet.MessagingFee memory ethFee ) = IEthSpUSDTController(ethSpUSDTPAU_controller)
            .layerZero_quoteTransfer(Ethereum.USDT_OFT, 1_000_114.038487e6, LZ_ARBITRUM_EID);

        vm.prank(SPARK_PLANNER_HOT_WALLET);
        IAdministeredAgentLike(ethPlannerAgent).call{ value: ethFee.nativeFee }(
            ethSparkAgent,
            abi.encodeCall(
                IAdministeredAgentLike.call,
                (
                    ethSpUSDTPAU_controller,
                    abi.encodeCall(
                        ILayerZeroController.layerZero_transfer,
                        (Ethereum.USDT_OFT, 1_000_114.038487e6, LZ_ARBITRUM_EID) // 114.038487e6 is the interest owed to the user on Arbitrum
                    )
                )
            )
        );

        assertEq(IRateLimits(ethSpUSDTPAU_rateLimits).getCurrentRateLimit(ethLayerZeroKey), 5_000_000e6 - 1_000_114.038487e6);

        // USDT is locked in the OFT adapter on Ethereum.
        assertEq(usdt.balanceOf(ethSpUSDTPAU_almProxy), 59.289017e6);
        assertEq(usdt.balanceOf(Ethereum.USDT_OFT),     3_669_379_271.951970e6);

        // Step 16: Relay the message to Arbitrum

        arbitrum.selectFork();

        assertEq(usdt0.balanceOf(arbSpUSDTPAU_almProxy), 0);
        assertEq(usdt0.totalSupply(),                    894_730_435.701070e6);

        lzBridge.relayMessagesToSource(true, Ethereum.USDT_OFT, Arbitrum.USDT_OFT);

        // USDT0 is minted on Arbitrum.
        assertEq(usdt0.balanceOf(arbSpUSDTPAU_almProxy), 1_000_114.038487e6);
        assertEq(usdt0.totalSupply(),                    895_730_549.739557e6);

        // Step 17: arbSparkAgent (arbPlannerAgent) transfers 1_000_000e6 USDT + interest to Arbitrum spUSDT vault using TransferAssetFacet

        assertEq(IRateLimits(arbSpUSDTPAU_rateLimits).getCurrentRateLimit(arbTransferKey), type(uint256).max);

        assertEq(usdt0.balanceOf(arbSpUSDTPAU_almProxy), 1_000_114.038487e6);
        assertEq(usdt0.balanceOf(address(arbSpUSDT)),    1_053_682.977823e6);

        vm.prank(SPARK_PLANNER_HOT_WALLET);
        IAdministeredAgentLike(arbPlannerAgent).call(
            arbSparkAgent,
            abi.encodeCall(
                IAdministeredAgentLike.call,
                (
                    arbSpUSDTPAU_controller,
                    abi.encodeCall(
                        ITransferAssetController.transferAsset_transfer,
                        (Arbitrum.USDT0, address(arbSpUSDT), 1_000_114.038487e6) // 114.038487e6 is the interest owed to the user on Arbitrum
                    )
                )
            )
        );

        assertEq(IRateLimits(arbSpUSDTPAU_rateLimits).getCurrentRateLimit(arbTransferKey), type(uint256).max);

        assertEq(usdt0.balanceOf(arbSpUSDTPAU_almProxy), 0);
        assertEq(usdt0.balanceOf(address(arbSpUSDT)),    2_053_797.016310e6);

        // Step 18: User redeems their Ethereum spUSDT deposit and receives the 1_000_000e6 USDT + interest

        mainnet.selectFork();

        assertEq(usdt.balanceOf(user),               0);
        assertEq(usdt.balanceOf(address(ethSpUSDT)), 67_176_986.548851e6);

        assertEq(ethSpUSDT.totalAssets(),   296_390_056.659257e6);
        assertEq(ethSpUSDT.totalSupply(),   285_763_058.534234e6);
        assertEq(ethSpUSDT.balanceOf(user), 964_255.176919e6);

        vm.prank(user);
        ethSpUSDT.redeem(964_255.176919e6, user, user);

        assertEq(usdt.balanceOf(user),               1_000_114.038486e6);
        assertEq(usdt.balanceOf(address(ethSpUSDT)), 66_176_872.510365e6);

        assertEq(ethSpUSDT.totalAssets(),   295_389_942.620770e6);
        assertEq(ethSpUSDT.totalSupply(),   284_798_803.357315e6);
        assertEq(ethSpUSDT.balanceOf(user), 0);

        // Step 19: User redeems their Arbitrum spUSDT deposit and receives the 1_000_000e6 USDT + interest

        arbitrum.selectFork();

        assertEq(usdt0.balanceOf(user),               0);
        assertEq(usdt0.balanceOf(address(arbSpUSDT)), 2_053_797.016310e6);

        assertEq(arbSpUSDT.totalAssets(),   2_055_126.743614e6);
        assertEq(arbSpUSDT.totalSupply(),   2_031_477.905271e6);
        assertEq(arbSpUSDT.balanceOf(user), 988_605.485404e6);

        vm.prank(user);
        arbSpUSDT.redeem(988_605.485404e6, user, user);

        assertEq(usdt0.balanceOf(user),               1_000_114.038487e6);
        assertEq(usdt0.balanceOf(address(arbSpUSDT)), 1_053_682.977823e6);

        assertEq(arbSpUSDT.totalAssets(),   1_055_012.705127e6);
        assertEq(arbSpUSDT.totalSupply(),   1_042_872.419867e6);
        assertEq(arbSpUSDT.balanceOf(user), 0);

        // The unused buffer and the USDS swap dust on Ethereum, nothing on Arbitrum.
        assertEq(usdt0.balanceOf(arbSpUSDTPAU_almProxy), 0);

        mainnet.selectFork();

        assertEq(usdt.balanceOf(ethSpUSDTPAU_almProxy), 59.289017e6);             // Remaining dust from the buffer deal of 100e6
        assertEq(usds.balanceOf(ethSpUSDTPAU_almProxy), 0.000000752247429128e18); // Remaining USDS swap dust
    }

}
