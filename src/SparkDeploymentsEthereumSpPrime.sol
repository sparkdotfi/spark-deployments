// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ERC1967Proxy } from "../lib/spark-prime-vault/lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Ethereum } from "../lib/spark-address-registry/src/Ethereum.sol";

import { ISparkPrimeVault } from "../lib/spark-prime-vault/src/ISparkPrimeVault.sol";

import { IAccessControls } from "../lib/diamond-pau/src/interfaces/IAccessControls.sol";
import { IALMProxy }       from "../lib/diamond-pau/src/interfaces/IALMProxy.sol";
import { IController }     from "../lib/diamond-pau/src/interfaces/IController.sol";
import { IPAUFactory }     from "../lib/diamond-pau/src/interfaces/IPAUFactory.sol";
import { IRateLimits }     from "../lib/diamond-pau/src/interfaces/IRateLimits.sol";

import { IERC4626Controller }       from "../lib/diamond-pau/src/facets/erc4626/IERC4626Controller.sol";
import { ISparkVaultController }    from "../lib/diamond-pau/src/facets/spark-vault/ISparkVaultController.sol";
import { ITransferAssetController } from "../lib/diamond-pau/src/facets/transfer-asset/ITransferAssetController.sol";

import { BeamState }    from "../lib/pas/src/BeamState.sol";
import { Configurator } from "../lib/pas/src/Configurator.sol";
import { Timelock }     from "../lib/pas/src/timelock/Timelock.sol";

import { PASInit }     from "../lib/pas/deploy/PASInit.sol";
import { PASInstance } from "../lib/pas/deploy/PASInstance.sol";

interface IERC20Like {

    function decimals() external view returns (uint8);

}

interface IERC4626Like {

    function asset() external view returns (address);

}

/**
 * @title  SparkDeploymentsEthereumSpPrime
 * @notice Single use deployment spell for PAS, Spark Prime Vault (spPrime) and its two PAU stacks
 *         (spPrimePAU and flcPAU) on Ethereum mainnet. The constructor deploys, configures and
 *         hands every contract over to its final owners. The spell holds no role afterwards.
 */
