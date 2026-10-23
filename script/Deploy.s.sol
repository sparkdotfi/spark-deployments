// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { console2 }        from "lib/forge-std/src/console2.sol";
import { Script, stdJson } from "lib/forge-std/src/Script.sol";

import { ScriptTools } from "lib/dss-test/src/ScriptTools.sol";

import { PASDeploy, PASInstance } from "lib/pas/deploy/PASDeploy.sol";
import { PASInit }                from "lib/pas/deploy/PASInit.sol";

import { ERC1967Proxy } from "lib/spark-prime-vault/lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { SparkPrimeVault } from "lib/spark-prime-vault/src/SparkPrimeVault.sol";

interface IAccessControlsLike {
    function grantRole(bytes32 role, address account) external;
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

abstract contract DeploySparkPrimeVaultBase is Script {

    using stdJson     for string;
    using ScriptTools for string;

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    IDefaultPAUAssembler defaultPAUAssembler;

    address internal spPrimeProxy;
    address internal spPrimePAUAlmProxy;

    address[] internal admins;
    address[] internal relayers;
    address[] internal freezers;
    address[] internal grantors;

    address[] internal accessControls;
    address[] internal rateLimits;

    string[] internal paus;

    function run() public virtual {
        _setRHChainFork();

        string memory chain = vm.envOr("CHAIN", string("mainnet"));

        vm.createSelectFork(getChain(chain).rpcUrl);

        vm.setEnv("FOUNDRY_ROOT_CHAINID", vm.toString(block.chainid));

        string memory env      = vm.envString("ENV");
        string memory fileSlug = string(abi.encodePacked("deploy-spark-prime-vault-", env));
        string memory config   = ScriptTools.loadConfig(fileSlug);

        require(block.chainid == config.readUint(".chainId"), "DeploySparkPrimeVault/Invalid chain ID");

        defaultPAUAssembler = IDefaultPAUAssembler(config.readAddress(".defaultPAUAssembler"));

        // Deploy Spark Prime Vault and configure.

        vm.startBroadcast();

        address spPrimeImplementation = address(new SparkPrimeVault());

        SparkPrimeVault spPrime = SparkPrimeVault(
            address(new ERC1967Proxy(
                spPrimeImplementation,
                abi.encodeCall(
                    SparkPrimeVault.initialize,
                    (
                        config.readAddress(".spPrime.savingsVaultV2"),
                        config.readString(".spPrime.name"),
                        config.readString(".spPrime.symbol"),
                        config.readAddress(".spPrime.admin"),
                        config.readUint(".spPrime.minimumDeposit"),
                        config.readUint(".spPrime.minimumDepositCancellation"),
                        config.readUint(".spPrime.minimumRedeem")
                    )
                )
            ))
        );

        spPrime.setVSRBounds(config.readUint(".spPrime.minVSR"), config.readUint(".spPrime.maxVSR"));
        spPrime.setMaxRedeemFeeRate(config.readUint(".spPrime.maxRedeemFeeRate"));

        spPrime.grantRole(spPrime.PAUSER_ROLE(),            config.readAddress(".spPrime.pauserRole"));
        spPrime.grantRole(spPrime.UNPAUSER_ROLE(),          config.readAddress(".spPrime.unpauserRole"));
        spPrime.grantRole(spPrime.OPERATOR_ROLE(),          config.readAddress(".spPrime.operatorRole"));
        spPrime.grantRole(spPrime.REDEEM_FEE_SETTER_ROLE(), config.readAddress(".spPrime.redeemFeeSetterRole"));
        spPrime.grantRole(spPrime.TAKER_ROLE(),             config.readAddress(".spPrime.takerRole"));
        spPrime.grantRole(spPrime.LOSS_MANAGER_ROLE(),      config.readAddress(".spPrime.lossManagerRole"));

        vm.stopBroadcast();

        spPrimeProxy = address(spPrime);

        console2.log("Deployed Spark Prime Vault");

        ScriptTools.exportContract(fileSlug, string(abi.encodePacked("spPrime.proxy")), address(spPrime));
        ScriptTools.exportContract(fileSlug, string(abi.encodePacked("spPrime.implementation")), address(spPrimeImplementation));

        // Deploy PAU's

        for (uint16 i; i < paus.length; ++i) {
            admins   = config.readAddressArray(string(abi.encodePacked(".", paus[i], ".admins")));
            relayers = config.readAddressArray(string(abi.encodePacked(".", paus[i], ".relayers")));
            freezers = config.readAddressArray(string(abi.encodePacked(".", paus[i], ".freezers")));
            grantors = config.readAddressArray(string(abi.encodePacked(".", paus[i], ".grantors")));

            string[] memory integrationIds = config.readStringArray(string(abi.encodePacked(".",  paus[i], ".integrationIds")));

            vm.startBroadcast();

            // Step 1: Prepare configs.

            bytes32[] memory integrationIdsBytes = new bytes32[](integrationIds.length);
            for (uint16 j; j < integrationIds.length; ++j) {
                integrationIdsBytes[j] = bytes32(abi.encodePacked(integrationIds[j]));
            }

            IDefaultPAUAssembler.AdminConfig               memory adminConfig  = _getAdminConfig(admins, admins, admins);
            IDefaultPAUAssembler.AdministeredAgentConfig[] memory agentConfigs = _getAgentConfigs(admins, relayers, freezers, grantors);

            // Step 2: Deploy PAU with default PAUAssembler.

            (
                address          proxy_,
                address          controller_,
                address          accessControls_,
                address          rateLimits_,
                address[] memory allocatorAgents_
            ) = defaultPAUAssembler.deploy(integrationIdsBytes, adminConfig, agentConfigs);

            if (_eq(paus[i], "spPrimePAU")) {
                spPrimePAUAlmProxy = proxy_;
            }

            _setRateLimits(config, paus[i], controller_, rateLimits_);

            accessControls.push(accessControls_);
            rateLimits.push(rateLimits_);

            vm.stopBroadcast();

            console2.log("Deployed", paus[i], "PAU with default PAUAssembler");

            ScriptTools.exportContract(fileSlug, string(abi.encodePacked(paus[i], ".proxy")),          address(proxy_));
            ScriptTools.exportContract(fileSlug, string(abi.encodePacked(paus[i], ".controller")),     address(controller_));
            ScriptTools.exportContract(fileSlug, string(abi.encodePacked(paus[i], ".accessControls")), address(accessControls_));
            ScriptTools.exportContract(fileSlug, string(abi.encodePacked(paus[i], ".rateLimits")),     address(rateLimits_));
            ScriptTools.exportContract(fileSlug, string(abi.encodePacked(paus[i], ".allocatorAgent")), allocatorAgents_[0]);
        }

        // Deploy PAS

        vm.startBroadcast();

        PASInstance memory pas = PASDeploy.deploy({
            deployer : msg.sender,
            owner    : config.readAddress(".pas.owner"),
            minDelay : config.readUint(".pas.minDelay")
        });

        PASInit.init({
            pasInstance : pas,
            minDelay    : config.readUint(".pas.minDelay"),
            coreCouncil : config.readAddress(".pas.coreCouncil"),
            cancellers  : config.readAddressArray(".pas.cancellers"),
            pausers     : config.readAddressArray(".pas.pausers")
        });

        for (uint16 i; i < paus.length; ++i) {
            IAccessControlsLike(accessControls[i]).grantRole(DEFAULT_ADMIN_ROLE, pas.configurator);
            IAccessControlsLike(rateLimits[i]).grantRole(DEFAULT_ADMIN_ROLE,     pas.configurator);
        }

        vm.stopBroadcast();

        ScriptTools.exportContract(fileSlug, string(abi.encodePacked("pas.beamState")),    address(pas.beamState));
        ScriptTools.exportContract(fileSlug, string(abi.encodePacked("pas.configurator")), address(pas.configurator));
        ScriptTools.exportContract(fileSlug, string(abi.encodePacked("pas.timelock")),     address(pas.timelock));
    }

    /**********************************************************************************************/
    /*** Helper Functions                                                                       ***/
    /**********************************************************************************************/

    function _getAdminConfig(
        address[] memory accessControlAdmins,
        address[] memory almProxyAdmins,
        address[] memory rateLimitsAdmins
    ) internal pure returns (IDefaultPAUAssembler.AdminConfig memory adminConfig) {
        adminConfig = IDefaultPAUAssembler.AdminConfig({
            accessControlAdmins : accessControlAdmins,
            proxyAdmins         : almProxyAdmins,
            rateLimitsAdmins    : rateLimitsAdmins
        });
    }

    function _getAgentConfigs(
        address[] memory agentAdmins,
        address[] memory agentActors,
        address[] memory agentGrantors,
        address[] memory agentRevokers
    ) internal pure returns (IDefaultPAUAssembler.AdministeredAgentConfig[] memory agentConfigs) {
        agentConfigs = new IDefaultPAUAssembler.AdministeredAgentConfig[](1);  // Only one allocator agent is deployed.

        agentConfigs[0] = IDefaultPAUAssembler.AdministeredAgentConfig({
            admins   : agentAdmins,
            actors   : agentActors,
            grantors : agentGrantors,
            revokers : agentRevokers
        });
    }

    function _setRateLimits(string memory config, string memory pau, address controller_, address rateLimits_) internal {
        for (uint256 i; vm.keyExistsJson(config, _rateLimitPath(pau, i)); ++i) {
            string memory path          = _rateLimitPath(pau, i);
            string memory integrationId = config.readString(string(abi.encodePacked(path, ".integrationId")));

            if (_eq(integrationId, "TRANSFER_ASSET_FACET")) {
                _setTransferAssetRateLimit(config, path, controller_, rateLimits_);
            } else if (_eq(integrationId, "ERC4626_FACET")) {
                _setERC4626RateLimits(config, path, controller_, rateLimits_);
            } else if (_eq(integrationId, "SPARK_VAULT_FACET")) {
                _setSparkVaultRateLimits(config, path, controller_, rateLimits_);
            } else {
                revert(string(abi.encodePacked("DeploySparkPrimeVault/Unknown rate limit: ", integrationId)));
            }
        }
    }

    function _setSparkVaultRateLimits(string memory config, string memory path, address controller_, address rateLimits_) internal {
        address sparkVault = _readAddress(config, string(abi.encodePacked(path, ".sparkVault")));

        IRateLimitsLike(rateLimits_).setRateLimitData(
            IControllerLike(controller_).sparkVault_getTakeRateLimitKey(sparkVault),
            config.readUint(string(abi.encodePacked(path, ".maxAmount"))),
            uint256(config.readUint(string(abi.encodePacked(path, ".slope")))) / 1 days
        );
    }

    function _setTransferAssetRateLimit(string memory config, string memory path, address controller_, address rateLimits_) internal {
        address asset       = _readAddress(config, string(abi.encodePacked(path, ".asset")));
        address destination = _readAddress(config, string(abi.encodePacked(path, ".destination")));

        IRateLimitsLike(rateLimits_).setRateLimitData(
            IControllerLike(controller_).transferAsset_getTransferRateLimitKey(asset, destination),
            config.readUint(string(abi.encodePacked(path, ".maxAmount"))),
            uint256(config.readUint(string(abi.encodePacked(path, ".slope")))) / 1 days
        );
    }

    function _setERC4626RateLimits(string memory config, string memory path, address controller_, address rateLimits_) internal {
        address token = _readAddress(config, string(abi.encodePacked(path, ".token")));
        address asset = _readAddress(config, string(abi.encodePacked(path, ".asset")));

        bytes32 depositKey  = IControllerLike(controller_).erc4626_getDepositRateLimitKey(token, asset);
        bytes32 withdrawKey = IControllerLike(controller_).erc4626_getWithdrawRateLimitKey(asset);

        IRateLimitsLike(rateLimits_).setRateLimitData(
            depositKey,
            config.readUint(string(abi.encodePacked(path, ".depositMaxAmount"))),
            uint256(config.readUint(string(abi.encodePacked(path, ".depositSlope")))) / 1 days
        );
        IRateLimitsLike(rateLimits_).setRateLimitData(
            withdrawKey,
            config.readUint(string(abi.encodePacked(path, ".withdrawMaxAmount"))),
            uint256(config.readUint(string(abi.encodePacked(path, ".withdrawSlope")))) / 1 days
        );

        IControllerLike(controller_).erc4626_setMaxExchangeRate(
            token,
            1 * 10 ** IERC20Like(token).decimals(),
            config.readUint(string(abi.encodePacked(path, ".maxExchangeRate"))) * 10 ** IERC20Like(asset).decimals()
        );
    }

    function _readAddress(string memory config, string memory key) internal view returns (address) {
        string memory value = config.readString(key);

        if (_eq(value, "spPrime")) return spPrimeProxy;
        if (_eq(value, "spPrimePAUAlmProxy")) return spPrimePAUAlmProxy;

        return vm.parseAddress(value);
    }

    function _rateLimitPath(string memory pau, uint256 i) internal pure returns (string memory) {
        return string(abi.encodePacked(".", pau, ".rateLimits[", vm.toString(i), "]"));
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _setRHChainFork() internal {
        setChain("robinhood_chain", ChainData({
            name    : "Robinhood Chain",
            rpcUrl  : vm.envString("RH_RPC_URL"),
            chainId : 4663
        }));
    }

}

contract DeploySparkPrimeVaultMainnet is DeploySparkPrimeVaultBase {

    function run() public override {
        paus = new string[](2);
        paus[0] = "spPrimePAU";
        paus[1] = "flcPAU";

        super.run();
    }

}
