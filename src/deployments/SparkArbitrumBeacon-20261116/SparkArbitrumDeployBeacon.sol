// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

import { Beacon } from "../../../lib/diamond-pau/src/Beacon.sol";

import { BeaconConfig } from "../../../lib/diamond-pau/src/libraries/BeaconConfig.sol";

import { Arbitrum } from "../../../lib/spark-address-registry/src/Arbitrum.sol";

/**
 * @title  SparkArbitrumDeployBeacon
 * @notice Single use deployment payload for deploying and configuring Spark Beacon on Arbitrum.
 */
contract SparkArbitrumDeployBeacon {

    /**********************************************************************************************/
    /*** Constants                                                                              ***/
    /**********************************************************************************************/

    uint256 internal constant ARBITRUM = 42161;

    // ROLES

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    /**********************************************************************************************/
    /*** Deployed contracts                                                                     ***/
    /**********************************************************************************************/

    struct Report {
        address beacon;
    }

    Report internal _report;

    function report() external view returns (Report memory) {
        return _report;
    }

    /**********************************************************************************************/
    /*** Constructor                                                                            ***/
    /**********************************************************************************************/

    constructor() {
        require(block.chainid == ARBITRUM, "SparkArbitrumDeployBeacon/invalid-chain-id");

        // Step 1: Deploy Beacon with the spell as temporary owner

        _report.beacon = address(new Beacon({
            admin : address(this)
        }));

        // Step 2: Configure Beacon

        _configure();

        // Step 3: Hand ownership over and remove the spell

        _handoff();
    }

    /**********************************************************************************************/
    /*** Configuration helpers                                                                  ***/
    /**********************************************************************************************/

    function _configure() internal {
        BeaconConfig.setAaveIntegration(_report.beacon,          Arbitrum.AAVE_FACET);
        BeaconConfig.setCCTPIntegration(_report.beacon,          Arbitrum.CCTP_FACET);
        BeaconConfig.setERC4626Integration(_report.beacon,       Arbitrum.ERC4626_FACET);
        BeaconConfig.setLayerZeroIntegration(_report.beacon,     Arbitrum.LAYER_ZERO_FACET);
        BeaconConfig.setSparkVaultIntegration(_report.beacon,    Arbitrum.SPARK_VAULT_FACET);
        BeaconConfig.setTransferAssetIntegration(_report.beacon, Arbitrum.TRANSFER_ASSET_FACET);
        BeaconConfig.setUniswapV4Integration(_report.beacon,     Arbitrum.UNISWAP_V4_FACET);
    }

    /**********************************************************************************************/
    /*** Handoff                                                                                ***/
    /**********************************************************************************************/

    function _handoff() internal {
        Beacon beacon = Beacon(_report.beacon);

        beacon.grantRole(DEFAULT_ADMIN_ROLE,  Arbitrum.SPARK_EXECUTOR);
        beacon.revokeRole(DEFAULT_ADMIN_ROLE, address(this));

        require(
            beacon.getRoleMemberCount(DEFAULT_ADMIN_ROLE) == 1,
            "SparkArbitrumDeployBeacon/admin-count-incorrect"
        );
        require(
            beacon.hasRole(DEFAULT_ADMIN_ROLE, Arbitrum.SPARK_EXECUTOR),
            "SparkArbitrumDeployBeacon/incorrect-admin"
        );
        require(
            !beacon.hasRole(DEFAULT_ADMIN_ROLE, address(this)),
            "SparkArbitrumDeployBeacon/spell-still-admin"
        );
    }

}
