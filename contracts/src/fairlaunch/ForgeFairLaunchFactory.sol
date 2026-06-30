// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";

import {
    FairLaunchCurrency,
    FairLaunchRouterKind,
    FairLaunchCreateParams,
    FairLaunchRouterConfig,
    FairLaunchInitParams
} from "./FairLaunchTypes.sol";
import {ForgeFairLaunchPool} from "./ForgeFairLaunchPool.sol";

/// @notice Factory contract that mints per-sale ForgeFairLaunchPool instances and charges a flat ZIL fee.
contract ForgeFairLaunchFactory is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address payable;

    error InsufficientFee(uint256 required, uint256 provided);
    error InvalidParam();

    event FairLaunchCreated(
        address indexed pool,
        address indexed creator,
        address indexed token,
        FairLaunchCurrency currency,
        uint256 tokensForSale,
        string metadataURI
    );
    event CreationFeeUpdated(uint256 oldFee, uint256 newFee);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event RouterConfigUpdated(
        address routerV2,
        address factoryV2,
        address wrappedNative,
        address v3Factory,
        address v3PoolDeployer,
        address v3Migrator,
        address positionManager
    );
    event UsdcUpdated(address indexed previous, address indexed current);

    uint256 public creationFee; // flat fee denominated in native ZIL
    address public treasury;
    address public usdcToken;
    FairLaunchRouterConfig public routerConfig;

    address[] public allLaunches;

    constructor(address _treasury, address _usdc, FairLaunchRouterConfig memory _routers) Ownable(msg.sender) {
        treasury = _treasury;
        usdcToken = _usdc;
        routerConfig = _routers;
    }

    function setCreationFee(uint256 newFee) external onlyOwner {
        emit CreationFeeUpdated(creationFee, newFee);
        creationFee = newFee;
    }

    function setTreasury(address newTreasury) external onlyOwner {
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    function setUsdcToken(address newUsdc) external onlyOwner {
        emit UsdcUpdated(usdcToken, newUsdc);
        usdcToken = newUsdc;
    }

    function setRouterConfig(FairLaunchRouterConfig calldata config) external onlyOwner {
        routerConfig = config;
        emit RouterConfigUpdated(
            config.routerV2,
            config.factoryV2,
            config.wrappedNative,
            config.v3Factory,
            config.v3PoolDeployer,
            config.v3Migrator,
            config.positionManager
        );
    }

    function launchCount() external view returns (uint256) {
        return allLaunches.length;
    }

    function launchAt(uint256 index) external view returns (address) {
        return allLaunches[index];
    }

    function createLaunch(FairLaunchCreateParams calldata params)
        external
        payable
        nonReentrant
        returns (address pool)
    {
        _validateParams(params);
        _collectFee();

        address raiseToken = params.currency == FairLaunchCurrency.USDC ? usdcToken : address(0);
        if (params.currency == FairLaunchCurrency.USDC && raiseToken == address(0)) revert InvalidParam();

        FairLaunchInitParams memory init = FairLaunchInitParams({
            creator: msg.sender,
            token: params.token,
            currency: params.currency,
            raiseToken: raiseToken,
            tokensForSale: params.tokensForSale,
            liquidityPercent: params.liquidityPercent,
            softCap: params.softCap,
            hardCap: params.hardCap,
            maxContribution: params.maxContribution,
            startTime: params.startTime,
            endTime: params.endTime,
            autoListing: params.autoListing,
            routerKind: params.routerKind,
            v3Fee: params.routerKind == FairLaunchRouterKind.V3 && params.v3Fee == 0 ? 10000 : params.v3Fee,
            lockDuration: params.lockDuration,
            whitelistRoot: params.whitelistRoot,
            whitelistEnabled: params.whitelistEnabled,
            routers: routerConfig
        });

        ForgeFairLaunchPool newPool = new ForgeFairLaunchPool(init);

        uint256 tokensRequired = newPool.totalTokensRequired();
        IERC20(params.token).safeTransferFrom(msg.sender, address(newPool), tokensRequired);

        pool = address(newPool);
        allLaunches.push(pool);

        emit FairLaunchCreated(
            pool, msg.sender, params.token, params.currency, params.tokensForSale, params.metadataURI
        );
    }

    function _collectFee() internal {
        if (creationFee == 0) return;
        if (msg.value < creationFee) revert InsufficientFee(creationFee, msg.value);
        if (treasury != address(0)) {
            payable(treasury).sendValue(creationFee);
        }
        uint256 refund = msg.value - creationFee;
        if (refund > 0) {
            payable(msg.sender).sendValue(refund);
        }
    }

    function _validateParams(FairLaunchCreateParams calldata params) internal view {
        if (params.token == address(0)) revert InvalidParam();
        if (params.tokensForSale == 0) revert InvalidParam();
        if (params.liquidityPercent < 51 || params.liquidityPercent > 100) revert InvalidParam();
        if (params.softCap == 0) revert InvalidParam();
        if (params.endTime <= params.startTime) revert InvalidParam();
        if (params.startTime < block.timestamp) revert InvalidParam();
        if (params.hardCap != 0 && params.hardCap < params.softCap) revert InvalidParam();
        if (params.routerKind == FairLaunchRouterKind.V3 && params.autoListing && !_isSupportedV3Fee(params.v3Fee)) {
            revert InvalidParam();
        }
        if (!_isAllowedLockDuration(params.lockDuration)) revert InvalidParam();
    }

    /// @dev Supported Plunder V3 fee tiers (must match ForgeFairLaunchPool tick spacing).
    function _isSupportedV3Fee(uint24 fee) internal pure returns (bool) {
        return fee == 100 || fee == 500 || fee == 2500 || fee == 10000;
    }

    function _isAllowedLockDuration(uint256 duration) internal pure returns (bool) {
        if (duration == 0) return true; // no lock (manual listing)
        if (duration == 30 days || duration == 90 days || duration == 180 days || duration == 365 days) return true;
        if (duration == type(uint256).max) return true; // indefinite
        return false;
    }
}
