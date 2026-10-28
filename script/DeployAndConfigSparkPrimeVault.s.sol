// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Script, stdJson } from "../lib/forge-std/src/Script.sol";

import { ScriptTools } from "../lib/dss-test/src/ScriptTools.sol";

import { ERC1967Proxy } from "../lib/spark-prime-vault/lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { SparkPrimeVault } from "../lib/spark-prime-vault/src/SparkPrimeVault.sol";

interface IAccessControlsLike {

    function grantRole(bytes32 role, address account) external;

    function revokeRole(bytes32 role, address account) external;

}

interface IControllerLike {

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

    function setRateLimitData(bytes32 key, uint256 maxAmount, uint256 slope) external;

}

interface IDefaultPAUAssembler {

    struct AdminConfig {
        address[] accessControlAdmins;
        address[] proxyAdmins;
        address[] rateLimitsAdmins;
    }

    struct AdministeredAgentConfig {
        address[] admins;
        address[] actors;
        address[] grantors;
        address[] revokers;
    }

    function deploy(
        bytes32[]                 memory integrationIds,
        AdminConfig               memory adminConfig,
        AdministeredAgentConfig[] memory allocatorAgentConfigs
    )
        external
        returns (
            address          proxy,
            address          controller,
            address          accessControls,
            address          rateLimits,
            address[] memory allocatorAgents
        );

}

