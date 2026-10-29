// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { stdJson } from "../lib/forge-std/src/StdJson.sol";
import { Vm }      from "../lib/forge-std/src/Vm.sol";

import { ERC1967Proxy } from "../lib/spark-prime-vault/lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { SparkPrimeVault } from "../lib/spark-prime-vault/src/SparkPrimeVault.sol";

interface IAccessControlsLike {

    function grantRole(bytes32 role, address account) external;

    function revokeRole(bytes32 role, address account) external;

    function ALLOCATOR_ROLE() external view returns (bytes32);

}

interface IALMProxyLike {

    function CONTROLLER() external view returns (bytes32);

    function grantRole(bytes32 role, address account) external;

}

interface IControllerLike {

    function updateIntegrations(bytes32[] calldata ids) external;

    function erc4626_getDepositRateLimitKey(address token, address asset)
    external
    pure
    returns (bytes32 key);

    function erc4626_getWithdrawRateLimitKey(address token) external pure returns (bytes32 key);

    function transferAsset_getTransferRateLimitKey(address asset, address destination) external view returns (bytes32);

    function erc4626_setMaxExchangeRate(address token, uint256 shares, uint256 maxExpectedAssets) external;

    function sparkVault_getTakeRateLimitKey(address sparkVault) external pure returns (bytes32 key);
}

interface IERC20Like {
    function decimals() external view returns (uint8);
}

interface IRateLimitsLike {
    function CONTROLLER() external view returns (bytes32);

    function grantRole(bytes32 role, address account) external;

    function setRateLimitData(bytes32 key, uint256 maxAmount, uint256 slope) external;
}

interface IPAUFactoryLike {

    function deployAccessControls(address admin) external returns (address);

    function deployALMProxy(address admin) external returns (address);

    function deployController(address accessControls, address proxy, address rateLimits) external returns (address);

    function deployRateLimits(address admin) external returns (address);

}

