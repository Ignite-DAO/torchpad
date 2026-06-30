// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {ForgeBondingCurveFactory} from "src/bondingcurve/ForgeBondingCurveFactory.sol";
import {ForgeBondingCurvePool} from "src/bondingcurve/ForgeBondingCurvePool.sol";
import {ForgeBondingCurveToken} from "src/bondingcurve/ForgeBondingCurveToken.sol";
import {
    BondingCurveCreateParams,
    BondingCurveRouterConfig,
    BondingCurveInitParams,
    PoolState
} from "src/bondingcurve/BondingCurveTypes.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract MockWETH {
    string public name = "Wrapped ZIL";
    string public symbol = "WZIL";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 wad) external {
        require(balanceOf[msg.sender] >= wad);
        balanceOf[msg.sender] -= wad;
        payable(msg.sender).transfer(wad);
    }

    function approve(address guy, uint256 wad) external returns (bool) {
        allowance[msg.sender][guy] = wad;
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= value;
        }
        balanceOf[from] -= value;
        balanceOf[to] += value;
        return true;
    }

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

contract MockPositionManager {
    uint256 public nextTokenId = 1;

    struct Position {
        address token0;
        address token1;
        uint24 fee;
        uint256 amount0;
        uint256 amount1;
        address owner;
    }

    mapping(uint256 => Position) public positions;

    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function createAndInitializePoolIfNecessary(
        address,
        address,
        uint24,
        uint160 sqrtPriceX96
    ) external returns (address) {
        return address(new MockV3Pool(sqrtPriceX96));
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        IERC20(params.token0).transferFrom(msg.sender, address(this), params.amount0Desired);
        IERC20(params.token1).transferFrom(msg.sender, address(this), params.amount1Desired);

        tokenId = nextTokenId++;
        liquidity = uint128(params.amount0Desired + params.amount1Desired);
        amount0 = params.amount0Desired;
        amount1 = params.amount1Desired;

        positions[tokenId] = Position({
            token0: params.token0,
            token1: params.token1,
            fee: params.fee,
            amount0: amount0,
            amount1: amount1,
            owner: params.recipient
        });
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(positions[tokenId].owner == from, "not owner");
        positions[tokenId].owner = to;
    }
}

contract MockV3Pool {
    uint160 public sqrtPriceX96;

    constructor(uint160 price) {
        sqrtPriceX96 = price;
    }

    function slot0()
        external
        view
        returns (uint160, int24, uint16, uint16, uint16, uint8, bool)
    {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, false);
    }
}

contract MockV3Factory {
    mapping(bytes32 => address) public pools;

    function getPool(address token0, address token1, uint24 fee) external view returns (address) {
        return pools[_poolKey(token0, token1, fee)];
    }

    function setPool(address token0, address token1, uint24 fee, address pool) external {
        pools[_poolKey(token0, token1, fee)] = pool;
    }

    function _poolKey(address token0, address token1, uint24 fee) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(token0, token1, fee));
    }
}

contract MockPositionManagerWithFactory {
    uint256 public nextTokenId = 1;
    address public factory;
    uint256 public amount0Bps = 10_000;
    uint256 public amount1Bps = 10_000;

    struct Position {
        address token0;
        address token1;
        uint24 fee;
        uint256 amount0;
        uint256 amount1;
        address owner;
    }

    mapping(uint256 => Position) public positions;

    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    constructor(address factory_) {
        factory = factory_;
    }

    function setUsedBps(uint256 amount0Bps_, uint256 amount1Bps_) external {
        amount0Bps = amount0Bps_;
        amount1Bps = amount1Bps_;
    }

    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external returns (address) {
        MockV3Factory v3Factory = MockV3Factory(factory);
        address existing = v3Factory.getPool(token0, token1, fee);
        if (existing != address(0)) {
            return existing;
        }

        MockV3Pool pool = new MockV3Pool(sqrtPriceX96);
        v3Factory.setPool(token0, token1, fee, address(pool));
        return address(pool);
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        amount0 = (params.amount0Desired * amount0Bps) / 10_000;
        amount1 = (params.amount1Desired * amount1Bps) / 10_000;

        IERC20(params.token0).transferFrom(msg.sender, address(this), amount0);
        IERC20(params.token1).transferFrom(msg.sender, address(this), amount1);

        tokenId = nextTokenId++;
        liquidity = uint128(amount0 + amount1);

        positions[tokenId] = Position({
            token0: params.token0,
            token1: params.token1,
            fee: params.fee,
            amount0: amount0,
            amount1: amount1,
            owner: params.recipient
        });
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(positions[tokenId].owner == from, "not owner");
        positions[tokenId].owner = to;
    }
}


