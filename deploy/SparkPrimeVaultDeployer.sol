// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { VmSafe }  from "forge-std/Vm.sol";
import { stdJson } from "forge-std/StdJson.sol";

import { PASDeploy }   from "pas/deploy/PASDeploy.sol";
import { PASInit }     from "pas/deploy/PASInit.sol";
import { PASInstance } from "pas/deploy/PASInstance.sol";

import { PAUInit, PAUInstance } from "diamond-pau/deploy/PAUInit.sol";

import { ERC1967Proxy } from "spark-prime-vault/lib/oz/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { SparkPrimeVault } from "spark-prime-vault/src/SparkPrimeVault.sol";

/**********************************************************************************************/
/*** Minimal interfaces (kept local so this file does not pull two OpenZeppelin copies)     ***/
/**********************************************************************************************/

interface IAccessControlLike {
    function grantRole(bytes32 role, address account) external;
    function hasRole(bytes32 role, address account) external view returns (bool);
    function revokeRole(bytes32 role, address account) external;
}

interface IALMProxyLike {
    function CONTROLLER() external view returns (bytes32);
}

interface IControllerLike {
    function accessControls() external view returns (address);
    function beacon() external view returns (address);
    function proxy() external view returns (address);
    function rateLimits() external view returns (address);
    function updateIntegrations(bytes32[] calldata ids) external;

    function erc4626_getDepositRateLimitKey(address token, address asset) external pure returns (bytes32);
    function erc4626_getWithdrawRateLimitKey(address token) external pure returns (bytes32);
    function erc4626_setMaxExchangeRate(address token, uint256 shares, uint256 maxExpectedAssets) external;
    function sparkVault_getTakeRateLimitKey(address sparkVault) external pure returns (bytes32);
    function transferAsset_getTransferRateLimitKey(address asset, address destination) external view returns (bytes32);
}

interface IERC20Like {
    function decimals() external view returns (uint8);
}

interface IPAUFactoryLike {
    function beacon() external view returns (address);
    function deployAccessControls(address admin) external returns (address);
    function deployALMProxy(address admin) external returns (address);
    function deployController(address accessControls, address proxy, address rateLimits) external returns (address);
    function deployRateLimits(address admin) external returns (address);
}

interface IRateLimitsLike {
    function CONTROLLER() external view returns (bytes32);
    function setRateLimitData(bytes32 key, uint256 maxAmount, uint256 slope) external;
}

interface IWardsLike {
    function deny(address usr) external;
    function rely(address usr) external;
    function wards(address usr) external view returns (uint256);
}

/**
 * @title  SparkPrimeVaultDeployer
 * @notice Deployment logic for the Spark Prime Vault, its two PAUs (taker + first-loss capital)
 *         and the PAS. Everything is driven by a `Config` struct and returns an `Instance`, so the
 *         exact same code path runs from the broadcast script and from a test `setUp`.
 *
 * @dev    Deliberately has no forge-std base contract: a consumer test inherits `Test` from its
 *         own forge-std and this contract side by side. All external calls and contract
 *         creations are expected to originate from `deployer` (the broadcaster, or the pranked
 *         address in tests). The deployer is a temporary admin everywhere and holds no role once
 *         `_deploy` returns, unless it is explicitly listed as a final admin.
 */