abstract contract DeploySparkPrimeVaultBase {

    using stdJson for string;

    Vm private constant _vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct VaultConfig {
        address savingsVaultV2;
        string  name;
        string  symbol;
        address admin;
        uint256 minDeposit;
        uint256 minDepositCancellation;
        uint256 minRedeem;
        uint256 minVSR;
        uint256 maxVSR;
        uint256 maxRedeemFeeRate;
        address pauser;
        address unpauser;
        address operator;
        address redeemFeeSetter;
        address lossManager;
    }

    struct PAUInstance {
        address accessControls;
        address almProxy;
        address controller;
        address rateLimits;
    }

    struct TransferAssetRateLimit {
        address asset;
        string  destination;
        uint256 maxAmount;
        uint256 slopePerDay;
    }

    struct ERC4626RateLimit {
        string  token;
        address asset;
        uint256 depositMaxAmount;
        uint256 depositSlopePerDay;
        uint256 withdrawMaxAmount;
        uint256 withdrawSlopePerDay;
        uint256 maxExchangeRate;
    }

    struct SparkVaultRateLimit {
        string  sparkVault;
        uint256 maxAmount;
        uint256 slopePerDay;
    }

    struct PAUConfig {
        string                   name;
        address                  admin;
        bytes32[]                integrationIds;
        TransferAssetRateLimit[] transferAssetRateLimits;
        ERC4626RateLimit[]       erc4626RateLimits;
        SparkVaultRateLimit[]    sparkVaultRateLimits;
    }

    struct SparkPrimeVaultConfig {
        uint256     chainId;
        address     pauFactory;
        address     allocatorAgent;
        address     configurator;
        VaultConfig vault;
        PAUConfig[] paus;
    }

    struct DeployedInstance {
        address       spPrimeImplementation;
        address       spPrime;
        PAUInstance[] paus;
    }

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    function _deployAndConfigure(SparkPrimeVaultConfig memory cfg, address deployer) internal returns (DeployedInstance memory deployed) {
        require(block.chainid == cfg.chainId, "DeploySparkPrimeVaultBase/invalid-chain-id");

        // Step 1: Deploy the Spark Prime Vault with the deployer as temporary admin.

        deployed.spPrimeImplementation = address(new SparkPrimeVault());

        deployed.spPrime = address(new ERC1967Proxy(
            deployed.spPrimeImplementation,
            abi.encodeCall(
                SparkPrimeVault.initialize,
                (
                    cfg.vault.savingsVaultV2,
                    cfg.vault.name,
                    cfg.vault.symbol,
                    deployer,
                    cfg.vault.minDeposit,
                    cfg.vault.minDepositCancellation,
                    cfg.vault.minRedeem
                )
            )
        ));

        // Step 2: Deploy PAU stacks against the existing factory with deployer as temporary admin
        //         of AccessControls, RateLimits, and ALMProxy.

        deployed.paus = new PAUInstance[](cfg.paus.length);

        for (uint16 i; i < cfg.paus.length; ++i) {
            deployed.paus[i] = _deployPAU(cfg.pauFactory, deployer);
        }

        // Step 3: Configure the Spark Prime Vault.

        _configureVault(cfg.vault, deployed);

        // Step 4: Configure the PAU stacks.

        for (uint16 i; i < cfg.paus.length; ++i) {
            _configurePAU(cfg.paus[i], deployed, cfg.allocatorAgent, cfg.configurator, i);
        }

        // Step 5: Hand admin rights over and strip the deployer.

        // Vault admin handoff.

        require(cfg.vault.admin != deployer && cfg.vault.admin != address(0), "DeploySparkPrimeVaultBase/invalid-vault-admin");

        IAccessControlsLike(deployed.spPrime).grantRole(DEFAULT_ADMIN_ROLE,  cfg.vault.admin);
        IAccessControlsLike(deployed.spPrime).revokeRole(DEFAULT_ADMIN_ROLE, deployer);

        // PAUs admin handoff.

        for (uint16 i; i < cfg.paus.length; ++i) {
            require(cfg.paus[i].admin != deployer && cfg.paus[i].admin != address(0), "DeploySparkPrimeVaultBase/invalid-pau-admin");

            IAccessControlsLike(deployed.paus[i].accessControls).grantRole(DEFAULT_ADMIN_ROLE, cfg.paus[i].admin);
            IAccessControlsLike(deployed.paus[i].rateLimits).grantRole(DEFAULT_ADMIN_ROLE,     cfg.paus[i].admin);
            IAccessControlsLike(deployed.paus[i].almProxy).grantRole(DEFAULT_ADMIN_ROLE,       cfg.paus[i].admin);

            IAccessControlsLike(deployed.paus[i].accessControls).revokeRole(DEFAULT_ADMIN_ROLE, deployer);
            IAccessControlsLike(deployed.paus[i].rateLimits).revokeRole(DEFAULT_ADMIN_ROLE,     deployer);
            IAccessControlsLike(deployed.paus[i].almProxy).revokeRole(DEFAULT_ADMIN_ROLE,       deployer);
        }
    }

    function _deployPAU(address pauFactory_, address admin_) internal returns (PAUInstance memory deployed) {
        IPAUFactoryLike pauFactory = IPAUFactoryLike(pauFactory_);

        deployed.accessControls = pauFactory.deployAccessControls(admin_);
        deployed.almProxy       = pauFactory.deployALMProxy(admin_);
        deployed.rateLimits     = pauFactory.deployRateLimits(admin_);
        deployed.controller     = pauFactory.deployController(deployed.accessControls, deployed.almProxy, deployed.rateLimits);
    }

    function _configureVault(VaultConfig memory vaultCfg, DeployedInstance memory deployed) internal {
        SparkPrimeVault vault = SparkPrimeVault(deployed.spPrime);

        vault.setVSRBounds(vaultCfg.minVSR, vaultCfg.maxVSR);
        vault.setMaxRedeemFeeRate(vaultCfg.maxRedeemFeeRate);

        vault.grantRole(vault.PAUSER_ROLE(),            vaultCfg.pauser);
        vault.grantRole(vault.UNPAUSER_ROLE(),          vaultCfg.unpauser);
        vault.grantRole(vault.OPERATOR_ROLE(),          vaultCfg.operator);
        vault.grantRole(vault.REDEEM_FEE_SETTER_ROLE(), vaultCfg.redeemFeeSetter);
        vault.grantRole(vault.LOSS_MANAGER_ROLE(),      vaultCfg.lossManager);

        // The taker PAU pulls savings shares out of the vault through its ALMProxy.
        // Here we assume the first PAU is the taker PAU.
        vault.grantRole(vault.TAKER_ROLE(), deployed.paus[0].almProxy);
    }

    function _configurePAU(PAUConfig memory pauCfg, DeployedInstance memory deployed, address allocatorAgent_, address configurator_, uint16 index) internal {
        PAUInstance memory pau = deployed.paus[index];

        IControllerLike controller = IControllerLike(pau.controller);

        // Roles

        IALMProxyLike(pau.almProxy).grantRole(IALMProxyLike(pau.almProxy).CONTROLLER(),         pau.controller);
        IAccessControlsLike(pau.accessControls).grantRole(keccak256("ALLOCATOR_ROLE"),          allocatorAgent_);
        IAccessControlsLike(pau.accessControls).grantRole(DEFAULT_ADMIN_ROLE,                   configurator_);
        IRateLimitsLike(pau.rateLimits).grantRole(IRateLimitsLike(pau.rateLimits).CONTROLLER(), pau.controller);
        IAccessControlsLike(pau.rateLimits).grantRole(DEFAULT_ADMIN_ROLE,                       configurator_);

        // Facets onboarding

        controller.updateIntegrations(pauCfg.integrationIds);

        // Rate limits.

        IRateLimitsLike rateLimits = IRateLimitsLike(pau.rateLimits);

        for (uint256 i; i < pauCfg.transferAssetRateLimits.length; ++i) {
            TransferAssetRateLimit memory rl = pauCfg.transferAssetRateLimits[i];

            rateLimits.setRateLimitData(
                controller.transferAsset_getTransferRateLimitKey(rl.asset, _resolve(rl.destination, deployed)),
                rl.maxAmount,
                rl.slopePerDay / 1 days
            );
        }

        for (uint256 i; i < pauCfg.erc4626RateLimits.length; ++i) {
            ERC4626RateLimit memory rl = pauCfg.erc4626RateLimits[i];

            address token = _resolve(rl.token, deployed);

            rateLimits.setRateLimitData(
                controller.erc4626_getDepositRateLimitKey(token, rl.asset),
                rl.depositMaxAmount,
                rl.depositSlopePerDay / 1 days
            );
            rateLimits.setRateLimitData(
                controller.erc4626_getWithdrawRateLimitKey(token),
                rl.withdrawMaxAmount,
                rl.withdrawSlopePerDay / 1 days
            );

            controller.erc4626_setMaxExchangeRate(
                token,
                10 ** IERC20Like(token).decimals(),
                rl.maxExchangeRate * 10 ** IERC20Like(rl.asset).decimals()
            );
        }

        for (uint256 i; i < pauCfg.sparkVaultRateLimits.length; ++i) {
            SparkVaultRateLimit memory rl = pauCfg.sparkVaultRateLimits[i];

            rateLimits.setRateLimitData(
                controller.sparkVault_getTakeRateLimitKey(_resolve(rl.sparkVault, deployed)),
                rl.maxAmount,
                rl.slopePerDay / 1 days
            );
        }
    }

    function _resolve(string memory str, DeployedInstance memory deployed) internal pure returns (address) {
        if (_eq(str, "spPrime"))            return deployed.spPrime;
        if (_eq(str, "spPrimePAUAlmProxy")) return deployed.paus[0].almProxy;

        return _vm.parseAddress(str);
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _length(string memory config, string memory key) internal view returns (uint256 length) {
        while (config.keyExists(_index(key, length))) ++length;
    }

    function _index(string memory key, uint256 index) internal pure returns (string memory) {
        return string(abi.encodePacked(key, "[", _vm.toString(index), "]"));
    }

    function _parseConfig(string memory config, string[] memory paus) internal view returns (SparkPrimeVaultConfig memory cfg) {
        cfg.chainId        = config.readUint(".chainId");
        cfg.pauFactory     = config.readAddress(".pauFactory");
        cfg.allocatorAgent = config.readAddress(".allocatorAgent");
        cfg.configurator   = config.readAddress(".configurator");

        cfg.vault = VaultConfig({
            savingsVaultV2         : config.readAddress(".spPrime.savingsVaultV2"),
            name                   : config.readString(".spPrime.name"),
            symbol                 : config.readString(".spPrime.symbol"),
            admin                  : config.readAddress(".spPrime.admin"),
            minDeposit             : config.readUint(".spPrime.minimumDeposit"),
            minDepositCancellation : config.readUint(".spPrime.minimumDepositCancellation"),
            minRedeem              : config.readUint(".spPrime.minimumRedeem"),
            minVSR                 : config.readUint(".spPrime.minVSR"),
            maxVSR                 : config.readUint(".spPrime.maxVSR"),
            maxRedeemFeeRate       : config.readUint(".spPrime.maxRedeemFeeRate"),
            pauser                 : config.readAddress(".spPrime.pauser"),
            unpauser               : config.readAddress(".spPrime.unpauser"),
            operator               : config.readAddress(".spPrime.operator"),
            redeemFeeSetter        : config.readAddress(".spPrime.redeemFeeSetter"),
            lossManager            : config.readAddress(".spPrime.lossManager")
        });

        cfg.paus = new PAUConfig[](paus.length);

        for (uint16 i; i < paus.length; ++i) {
            string[] memory integrationIds = config.readStringArray(string(abi.encodePacked(".", paus[i], ".integrationIds")));

            bytes32[] memory integrationIdsBytes = new bytes32[](integrationIds.length);

            for (uint16 j; j < integrationIds.length; ++j) {
                integrationIdsBytes[j] = bytes32(abi.encodePacked(integrationIds[j]));
            }

            string memory key = string(abi.encodePacked(".", paus[i], ".transferAssetRateLimits"));

            TransferAssetRateLimit[] memory transferAssetRateLimitsStructs = new TransferAssetRateLimit[](_length(config, key));

            for (uint256 j; j < transferAssetRateLimitsStructs.length; ++j) {
                string memory entry = _index(key, j);

                transferAssetRateLimitsStructs[j] = TransferAssetRateLimit({
                    asset       : config.readAddress(string(abi.encodePacked(entry, ".asset"))),
                    destination : config.readString(string(abi.encodePacked(entry, ".destination"))),
                    maxAmount   : config.readUint(string(abi.encodePacked(entry, ".maxAmount"))),
                    slopePerDay : config.readUint(string(abi.encodePacked(entry, ".slope")))
                });
            }

            key = string(abi.encodePacked(".", paus[i], ".erc4626RateLimits"));

            ERC4626RateLimit[] memory erc4626RateLimitsStructs = new ERC4626RateLimit[](_length(config, key));

            for (uint256 j; j < erc4626RateLimitsStructs.length; ++j) {
                string memory entry = _index(key, j);

                erc4626RateLimitsStructs[j] = ERC4626RateLimit({
                    token               : config.readString(string(abi.encodePacked(entry, ".token"))),
                    asset               : config.readAddress(string(abi.encodePacked(entry, ".asset"))),
                    depositMaxAmount    : config.readUint(string(abi.encodePacked(entry, ".depositMaxAmount"))),
                    depositSlopePerDay  : config.readUint(string(abi.encodePacked(entry, ".depositSlope"))),
                    withdrawMaxAmount   : config.readUint(string(abi.encodePacked(entry, ".withdrawMaxAmount"))),
                    withdrawSlopePerDay : config.readUint(string(abi.encodePacked(entry, ".withdrawSlope"))),
                    maxExchangeRate     : config.readUint(string(abi.encodePacked(entry, ".maxExchangeRate")))
                });
            }

            key = string(abi.encodePacked(".", paus[i], ".sparkVaultRateLimits"));

            SparkVaultRateLimit[] memory sparkVaultRateLimitsStructs = new SparkVaultRateLimit[](_length(config, key));

            for (uint256 j; j < sparkVaultRateLimitsStructs.length; ++j) {
                string memory entry = _index(key, j);

                sparkVaultRateLimitsStructs[j] = SparkVaultRateLimit({
                    sparkVault  : config.readString(string(abi.encodePacked(entry, ".sparkVault"))),
                    maxAmount   : config.readUint(string(abi.encodePacked(entry, ".maxAmount"))),
                    slopePerDay : config.readUint(string(abi.encodePacked(entry, ".slope")))
                });
            }

            cfg.paus[i] = PAUConfig({
                name                    : paus[i],
                admin                   : config.readAddress(string(abi.encodePacked(".", paus[i], ".admin"))),
                integrationIds          : integrationIdsBytes,
                transferAssetRateLimits : transferAssetRateLimitsStructs,
                erc4626RateLimits       : erc4626RateLimitsStructs,
                sparkVaultRateLimits    : sparkVaultRateLimitsStructs
            });
        }
    }

}
