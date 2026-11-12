// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { ERC1967Proxy } from "../../../lib/spark-prime-vault/lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Ethereum } from "../../../lib/spark-address-registry/src/Ethereum.sol";

import { ISparkPrimeVault } from "../../../lib/spark-prime-vault/src/ISparkPrimeVault.sol";

import { IAccessControls } from "../../../lib/diamond-pau/src/interfaces/IAccessControls.sol";
import { IALMProxy }       from "../../../lib/diamond-pau/src/interfaces/IALMProxy.sol";
import { IController }     from "../../../lib/diamond-pau/src/interfaces/IController.sol";
import { IPAUFactory }     from "../../../lib/diamond-pau/src/interfaces/IPAUFactory.sol";
import { IRateLimits }     from "../../../lib/diamond-pau/src/interfaces/IRateLimits.sol";

import { IERC4626Controller }       from "../../../lib/diamond-pau/src/facets/erc4626/IERC4626Controller.sol";
import { ISparkVaultController }    from "../../../lib/diamond-pau/src/facets/spark-vault/ISparkVaultController.sol";
import { ITransferAssetController } from "../../../lib/diamond-pau/src/facets/transfer-asset/ITransferAssetController.sol";

/**
 * @title  SparkEthereumDeploySpPrime
 * @notice Single use deployment spell for Spark Prime Vault (spPrime) and its two PAU stacks
 *         (spPrimePAU and flcPAU) on Ethereum mainnet. The constructor deploys, configures and
 *         hands every contract over to its final owners. The spell holds no role afterwards.
 *         Requires PAS, deployed by SparkDeploymentsEthereumPAS.
 */