abstract contract SparkPrimeVaultDeployer {

    using stdJson for string;

    /**********************************************************************************************/
    /*** Config                                                                                 ***/
    /**********************************************************************************************/

    /// @dev Symbolic address references that can only be resolved once deployment has started.
    enum Ref {
        Literal,
        SpPrime,            // The Spark Prime Vault proxy.
        SpPrimePAUAlmProxy  // The ALMProxy of the taker PAU.
    }

    struct AddressRef {
        Ref     ref;
        address value;  // Only used when `ref == Ref.Literal`.
    }

    struct VaultConfig {
        address savings;  // Spark Savings Vault V2 (spUSDC).
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

    struct TransferAssetRateLimit {
        address    asset;
        AddressRef destination;
        uint256    maxAmount;
        uint256    slopePerDay;
    }

    struct ERC4626RateLimit {
        address token;
        address asset;
        uint256 depositMaxAmount;
        uint256 depositSlopePerDay;
        uint256 withdrawMaxAmount;
        uint256 withdrawSlopePerDay;
        uint256 maxExchangeRate;  // Whole asset units per one whole share.
    }

    struct SparkVaultRateLimit {
        AddressRef sparkVault;
        uint256    maxAmount;
        uint256    slopePerDay;
    }

    struct PAUConfig {
        address[]                admins;  // Final DEFAULT_ADMIN_ROLE holders of AccessControls, ALMProxy and RateLimits.
        bytes32[]                integrationIds;
        TransferAssetRateLimit[] transferAssetRateLimits;
        ERC4626RateLimit[]       erc4626RateLimits;
        SparkVaultRateLimit[]    sparkVaultRateLimits;
    }

    struct PASConfig {
        address   owner;
        uint256   minDelay;
        address   coreCouncil;
        address[] cancellers;
        address[] pausers;
    }

    struct Config {
        uint256     chainId;
        address     pauFactory;      // Existing PAUFactory; binds the PAUs to its Beacon.
        address     allocatorAgent;  // Existing AdministeredAgent, granted ALLOCATOR_ROLE on both PAUs.
        VaultConfig vault;
        PAUConfig   spPrimePAU;      // Taker PAU.
        PAUConfig   flcPAU;          // First-loss capital PAU.
        PASConfig   pas;
    }

    struct Instance {
        address     spPrimeImplementation;
        address     spPrime;
        PAUInstance spPrimePAU;
        PAUInstance flcPAU;
        PASInstance pas;
    }

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    VmSafe private constant _vm = VmSafe(address(uint160(uint256(keccak256("hevm cheat code")))));

    /**********************************************************************************************/
    /*** Deployment                                                                             ***/
    /**********************************************************************************************/

    function _deploy(address deployer, Config memory cfg) internal returns (Instance memory inst) {
        require(block.chainid == cfg.chainId, "SparkPrimeVaultDeployer/invalid-chain-id");

        IPAUFactoryLike factory = IPAUFactoryLike(cfg.pauFactory);

        // Step 1: Deploy the Spark Prime Vault with the deployer as temporary admin.

        inst.spPrimeImplementation = address(new SparkPrimeVault());

        inst.spPrime = address(new ERC1967Proxy(
            inst.spPrimeImplementation,
            abi.encodeCall(
                SparkPrimeVault.initialize,
                (
                    cfg.vault.savings,
                    cfg.vault.name,
                    cfg.vault.symbol,
                    deployer,
                    cfg.vault.minDeposit,
                    cfg.vault.minDepositCancellation,
                    cfg.vault.minRedeem
                )
            )
        ));

        // Step 2: Deploy both PAU stacks against the existing factory (and therefore Beacon).

        inst.spPrimePAU = _deployPAU(factory, deployer);
        inst.flcPAU     = _deployPAU(factory, deployer);

        // Step 3: Deploy and initialize the PAS with the deployer as temporary owner.

        inst.pas = PASDeploy.deploy({ deployer: deployer, owner: deployer, minDelay: cfg.pas.minDelay });

        PASInit.init({
            pasInstance : inst.pas,
            minDelay    : cfg.pas.minDelay,
            coreCouncil : cfg.pas.coreCouncil,
            cancellers  : cfg.pas.cancellers,
            pausers     : cfg.pas.pausers
        });

        // Step 4: Configure everything (needs all addresses to resolve symbolic references).

        _configureVault(cfg.vault, inst);
        _configurePAU(cfg.spPrimePAU, inst.spPrimePAU, cfg.allocatorAgent, inst);
        _configurePAU(cfg.flcPAU,     inst.flcPAU,     cfg.allocatorAgent, inst);

        // Step 5: Hand admin rights over and strip the deployer.

        _handOffVault(cfg.vault, inst.spPrime, deployer);
        _handOffPAU(cfg.spPrimePAU, inst.spPrimePAU, deployer);
        _handOffPAU(cfg.flcPAU,     inst.flcPAU,     deployer);
        _handOffPAS(cfg.pas, inst.pas, deployer);
    }

    function _deployPAU(IPAUFactoryLike factory, address deployer) internal returns (PAUInstance memory pau) {
        pau.beacon         = factory.beacon();
        pau.accessControls = factory.deployAccessControls(deployer);
        pau.almProxy       = factory.deployALMProxy(deployer);
        pau.rateLimits     = factory.deployRateLimits(deployer);
        pau.controller     = factory.deployController(pau.accessControls, pau.almProxy, pau.rateLimits);
    }

    /**********************************************************************************************/
    /*** Configuration                                                                          ***/
    /**********************************************************************************************/

    function _configureVault(VaultConfig memory cfg, Instance memory inst) internal {
        SparkPrimeVault vault = SparkPrimeVault(inst.spPrime);

        vault.setVSRBounds(cfg.minVSR, cfg.maxVSR);
        vault.setMaxRedeemFeeRate(cfg.maxRedeemFeeRate);

        vault.grantRole(vault.PAUSER_ROLE(),            cfg.pauser);
        vault.grantRole(vault.UNPAUSER_ROLE(),          cfg.unpauser);
        vault.grantRole(vault.OPERATOR_ROLE(),          cfg.operator);
        vault.grantRole(vault.REDEEM_FEE_SETTER_ROLE(), cfg.redeemFeeSetter);
        vault.grantRole(vault.LOSS_MANAGER_ROLE(),      cfg.lossManager);

        // The taker PAU pulls savings shares out of the vault through its ALMProxy.
        vault.grantRole(vault.TAKER_ROLE(), inst.spPrimePAU.almProxy);
    }

    function _configurePAU(
        PAUConfig   memory cfg,
        PAUInstance memory pau,
        address            allocatorAgent,
        Instance    memory inst
    ) internal {
        IControllerLike controller = IControllerLike(pau.controller);

        // Structural wiring (same steps as PAUInit.init, which can only run as the admin itself).
        IAccessControlLike(pau.almProxy).grantRole(IALMProxyLike(pau.almProxy).CONTROLLER(), pau.controller);
        IAccessControlLike(pau.rateLimits).grantRole(IRateLimitsLike(pau.rateLimits).CONTROLLER(), pau.controller);

        if (cfg.integrationIds.length > 0) controller.updateIntegrations(cfg.integrationIds);

        PAUInit.addAllocator(pau, allocatorAgent);

        // Rate limits.
        for (uint256 i; i < cfg.transferAssetRateLimits.length; ++i) {
            TransferAssetRateLimit memory rl = cfg.transferAssetRateLimits[i];

            IRateLimitsLike(pau.rateLimits).setRateLimitData(
                controller.transferAsset_getTransferRateLimitKey(rl.asset, _resolve(rl.destination, inst)),
                rl.maxAmount,
                rl.slopePerDay / 1 days
            );
        }

        for (uint256 i; i < cfg.erc4626RateLimits.length; ++i) {
            ERC4626RateLimit memory rl = cfg.erc4626RateLimits[i];

            IRateLimitsLike(pau.rateLimits).setRateLimitData(
                controller.erc4626_getDepositRateLimitKey(rl.token, rl.asset),
                rl.depositMaxAmount,
                rl.depositSlopePerDay / 1 days
            );
            IRateLimitsLike(pau.rateLimits).setRateLimitData(
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

            IRateLimitsLike(pau.rateLimits).setRateLimitData(
                controller.sparkVault_getTakeRateLimitKey(_resolve(rl.sparkVault, inst)),
                rl.maxAmount,
                rl.slopePerDay / 1 days
            );
        }

        // The PAS configurator administers AccessControls and RateLimits.
        IAccessControlLike(pau.accessControls).grantRole(DEFAULT_ADMIN_ROLE, inst.pas.configurator);
        IAccessControlLike(pau.rateLimits).grantRole(DEFAULT_ADMIN_ROLE,     inst.pas.configurator);
    }

    /**********************************************************************************************/
    /*** Admin hand-off                                                                         ***/
    /**********************************************************************************************/

    function _handOffVault(VaultConfig memory cfg, address vault, address deployer) internal {
        address[] memory admins = new address[](1);
        admins[0] = cfg.admin;

        _transferAdmin(vault, deployer, admins);
    }

    function _handOffPAU(PAUConfig memory cfg, PAUInstance memory pau, address deployer) internal {
        _transferAdmin(pau.accessControls, deployer, cfg.admins);
        _transferAdmin(pau.almProxy,       deployer, cfg.admins);
        _transferAdmin(pau.rateLimits,     deployer, cfg.admins);
    }

    function _handOffPAS(PASConfig memory cfg, PASInstance memory pas, address deployer) internal {
        address[] memory admins = new address[](1);
        admins[0] = cfg.owner;

        _transferAdmin(pas.timelock, deployer, admins);

        if (cfg.owner == deployer) return;

        require(IWardsLike(pas.beamState).wards(deployer) == 1, "SparkPrimeVaultDeployer/deployer-not-authed");

        IWardsLike(pas.beamState).rely(cfg.owner);
        IWardsLike(pas.beamState).deny(deployer);
    }

    /// @dev Grants DEFAULT_ADMIN_ROLE to every `admins` entry and revokes it from `deployer`
    ///      unless the deployer is itself one of the final admins.
    function _transferAdmin(address target, address deployer, address[] memory admins) internal {
        bool deployerIsAdmin;

        for (uint256 i; i < admins.length; ++i) {
            require(admins[i] != address(0), "SparkPrimeVaultDeployer/zero-admin");

            if (admins[i] == deployer) {
                deployerIsAdmin = true;
                continue;
            }

            IAccessControlLike(target).grantRole(DEFAULT_ADMIN_ROLE, admins[i]);
        }

        if (!deployerIsAdmin) IAccessControlLike(target).revokeRole(DEFAULT_ADMIN_ROLE, deployer);
    }

    /**********************************************************************************************/
    /*** Config parsing                                                                         ***/
    /**********************************************************************************************/

    function _parseConfig(string memory json) internal view returns (Config memory cfg) {
        cfg.chainId        = json.readUint(".chainId");
        cfg.pauFactory     = json.readAddress(".pauFactory");
        cfg.allocatorAgent = json.readAddress(".allocatorAgent");

        cfg.vault = VaultConfig({
            savings                : json.readAddress(".spPrime.savingsVaultV2"),
            name                   : json.readString(".spPrime.name"),
            symbol                 : json.readString(".spPrime.symbol"),
            admin                  : json.readAddress(".spPrime.admin"),
            minDeposit             : json.readUint(".spPrime.minimumDeposit"),
            minDepositCancellation : json.readUint(".spPrime.minimumDepositCancellation"),
            minRedeem              : json.readUint(".spPrime.minimumRedeem"),
            minVSR                 : json.readUint(".spPrime.minVSR"),
            maxVSR                 : json.readUint(".spPrime.maxVSR"),
            maxRedeemFeeRate       : json.readUint(".spPrime.maxRedeemFeeRate"),
            pauser                 : json.readAddress(".spPrime.pauserRole"),
            unpauser               : json.readAddress(".spPrime.unpauserRole"),
            operator               : json.readAddress(".spPrime.operatorRole"),
            redeemFeeSetter        : json.readAddress(".spPrime.redeemFeeSetterRole"),
            lossManager            : json.readAddress(".spPrime.lossManagerRole")
        });

        cfg.spPrimePAU = _parsePAU(json, ".spPrimePAU");
        cfg.flcPAU     = _parsePAU(json, ".flcPAU");

        cfg.pas = PASConfig({
            owner       : json.readAddress(".pas.owner"),
            minDelay    : json.readUint(".pas.minDelay"),
            coreCouncil : json.readAddress(".pas.coreCouncil"),
            cancellers  : json.readAddressArray(".pas.cancellers"),
            pausers     : json.readAddressArray(".pas.pausers")
        });
    }

    function _parsePAU(string memory json, string memory path) internal view returns (PAUConfig memory cfg) {
        cfg.admins = json.readAddressArray(_key(path, ".admins"));

        string[] memory ids = json.readStringArray(_key(path, ".integrationIds"));

        cfg.integrationIds = new bytes32[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            require(bytes(ids[i]).length <= 32, "SparkPrimeVaultDeployer/integration-id-too-long");
            cfg.integrationIds[i] = bytes32(abi.encodePacked(ids[i]));
        }

        // Pass 1: count entries per integration so memory arrays can be sized.
        uint256 transferAssetCount;
        uint256 erc4626Count;
        uint256 sparkVaultCount;

        uint256 count = _rateLimitCount(json, path);

        for (uint256 i; i < count; ++i) {
            string memory id = json.readString(_key(_rateLimitPath(path, i), ".integrationId"));

            if      (_eq(id, "TRANSFER_ASSET_FACET")) ++transferAssetCount;
            else if (_eq(id, "ERC4626_FACET"))        ++erc4626Count;
            else if (_eq(id, "SPARK_VAULT_FACET"))    ++sparkVaultCount;
            else revert(string(abi.encodePacked("SparkPrimeVaultDeployer/unknown-rate-limit: ", id)));
        }

        cfg.transferAssetRateLimits = new TransferAssetRateLimit[](transferAssetCount);
        cfg.erc4626RateLimits       = new ERC4626RateLimit[](erc4626Count);
        cfg.sparkVaultRateLimits    = new SparkVaultRateLimit[](sparkVaultCount);

        // Pass 2: fill.
        transferAssetCount = erc4626Count = sparkVaultCount = 0;

        for (uint256 i; i < count; ++i) {
            string memory p  = _rateLimitPath(path, i);
            string memory id = json.readString(_key(p, ".integrationId"));

            if (_eq(id, "TRANSFER_ASSET_FACET")) {
                cfg.transferAssetRateLimits[transferAssetCount++] = TransferAssetRateLimit({
                    asset       : json.readAddress(_key(p, ".asset")),
                    destination : _readAddressRef(json, _key(p, ".destination")),
                    maxAmount   : json.readUint(_key(p, ".maxAmount")),
                    slopePerDay : json.readUint(_key(p, ".slope"))
                });
            } else if (_eq(id, "ERC4626_FACET")) {
                cfg.erc4626RateLimits[erc4626Count++] = ERC4626RateLimit({
                    token               : json.readAddress(_key(p, ".token")),
                    asset               : json.readAddress(_key(p, ".asset")),
                    depositMaxAmount    : json.readUint(_key(p, ".depositMaxAmount")),
                    depositSlopePerDay  : json.readUint(_key(p, ".depositSlope")),
                    withdrawMaxAmount   : json.readUint(_key(p, ".withdrawMaxAmount")),
                    withdrawSlopePerDay : json.readUint(_key(p, ".withdrawSlope")),
                    maxExchangeRate     : json.readUint(_key(p, ".maxExchangeRate"))
                });
            } else {
                cfg.sparkVaultRateLimits[sparkVaultCount++] = SparkVaultRateLimit({
                    sparkVault  : _readAddressRef(json, _key(p, ".sparkVault")),
                    maxAmount   : json.readUint(_key(p, ".maxAmount")),
                    slopePerDay : json.readUint(_key(p, ".slope"))
                });
            }
        }
    }

    function _rateLimitCount(string memory json, string memory path) internal view returns (uint256 count) {
        while (_vm.keyExistsJson(json, _rateLimitPath(path, count))) ++count;
    }

    function _rateLimitPath(string memory path, uint256 index) internal pure returns (string memory) {
        return string(abi.encodePacked(path, ".rateLimits[", _vm.toString(index), "]"));
    }

    function _readAddressRef(string memory json, string memory key) internal pure returns (AddressRef memory ref) {
        string memory value = json.readString(key);

        if      (_eq(value, "spPrime"))            ref.ref = Ref.SpPrime;
        else if (_eq(value, "spPrimePAUAlmProxy")) ref.ref = Ref.SpPrimePAUAlmProxy;
        else {
            ref.ref   = Ref.Literal;
            ref.value = _vm.parseAddress(value);
        }
    }

    function _resolve(AddressRef memory ref, Instance memory inst) internal pure returns (address) {
        if (ref.ref == Ref.SpPrime)            return inst.spPrime;
        if (ref.ref == Ref.SpPrimePAUAlmProxy) return inst.spPrimePAU.almProxy;

        require(ref.value != address(0), "SparkPrimeVaultDeployer/zero-address-ref");

        return ref.value;
    }

    function _key(string memory path, string memory suffix) internal pure returns (string memory) {
        return string(abi.encodePacked(path, suffix));
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

}
