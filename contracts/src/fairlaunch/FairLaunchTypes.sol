// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Supported raise currencies. `ZIL` uses native value, `USDC` uses the configured ERC20.
enum FairLaunchCurrency {
    ZIL,
    USDC
}

/// @dev Router flavors for automatic listing.
enum FairLaunchRouterKind {
    V2,
    V3
}

/// @dev User-supplied parameters when creating a new fair launch.
struct FairLaunchCreateParams {
    address token;
    FairLaunchCurrency currency;
    uint256 tokensForSale;
    uint256 softCap;
    uint256 hardCap; // 0 = uncapped
    uint256 maxContribution; // 0 = unlimited per wallet
    uint64 startTime;
    uint64 endTime;
    uint16 liquidityPercent; // 51-100 inclusive
    bool autoListing;
    FairLaunchRouterKind routerKind;
    uint24 v3Fee; // supported tiers: 100, 500, 2500, 10000. Ignored when routerKind == V2
    uint256 lockDuration; // seconds; type(uint256).max == indefinite
    bytes32 whitelistRoot;
    bool whitelistEnabled;
    string metadataURI; // emitted in factory event for off-chain metadata
}

/// @dev On-chain addresses for PlunderSwap integration.
struct FairLaunchRouterConfig {
    address routerV2;
    address factoryV2;
    address wrappedNative;
    address v3Factory;
    address v3PoolDeployer;
    address v3Migrator;
    address positionManager;
}

/// @dev Internal initialization params forwarded from factory to each pool.
struct FairLaunchInitParams {
    address creator;
    address token;
    FairLaunchCurrency currency;
    address raiseToken; // USDC token when currency == USDC, address(0) for ZIL
    uint256 tokensForSale;
    uint16 liquidityPercent;
    uint256 softCap;
    uint256 hardCap;
    uint256 maxContribution;
    uint64 startTime;
    uint64 endTime;
    bool autoListing;
    FairLaunchRouterKind routerKind;
    uint24 v3Fee;
    uint256 lockDuration;
    bytes32 whitelistRoot;
    bool whitelistEnabled;
    FairLaunchRouterConfig routers;
}