abstract contract DeployAndConfigSparkPrimeVault is Script {

    using stdJson     for string;
    using ScriptTools for string;

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    string internal constant PAUS_KEY = ".PAU.PAUs";

    /**********************************************************************************************/
    /*** Deploy Config                                                                          ***/
    /**********************************************************************************************/

    struct VaultDeployConfig {
        address savingsVaultV2;
        string  name;
        string  symbol;
        uint256 minDeposit;
        uint256 minDepositCancellation;
        uint256 minRedeem;
    }

    struct PAUDeployConfig {
        address   admin;
        address   relayer;
        address   grantor;
        address   revoker;
        bytes32[] integrationIds;
    }

    struct DeployConfig {
        uint256           chainId;
        address           defaultPAUAssembler;
        address           configurator;
        VaultDeployConfig vault;
        PAUDeployConfig[] paus;
    }

    /**********************************************************************************************/
    /*** Configure Config                                                                       ***/
    /**********************************************************************************************/

    struct VaultConfigureConfig {
        address admin;
        uint256 minVSR;
        uint256 maxVSR;
        uint256 maxRedeemFeeRate;
        address pauser;
        address unpauser;
        address operator;
        address redeemFeeSetter;
        address lossManager;
        address taker;
    }

    struct TransferAssetRateLimit {
        address asset;
        address destination;
        uint256 maxAmount;
        uint256 slopePerDay;
    }

    struct ERC4626RateLimit {
        address token;
        address asset;
        uint256 depositMaxAmount;
        uint256 depositSlopePerDay;
        uint256 withdrawMaxAmount;
        uint256 withdrawSlopePerDay;
        uint256 maxExchangeRate;
    }

    struct SparkVaultRateLimit {
        address sparkVault;
        uint256 maxAmount;
        uint256 slopePerDay;
    }

    struct PAUConfigureConfig {
        TransferAssetRateLimit[] transferAssetRateLimits;
        ERC4626RateLimit[]       erc4626RateLimits;
        SparkVaultRateLimit[]    sparkVaultRateLimits;
    }

    struct ConfigureConfig {
        VaultConfigureConfig vault;
        PAUConfigureConfig[] paus;
    }

    /**********************************************************************************************/
    /*** Deployed Instance                                                                      ***/
    /**********************************************************************************************/

    struct PAUInstance {
        address accessControls;
        address almProxy;
        address controller;
        address rateLimits;
        address allocatorAgent;
    }

    struct DeployedInstance {
        address       spPrimeImplementation;
        address       spPrime;
        PAUInstance[] paus;
    }

    /**********************************************************************************************/
    /*** Public interactive functions                                                           ***/
    /**********************************************************************************************/

    function run() public virtual returns (DeployedInstance memory deployed) {
        _setRHChainFork();

        string memory chain = vm.envOr("CHAIN", string("mainnet"));

        vm.createSelectFork(getChain(chain).rpcUrl);

        vm.setEnv("FOUNDRY_ROOT_CHAINID", vm.toString(block.chainid));

        string memory env      = vm.envString("ENV");
        string memory fileSlug = string(abi.encodePacked("deploy-spark-prime-vault-", env));
        string memory config   = ScriptTools.loadConfig(fileSlug);

        deployed = deployAndConfigure(config);

        ScriptTools.exportContract(fileSlug, string(abi.encodePacked("spPrime.proxy")),          deployed.spPrime);
        ScriptTools.exportContract(fileSlug, string(abi.encodePacked("spPrime.implementation")), deployed.spPrimeImplementation);

        for (uint16 i; i < deployed.paus.length; ++i) {
            string memory name = config.readString(string(abi.encodePacked(_index(PAUS_KEY, i), ".name")));

            ScriptTools.exportContract(fileSlug, string(abi.encodePacked(name, ".proxy")),          deployed.paus[i].almProxy);
            ScriptTools.exportContract(fileSlug, string(abi.encodePacked(name, ".controller")),     deployed.paus[i].controller);
            ScriptTools.exportContract(fileSlug, string(abi.encodePacked(name, ".accessControls")), deployed.paus[i].accessControls);
            ScriptTools.exportContract(fileSlug, string(abi.encodePacked(name, ".rateLimits")),     deployed.paus[i].rateLimits);
            ScriptTools.exportContract(fileSlug, string(abi.encodePacked(name, ".allocatorAgent")), deployed.paus[i].allocatorAgent);
        }
    }

    // Deploys and configures everything from a JSON config on the current chain. No fork, env vars or
    // file writes, so tests can call it directly.
    function deployAndConfigure(string memory config)
        public returns (DeployedInstance memory deployed)
    {
        DeployConfig memory deployCfg = _parseDeployConfig(config);

        require(block.chainid == deployCfg.chainId, "DeploySparkPrimeVault/invalid-chain-id");

        vm.startBroadcast();

        ( , address deployer, ) = vm.readCallers();

        // Step 1: Deploy the Spark Prime Vault and the PAU stacks.

        (deployed.spPrimeImplementation, deployed.spPrime) = _deployVault(deployCfg.vault, deployer);

        deployed.paus = new PAUInstance[](deployCfg.paus.length);

        for (uint256 i; i < deployCfg.paus.length; ++i) {
            deployed.paus[i] = _deployPAU(
                deployCfg.defaultPAUAssembler,
                deployCfg.configurator,
                deployCfg.paus[i],
                deployer
            );
        }

        // Step 2: Configure the vault and PAUs, handing admin over and stripping the deployer.
        //         Parsed after deploy so names like "spPrime" can resolve to deployed addresses.

        ConfigureConfig memory configureCfg = _parseConfigureConfig(config, deployed);

        _configureVault(configureCfg.vault, deployed.spPrime, deployer);

        for (uint256 i; i < deployed.paus.length; ++i) {
            _configurePAU(configureCfg.paus[i], deployed.paus[i], deployer);
        }

        vm.stopBroadcast();
    }

    /**********************************************************************************************/
    /*** Deploy and Configure helpers                                                           ***/
    /**********************************************************************************************/

    // Deploys the Spark Prime Vault with `deployer` as temporary admin. Must be called by `deployer`.
    function _deployVault(VaultDeployConfig memory cfg, address deployer)
        internal returns (address implementation, address proxy)
    {
        implementation = address(new SparkPrimeVault());

        proxy = address(new ERC1967Proxy(
            implementation,
            abi.encodeCall(
                SparkPrimeVault.initialize,
                (
                    cfg.savingsVaultV2,
                    cfg.name,
                    cfg.symbol,
                    deployer,
                    cfg.minDeposit,
                    cfg.minDepositCancellation,
                    cfg.minRedeem
                )
            )
        ));
    }

    // Deploys a PAU stack through the assembler, which also wires controller roles, integrations
    // and the allocator agent. `deployer` stays admin of AccessControls and RateLimits until
    // `_configurePAU` finishes.
    function _deployPAU(
        address                defaultPAUAssembler,
        address                configurator,
        PAUDeployConfig memory cfg,
        address                deployer
    )
        internal returns (PAUInstance memory pau)
    {
        address[] memory allocatorAgents;

        (
            pau.almProxy,
            pau.controller,
            pau.accessControls,
            pau.rateLimits,
            allocatorAgents
        ) = IDefaultPAUAssembler(defaultPAUAssembler).deploy(
            cfg.integrationIds,
            _getAdminConfig(configurator, cfg, deployer),
            _getAgentConfigs(cfg)
        );

        pau.allocatorAgent = allocatorAgents[0];
    }

    function _getAdminConfig(address configurator, PAUDeployConfig memory cfg, address deployer)
        internal pure returns (IDefaultPAUAssembler.AdminConfig memory adminConfig)
    {
        address[] memory accessControlAdmins = new address[](3);
        address[] memory proxyAdmins         = new address[](1);
        address[] memory rateLimitsAdmins    = new address[](3);

        accessControlAdmins[0] = cfg.admin;
        accessControlAdmins[1] = configurator;
        accessControlAdmins[2] = deployer;

        proxyAdmins[0] = cfg.admin;

        rateLimitsAdmins[0] = cfg.admin;
        rateLimitsAdmins[1] = configurator;
        rateLimitsAdmins[2] = deployer;

        adminConfig = IDefaultPAUAssembler.AdminConfig({
            accessControlAdmins : accessControlAdmins,
            proxyAdmins         : proxyAdmins,
            rateLimitsAdmins    : rateLimitsAdmins
        });
    }

    function _getAgentConfigs(PAUDeployConfig memory cfg)
        internal pure returns (IDefaultPAUAssembler.AdministeredAgentConfig[] memory agentConfigs)
    {
        address[] memory agentAdmins   = new address[](1);
        address[] memory agentActors   = new address[](1);
        address[] memory agentGrantors = new address[](1);
        address[] memory agentRevokers = new address[](1);

        agentAdmins[0]   = cfg.admin;
        agentActors[0]   = cfg.relayer;
        agentGrantors[0] = cfg.grantor;
        agentRevokers[0] = cfg.revoker;

        agentConfigs = new IDefaultPAUAssembler.AdministeredAgentConfig[](1);  // Only one allocator agent is deployed.

        agentConfigs[0] = IDefaultPAUAssembler.AdministeredAgentConfig({
            admins   : agentAdmins,
            actors   : agentActors,
            grantors : agentGrantors,
            revokers : agentRevokers
        });
    }

    // Configures the vault, hands admin over to `cfg.admin` and strips `deployer`. Must be called by `deployer`.
    function _configureVault(VaultConfigureConfig memory cfg, address spPrime, address deployer) internal {
        SparkPrimeVault vault = SparkPrimeVault(spPrime);

        vault.setVSRBounds(cfg.minVSR, cfg.maxVSR);
        vault.setMaxRedeemFeeRate(cfg.maxRedeemFeeRate);

        vault.grantRole(vault.PAUSER_ROLE(),            cfg.pauser);
        vault.grantRole(vault.UNPAUSER_ROLE(),          cfg.unpauser);
        vault.grantRole(vault.OPERATOR_ROLE(),          cfg.operator);
        vault.grantRole(vault.REDEEM_FEE_SETTER_ROLE(), cfg.redeemFeeSetter);
        vault.grantRole(vault.LOSS_MANAGER_ROLE(),      cfg.lossManager);

        // The taker PAU pulls savings shares out of the vault through its ALMProxy.
        vault.grantRole(vault.TAKER_ROLE(), cfg.taker);

        // Admin handoff.

        vault.grantRole(DEFAULT_ADMIN_ROLE,  cfg.admin);
        vault.revokeRole(DEFAULT_ADMIN_ROLE, deployer);
    }

    // Sets the PAU rate limits and strips `deployer`. Final admins were already set by the assembler.
    // Must be called by `deployer`.
    function _configurePAU(PAUConfigureConfig memory cfg, PAUInstance memory pau, address deployer) internal {
        IControllerLike controller = IControllerLike(pau.controller);
        IRateLimitsLike rateLimits = IRateLimitsLike(pau.rateLimits);

        for (uint256 i; i < cfg.transferAssetRateLimits.length; ++i) {
            TransferAssetRateLimit memory rl = cfg.transferAssetRateLimits[i];

            rateLimits.setRateLimitData(
                controller.transferAsset_getTransferRateLimitKey(rl.asset, rl.destination),
                rl.maxAmount,
                rl.slopePerDay / 1 days
            );
        }

        for (uint256 i; i < cfg.erc4626RateLimits.length; ++i) {
            ERC4626RateLimit memory rl = cfg.erc4626RateLimits[i];

            rateLimits.setRateLimitData(
                controller.erc4626_getDepositRateLimitKey(rl.token, rl.asset),
                rl.depositMaxAmount,
                rl.depositSlopePerDay / 1 days
            );
            rateLimits.setRateLimitData(
                controller.erc4626_getWithdrawRateLimitKey(rl.token),
                rl.withdrawMaxAmount,
                rl.withdrawSlopePerDay / 1 days
            );

            controller.erc4626_setMaxExchangeRate(
                rl.token,
                10 ** IERC20Like(rl.token).decimals(),
                rl.maxExchangeRate * 10 ** IERC20Like(rl.asset).decimals()
            );
        }

        for (uint256 i; i < cfg.sparkVaultRateLimits.length; ++i) {
            SparkVaultRateLimit memory rl = cfg.sparkVaultRateLimits[i];

            rateLimits.setRateLimitData(
                controller.sparkVault_getTakeRateLimitKey(rl.sparkVault),
                rl.maxAmount,
                rl.slopePerDay / 1 days
            );
        }

        // Admin handoff.

        IAccessControlsLike(pau.accessControls).revokeRole(DEFAULT_ADMIN_ROLE, deployer);
        IAccessControlsLike(pau.rateLimits).revokeRole(DEFAULT_ADMIN_ROLE,     deployer);
    }

    /**********************************************************************************************/
    /*** Input file parsing helpers                                                             ***/
    /**********************************************************************************************/

    function _parseDeployConfig(string memory config)
        internal view returns (DeployConfig memory cfg)
    {
        cfg.chainId             = config.readUint(".chainId");
        cfg.defaultPAUAssembler = config.readAddress(".PAU.defaultPAUAssembler");
        cfg.configurator        = config.readAddress(".PAU.configurator");

        cfg.vault = VaultDeployConfig({
            savingsVaultV2         : config.readAddress(".spPrime.savingsVaultV2"),
            name                   : config.readString(".spPrime.name"),
            symbol                 : config.readString(".spPrime.symbol"),
            minDeposit             : config.readUint(".spPrime.minimumDeposit"),
            minDepositCancellation : config.readUint(".spPrime.minimumDepositCancellation"),
            minRedeem              : config.readUint(".spPrime.minimumRedeem")
        });

        cfg.paus = new PAUDeployConfig[](_length(config, PAUS_KEY));

        for (uint16 i; i < cfg.paus.length; ++i) {
            string memory pau = _index(PAUS_KEY, i);

            string[] memory integrationIds = config.readStringArray(string(abi.encodePacked(pau, ".integrationIds")));

            bytes32[] memory integrationIdsBytes = new bytes32[](integrationIds.length);

            for (uint16 j; j < integrationIds.length; ++j) {
                integrationIdsBytes[j] = bytes32(abi.encodePacked(integrationIds[j]));
            }

            cfg.paus[i] = PAUDeployConfig({
                admin          : config.readAddress(string(abi.encodePacked(pau, ".admin"))),
                relayer        : config.readAddress(string(abi.encodePacked(pau, ".relayer"))),
                grantor        : config.readAddress(string(abi.encodePacked(pau, ".grantor"))),
                revoker        : config.readAddress(string(abi.encodePacked(pau, ".revoker"))),
                integrationIds : integrationIdsBytes
            });
        }
    }

    function _parseConfigureConfig(
        string                                             memory config,
        DeployedInstance memory deployed
    )
        internal view returns (ConfigureConfig memory cfg)
    {
        cfg.vault = VaultConfigureConfig({
            admin            : config.readAddress(".spPrime.admin"),
            minVSR           : config.readUint(".spPrime.minVSR"),
            maxVSR           : config.readUint(".spPrime.maxVSR"),
            maxRedeemFeeRate : config.readUint(".spPrime.maxRedeemFeeRate"),
            pauser           : config.readAddress(".spPrime.pauser"),
            unpauser         : config.readAddress(".spPrime.unpauser"),
            operator         : config.readAddress(".spPrime.operator"),
            redeemFeeSetter  : config.readAddress(".spPrime.redeemFeeSetter"),
            lossManager      : config.readAddress(".spPrime.lossManager"),
            taker            : deployed.paus[0].almProxy  // The first PAU is the taker PAU.
        });

        cfg.paus = new PAUConfigureConfig[](_length(config, PAUS_KEY));

        for (uint16 i; i < cfg.paus.length; ++i) {
            string memory rateLimits = string(abi.encodePacked(_index(PAUS_KEY, i), ".rateLimits"));

            string memory key = string(abi.encodePacked(rateLimits, ".transferAssetRateLimits"));

            TransferAssetRateLimit[] memory transferAssetRateLimits
                = new TransferAssetRateLimit[](_length(config, key));

            for (uint256 j; j < transferAssetRateLimits.length; ++j) {
                string memory entry = _index(key, j);

                transferAssetRateLimits[j] = TransferAssetRateLimit({
                    asset       : config.readAddress(string(abi.encodePacked(entry, ".asset"))),
                    destination : _resolve(config.readString(string(abi.encodePacked(entry, ".destination"))), deployed),
                    maxAmount   : config.readUint(string(abi.encodePacked(entry, ".maxAmount"))),
                    slopePerDay : config.readUint(string(abi.encodePacked(entry, ".slope")))
                });
            }

            key = string(abi.encodePacked(rateLimits, ".erc4626RateLimits"));

            ERC4626RateLimit[] memory erc4626RateLimits
                = new ERC4626RateLimit[](_length(config, key));

            for (uint256 j; j < erc4626RateLimits.length; ++j) {
                string memory entry = _index(key, j);

                erc4626RateLimits[j] = ERC4626RateLimit({
                    token               : _resolve(config.readString(string(abi.encodePacked(entry, ".token"))), deployed),
                    asset               : config.readAddress(string(abi.encodePacked(entry, ".asset"))),
                    depositMaxAmount    : config.readUint(string(abi.encodePacked(entry, ".depositMaxAmount"))),
                    depositSlopePerDay  : config.readUint(string(abi.encodePacked(entry, ".depositSlope"))),
                    withdrawMaxAmount   : config.readUint(string(abi.encodePacked(entry, ".withdrawMaxAmount"))),
                    withdrawSlopePerDay : config.readUint(string(abi.encodePacked(entry, ".withdrawSlope"))),
                    maxExchangeRate     : config.readUint(string(abi.encodePacked(entry, ".maxExchangeRate")))
                });
            }

            key = string(abi.encodePacked(rateLimits, ".sparkVaultRateLimits"));

            SparkVaultRateLimit[] memory sparkVaultRateLimits
                = new SparkVaultRateLimit[](_length(config, key));

            for (uint256 j; j < sparkVaultRateLimits.length; ++j) {
                string memory entry = _index(key, j);

                sparkVaultRateLimits[j] = SparkVaultRateLimit({
                    sparkVault  : _resolve(config.readString(string(abi.encodePacked(entry, ".sparkVault"))), deployed),
                    maxAmount   : config.readUint(string(abi.encodePacked(entry, ".maxAmount"))),
                    slopePerDay : config.readUint(string(abi.encodePacked(entry, ".slope")))
                });
            }

            cfg.paus[i] = PAUConfigureConfig({
                transferAssetRateLimits : transferAssetRateLimits,
                erc4626RateLimits       : erc4626RateLimits,
                sparkVaultRateLimits    : sparkVaultRateLimits
            });
        }
    }

    function _length(string memory config, string memory key) internal view returns (uint256 length) {
        while (config.keyExists(_index(key, length))) ++length;
    }

    function _index(string memory key, uint256 index) internal pure returns (string memory) {
        return string(abi.encodePacked(key, "[", vm.toString(index), "]"));
    }

    function _resolve(string memory str, DeployedInstance memory deployed)
        internal pure returns (address)
    {
        if (_eq(str, "spPrime"))            return deployed.spPrime;
        if (_eq(str, "spPrimePAUAlmProxy")) return deployed.paus[0].almProxy;

        return vm.parseAddress(str);
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /**********************************************************************************************/
    /*** Setup helpers                                                                          ***/
    /**********************************************************************************************/

    function _setRHChainFork() internal {
        setChain("robinhood_chain", ChainData({
            name    : "Robinhood Chain",
            rpcUrl  : vm.envString("RH_RPC_URL"),
            chainId : 4663
        }));
    }

}

contract DeploySparkPrimeVaultMainnet is DeployAndConfigSparkPrimeVault { }