contract SparkDeploymentsEthereumSpPrime {

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    uint256 internal constant ETHEREUM_MAINNET = 1;

    // ROLES

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant ALLOCATOR_ROLE     = keccak256("ALLOCATOR_ROLE");

    // PAU BEACON

    address internal constant PAU_BEACON = Ethereum.SPARK_BEACON;

    bytes32 internal constant TRANSFER_ASSET_FACET = "TRANSFER_ASSET_FACET";
    bytes32 internal constant ERC4626_FACET        = "ERC4626_FACET";
    bytes32 internal constant SPARK_VAULT_FACET    = "SPARK_VAULT_FACET";

    // PAS CONFIG

    // TODO: Replace with the final PAS addresses.
    address internal constant PAS_OWNER        = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;
    address internal constant PAS_CORE_COUNCIL = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;
    address internal constant PAS_CANCELLER    = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;
    address internal constant PAS_PAUSER       = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    uint256 internal constant PAS_MIN_DELAY = 100_000;

    // ADMINISTERED AGENT

    // TODO: Confirm this is the correct AdministeredAgent.
    address internal constant ADMINISTERED_AGENT = Ethereum.SPUSDC_PAU_ADMINISTERED_AGENT;

    // SPARK PRIME VAULT CONFIG

    // TODO: Replace with the final owner addresses.
    address internal constant SPPRIME_ADMIN     = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;
    address internal constant PAUSER            = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;
    address internal constant UNPAUSER          = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;
    address internal constant OPERATOR          = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;
    address internal constant REDEEM_FEE_SETTER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;
    address internal constant LOSS_MANAGER      = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    address internal constant SPUSDC = Ethereum.SPARK_VAULT_V2_SPUSDC;

    string internal constant NAME   = "Spark Prime USDC";
    string internal constant SYMBOL = "spPrime";

    // TODO: Replace with the final values.
    uint256 internal constant MIN_DEPOSIT              = 1_000e6;  // USDC
    uint256 internal constant MIN_DEPOSIT_CANCELLATION = 1_000e6;  // spUSDC shares
    uint256 internal constant MIN_REDEEM               = 1_000e6;  // spPrime shares
    uint256 internal constant MIN_VSR                  = 1e27;
    uint256 internal constant MAX_VSR                  = 1e27;
    uint256 internal constant MAX_REDEEM_FEE_RATE      = 1;

    // SPPRIME PAU CONFIG

    // TODO: Replace with the final owner address.
    address internal constant SPPRIME_PAU_ADMIN = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    bytes32 internal constant SPPRIME_PAU_SALT = "SPPRIME_PAU";

    // TransferAsset: spPrimePAU returns spUSDC to spPrime
    uint256 internal constant SPPRIME_PAU_TRANSFER_MAX   = 100_000_000e6;
    uint256 internal constant SPPRIME_PAU_TRANSFER_SLOPE = 0;

    // ERC4626: Wrap USDC into spUSDC and unwrap spUSDC into USDC
    uint256 internal constant SPPRIME_PAU_ERC4626_DEPOSIT_MAX    = 0;
    uint256 internal constant SPPRIME_PAU_ERC4626_DEPOSIT_SLOPE  = 0;
    uint256 internal constant SPPRIME_PAU_ERC4626_WITHDRAW_MAX   = 0;
    uint256 internal constant SPPRIME_PAU_ERC4626_WITHDRAW_SLOPE = 0;

    uint256 internal constant SPUSDC_MAX_EXCHANGE_RATE_SHARES = 1e6;
    uint256 internal constant SPUSDC_MAX_EXCHANGE_RATE_ASSETS = 10e6;

    // SparkVault: spUSDC taken out of spPrime
    uint256 internal constant SPPRIME_PAU_TAKE_MAX   = 100_000_000e6;
    uint256 internal constant SPPRIME_PAU_TAKE_SLOPE = 0;

    // FLC PAU CONFIG

    // TODO: Replace with the final owner address.
    address internal constant FLC_PAU_ADMIN = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    bytes32 internal constant FLC_PAU_SALT = "FLC_PAU";

    // TransferAsset: FLCPAU returns spUSDC to spPrimePAU ALMProxy
    uint256 internal constant FLC_PAU_TRANSFER_MAX   = 100_000_000e6;
    uint256 internal constant FLC_PAU_TRANSFER_SLOPE = 0;

    /**********************************************************************************************/
    /*** Deployed contracts                                                                     ***/
    /**********************************************************************************************/

    address public immutable PAS_BEAM_STATE;
    address public immutable PAS_CONFIGURATOR;
    address public immutable PAS_TIMELOCK;

    address public immutable SPPRIME;

    address public immutable SPPRIME_PAU_ACCESS_CONTROLS;
    address public immutable SPPRIME_PAU_ALM_PROXY;
    address public immutable SPPRIME_PAU_CONTROLLER;
    address public immutable SPPRIME_PAU_RATE_LIMITS;

    address public immutable FLC_PAU_ACCESS_CONTROLS;
    address public immutable FLC_PAU_ALM_PROXY;
    address public immutable FLC_PAU_CONTROLLER;
    address public immutable FLC_PAU_RATE_LIMITS;

    /**********************************************************************************************/
    /*** Constructor                                                                            ***/
    /**********************************************************************************************/

    constructor(address pauFactory, address spPrimeImplementation) {
        _assertPreconditions(pauFactory, spPrimeImplementation);

        // Step 1: Deploy PAS with the spell as temporary owner

        PAS_BEAM_STATE   = address(new BeamState());
        PAS_CONFIGURATOR = address(new Configurator(PAS_BEAM_STATE));
        PAS_TIMELOCK     = address(new Timelock(PAS_MIN_DELAY, address(this)));

        // Step 2: Deploy spPrime with the spell as temporary admin

        SPPRIME = address(new ERC1967Proxy(
            spPrimeImplementation,
            abi.encodeCall(
                ISparkPrimeVault.initialize,
                (
                    SPUSDC,
                    NAME,
                    SYMBOL,
                    address(this),
                    MIN_DEPOSIT,
                    MIN_DEPOSIT_CANCELLATION,
                    MIN_REDEEM
                )
            )
        ));

        // Step 3: Deploy the PAU stacks with the spell as temporary admin

        SPPRIME_PAU_CONTROLLER      = IPAUFactory(pauFactory).deployPAU(address(this), SPPRIME_PAU_SALT);
        SPPRIME_PAU_ACCESS_CONTROLS = IController(SPPRIME_PAU_CONTROLLER).accessControls();
        SPPRIME_PAU_ALM_PROXY       = IController(SPPRIME_PAU_CONTROLLER).proxy();
        SPPRIME_PAU_RATE_LIMITS     = IController(SPPRIME_PAU_CONTROLLER).rateLimits();

        FLC_PAU_CONTROLLER      = IPAUFactory(pauFactory).deployPAU(address(this), FLC_PAU_SALT);
        FLC_PAU_ACCESS_CONTROLS = IController(FLC_PAU_CONTROLLER).accessControls();
        FLC_PAU_ALM_PROXY       = IController(FLC_PAU_CONTROLLER).proxy();
        FLC_PAU_RATE_LIMITS     = IController(FLC_PAU_CONTROLLER).rateLimits();

        // Step 4: Configure PAS, spPrime and the PAU stacks

        _configurePAS();
        _configureSpPrime();
        _configureSpPrimePAU();
        _configureFlcPAU();

        // Step 5: Hand admin rights over and revoke the spell's admin role

        _handoffPAS();

        _handoff(SPPRIME, SPPRIME_ADMIN);

        _handoff(SPPRIME_PAU_ACCESS_CONTROLS, SPPRIME_PAU_ADMIN);
        _handoff(SPPRIME_PAU_RATE_LIMITS,     SPPRIME_PAU_ADMIN);
        _handoff(SPPRIME_PAU_ALM_PROXY,       SPPRIME_PAU_ADMIN);

        _handoff(FLC_PAU_ACCESS_CONTROLS, FLC_PAU_ADMIN);
        _handoff(FLC_PAU_RATE_LIMITS,     FLC_PAU_ADMIN);
        _handoff(FLC_PAU_ALM_PROXY,       FLC_PAU_ADMIN);
    }

    /**********************************************************************************************/
    /*** Configuration helpers                                                                  ***/
    /**********************************************************************************************/

    function _configurePAS() internal {
        address[] memory cancellers = new address[](1);
        cancellers[0] = PAS_CANCELLER;

        address[] memory pausers = new address[](1);
        pausers[0] = PAS_PAUSER;

        PASInit.init({
            pasInstance : PASInstance({
                beamState    : PAS_BEAM_STATE,
                configurator : PAS_CONFIGURATOR,
                timelock     : PAS_TIMELOCK
            }),
            minDelay    : PAS_MIN_DELAY,
            coreCouncil : PAS_CORE_COUNCIL,
            cancellers  : cancellers,
            pausers     : pausers
        });
    }

    function _configureSpPrime() internal {
        ISparkPrimeVault spPrime = ISparkPrimeVault(SPPRIME);

        spPrime.setVSRBounds(MIN_VSR, MAX_VSR);
        spPrime.setMaxRedeemFeeRate(MAX_REDEEM_FEE_RATE);

        spPrime.grantRole(spPrime.PAUSER_ROLE(),            PAUSER);
        spPrime.grantRole(spPrime.UNPAUSER_ROLE(),          UNPAUSER);
        spPrime.grantRole(spPrime.OPERATOR_ROLE(),          OPERATOR);
        spPrime.grantRole(spPrime.REDEEM_FEE_SETTER_ROLE(), REDEEM_FEE_SETTER);
        spPrime.grantRole(spPrime.LOSS_MANAGER_ROLE(),      LOSS_MANAGER);

        // The spPrimePAU pulls spUSDC out of spPrime through its ALMProxy.
        spPrime.grantRole(spPrime.TAKER_ROLE(), SPPRIME_PAU_ALM_PROXY);
    }

    function _configureSpPrimePAU() internal {
        // Configure the PAU roles

        _configurePAURoles(
            SPPRIME_PAU_ACCESS_CONTROLS,
            SPPRIME_PAU_ALM_PROXY,
            SPPRIME_PAU_CONTROLLER,
            SPPRIME_PAU_RATE_LIMITS
        );

        // Facet onboarding

        bytes32[] memory integrationIds = new bytes32[](3);
        integrationIds[0] = TRANSFER_ASSET_FACET;
        integrationIds[1] = ERC4626_FACET;
        integrationIds[2] = SPARK_VAULT_FACET;

        IController(SPPRIME_PAU_CONTROLLER).updateIntegrations(integrationIds);

        // Configure the Rate limits

        IRateLimits rateLimits = IRateLimits(SPPRIME_PAU_RATE_LIMITS);

        rateLimits.setRateLimitData(
            ITransferAssetController(SPPRIME_PAU_CONTROLLER).transferAsset_getTransferRateLimitKey(
                SPUSDC,
                SPPRIME
            ),
            SPPRIME_PAU_TRANSFER_MAX,
            SPPRIME_PAU_TRANSFER_SLOPE
        );

        IERC4626Controller erc4626 = IERC4626Controller(SPPRIME_PAU_CONTROLLER);

        rateLimits.setRateLimitData(
            erc4626.erc4626_getDepositRateLimitKey(SPUSDC, Ethereum.USDC),
            SPPRIME_PAU_ERC4626_DEPOSIT_MAX,
            SPPRIME_PAU_ERC4626_DEPOSIT_SLOPE
        );
        rateLimits.setRateLimitData(
            erc4626.erc4626_getWithdrawRateLimitKey(SPUSDC),
            SPPRIME_PAU_ERC4626_WITHDRAW_MAX,
            SPPRIME_PAU_ERC4626_WITHDRAW_SLOPE
        );

        erc4626.erc4626_setMaxExchangeRate(
            SPUSDC,
            SPUSDC_MAX_EXCHANGE_RATE_SHARES,
            SPUSDC_MAX_EXCHANGE_RATE_ASSETS
        );

        rateLimits.setRateLimitData(
            ISparkVaultController(SPPRIME_PAU_CONTROLLER).sparkVault_getTakeRateLimitKey(SPPRIME),
            SPPRIME_PAU_TAKE_MAX,
            SPPRIME_PAU_TAKE_SLOPE
        );
    }

    function _configureFlcPAU() internal {
        // Configure the PAU roles

        _configurePAURoles(
            FLC_PAU_ACCESS_CONTROLS,
            FLC_PAU_ALM_PROXY,
            FLC_PAU_CONTROLLER,
            FLC_PAU_RATE_LIMITS
        );

        // Facet onboarding

        bytes32[] memory integrationIds = new bytes32[](1);
        integrationIds[0] = TRANSFER_ASSET_FACET;

        IController(FLC_PAU_CONTROLLER).updateIntegrations(integrationIds);

        // Configure the Rate limits

        IRateLimits(FLC_PAU_RATE_LIMITS).setRateLimitData(
            ITransferAssetController(FLC_PAU_CONTROLLER).transferAsset_getTransferRateLimitKey(
                SPUSDC,
                SPPRIME_PAU_ALM_PROXY
            ),
            FLC_PAU_TRANSFER_MAX,
            FLC_PAU_TRANSFER_SLOPE
        );
    }

    function _configurePAURoles(
        address accessControls,
        address almProxy,
        address controller,
        address rateLimits
    )
        internal
    {
        IALMProxy(almProxy).grantRole(IALMProxy(almProxy).CONTROLLER(),         controller);
        IRateLimits(rateLimits).grantRole(IRateLimits(rateLimits).CONTROLLER(), controller);

        IAccessControls(accessControls).grantRole(ALLOCATOR_ROLE, ADMINISTERED_AGENT);

        // The PAS Configurator administers the AccessControls and the RateLimits.
        IAccessControls(accessControls).grantRole(DEFAULT_ADMIN_ROLE, PAS_CONFIGURATOR);
        IRateLimits(rateLimits).grantRole(DEFAULT_ADMIN_ROLE,         PAS_CONFIGURATOR);
    }

    /**********************************************************************************************/
    /*** Handoff                                                                                ***/
    /**********************************************************************************************/

    function _handoffPAS() internal {
        BeamState(PAS_BEAM_STATE).rely(PAS_OWNER);
        BeamState(PAS_BEAM_STATE).deny(address(this));

        require(BeamState(PAS_BEAM_STATE).wards(PAS_OWNER)     == 1, "SparkDeploymentsEthereumSpPrime/beam-state-owner-not-set");
        require(BeamState(PAS_BEAM_STATE).wards(address(this)) == 0, "SparkDeploymentsEthereumSpPrime/spell-still-beam-state-ward");

        _handoff(PAS_TIMELOCK, PAS_OWNER);
    }

    function _handoff(address target, address admin) internal {
        IAccessControls(target).grantRole(DEFAULT_ADMIN_ROLE,  admin);
        IAccessControls(target).revokeRole(DEFAULT_ADMIN_ROLE, address(this));

        require(
            IAccessControls(target).hasRole(DEFAULT_ADMIN_ROLE, admin),
            "SparkDeploymentsEthereumSpPrime/admin-not-set"
        );
        require(
            !IAccessControls(target).hasRole(DEFAULT_ADMIN_ROLE, address(this)),
            "SparkDeploymentsEthereumSpPrime/spell-still-admin"
        );
    }

    /**********************************************************************************************/
    /*** Assertions                                                                             ***/
    /**********************************************************************************************/

    function _assertPreconditions(address pauFactory, address spPrimeImplementation) internal view {
        require(block.chainid == ETHEREUM_MAINNET, "SparkDeploymentsEthereumSpPrime/invalid-chain-id");

        // Guards against a wrong constructor argument or an unfilled placeholder.
        require(spPrimeImplementation.code.length > 0, "SparkDeploymentsEthereumSpPrime/no-spprime-implementation");
        require(pauFactory.code.length            > 0, "SparkDeploymentsEthereumSpPrime/no-pau-factory");
        require(PAU_BEACON.code.length            > 0, "SparkDeploymentsEthereumSpPrime/no-pau-beacon");
        require(ADMINISTERED_AGENT.code.length    > 0, "SparkDeploymentsEthereumSpPrime/no-administered-agent");

        require(IPAUFactory(pauFactory).beacon() == PAU_BEACON, "SparkDeploymentsEthereumSpPrime/invalid-pau-beacon");
    }

}