contract SparkEthereumDeploySpPrime {

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    uint256 internal constant MAINNET = 1;

    // ROLES

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant ALLOCATOR_ROLE     = keccak256("ALLOCATOR_ROLE");

    // PAU BEACON

    address internal constant PAU_BEACON = Ethereum.SPARK_BEACON;

    bytes32 internal constant TRANSFER_ASSET_FACET = "TRANSFER_ASSET_FACET";
    bytes32 internal constant ERC4626_FACET        = "ERC4626_FACET";
    bytes32 internal constant SPARK_VAULT_FACET    = "SPARK_VAULT_FACET";

    // ADMINISTERED AGENT

    // TODO: Confirm this is the correct AdministeredAgent.
    address internal constant ADMINISTERED_AGENT = Ethereum.SPUSDC_PAU_ADMINISTERED_AGENT;

    // SPARK PRIME VAULT CONFIG

    // TODO: Replace with the final addresses.
    address internal constant SPPRIME_ADMIN             = address(1);
    address internal constant SPPRIME_PAUSER            = address(2);
    address internal constant SPPRIME_UNPAUSER          = address(3);
    address internal constant SPPRIME_OPERATOR          = address(4);
    address internal constant SPPRIME_REDEEM_FEE_SETTER = address(5);
    address internal constant SPPRIME_LOSS_MANAGER      = address(6);

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

    // TODO: Replace with the final address.
    address internal constant SPPRIME_PAU_ADMIN = address(7);

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

    // TODO: Replace with the final address.
    address internal constant FLC_PAU_ADMIN = address(8);

    bytes32 internal constant FLC_PAU_SALT = "FLC_PAU";

    // TransferAsset: FLCPAU returns spUSDC to spPrimePAU ALMProxy
    uint256 internal constant FLC_PAU_TRANSFER_MAX   = 100_000_000e6;
    uint256 internal constant FLC_PAU_TRANSFER_SLOPE = 0;

    /**********************************************************************************************/
    /*** Deployed contracts                                                                     ***/
    /**********************************************************************************************/

    struct SpPrimeDeploymentReport {
        address spPrime;
        address spPrimePAUAccessControls;
        address spPrimePAUAlmProxy;
        address spPrimePAUController;
        address spPrimePAURateLimits;
        address flcPAUAccessControls;
        address flcPAUAlmProxy;
        address flcPAUController;
        address flcPAURateLimits;
    }

    SpPrimeDeploymentReport internal _spPrimeDeployment;

    function spPrimeDeployment() external view returns (SpPrimeDeploymentReport memory) {
        return _spPrimeDeployment;
    }

    /**********************************************************************************************/
    /*** Constructor                                                                            ***/
    /**********************************************************************************************/

    constructor(address pasConfigurator) {
        _assertPreconditions(Ethereum.SPARK_PAU_FACTORY, Ethereum.SPPRIME_IMPL, pasConfigurator);

        // Step 1: Deploy spPrime with the spell as temporary admin

        _spPrimeDeployment.spPrime = address(new ERC1967Proxy(
            Ethereum.SPPRIME_IMPL,
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

        // Step 2: Deploy the PAU stacks with the spell as temporary admin

        _spPrimeDeployment.spPrimePAUController     = IPAUFactory(Ethereum.SPARK_PAU_FACTORY).deployPAU(address(this), SPPRIME_PAU_SALT);
        _spPrimeDeployment.spPrimePAUAccessControls = IController(_spPrimeDeployment.spPrimePAUController).accessControls();
        _spPrimeDeployment.spPrimePAUAlmProxy       = IController(_spPrimeDeployment.spPrimePAUController).proxy();
        _spPrimeDeployment.spPrimePAURateLimits     = IController(_spPrimeDeployment.spPrimePAUController).rateLimits();

        _spPrimeDeployment.flcPAUController     = IPAUFactory(Ethereum.SPARK_PAU_FACTORY).deployPAU(address(this), FLC_PAU_SALT);
        _spPrimeDeployment.flcPAUAccessControls = IController(_spPrimeDeployment.flcPAUController).accessControls();
        _spPrimeDeployment.flcPAUAlmProxy       = IController(_spPrimeDeployment.flcPAUController).proxy();
        _spPrimeDeployment.flcPAURateLimits     = IController(_spPrimeDeployment.flcPAUController).rateLimits();

        // Step 3: Configure spPrime and the PAU stacks

        _configureSpPrime();
        _configureSpPrimePAU(pasConfigurator);
        _configureFlcPAU(pasConfigurator);

        // Step 4: Hand admin rights over and revoke the spell's admin role

        _handoff(_spPrimeDeployment.spPrime, SPPRIME_ADMIN);

        _handoff(_spPrimeDeployment.spPrimePAUAccessControls, SPPRIME_PAU_ADMIN);
        _handoff(_spPrimeDeployment.spPrimePAURateLimits,     SPPRIME_PAU_ADMIN);
        _handoff(_spPrimeDeployment.spPrimePAUAlmProxy,       SPPRIME_PAU_ADMIN);

        _handoff(_spPrimeDeployment.flcPAUAccessControls, FLC_PAU_ADMIN);
        _handoff(_spPrimeDeployment.flcPAURateLimits,     FLC_PAU_ADMIN);
        _handoff(_spPrimeDeployment.flcPAUAlmProxy,       FLC_PAU_ADMIN);
    }

    /**********************************************************************************************/
    /*** Configuration helpers                                                                  ***/
    /**********************************************************************************************/

    function _configureSpPrime() internal {
        ISparkPrimeVault spPrime = ISparkPrimeVault(_spPrimeDeployment.spPrime);

        spPrime.setVSRBounds(MIN_VSR, MAX_VSR);
        spPrime.setMaxRedeemFeeRate(MAX_REDEEM_FEE_RATE);

        spPrime.grantRole(spPrime.PAUSER_ROLE(),            SPPRIME_PAUSER);
        spPrime.grantRole(spPrime.UNPAUSER_ROLE(),          SPPRIME_UNPAUSER);
        spPrime.grantRole(spPrime.OPERATOR_ROLE(),          SPPRIME_OPERATOR);
        spPrime.grantRole(spPrime.REDEEM_FEE_SETTER_ROLE(), SPPRIME_REDEEM_FEE_SETTER);
        spPrime.grantRole(spPrime.LOSS_MANAGER_ROLE(),      SPPRIME_LOSS_MANAGER);

        // The spPrimePAU pulls spUSDC out of spPrime through its ALMProxy.
        spPrime.grantRole(spPrime.TAKER_ROLE(), _spPrimeDeployment.spPrimePAUAlmProxy);
    }

    function _configureSpPrimePAU(address pasConfigurator) internal {
        // Configure the PAU roles

        _configurePAURoles(
            _spPrimeDeployment.spPrimePAUAccessControls,
            _spPrimeDeployment.spPrimePAUAlmProxy,
            _spPrimeDeployment.spPrimePAUController,
            _spPrimeDeployment.spPrimePAURateLimits,
            pasConfigurator
        );

        // Facet onboarding

        bytes32[] memory integrationIds = new bytes32[](3);
        integrationIds[0] = TRANSFER_ASSET_FACET;
        integrationIds[1] = ERC4626_FACET;
        integrationIds[2] = SPARK_VAULT_FACET;

        IController(_spPrimeDeployment.spPrimePAUController).updateIntegrations(integrationIds);

        // Configure the Rate limits

        IRateLimits rateLimits = IRateLimits(_spPrimeDeployment.spPrimePAURateLimits);

        rateLimits.setRateLimitData(
            ITransferAssetController(_spPrimeDeployment.spPrimePAUController).transferAsset_getTransferRateLimitKey(
                SPUSDC,
                _spPrimeDeployment.spPrime
            ),
            SPPRIME_PAU_TRANSFER_MAX,
            SPPRIME_PAU_TRANSFER_SLOPE
        );

        IERC4626Controller erc4626 = IERC4626Controller(_spPrimeDeployment.spPrimePAUController);

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
            ISparkVaultController(_spPrimeDeployment.spPrimePAUController).sparkVault_getTakeRateLimitKey(_spPrimeDeployment.spPrime),
            SPPRIME_PAU_TAKE_MAX,
            SPPRIME_PAU_TAKE_SLOPE
        );
    }

    function _configureFlcPAU(address pasConfigurator) internal {
        // Configure the PAU roles

        _configurePAURoles(
            _spPrimeDeployment.flcPAUAccessControls,
            _spPrimeDeployment.flcPAUAlmProxy,
            _spPrimeDeployment.flcPAUController,
            _spPrimeDeployment.flcPAURateLimits,
            pasConfigurator
        );

        // Facet onboarding

        bytes32[] memory integrationIds = new bytes32[](1);
        integrationIds[0] = TRANSFER_ASSET_FACET;

        IController(_spPrimeDeployment.flcPAUController).updateIntegrations(integrationIds);

        // Configure the Rate limits

        IRateLimits(_spPrimeDeployment.flcPAURateLimits).setRateLimitData(
            ITransferAssetController(_spPrimeDeployment.flcPAUController).transferAsset_getTransferRateLimitKey(
                SPUSDC,
                _spPrimeDeployment.spPrimePAUAlmProxy
            ),
            FLC_PAU_TRANSFER_MAX,
            FLC_PAU_TRANSFER_SLOPE
        );
    }

    function _configurePAURoles(
        address accessControls,
        address almProxy,
        address controller,
        address rateLimits,
        address pasConfigurator
    )
        internal
    {
        IALMProxy(almProxy).grantRole(IALMProxy(almProxy).CONTROLLER(),         controller);
        IRateLimits(rateLimits).grantRole(IRateLimits(rateLimits).CONTROLLER(), controller);

        IAccessControls(accessControls).grantRole(ALLOCATOR_ROLE, ADMINISTERED_AGENT);

        // The PAS Configurator administers the AccessControls and the RateLimits.
        IAccessControls(accessControls).grantRole(DEFAULT_ADMIN_ROLE, pasConfigurator);
        IRateLimits(rateLimits).grantRole(DEFAULT_ADMIN_ROLE,         pasConfigurator);
    }

    /**********************************************************************************************/
    /*** Handoff                                                                                ***/
    /**********************************************************************************************/

    function _handoff(address target, address admin) internal {
        IAccessControls(target).grantRole(DEFAULT_ADMIN_ROLE,  admin);
        IAccessControls(target).revokeRole(DEFAULT_ADMIN_ROLE, address(this));

        require(
            IAccessControls(target).hasRole(DEFAULT_ADMIN_ROLE, admin),
            "SparkEthereumDeploySpPrime/admin-not-set"
        );
        require(
            !IAccessControls(target).hasRole(DEFAULT_ADMIN_ROLE, address(this)),
            "SparkEthereumDeploySpPrime/spell-still-admin"
        );
    }

    /**********************************************************************************************/
    /*** Assertions                                                                             ***/
    /**********************************************************************************************/

    function _assertPreconditions(
        address pauFactory,
        address spPrimeImplementation,
        address pasConfigurator
    )
        internal view
    {
        require(block.chainid == MAINNET, "SparkEthereumDeploySpPrime/invalid-chain-id");

        // Guards against a wrong constructor argument or an unfilled placeholder.
        require(spPrimeImplementation.code.length > 0, "SparkEthereumDeploySpPrime/no-spprime-implementation");
        require(pauFactory.code.length            > 0, "SparkEthereumDeploySpPrime/no-pau-factory");
        require(pasConfigurator.code.length       > 0, "SparkEthereumDeploySpPrime/no-pas-configurator");
        require(PAU_BEACON.code.length            > 0, "SparkEthereumDeploySpPrime/no-pau-beacon");
        require(ADMINISTERED_AGENT.code.length    > 0, "SparkEthereumDeploySpPrime/no-administered-agent");

        require(IPAUFactory(pauFactory).beacon() == PAU_BEACON, "SparkEthereumDeploySpPrime/invalid-pau-beacon");
    }

}
