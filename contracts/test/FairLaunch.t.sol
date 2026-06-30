// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ForgeFairLaunchFactory} from "src/fairlaunch/ForgeFairLaunchFactory.sol";
import {ForgeFairLaunchPool} from "src/fairlaunch/ForgeFairLaunchPool.sol";
import {
    FairLaunchCurrency,
    FairLaunchRouterKind,
    FairLaunchCreateParams,
    FairLaunchRouterConfig
} from "src/fairlaunch/FairLaunchTypes.sol";
import {ForgeStandardERC20} from "src/ForgeStandardERC20.sol";

contract FairLaunchTest is Test {
    ForgeFairLaunchFactory factory;
    ForgeStandardERC20 saleToken;
    ForgeStandardERC20 usdc;

    address creator = address(0xA11CE);
    address alice = address(0xBEEF);
    address bob = address(0xC0FFEE);
    address treasury = address(0xDAD);

    function setUp() public {
        saleToken = new ForgeStandardERC20("Sale Token", "SALE", 18, 10_000_000 ether, address(this));
        usdc = new ForgeStandardERC20("USD Coin", "USDC", 6, 10_000_000e6, address(this));

        FairLaunchRouterConfig memory routers = FairLaunchRouterConfig({
            routerV2: address(0),
            factoryV2: address(0),
            wrappedNative: address(0),
            v3Factory: address(0),
            v3PoolDeployer: address(0),
            v3Migrator: address(0),
            positionManager: address(0)
        });

        factory = new ForgeFairLaunchFactory(treasury, address(usdc), routers);
    }

    // ------------------------------
    // Tests
    // ------------------------------

    function test_CreateLaunch_TransfersTokens() public {
        FairLaunchCreateParams memory params = _defaultParams(FairLaunchCurrency.ZIL);
        uint256 required = _tokensRequired(params);
        saleToken.transfer(creator, required);

        vm.startPrank(creator);
        saleToken.approve(address(factory), required);
        address poolAddr = factory.createLaunch(params);
        vm.stopPrank();

        assertEq(saleToken.balanceOf(poolAddr), required, "pool should hold deposit");
        assertEq(factory.launchCount(), 1);
        assertEq(factory.launchAt(0), poolAddr);
    }

    function test_NativeContributions_Finalize_And_Claim() public {
        FairLaunchCreateParams memory params = _defaultParams(FairLaunchCurrency.ZIL);
        uint256 required = _tokensRequired(params);
        saleToken.transfer(creator, required);

        vm.startPrank(creator);
        saleToken.approve(address(factory), required);
        address poolAddr = factory.createLaunch(params);
        vm.stopPrank();
        ForgeFairLaunchPool pool = ForgeFairLaunchPool(payable(poolAddr));

        vm.warp(params.startTime + 1);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);

        vm.prank(alice);
        pool.contribute{value: 6 ether}(0, new bytes32[](0));

        vm.prank(bob);
        pool.contribute{value: 4 ether}(0, new bytes32[](0));

        vm.warp(params.endTime + 1);
        vm.prank(creator);
        pool.finalize(0, 0);

        uint256 aliceExpected = (params.tokensForSale * 6 ether) / 10 ether;
        uint256 bobExpected = params.tokensForSale - aliceExpected;

        vm.prank(alice);
        pool.claim();
        vm.prank(bob);
        pool.claim();

        assertEq(saleToken.balanceOf(alice), aliceExpected, "alice tokens");
        assertEq(saleToken.balanceOf(bob), bobExpected, "bob tokens");
        assertEq(pool.creatorProceeds(), 10 ether, "manual listing keeps all funds");

        uint256 creatorBalBefore = creator.balance;
        vm.prank(creator);
        pool.withdrawCreatorProceeds(payable(creator));
        assertEq(creator.balance, creatorBalBefore + 10 ether, "creator withdrew native proceeds");
    }

    function test_Refund_When_SoftCap_Not_Met() public {
        FairLaunchCreateParams memory params = _defaultParams(FairLaunchCurrency.ZIL);
        params.softCap = 5 ether;
        params.tokensForSale = 1_000 ether;
        uint256 required = _tokensRequired(params);
        saleToken.transfer(creator, required);

        vm.startPrank(creator);
        saleToken.approve(address(factory), required);
        address poolAddr = factory.createLaunch(params);
        vm.stopPrank();
        ForgeFairLaunchPool pool = ForgeFairLaunchPool(payable(poolAddr));

        vm.deal(alice, 1 ether);
        vm.warp(params.startTime + 1);
        vm.prank(alice);
        pool.contribute{value: 1 ether}(0, new bytes32[](0));

        vm.warp(params.endTime + 1);
        uint256 before = alice.balance;
        vm.prank(alice);
        pool.refund();
        assertEq(alice.balance, before + 1 ether, "refund restores funds");
    }

    function test_USDC_Raise_Flow() public {
        FairLaunchCreateParams memory params = _defaultParams(FairLaunchCurrency.USDC);
        uint256 required = _tokensRequired(params);
        saleToken.transfer(creator, required);

        // Seed USDC to participants
        usdc.transfer(alice, 5_000e6);
        usdc.transfer(bob, 5_000e6);

        vm.startPrank(creator);
        saleToken.approve(address(factory), required);
        address poolAddr = factory.createLaunch(params);
        vm.stopPrank();
        ForgeFairLaunchPool pool = ForgeFairLaunchPool(payable(poolAddr));

        vm.warp(params.startTime + 1);
        vm.startPrank(alice);
        usdc.approve(poolAddr, type(uint256).max);
        pool.contribute(3_000e6, new bytes32[](0));
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(poolAddr, type(uint256).max);
        pool.contribute(2_000e6, new bytes32[](0));
        vm.stopPrank();

        vm.warp(params.endTime + 1);
        vm.prank(creator);
        pool.finalize(0, 0);

        vm.prank(alice);
        pool.claim();
        vm.prank(bob);
        pool.claim();

        uint256 totalRaised = 5_000e6;
        assertEq(pool.creatorProceeds(), totalRaised, "all USDC available to creator in manual mode");

        uint256 creatorUsdcBefore = usdc.balanceOf(creator);
        vm.prank(creator);
        pool.withdrawCreatorProceeds(payable(creator));
        assertEq(usdc.balanceOf(creator), creatorUsdcBefore + totalRaised, "creator received USDC proceeds");
    }

    function test_CreationFee_Enforced() public {
        factory.setCreationFee(1 ether);
        FairLaunchCreateParams memory params = _defaultParams(FairLaunchCurrency.ZIL);
        uint256 required = _tokensRequired(params);
        saleToken.transfer(creator, required);
        vm.deal(creator, 1 ether);

        vm.startPrank(creator);
        saleToken.approve(address(factory), required);
        vm.expectRevert(abi.encodeWithSelector(ForgeFairLaunchFactory.InsufficientFee.selector, 1 ether, 0.5 ether));
        factory.createLaunch{value: 0.5 ether}(params);
        vm.stopPrank();
    }

    // ------------------------------
    // Security finding M-1: V3 fee tier validation (fair launch)
    // ------------------------------

    function _v3RouterConfig() internal pure returns (FairLaunchRouterConfig memory) {
        return FairLaunchRouterConfig({
            routerV2: address(0xBEEF),
            factoryV2: address(0xCAFE),
            wrappedNative: address(0xF00D),
            v3Factory: address(0),
            v3PoolDeployer: address(0),
            v3Migrator: address(0),
            positionManager: address(0xABCD)
        });
    }

    // A creator selecting V3 auto-listing with an unsupported fee tier (e.g. 3000) would
    // deploy a sale whose finalize() can never succeed (the V3 tick-spacing lookup reverts).
    // The fix rejects the unsupported tier up-front at creation.
    function test_M1_FairLaunch_RejectsUnsupportedV3FeeTier() public {
        ForgeFairLaunchFactory v3Factory = new ForgeFairLaunchFactory(treasury, address(usdc), _v3RouterConfig());

        FairLaunchCreateParams memory params = _defaultParams(FairLaunchCurrency.ZIL);
        params.routerKind = FairLaunchRouterKind.V3;
        params.autoListing = true;
        params.v3Fee = 3000; // unsupported tick spacing tier
        params.lockDuration = 30 days;

        uint256 required = _tokensRequired(params);
        saleToken.transfer(creator, required);

        vm.startPrank(creator);
        saleToken.approve(address(v3Factory), required);
        vm.expectRevert(ForgeFairLaunchFactory.InvalidParam.selector);
        v3Factory.createLaunch(params);
        vm.stopPrank();
    }

    function test_M1_FairLaunch_AcceptsSupportedV3FeeTier() public {
        ForgeFairLaunchFactory v3Factory = new ForgeFairLaunchFactory(treasury, address(usdc), _v3RouterConfig());

        FairLaunchCreateParams memory params = _defaultParams(FairLaunchCurrency.ZIL);
        params.routerKind = FairLaunchRouterKind.V3;
        params.autoListing = true;
        params.v3Fee = 10000; // supported tier
        params.lockDuration = 30 days;

        uint256 required = _tokensRequired(params);
        saleToken.transfer(creator, required);

        vm.startPrank(creator);
        saleToken.approve(address(v3Factory), required);
        address pool = v3Factory.createLaunch(params);
        vm.stopPrank();

        assertEq(v3Factory.launchCount(), 1);
        assertTrue(pool != address(0));
    }

    // ------------------------------
    // Helpers
    // ------------------------------

    function _defaultParams(FairLaunchCurrency currency) internal view returns (FairLaunchCreateParams memory params) {
        params.token = address(saleToken);
        params.currency = currency;
        params.tokensForSale = 10_000 ether;
        params.softCap = currency == FairLaunchCurrency.ZIL ? 5 ether : 5_000e6;
        params.hardCap = 0;
        params.maxContribution = 0;
        params.startTime = uint64(block.timestamp + 10);
        params.endTime = uint64(block.timestamp + 1 days);
        params.liquidityPercent = 80;
        params.autoListing = false;
        params.routerKind = FairLaunchRouterKind.V2;
        params.v3Fee = 3000;
        params.lockDuration = 0;
        params.whitelistRoot = bytes32(0);
        params.whitelistEnabled = false;
        params.metadataURI = "ipfs://useforge/fairlaunch";
    }

    function _tokensRequired(FairLaunchCreateParams memory params) internal pure returns (uint256) {
        return params.tokensForSale + (params.tokensForSale * params.liquidityPercent) / 100;
    }
}