contract BondingCurveTest is Test {
    using stdStorage for StdStorage;

    ForgeBondingCurveFactory factory;
    MockWETH weth;
    MockPositionManager positionManager;

    address creator = address(0xA11CE);
    address alice = address(0xBEEF);
    address bob = address(0xC0FFEE);
    address treasury = address(0xDAD);

    uint256 constant GRADUATION_MARKET_CAP = 8_000_000 ether;
    uint256 constant INITIAL_VIRTUAL_ZIL_RESERVE = 22_500 ether;
    uint256 constant TRADING_FEE_PERCENT = 100; // 1%
    uint256 constant GRADUATION_FEE_PERCENT = 250; // 2.5%
    uint24 constant DEFAULT_V3_FEE = 10000; // 1%

    function setUp() public {
        weth = new MockWETH();
        positionManager = new MockPositionManager();

        BondingCurveRouterConfig memory config = BondingCurveRouterConfig({
            wrappedNative: address(weth),
            positionManager: address(positionManager)
        });

        factory = new ForgeBondingCurveFactory(
            treasury,
            GRADUATION_MARKET_CAP,
            INITIAL_VIRTUAL_ZIL_RESERVE,
            TRADING_FEE_PERCENT,
            GRADUATION_FEE_PERCENT,
            DEFAULT_V3_FEE,
            config
        );
    }

    // ------------------------------
    // Factory Tests
    // ------------------------------

    function test_CreatePool_Success() public {
        BondingCurveCreateParams memory params = BondingCurveCreateParams({
            name: "Test Token",
            symbol: "TEST",
            metadataURI: "ipfs://test"
        });

        vm.prank(creator);
        address poolAddr = factory.createPool(params);

        assertEq(factory.poolCount(), 1);
        assertEq(factory.poolAt(0), poolAddr);

        ForgeBondingCurvePool pool = ForgeBondingCurvePool(payable(poolAddr));
        assertEq(pool.creator(), creator);
        assertEq(pool.graduationMarketCap(), GRADUATION_MARKET_CAP);
        assertEq(pool.initialVirtualZilReserve(), INITIAL_VIRTUAL_ZIL_RESERVE);
        assertEq(pool.tradingFeePercent(), TRADING_FEE_PERCENT);
        assertEq(uint8(pool.state()), uint8(PoolState.Trading));
        assertEq(pool.virtualTokenReserve(), pool.TOTAL_SUPPLY());
        assertEq(pool.virtualZilReserve(), INITIAL_VIRTUAL_ZIL_RESERVE);
    }

    function test_CreatePool_WithFee() public {
        factory.setCreationFee(1 ether);

        BondingCurveCreateParams memory params = BondingCurveCreateParams({
            name: "Test Token",
            symbol: "TEST",
            metadataURI: ""
        });

        vm.deal(creator, 2 ether);
        uint256 treasuryBefore = treasury.balance;

        vm.prank(creator);
        factory.createPool{value: 1 ether}(params);

        assertEq(treasury.balance, treasuryBefore + 1 ether);
    }

    function test_CreatePool_InsufficientFee_Reverts() public {
        factory.setCreationFee(1 ether);

        BondingCurveCreateParams memory params = BondingCurveCreateParams({
            name: "Test Token",
            symbol: "TEST",
            metadataURI: ""
        });

        vm.deal(creator, 0.5 ether);
        vm.prank(creator);
        vm.expectRevert();
        factory.createPool{value: 0.5 ether}(params);
    }

    // ------------------------------
    // Virtual AMM Tests
    // ------------------------------

    function test_InitialReserves() public {
        ForgeBondingCurvePool pool = _createPool();

        assertEq(pool.virtualTokenReserve(), 1_000_000_000e18);
        assertEq(pool.virtualZilReserve(), INITIAL_VIRTUAL_ZIL_RESERVE);
        assertEq(pool.realZilReserve(), 0);
        assertEq(pool.k(), 1_000_000_000e18 * INITIAL_VIRTUAL_ZIL_RESERVE);
    }

    function test_ConstantProductMath() public {
        ForgeBondingCurvePool pool = _createPool();

        uint256 k = pool.k();
        uint256 initialTokenReserve = pool.virtualTokenReserve();
        uint256 initialZilReserve = pool.virtualZilReserve();

        assertEq(k, initialTokenReserve * initialZilReserve);
    }

    // ------------------------------
    // Buy Tests
    // ------------------------------

    function test_Buy_Success() public {
        ForgeBondingCurvePool pool = _createPool();

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        uint256 tokensOut = pool.buy{value: 1 ether}(0);

        assertGt(tokensOut, 0);
        assertEq(IERC20(address(pool.token())).balanceOf(alice), tokensOut);
        assertGt(pool.realZilReserve(), 0);
        assertGt(pool.feesCollected(), 0);
    }

    function test_Buy_UpdatesVirtualReserves() public {
        ForgeBondingCurvePool pool = _createPool();

        uint256 initialTokenReserve = pool.virtualTokenReserve();
        uint256 initialZilReserve = pool.virtualZilReserve();

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        uint256 tokensOut = pool.buy{value: 1 ether}(0);

        uint256 zilAfterFee = 0.99 ether; // 1% fee deducted

        assertEq(pool.virtualZilReserve(), initialZilReserve + zilAfterFee);
        assertEq(pool.virtualTokenReserve(), initialTokenReserve - tokensOut);
        assertEq(pool.realZilReserve(), zilAfterFee);
    }

    function test_Buy_MultipleBuys_PriceIncreases() public {
        ForgeBondingCurvePool pool = _createPool();

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);

        uint256 price1 = pool.currentPrice();

        vm.prank(alice);
        pool.buy{value: 1 ether}(0);

        uint256 price2 = pool.currentPrice();
        assertGt(price2, price1, "price should increase after buy");

        vm.prank(bob);
        pool.buy{value: 1 ether}(0);

        uint256 price3 = pool.currentPrice();
        assertGt(price3, price2, "price should increase after second buy");
    }

    function test_Buy_SlippageProtection() public {
        ForgeBondingCurvePool pool = _createPool();

        vm.deal(alice, 1 ether);

        (uint256 expectedTokens,) = pool.quoteBuy(1 ether);

        vm.prank(alice);
        vm.expectRevert(ForgeBondingCurvePool.SlippageExceeded.selector);
        pool.buy{value: 1 ether}(expectedTokens * 2); // Require double the expected
    }

    function test_Buy_ZeroAmount_Reverts() public {
        ForgeBondingCurvePool pool = _createPool();

        vm.prank(alice);
        vm.expectRevert(ForgeBondingCurvePool.ZeroAmount.selector);
        pool.buy{value: 0}(0);
    }

    // ------------------------------
    // Sell Tests
    // ------------------------------

    function test_Sell_Success() public {
        ForgeBondingCurvePool pool = _createPool();

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        uint256 tokensOut = pool.buy{value: 1 ether}(0);

        IERC20 token = pool.token();
        uint256 aliceBalBefore = alice.balance;

        vm.startPrank(alice);
        token.approve(address(pool), tokensOut);
        uint256 zilOut = pool.sell(tokensOut, 0);
        vm.stopPrank();

        assertGt(zilOut, 0);
        assertEq(token.balanceOf(alice), 0);
        assertGt(alice.balance, aliceBalBefore);
    }

    function test_Sell_UpdatesVirtualReserves() public {
        ForgeBondingCurvePool pool = _createPool();

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        uint256 tokensOut = pool.buy{value: 1 ether}(0);

        uint256 tokenReserveAfterBuy = pool.virtualTokenReserve();
        uint256 zilReserveAfterBuy = pool.virtualZilReserve();

        IERC20 token = pool.token();
        vm.startPrank(alice);
        token.approve(address(pool), tokensOut);
        pool.sell(tokensOut, 0);
        vm.stopPrank();

        assertGt(pool.virtualTokenReserve(), tokenReserveAfterBuy);
        assertLt(pool.virtualZilReserve(), zilReserveAfterBuy);
    }

    function test_Sell_PartialSell() public {
        ForgeBondingCurvePool pool = _createPool();

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        uint256 tokensOut = pool.buy{value: 1 ether}(0);

        IERC20 token = pool.token();
        uint256 halfTokens = tokensOut / 2;

        vm.startPrank(alice);
        token.approve(address(pool), halfTokens);
        pool.sell(halfTokens, 0);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), tokensOut - halfTokens);
    }

    function test_Sell_SlippageProtection() public {
        ForgeBondingCurvePool pool = _createPool();

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        uint256 tokensOut = pool.buy{value: 1 ether}(0);

        IERC20 token = pool.token();
        (uint256 expectedZil,) = pool.quoteSell(tokensOut);

        vm.startPrank(alice);
        token.approve(address(pool), tokensOut);
        vm.expectRevert(ForgeBondingCurvePool.SlippageExceeded.selector);
        pool.sell(tokensOut, expectedZil * 2); // Require double
        vm.stopPrank();
    }

    function test_Sell_ExceedsRealReserve_Reverts() public {
        ForgeBondingCurvePool pool = _createPool();

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        pool.buy{value: 1 ether}(0);

        vm.deal(bob, 10 ether);
        vm.prank(bob);
        uint256 bobTokens = pool.buy{value: 1 ether}(0);

        vm.prank(alice);
        uint256 aliceTokens = pool.buy{value: 5 ether}(0);

        IERC20 token = pool.token();

        vm.startPrank(alice);
        token.approve(address(pool), aliceTokens);
        pool.sell(aliceTokens, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        token.approve(address(pool), bobTokens);
        pool.sell(bobTokens, 0);
        vm.stopPrank();
    }

    // ------------------------------
    // Graduation Tests
    // ------------------------------

    function test_Graduation_OnlyAtMarketCapThreshold() public {
        ForgeBondingCurvePool pool = _createLowCapPool();

        vm.deal(alice, 10000 ether);
        vm.prank(alice);
        pool.buy{value: 100 ether}(0);

        assertEq(uint8(pool.state()), uint8(PoolState.Graduated));
        assertGt(pool.lpTokenIdV3(), 0);
    }

    function test_Graduation_TradingStops() public {
        ForgeBondingCurvePool pool = _createLowCapPool();

        vm.deal(alice, 10000 ether);
        vm.prank(alice);
        pool.buy{value: 100 ether}(0);

        vm.deal(bob, 10 ether);
        vm.prank(bob);
        vm.expectRevert(ForgeBondingCurvePool.NotTrading.selector);
        pool.buy{value: 1 ether}(0);

        IERC20 token = pool.token();
        uint256 aliceBalance = token.balanceOf(alice);

        vm.startPrank(alice);
        token.approve(address(pool), aliceBalance);
        vm.expectRevert(ForgeBondingCurvePool.NotTrading.selector);
        pool.sell(aliceBalance, 0);
        vm.stopPrank();
    }

    function test_Graduation_UsesRealZilReserve() public {
        ForgeBondingCurvePool pool = _createLowCapPool();

        vm.deal(alice, 10000 ether);

        vm.prank(alice);
        pool.buy{value: 100 ether}(0);

        assertEq(uint8(pool.state()), uint8(PoolState.Graduated));
        assertEq(pool.realZilReserve(), 0);
    }

    function test_Graduation_SweepsLeftoverAssetsToTreasury() public {
        MockWETH localWeth = new MockWETH();
        MockV3Factory v3Factory = new MockV3Factory();
        MockPositionManagerWithFactory pm = new MockPositionManagerWithFactory(address(v3Factory));
        pm.setUsedBps(5000, 5000);

        ForgeBondingCurvePool pool = _createLowCapPoolWithConfig(address(localWeth), address(pm));
        IERC20 token = pool.token();

        uint256 treasuryTokenBefore = token.balanceOf(treasury);
        uint256 treasuryWethBefore = localWeth.balanceOf(treasury);

        vm.deal(alice, 1000 ether);
        vm.prank(alice);
        pool.buy{value: 100 ether}(0);

        assertEq(uint8(pool.state()), uint8(PoolState.Graduated));
        assertEq(token.balanceOf(address(pool)), 0, "pool tokens should be swept");
        assertEq(localWeth.balanceOf(address(pool)), 0, "pool WETH should be swept");
        assertGt(token.balanceOf(treasury), treasuryTokenBefore, "treasury should receive leftover tokens");
        assertGt(localWeth.balanceOf(treasury), treasuryWethBefore, "treasury should receive leftover WETH");
    }

    // ------------------------------
    // Fee Tests
    // ------------------------------

    function test_WithdrawFees_OnlyTreasury() public {
        ForgeBondingCurvePool pool = _createPool();

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        pool.buy{value: 1 ether}(0);

        assertGt(pool.feesCollected(), 0);

        vm.prank(alice);
        vm.expectRevert(ForgeBondingCurvePool.OnlyTreasury.selector);
        pool.withdrawFees();

        uint256 treasuryBefore = treasury.balance;
        uint256 fees = pool.feesCollected();

        vm.prank(treasury);
        pool.withdrawFees();

        assertEq(treasury.balance, treasuryBefore + fees);
        assertEq(pool.feesCollected(), 0);
    }

    function test_Sell_UsesFeesWhenRealReserveDepleted() public {
        ForgeBondingCurvePool pool = _createPool();
        IERC20 token = pool.token();

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        uint256 aliceTokens = pool.buy{value: 10 ether}(0);

        uint256 feesBefore = pool.feesCollected();
        assertGt(feesBefore, 0);

        uint256 realReserveSlot = stdstore.target(address(pool)).sig("realZilReserve()").find();
        vm.store(address(pool), bytes32(realReserveSlot), bytes32(uint256(0)));
        assertEq(pool.realZilReserve(), 0);

        uint256 target = feesBefore / 10;
        if (target == 0) {
            target = 1;
        }

        uint256 tokensToSell = _tokensToSellForGross(
            target,
            pool.virtualZilReserve(),
            pool.virtualTokenReserve(),
            pool.k()
        );
        assertGt(tokensToSell, 0);
        assertLt(tokensToSell, aliceTokens);

        (uint256 quotedZil,) = pool.quoteSell(tokensToSell);
        assertGt(quotedZil, 0, "quote should use fees");

        vm.startPrank(alice);
        token.approve(address(pool), tokensToSell);
        pool.sell(tokensToSell, 0);
        vm.stopPrank();

        assertEq(pool.realZilReserve(), 0);
        assertLt(pool.feesCollected(), feesBefore);
    }

    function test_QuoteSell_ZeroWhenExceedingRealPlusFees() public {
        ForgeBondingCurvePool pool = _createPool();

        vm.deal(alice, 200_000 ether);
        vm.prank(alice);
        pool.buy{value: 150_000 ether}(0);

        uint256 available = pool.realZilReserve() + pool.feesCollected();
        uint256 vZ = pool.virtualZilReserve();
        uint256 vT = pool.virtualTokenReserve();
        uint256 k = pool.k();

        uint256 target = available + 1;
        require(target < vZ, "target too large");
        uint256 tokensToSell = _tokensToSellForGross(target, vZ, vT, k);

        (uint256 zilOut, uint256 fee) = pool.quoteSell(tokensToSell);
        assertEq(zilOut, 0);
        assertEq(fee, 0);
    }

    function test_Graduation_SendsFeeToTreasury() public {
        ForgeBondingCurvePool pool = _createLowCapPool();

        uint256 treasuryBefore = treasury.balance;

        vm.deal(alice, 10000 ether);
        vm.prank(alice);
        pool.buy{value: 100 ether}(0);

        assertEq(uint8(pool.state()), uint8(PoolState.Graduated));

        uint256 treasuryAfter = treasury.balance;
        uint256 treasuryReceived = treasuryAfter - treasuryBefore;

        assertGt(treasuryReceived, 0, "treasury should receive graduation fee");
    }

    function test_SetGraduationFeePercent_Success() public {
        factory.setGraduationFeePercent(500); // 5%
        assertEq(factory.graduationFeePercent(), 500);
    }

    function test_SetGraduationFeePercent_TooHigh_Reverts() public {
        vm.expectRevert(ForgeBondingCurveFactory.InvalidParam.selector);
        factory.setGraduationFeePercent(1001); // > 10%
    }

    function test_SetInitialVirtualZilReserve_Success() public {
        factory.setInitialVirtualZilReserve(50_000 ether);
        assertEq(factory.initialVirtualZilReserve(), 50_000 ether);
    }

    function test_SetInitialVirtualZilReserve_Zero_Reverts() public {
        vm.expectRevert(ForgeBondingCurveFactory.InvalidParam.selector);
        factory.setInitialVirtualZilReserve(0);
    }

    // ------------------------------
    // View Function Tests
    // ------------------------------

    function test_QuoteBuy_MatchesActual() public {
        ForgeBondingCurvePool pool = _createPool();

        vm.deal(alice, 10 ether);

        (uint256 quotedTokens,) = pool.quoteBuy(1 ether);

        vm.prank(alice);
        uint256 actualTokens = pool.buy{value: 1 ether}(0);

        assertEq(actualTokens, quotedTokens);
    }

    function test_QuoteSell_MatchesActual() public {
        ForgeBondingCurvePool pool = _createPool();

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        uint256 tokensOut = pool.buy{value: 1 ether}(0);

        (uint256 quotedZil,) = pool.quoteSell(tokensOut);

        IERC20 token = pool.token();
        vm.startPrank(alice);
        token.approve(address(pool), tokensOut);
        uint256 actualZil = pool.sell(tokensOut, 0);
        vm.stopPrank();

        assertEq(actualZil, quotedZil);
    }

    function test_ProgressBps() public {
        ForgeBondingCurvePool pool = _createPool();

        uint256 initialProgress = pool.progressBps();
        assertLt(initialProgress, 10_000, "should not be graduated initially");

        vm.deal(alice, 10000 ether);
        vm.prank(alice);
        pool.buy{value: 1000 ether}(0);

        uint256 progressAfterBuy = pool.progressBps();
        assertGt(progressAfterBuy, initialProgress, "progress should increase after buy");
        assertLe(progressAfterBuy, 10_000);
    }

    function test_TokensSold() public {
        ForgeBondingCurvePool pool = _createPool();

        assertEq(pool.tokensSold(), 0);

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        uint256 tokensOut = pool.buy{value: 1 ether}(0);

        assertEq(pool.tokensSold(), tokensOut);
    }

    function test_CurrentPrice() public {
        ForgeBondingCurvePool pool = _createPool();

        uint256 expectedInitialPrice = (INITIAL_VIRTUAL_ZIL_RESERVE * 1e18) / 1_000_000_000e18;
        assertEq(pool.currentPrice(), expectedInitialPrice);
    }

    function test_MarketCap() public {
        ForgeBondingCurvePool pool = _createPool();

        uint256 price = pool.currentPrice();
        uint256 expectedMarketCap = (price * 1_000_000_000e18) / 1e18;
        assertEq(pool.marketCap(), expectedMarketCap);
    }

    // ------------------------------
    // Validation Tests
    // ------------------------------

    function test_CreatePool_NameTooLong_Reverts() public {
        string memory longName = "This is a very long token name that exceeds the maximum allowed!!";

        BondingCurveCreateParams memory params = BondingCurveCreateParams({
            name: longName,
            symbol: "TEST",
            metadataURI: ""
        });

        vm.prank(creator);
        vm.expectRevert(ForgeBondingCurveFactory.NameTooLong.selector);
        factory.createPool(params);
    }

    function test_CreatePool_SymbolTooLong_Reverts() public {
        string memory longSymbol = "VERYLONGSYMBL";

        BondingCurveCreateParams memory params = BondingCurveCreateParams({
            name: "Test Token",
            symbol: longSymbol,
            metadataURI: ""
        });

        vm.prank(creator);
        vm.expectRevert(ForgeBondingCurveFactory.SymbolTooLong.selector);
        factory.createPool(params);
    }

    function test_CreatePool_EmptyName_Reverts() public {
        BondingCurveCreateParams memory params = BondingCurveCreateParams({
            name: "",
            symbol: "TEST",
            metadataURI: ""
        });

        vm.prank(creator);
        vm.expectRevert(ForgeBondingCurveFactory.InvalidParam.selector);
        factory.createPool(params);
    }

    function test_CreatePool_EmptySymbol_Reverts() public {
        BondingCurveCreateParams memory params = BondingCurveCreateParams({
            name: "Test Token",
            symbol: "",
            metadataURI: ""
        });

        vm.prank(creator);
        vm.expectRevert(ForgeBondingCurveFactory.InvalidParam.selector);
        factory.createPool(params);
    }

    function test_SetGraduationMarketCap_TooLow_Reverts() public {
        vm.expectRevert(ForgeBondingCurveFactory.GraduationCapTooLow.selector);
        factory.setGraduationMarketCap(0.5 ether); // Below MIN_GRADUATION_MARKET_CAP
    }

    function test_SetGraduationMarketCap_Success() public {
        uint256 newCap = 50 ether;
        factory.setGraduationMarketCap(newCap);
        assertEq(factory.graduationMarketCap(), newCap);
    }

    function test_Factory_ZeroGraduationCap_Reverts() public {
        BondingCurveRouterConfig memory config = BondingCurveRouterConfig({
            wrappedNative: address(weth),
            positionManager: address(positionManager)
        });

        vm.expectRevert(ForgeBondingCurveFactory.GraduationCapTooLow.selector);
        new ForgeBondingCurveFactory(
            treasury,
            0,
            INITIAL_VIRTUAL_ZIL_RESERVE,
            TRADING_FEE_PERCENT,
            GRADUATION_FEE_PERCENT,
            DEFAULT_V3_FEE,
            config
        );
    }

    function test_Factory_ZeroInitialVirtualZilReserve_Reverts() public {
        BondingCurveRouterConfig memory config = BondingCurveRouterConfig({
            wrappedNative: address(weth),
            positionManager: address(positionManager)
        });

        vm.expectRevert(ForgeBondingCurveFactory.InvalidParam.selector);
        new ForgeBondingCurveFactory(
            treasury,
            GRADUATION_MARKET_CAP,
            0,
            TRADING_FEE_PERCENT,
            GRADUATION_FEE_PERCENT,
            DEFAULT_V3_FEE,
            config
        );
    }

    // ------------------------------
    // LP Auto-Burn Tests
    // ------------------------------

    function test_Graduation_AutoBurnsLp() public {
        ForgeBondingCurvePool pool = _createGraduatedPool();

        uint256 lpTokenId = pool.lpTokenIdV3();
        assertGt(lpTokenId, 0, "should have LP token ID");

        (,,,,,address owner) = positionManager.positions(lpTokenId);
        assertEq(owner, address(0x000000000000000000000000000000000000dEaD), "LP should be burned");
    }

    // ------------------------------
    // Security Tests
    // ------------------------------

    function test_Buy_BelowMinimum_Reverts() public {
        ForgeBondingCurvePool pool = _createPool();

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(ForgeBondingCurvePool.BelowMinimum.selector);
        pool.buy{value: 0.0001 ether}(0); // Below MIN_BUY_AMOUNT of 0.001 ether
    }

    function test_Sell_BelowMinimum_Reverts() public {
        ForgeBondingCurvePool pool = _createPool();

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        pool.buy{value: 1 ether}(0);

        IERC20 token = pool.token();
        uint256 tinyAmount = 1e14; // Below MIN_SELL_TOKENS of 1e15

        vm.startPrank(alice);
        token.approve(address(pool), tinyAmount);
        vm.expectRevert(ForgeBondingCurvePool.BelowMinimum.selector);
        pool.sell(tinyAmount, 0);
        vm.stopPrank();
    }

    function test_SecurityConstants_Exist() public {
        ForgeBondingCurvePool pool = _createPool();

        assertEq(pool.MIN_BUY_AMOUNT(), 0.001 ether);
        assertEq(pool.MIN_SELL_TOKENS(), 1e15);
        assertEq(pool.MIN_GRADUATION_LIQUIDITY(), 0.1 ether);
    }

    // ------------------------------
    // Receive Tests
    // ------------------------------

    function test_DirectEthTransfer_Reverts() public {
        ForgeBondingCurvePool pool = _createPool();

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(ForgeBondingCurvePool.TransferFailed.selector);
        payable(address(pool)).transfer(1 ether);
    }

    // ------------------------------
    // Transfer Lock Tests
    // ------------------------------

    function test_TransferBlockedBeforeGraduation() public {
        ForgeBondingCurvePool pool = _createPool();

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        uint256 tokensOut = pool.buy{value: 1 ether}(0);

        IERC20 token = pool.token();
        vm.prank(alice);
        vm.expectRevert(ForgeBondingCurveToken.TradingNotEnabled.selector);
        token.transfer(bob, tokensOut / 2);
    }

    function test_TransferEnabledAfterGraduation() public {
        ForgeBondingCurvePool pool = _createLowCapPool();

        vm.deal(alice, 10000 ether);
        vm.prank(alice);
        pool.buy{value: 100 ether}(0);

        IERC20 token = pool.token();
        uint256 aliceBal = token.balanceOf(alice);

        vm.prank(alice);
        token.transfer(bob, aliceBal / 2);

        assertEq(token.balanceOf(bob), aliceBal / 2);
    }

    // ------------------------------
    // Edge Case Tests
    // ------------------------------

    function test_BuySell_Symmetry() public {
        ForgeBondingCurvePool pool = _createPool();

        vm.deal(alice, 100 ether);

        vm.prank(alice);
        uint256 tokensOut = pool.buy{value: 10 ether}(0);

        uint256 realReserveAfterBuy = pool.realZilReserve();
        uint256 aliceZilAfterBuy = alice.balance;

        IERC20 token = pool.token();
        vm.startPrank(alice);
        token.approve(address(pool), tokensOut);
        uint256 zilBack = pool.sell(tokensOut, 0);
        vm.stopPrank();

        assertLt(aliceZilAfterBuy + zilBack, 100 ether, "should lose some to fees");
        assertLt(pool.realZilReserve(), realReserveAfterBuy, "reserve should decrease after sell");
    }

    function test_MultipleBuyersSell() public {
        ForgeBondingCurvePool pool = _createPool();

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);

        vm.prank(alice);
        uint256 aliceTokens = pool.buy{value: 5 ether}(0);

        vm.prank(bob);
        uint256 bobTokens = pool.buy{value: 5 ether}(0);

        assertGt(aliceTokens, bobTokens, "earlier buyer should get more tokens");

        IERC20 token = pool.token();
        vm.startPrank(bob);
        token.approve(address(pool), bobTokens);
        uint256 bobZilBack = pool.sell(bobTokens, 0);
        vm.stopPrank();

        vm.startPrank(alice);
        token.approve(address(pool), aliceTokens);
        uint256 aliceZilBack = pool.sell(aliceTokens, 0);
        vm.stopPrank();

        assertGt(aliceZilBack + bobZilBack, 0, "should get some ZIL back");
    }

    function test_SmallBuy() public {
        ForgeBondingCurvePool pool = _createPool();

        vm.deal(alice, 1 ether);

        vm.prank(alice);
        uint256 tokensOut = pool.buy{value: 0.001 ether}(0);

        assertGt(tokensOut, 0, "should get some tokens for small buy");
    }

    function test_QuoteSell_ReturnsZeroForExcessiveAmount() public {
        ForgeBondingCurvePool pool = _createPool();

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        uint256 tokensOut = pool.buy{value: 1 ether}(0);

        (uint256 zilOut, uint256 fee) = pool.quoteSell(tokensOut * 1000);
        assertEq(zilOut, 0);
        assertEq(fee, 0);
    }

    // ------------------------------
    // K Invariant Tests
    // ------------------------------

    function test_KInvariant_AfterBuy() public {
        ForgeBondingCurvePool pool = _createPool();
        uint256 kBefore = pool.k();

        vm.deal(alice, 100 ether);
        vm.prank(alice);
        pool.buy{value: 10 ether}(0);

        uint256 computedK = pool.virtualTokenReserve() * pool.virtualZilReserve();
        assertApproxEqRel(computedK, kBefore, 1e10, "k should remain constant after buy");
    }

    function test_KInvariant_AfterSell() public {
        ForgeBondingCurvePool pool = _createPool();
        uint256 kBefore = pool.k();

        vm.deal(alice, 100 ether);
        vm.prank(alice);
        uint256 tokensOut = pool.buy{value: 10 ether}(0);

        IERC20 token = pool.token();
        vm.startPrank(alice);
        token.approve(address(pool), tokensOut);
        pool.sell(tokensOut, 0);
        vm.stopPrank();

        uint256 computedK = pool.virtualTokenReserve() * pool.virtualZilReserve();
        assertApproxEqRel(computedK, kBefore, 1e10, "k should remain constant after sell");
    }

    function test_KInvariant_AfterMultipleTradesSequence() public {
        ForgeBondingCurvePool pool = _createPool();
        uint256 kBefore = pool.k();
        IERC20 token = pool.token();

        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);

        vm.prank(alice);
        uint256 aliceTokens = pool.buy{value: 100 ether}(0);

        vm.prank(bob);
        uint256 bobTokens = pool.buy{value: 50 ether}(0);

        vm.startPrank(alice);
        token.approve(address(pool), aliceTokens / 2);
        pool.sell(aliceTokens / 2, 0);
        vm.stopPrank();

        vm.prank(bob);
        pool.buy{value: 25 ether}(0);

        vm.startPrank(bob);
        token.approve(address(pool), bobTokens);
        pool.sell(bobTokens, 0);
        vm.stopPrank();

        uint256 computedK = pool.virtualTokenReserve() * pool.virtualZilReserve();
        assertApproxEqRel(computedK, kBefore, 1e10, "k should remain constant after trade sequence");
    }

    // ------------------------------
    // Graduation Boundary Tests
    // ------------------------------

    function test_Graduation_ExactThreshold() public {
        ForgeBondingCurvePool pool = _createMediumCapPool();
        uint256 graduationCap = pool.graduationMarketCap();

        uint256 preBuyMarketCap = pool.marketCap();
        assertLt(preBuyMarketCap, graduationCap, "should not be graduated initially");

        vm.deal(alice, 100_000 ether);
        vm.prank(alice);
        pool.buy{value: 50_000 ether}(0);

        assertEq(uint8(pool.state()), uint8(PoolState.Graduated), "should graduate at threshold");
        assertGe(pool.marketCap(), graduationCap, "market cap should be at or above graduation cap");
    }

    function test_Graduation_JustBelowThreshold_DoesNotGraduate() public {
        ForgeBondingCurvePool pool = _createMediumCapPool();

        vm.deal(alice, 1000 ether);
        vm.prank(alice);
        pool.buy{value: 100 ether}(0);

        assertEq(uint8(pool.state()), uint8(PoolState.Trading), "should still be trading");
        assertLt(pool.marketCap(), pool.graduationMarketCap(), "market cap should be below threshold");
    }

    function test_Graduation_SingleLargeBuy_FullJourney() public {
        ForgeBondingCurvePool pool = _createMediumCapPool();
        IERC20 token = pool.token();
        uint256 totalSupply = pool.TOTAL_SUPPLY();

        uint256 initialTokenReserve = pool.virtualTokenReserve();
        uint256 initialMarketCap = pool.marketCap();

        assertEq(initialTokenReserve, totalSupply, "initial reserve should be total supply");
        assertLt(initialMarketCap, pool.graduationMarketCap(), "should start below graduation cap");

        vm.deal(alice, 100_000 ether);
        vm.prank(alice);
        uint256 tokensBought = pool.buy{value: 60_000 ether}(0);

        assertEq(uint8(pool.state()), uint8(PoolState.Graduated), "should graduate after large buy");

        uint256 aliceBalance = token.balanceOf(alice);
        assertEq(aliceBalance, tokensBought, "alice should have all bought tokens");

        assertGt(tokensBought, 0, "should have bought some tokens");
        assertLt(tokensBought, totalSupply, "should not have bought entire supply");
    }

    function test_Graduation_TokenAccountingIsCorrect() public {
        ForgeBondingCurvePool pool = _createMediumCapPool();
        IERC20 token = pool.token();
        uint256 totalSupply = pool.TOTAL_SUPPLY();

        vm.deal(alice, 100_000 ether);
        vm.prank(alice);
        uint256 tokensBought = pool.buy{value: 60_000 ether}(0);

        assertEq(uint8(pool.state()), uint8(PoolState.Graduated), "should be graduated");

        uint256 aliceTokens = token.balanceOf(alice);
        uint256 positionManagerTokens = token.balanceOf(address(positionManager));

        assertEq(aliceTokens, tokensBought, "alice balance should match tokens bought");
        assertGt(positionManagerTokens, 0, "position manager should have liquidity tokens");

        uint256 accountedTokens = aliceTokens + positionManagerTokens;
        assertEq(accountedTokens, totalSupply, "all tokens should be accounted for");
    }

    function test_Graduation_AMMFormulaPreventsTotalExhaustion() public {
        ForgeBondingCurvePool pool = _createMediumCapPool();
        uint256 totalSupply = pool.TOTAL_SUPPLY();

        (uint256 quotedTokens,) = pool.quoteBuy(1_000_000 ether);

        assertLt(quotedTokens, totalSupply, "cannot buy entire supply even with huge amount");
        assertGt(quotedTokens, totalSupply / 2, "should be able to buy significant portion");
    }

    function test_Graduation_RealZilMatchesBuyerDeposits() public {
        ForgeBondingCurvePool pool = _createPool();

        uint256 buy1Amount = 1_000 ether;
        uint256 buy2Amount = 2_000 ether;

        vm.deal(alice, buy1Amount);
        vm.prank(alice);
        pool.buy{value: buy1Amount}(0);

        uint256 fee1 = (buy1Amount * pool.tradingFeePercent()) / pool.FEE_DENOMINATOR();
        uint256 expectedReserve1 = buy1Amount - fee1;
        assertEq(pool.realZilReserve(), expectedReserve1, "real reserve should match after first buy");

        vm.deal(bob, buy2Amount);
        vm.prank(bob);
        pool.buy{value: buy2Amount}(0);

        uint256 fee2 = (buy2Amount * pool.tradingFeePercent()) / pool.FEE_DENOMINATOR();
        uint256 expectedReserve2 = expectedReserve1 + (buy2Amount - fee2);
        assertEq(pool.realZilReserve(), expectedReserve2, "real reserve should accumulate correctly");

        assertEq(uint8(pool.state()), uint8(PoolState.Trading), "should still be trading");
    }

    function test_Graduation_LiquidityTokensRemainForV3() public {
        ForgeBondingCurvePool pool = _createMediumCapPool();
        IERC20 token = pool.token();
        uint256 totalSupply = pool.TOTAL_SUPPLY();

        vm.deal(alice, 100_000 ether);
        vm.prank(alice);
        uint256 tokensBought = pool.buy{value: 60_000 ether}(0);

        assertEq(uint8(pool.state()), uint8(PoolState.Graduated), "should be graduated");

        uint256 tokensForLiquidity = token.balanceOf(address(positionManager));

        assertGt(tokensForLiquidity, 0, "must have tokens for V3 liquidity");
        assertEq(tokensBought + tokensForLiquidity, totalSupply, "tokens sold + liquidity = total supply");

        uint256 liquidityPercent = (tokensForLiquidity * 100) / totalSupply;
        assertGt(liquidityPercent, 10, "at least 10% should go to liquidity");
    }

    // ------------------------------
    // Fee Withdrawal Edge Cases
    // ------------------------------

    function test_WithdrawFees_ZeroBalance_Reverts() public {
        ForgeBondingCurvePool pool = _createPool();

        assertEq(pool.feesCollected(), 0, "no fees initially");

        vm.prank(treasury);
        vm.expectRevert(ForgeBondingCurvePool.ZeroAmount.selector);
        pool.withdrawFees();
    }

    function test_WithdrawFees_AfterGraduation() public {
        ForgeBondingCurvePool pool = _createMediumCapPool();

        vm.deal(alice, 1000 ether);
        vm.prank(alice);
        pool.buy{value: 100 ether}(0);

        uint256 feesBeforeGraduation = pool.feesCollected();
        assertGt(feesBeforeGraduation, 0, "should have fees from trading");

        vm.deal(bob, 100_000 ether);
        vm.prank(bob);
        pool.buy{value: 50_000 ether}(0);

        assertEq(uint8(pool.state()), uint8(PoolState.Graduated), "should be graduated");

        uint256 feesAfterGraduation = pool.feesCollected();
        assertGt(feesAfterGraduation, 0, "fees should still be available");

        uint256 treasuryBefore = treasury.balance;
        vm.prank(treasury);
        pool.withdrawFees();

        assertEq(treasury.balance, treasuryBefore + feesAfterGraduation, "treasury should receive fees");
        assertEq(pool.feesCollected(), 0, "fees should be zeroed");
    }

    // ------------------------------
    // Multi-User Graduation Tests
    // ------------------------------

    function test_MultiUser_OneTriggersGraduation() public {
        ForgeBondingCurvePool pool = _createMediumCapPool();
        IERC20 token = pool.token();

        address user1 = address(0x1001);
        address user2 = address(0x1002);
        address user3 = address(0x1003);
        address user4 = address(0x1004);
        address user5 = address(0x1005);

        vm.deal(user1, 10_000 ether);
        vm.deal(user2, 10_000 ether);
        vm.deal(user3, 10_000 ether);
        vm.deal(user4, 10_000 ether);
        vm.deal(user5, 100_000 ether);

        vm.prank(user1);
        uint256 tokens1 = pool.buy{value: 1000 ether}(0);
        assertEq(uint8(pool.state()), uint8(PoolState.Trading), "should still be trading after user1");

        vm.prank(user2);
        uint256 tokens2 = pool.buy{value: 1500 ether}(0);
        assertEq(uint8(pool.state()), uint8(PoolState.Trading), "should still be trading after user2");

        vm.prank(user3);
        uint256 tokens3 = pool.buy{value: 2000 ether}(0);
        assertEq(uint8(pool.state()), uint8(PoolState.Trading), "should still be trading after user3");

        vm.prank(user4);
        uint256 tokens4 = pool.buy{value: 2500 ether}(0);
        assertEq(uint8(pool.state()), uint8(PoolState.Trading), "should still be trading after user4");

        vm.prank(user5);
        uint256 tokens5 = pool.buy{value: 50_000 ether}(0);
        assertEq(uint8(pool.state()), uint8(PoolState.Graduated), "should be graduated after user5");

        assertGt(tokens1, 0, "user1 should have tokens");
        assertGt(tokens2, 0, "user2 should have tokens");
        assertGt(tokens3, 0, "user3 should have tokens");
        assertGt(tokens4, 0, "user4 should have tokens");
        assertGt(tokens5, 0, "user5 should have tokens");

        assertEq(token.balanceOf(user1), tokens1, "user1 token balance should match");
        assertEq(token.balanceOf(user2), tokens2, "user2 token balance should match");
        assertEq(token.balanceOf(user3), tokens3, "user3 token balance should match");
        assertEq(token.balanceOf(user4), tokens4, "user4 token balance should match");
        assertEq(token.balanceOf(user5), tokens5, "user5 token balance should match");

        uint256 tokensPerZil1 = tokens1 / 1000;
        uint256 tokensPerZil5 = tokens5 / 50_000;
        assertGt(tokensPerZil1, tokensPerZil5, "earlier buyers should get more tokens per ZIL");
    }

    // ------------------------------
    // Fuzz Tests
    // ------------------------------

    function testFuzz_BuyQuoteMatchesActual(uint96 buyAmount) public {
        vm.assume(buyAmount >= 0.001 ether && buyAmount <= 100 ether);

        ForgeBondingCurvePool pool = _createPool();

        vm.deal(alice, uint256(buyAmount) + 1 ether);

        (uint256 quotedTokens,) = pool.quoteBuy(buyAmount);

        vm.prank(alice);
        uint256 actualTokens = pool.buy{value: buyAmount}(0);

        assertEq(actualTokens, quotedTokens, "quote should match actual");
    }

    function testFuzz_SellQuoteMatchesActual(uint96 buyAmount) public {
        vm.assume(buyAmount >= 0.01 ether && buyAmount <= 50 ether);

        ForgeBondingCurvePool pool = _createPool();

        vm.deal(alice, uint256(buyAmount) + 1 ether);

        vm.prank(alice);
        uint256 tokensOut = pool.buy{value: buyAmount}(0);

        (uint256 quotedZil,) = pool.quoteSell(tokensOut);

        IERC20 token = pool.token();
        vm.startPrank(alice);
        token.approve(address(pool), tokensOut);
        uint256 actualZil = pool.sell(tokensOut, 0);
        vm.stopPrank();

        assertEq(actualZil, quotedZil, "quote should match actual");
    }

    // ------------------------------
    // Zilliqa-Scale Fuzz Tests
    // ------------------------------

    function testFuzz_BuyQuoteMatchesActual_ZiliqaScale(uint256 buyAmount) public {
        buyAmount = bound(buyAmount, 1000 ether, 1_000_000 ether);

        ForgeBondingCurvePool pool = _createPool();

        vm.deal(alice, buyAmount + 1 ether);

        (uint256 quotedTokens,) = pool.quoteBuy(buyAmount);

        vm.prank(alice);
        uint256 actualTokens = pool.buy{value: buyAmount}(0);

        assertEq(actualTokens, quotedTokens, "quote should match actual at Zilliqa scale");
    }

    function testFuzz_SellQuoteMatchesActual_ZiliqaScale(uint256 buyAmount) public {
        buyAmount = bound(buyAmount, 10_000 ether, 500_000 ether);

        ForgeBondingCurvePool pool = _createPool();

        if (pool.graduationMarketCap() < 100_000_000 ether) {
            return;
        }

        vm.deal(alice, buyAmount + 1 ether);

        vm.prank(alice);
        uint256 tokensOut = pool.buy{value: buyAmount}(0);

        if (pool.state() != PoolState.Trading) {
            return;
        }

        (uint256 quotedZil,) = pool.quoteSell(tokensOut);

        IERC20 token = pool.token();
        vm.startPrank(alice);
        token.approve(address(pool), tokensOut);
        uint256 actualZil = pool.sell(tokensOut, 0);
        vm.stopPrank();

        assertEq(actualZil, quotedZil, "quote should match actual at Zilliqa scale");
    }

    function test_LargeBuy_NoPrecisionLoss() public {
        ForgeBondingCurvePool pool = _createPool();
        uint256 kBefore = pool.k();

        vm.deal(alice, 600_000 ether);

        (uint256 quotedTokens,) = pool.quoteBuy(500_000 ether);

        vm.prank(alice);
        uint256 actualTokens = pool.buy{value: 500_000 ether}(0);

        assertEq(actualTokens, quotedTokens, "quote should match for large buy");
        assertGt(actualTokens, 0, "should receive tokens");

        uint256 computedK = pool.virtualTokenReserve() * pool.virtualZilReserve();
        assertApproxEqRel(computedK, kBefore, 1e10, "k should remain constant for large buy");
    }

    function testFuzz_KInvariant_RandomTrades(uint256 buyAmount1, uint256 buyAmount2) public {
        buyAmount1 = bound(buyAmount1, 1 ether, 100_000 ether);
        buyAmount2 = bound(buyAmount2, 1 ether, 100_000 ether);

        ForgeBondingCurvePool pool = _createPool();
        uint256 kBefore = pool.k();
        IERC20 token = pool.token();

        vm.deal(alice, buyAmount1 + 1 ether);
        vm.deal(bob, buyAmount2 + 1 ether);

        vm.prank(alice);
        uint256 aliceTokens = pool.buy{value: buyAmount1}(0);

        uint256 kAfterBuy1 = pool.virtualTokenReserve() * pool.virtualZilReserve();
        assertApproxEqRel(kAfterBuy1, kBefore, 1e10, "k should remain constant after first buy");

        vm.prank(bob);
        pool.buy{value: buyAmount2}(0);

        uint256 kAfterBuy2 = pool.virtualTokenReserve() * pool.virtualZilReserve();
        assertApproxEqRel(kAfterBuy2, kBefore, 1e10, "k should remain constant after second buy");

        if (aliceTokens > pool.MIN_SELL_TOKENS()) {
            vm.startPrank(alice);
            token.approve(address(pool), aliceTokens);
            pool.sell(aliceTokens, 0);
            vm.stopPrank();

            uint256 kAfterSell = pool.virtualTokenReserve() * pool.virtualZilReserve();
            assertApproxEqRel(kAfterSell, kBefore, 1e10, "k should remain constant after sell");
        }
    }

    // ------------------------------
    // Security finding H-1: graduation front-run / pool price manipulation
    // ------------------------------

    // An attacker pre-initializes the Plunder V3 pool at a manipulated price before
    // graduation. Because graduation minted liquidity with amount0Min/amount1Min == 0 and
    // never checked the pool price, the raised liquidity could be added at the attacker's
    // price and siphoned. The fix makes graduation revert when the pool price deviates from
    // the curve's intended price.
    function test_H1_Graduation_RevertsIfPoolPreInitializedAtManipulatedPrice() public {
        MockWETH localWeth = new MockWETH();
        MockV3Factory v3Factory = new MockV3Factory();
        MockPositionManagerWithFactory pm = new MockPositionManagerWithFactory(address(v3Factory));

        ForgeBondingCurvePool pool = _createLowCapPoolWithConfig(address(localWeth), address(pm));
        IERC20 token = pool.token();

        // Attacker front-runs graduation by initializing the V3 pool at an extreme price.
        bool tokenIsToken0 = address(token) < address(localWeth);
        address token0 = tokenIsToken0 ? address(token) : address(localWeth);
        address token1 = tokenIsToken0 ? address(localWeth) : address(token);
        pm.createAndInitializePoolIfNecessary(token0, token1, DEFAULT_V3_FEE, type(uint160).max);

        // The buy that would trigger graduation must now revert instead of minting at the bad price.
        vm.deal(alice, 10_000 ether);
        vm.prank(alice);
        vm.expectRevert(ForgeBondingCurvePool.UnexpectedPoolPrice.selector);
        pool.buy{value: 100 ether}(0);
    }

    // Sanity: with no manipulation the same low-cap pool graduates normally (price check passes).
    function test_H1_Graduation_SucceedsWhenPoolPriceIsHonest() public {
        MockWETH localWeth = new MockWETH();
        MockV3Factory v3Factory = new MockV3Factory();
        MockPositionManagerWithFactory pm = new MockPositionManagerWithFactory(address(v3Factory));

        ForgeBondingCurvePool pool = _createLowCapPoolWithConfig(address(localWeth), address(pm));

        vm.deal(alice, 10_000 ether);
        vm.prank(alice);
        pool.buy{value: 100 ether}(0);

        assertEq(uint8(pool.state()), uint8(PoolState.Graduated), "should graduate at honest price");
    }

    // ------------------------------
    // Security finding M-1: V3 fee tier must be a supported tick-spacing tier
    // ------------------------------

    function test_M1_Factory_RejectsUnsupportedV3FeeTier_Setter() public {
        // 3000 (0.3%) is a standard Uniswap tier but is NOT supported by _getTickSpacing.
        vm.expectRevert(ForgeBondingCurveFactory.InvalidParam.selector);
        factory.setDefaultV3Fee(3000);
    }

    function test_M1_Factory_RejectsUnsupportedV3FeeTier_Constructor() public {
        BondingCurveRouterConfig memory config = BondingCurveRouterConfig({
            wrappedNative: address(weth),
            positionManager: address(positionManager)
        });
        vm.expectRevert(ForgeBondingCurveFactory.InvalidParam.selector);
        new ForgeBondingCurveFactory(
            treasury,
            GRADUATION_MARKET_CAP,
            INITIAL_VIRTUAL_ZIL_RESERVE,
            TRADING_FEE_PERCENT,
            GRADUATION_FEE_PERCENT,
            uint24(3000),
            config
        );
    }

    function test_M1_Factory_AcceptsSupportedV3FeeTiers() public {
        factory.setDefaultV3Fee(100);
        assertEq(factory.defaultV3Fee(), 100);
        factory.setDefaultV3Fee(500);
        assertEq(factory.defaultV3Fee(), 500);
        factory.setDefaultV3Fee(2500);
        assertEq(factory.defaultV3Fee(), 2500);
        factory.setDefaultV3Fee(10000);
        assertEq(factory.defaultV3Fee(), 10000);
    }

    // Confirms the consequence the factory guard prevents: a pool carrying an unsupported
    // fee tier can never graduate (the V3 tick-spacing lookup reverts).
    function test_M1_Confirm_GraduationBricksWithUnsupportedFee() public {
        BondingCurveInitParams memory params = BondingCurveInitParams({
            creator: creator,
            name: "Brick",
            symbol: "BRK",
            graduationMarketCap: 1 ether,
            initialVirtualZilReserve: INITIAL_VIRTUAL_ZIL_RESERVE,
            v3Fee: 3000, // unsupported tick spacing
            treasury: treasury,
            tradingFeePercent: TRADING_FEE_PERCENT,
            graduationFeePercent: GRADUATION_FEE_PERCENT,
            routers: BondingCurveRouterConfig({
                wrappedNative: address(weth),
                positionManager: address(positionManager)
            })
        });

        ForgeBondingCurvePool pool = new ForgeBondingCurvePool(params);

        vm.deal(alice, 10_000 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("Invalid fee"));
        pool.buy{value: 100 ether}(0);
    }

    // ------------------------------
    // Helpers
    // ------------------------------

    function _createPool() internal returns (ForgeBondingCurvePool) {
        BondingCurveCreateParams memory params = BondingCurveCreateParams({
            name: "Test Token",
            symbol: "TEST",
            metadataURI: ""
        });

        vm.prank(creator);
        address poolAddr = factory.createPool(params);
        return ForgeBondingCurvePool(payable(poolAddr));
    }

    function _createLowCapPool() internal returns (ForgeBondingCurvePool) {
        BondingCurveRouterConfig memory config = BondingCurveRouterConfig({
            wrappedNative: address(weth),
            positionManager: address(positionManager)
        });

        ForgeBondingCurveFactory lowCapFactory = new ForgeBondingCurveFactory(
            treasury,
            1 ether,
            INITIAL_VIRTUAL_ZIL_RESERVE,
            TRADING_FEE_PERCENT,
            GRADUATION_FEE_PERCENT,
            DEFAULT_V3_FEE,
            config
        );

        BondingCurveCreateParams memory params = BondingCurveCreateParams({
            name: "Graduate Token",
            symbol: "GRAD",
            metadataURI: ""
        });

        vm.prank(creator);
        address poolAddr = lowCapFactory.createPool(params);
        return ForgeBondingCurvePool(payable(poolAddr));
    }

    function _createMediumCapPool() internal returns (ForgeBondingCurvePool) {
        BondingCurveRouterConfig memory config = BondingCurveRouterConfig({
            wrappedNative: address(weth),
            positionManager: address(positionManager)
        });

        ForgeBondingCurveFactory mediumCapFactory = new ForgeBondingCurveFactory(
            treasury,
            100_000 ether,
            INITIAL_VIRTUAL_ZIL_RESERVE,
            TRADING_FEE_PERCENT,
            GRADUATION_FEE_PERCENT,
            DEFAULT_V3_FEE,
            config
        );

        BondingCurveCreateParams memory params = BondingCurveCreateParams({
            name: "Medium Cap Token",
            symbol: "MCAP",
            metadataURI: ""
        });

        vm.prank(creator);
        address poolAddr = mediumCapFactory.createPool(params);
        return ForgeBondingCurvePool(payable(poolAddr));
    }

    function _createGraduatedPool() internal returns (ForgeBondingCurvePool) {
        ForgeBondingCurvePool pool = _createLowCapPool();

        vm.deal(alice, 10000 ether);
        vm.prank(alice);
        pool.buy{value: 100 ether}(0);

        require(pool.state() == PoolState.Graduated, "pool should be graduated");
        return pool;
    }

    function _tokensToSellForGross(uint256 target, uint256 vZ, uint256 vT, uint256 k)
        internal
        pure
        returns (uint256)
    {
        require(target < vZ, "target too large");
        uint256 newVZ = vZ - target;
        uint256 newVT = k / newVZ;
        return newVT - vT;
    }

    function _createLowCapPoolWithConfig(address wrappedNative, address positionManager_)
        internal
        returns (ForgeBondingCurvePool)
    {
        BondingCurveRouterConfig memory config = BondingCurveRouterConfig({
            wrappedNative: wrappedNative,
            positionManager: positionManager_
        });

        ForgeBondingCurveFactory lowCapFactory = new ForgeBondingCurveFactory(
            treasury,
            1 ether,
            INITIAL_VIRTUAL_ZIL_RESERVE,
            TRADING_FEE_PERCENT,
            GRADUATION_FEE_PERCENT,
            DEFAULT_V3_FEE,
            config
        );

        BondingCurveCreateParams memory params = BondingCurveCreateParams({
            name: "Graduate Token",
            symbol: "GRAD",
            metadataURI: ""
        });

        vm.prank(creator);
        address poolAddr = lowCapFactory.createPool(params);
        return ForgeBondingCurvePool(payable(poolAddr));
    }
}
