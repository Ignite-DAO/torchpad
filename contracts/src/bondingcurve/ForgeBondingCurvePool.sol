// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";

import {PoolState, BondingCurveInitParams} from "./BondingCurveTypes.sol";
import {IWETH9, INonfungiblePositionManager, IUniswapV3PoolMinimal} from "../fairlaunch/PlunderInterfaces.sol";
import {ForgeBondingCurveToken} from "./ForgeBondingCurveToken.sol";

contract ForgeBondingCurvePool is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address payable;

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 public constant FEE_DENOMINATOR = 10_000;
    uint256 public constant MIN_BUY_AMOUNT = 0.001 ether;
    uint256 public constant MIN_SELL_TOKENS = 1e15;
    uint256 public constant MIN_GRADUATION_LIQUIDITY = 0.1 ether;
    // Max deviation (in bps) allowed between the live V3 pool price and the curve's intended
    // graduation price. Guards against a pool that was front-run/initialized at a bad price.
    uint256 public constant GRADUATION_PRICE_TOLERANCE_BPS = 1000; // 10%
    // Min-amount slippage (in bps) applied to graduation liquidity provision.
    uint256 public constant GRADUATION_SLIPPAGE_BPS = 500; // 5%
    int24 private constant MAX_TICK = 887272;
    int24 private constant MIN_TICK = -887272;

    error NotTrading();
    error SlippageExceeded();
    error InsufficientPayment();
    error InsufficientTokens();
    error InsufficientReserve();
    error InsufficientLiquidity();
    error ZeroAmount();
    error BelowMinimum();
    error TransferFailed();
    error LiquidityCreationFailed();
    error OnlyTreasury();
    error UnexpectedPoolPrice();

    event Buy(
        address indexed buyer,
        uint256 zilIn,
        uint256 tokensOut,
        uint256 fee,
        uint256 newVirtualTokenReserve,
        uint256 newPrice
    );
    event Sell(
        address indexed seller,
        uint256 tokensIn,
        uint256 zilOut,
        uint256 fee,
        uint256 newVirtualTokenReserve,
        uint256 newPrice
    );
    event Graduated(
        uint256 totalZilRaised,
        uint256 liquidityZil,
        uint256 liquidityTokens,
        uint256 lpTokenId,
        uint256 graduationFee
    );
    event FeesWithdrawn(address indexed to, uint256 amount);

    address public immutable factory;
    address public immutable creator;
    IERC20 public immutable token;
    uint256 public immutable graduationMarketCap;
    uint256 public immutable initialVirtualZilReserve;
    uint256 public immutable k;
    uint24 public immutable v3Fee;
    address public immutable treasury;
    uint256 public immutable tradingFeePercent;
    uint256 public immutable graduationFeePercent;
    address public immutable wrappedNative;
    address public immutable positionManager;

    PoolState public state;
    uint256 public virtualTokenReserve;
    uint256 public virtualZilReserve;
    uint256 public realZilReserve;
    uint256 public feesCollected;
    uint256 public lpTokenIdV3;

    constructor(BondingCurveInitParams memory params) {
        factory = msg.sender;
        creator = params.creator;
        graduationMarketCap = params.graduationMarketCap;
        initialVirtualZilReserve = params.initialVirtualZilReserve;
        v3Fee = params.v3Fee;
        treasury = params.treasury;
        tradingFeePercent = params.tradingFeePercent;
        graduationFeePercent = params.graduationFeePercent;
        wrappedNative = params.routers.wrappedNative;
        positionManager = params.routers.positionManager;

        virtualTokenReserve = TOTAL_SUPPLY;
        virtualZilReserve = params.initialVirtualZilReserve;
        k = TOTAL_SUPPLY * params.initialVirtualZilReserve;

        token = IERC20(
            address(
                new ForgeBondingCurveToken(params.name, params.symbol, 18, TOTAL_SUPPLY, address(this))
            )
        );

        state = PoolState.Trading;
    }

    function buy(uint256 minTokensOut) external payable nonReentrant returns (uint256 tokensOut) {
        if (state != PoolState.Trading) revert NotTrading();
        if (msg.value == 0) revert ZeroAmount();
        if (msg.value < MIN_BUY_AMOUNT) revert BelowMinimum();

        uint256 fee = (msg.value * tradingFeePercent) / FEE_DENOMINATOR;
        uint256 zilAfterFee = msg.value - fee;

        tokensOut = _calculateBuy(zilAfterFee);
        if (tokensOut == 0) revert ZeroAmount();
        if (tokensOut < minTokensOut) revert SlippageExceeded();

        virtualZilReserve += zilAfterFee;
        virtualTokenReserve -= tokensOut;
        realZilReserve += zilAfterFee;
        feesCollected += fee;

        token.safeTransfer(msg.sender, tokensOut);

        emit Buy(msg.sender, msg.value, tokensOut, fee, virtualTokenReserve, currentPrice());

        _checkGraduation();
    }

    function sell(uint256 tokensIn, uint256 minZilOut) external nonReentrant returns (uint256 zilOut) {
        if (state != PoolState.Trading) revert NotTrading();
        if (tokensIn == 0) revert ZeroAmount();
        if (tokensIn < MIN_SELL_TOKENS) revert BelowMinimum();

        uint256 grossProceeds = _calculateSell(tokensIn);
        uint256 fee = (grossProceeds * tradingFeePercent) / FEE_DENOMINATOR;
        zilOut = grossProceeds - fee;

        if (zilOut < minZilOut) revert SlippageExceeded();
        uint256 available = realZilReserve + feesCollected;
        if (grossProceeds > available) revert InsufficientReserve();

        virtualTokenReserve += tokensIn;
        virtualZilReserve -= grossProceeds;
        if (grossProceeds > realZilReserve) {
            uint256 feesUsed = grossProceeds - realZilReserve;
            realZilReserve = 0;
            feesCollected -= feesUsed;
        } else {
            realZilReserve -= grossProceeds;
        }
        feesCollected += fee;

        token.safeTransferFrom(msg.sender, address(this), tokensIn);
        payable(msg.sender).sendValue(zilOut);

        emit Sell(msg.sender, tokensIn, zilOut, fee, virtualTokenReserve, currentPrice());
    }

    function withdrawFees() external nonReentrant {
        if (msg.sender != treasury) revert OnlyTreasury();
        uint256 amount = feesCollected;
        if (amount == 0) revert ZeroAmount();
        feesCollected = 0;
        payable(treasury).sendValue(amount);
        emit FeesWithdrawn(treasury, amount);
    }

    // ------------------------
    // View Functions
    // ------------------------

    function currentPrice() public view returns (uint256) {
        if (virtualTokenReserve == 0) return 0;
        return (virtualZilReserve * 1e18) / virtualTokenReserve;
    }

    function marketCap() public view returns (uint256) {
        return (currentPrice() * TOTAL_SUPPLY) / 1e18;
    }

    function progressBps() external view returns (uint256) {
        if (graduationMarketCap == 0) return 0;
        uint256 mcap = marketCap();
        if (mcap >= graduationMarketCap) return 10_000;
        return (mcap * 10_000) / graduationMarketCap;
    }

    function tokensSold() external view returns (uint256) {
        return TOTAL_SUPPLY - virtualTokenReserve;
    }

    function quoteBuy(uint256 zilAmount) external view returns (uint256 tokensOut, uint256 fee) {
        fee = (zilAmount * tradingFeePercent) / FEE_DENOMINATOR;
        uint256 zilAfterFee = zilAmount - fee;
        tokensOut = _calculateBuy(zilAfterFee);
    }

    function quoteSell(uint256 tokensIn) external view returns (uint256 zilOut, uint256 fee) {
        uint256 grossProceeds = _calculateSell(tokensIn);
        uint256 available = realZilReserve + feesCollected;
        if (grossProceeds > available) {
            return (0, 0);
        }
        fee = (grossProceeds * tradingFeePercent) / FEE_DENOMINATOR;
        zilOut = grossProceeds - fee;
    }

    // ------------------------
    // Internal Functions
    // ------------------------

    function _calculateBuy(uint256 zilIn) internal view returns (uint256 tokensOut) {
        uint256 newVirtualZilReserve = virtualZilReserve + zilIn;
        uint256 newVirtualTokenReserve = k / newVirtualZilReserve;
        tokensOut = virtualTokenReserve - newVirtualTokenReserve;
    }

    function _calculateSell(uint256 tokensIn) internal view returns (uint256 zilOut) {
        uint256 newVirtualTokenReserve = virtualTokenReserve + tokensIn;
        uint256 newVirtualZilReserve = k / newVirtualTokenReserve;
        zilOut = virtualZilReserve - newVirtualZilReserve;
    }

    function _checkGraduation() internal {
        if (state != PoolState.Trading) return;
        if (marketCap() >= graduationMarketCap) {
            _graduate();
        }
    }

    function _graduate() internal {
        state = PoolState.Graduated;

        uint256 totalZil = realZilReserve;
        uint256 graduationFee = (totalZil * graduationFeePercent) / FEE_DENOMINATOR;
        uint256 liquidityZil = totalZil - graduationFee;

        if (liquidityZil < MIN_GRADUATION_LIQUIDITY) revert InsufficientLiquidity();

        uint256 liquidityTokens = token.balanceOf(address(this));

        IWETH9(wrappedNative).deposit{value: liquidityZil}();

        IERC20(wrappedNative).forceApprove(positionManager, liquidityZil);
        token.forceApprove(positionManager, liquidityTokens);

        (uint256 tokenId, uint256 usedToken, uint256 usedWeth) =
            _mintV3Liquidity(liquidityTokens, liquidityZil);
        lpTokenIdV3 = tokenId;

        IERC20(wrappedNative).forceApprove(positionManager, 0);
        token.forceApprove(positionManager, 0);
        _sweepLeftovers(liquidityTokens, liquidityZil, usedToken, usedWeth);

        INonfungiblePositionManager(positionManager).transferFrom(
            address(this),
            address(0x000000000000000000000000000000000000dEaD),
            tokenId
        );

        realZilReserve = 0;

        if (graduationFee > 0) {
            payable(treasury).sendValue(graduationFee);
        }

        ForgeBondingCurveToken(address(token)).enableTrading();

        emit Graduated(totalZil, liquidityZil, liquidityTokens, tokenId, graduationFee);
    }

    function _mintV3Liquidity(uint256 liquidityTokens, uint256 liquidityZil)
        internal
        returns (uint256 tokenId, uint256 usedToken, uint256 usedWeth)
    {
        bool tokenIsToken0 = address(token) < wrappedNative;
        address token0 = tokenIsToken0 ? address(token) : wrappedNative;
        address token1 = tokenIsToken0 ? wrappedNative : address(token);
        uint256 amount0Desired = tokenIsToken0 ? liquidityTokens : liquidityZil;
        uint256 amount1Desired = tokenIsToken0 ? liquidityZil : liquidityTokens;

        _createAndValidateV3Pool(token0, token1, amount0Desired, amount1Desired);

        uint256 amount0;
        uint256 amount1;
        (tokenId, amount0, amount1) = _mintFullRange(token0, token1, amount0Desired, amount1Desired);

        usedToken = tokenIsToken0 ? amount0 : amount1;
        usedWeth = tokenIsToken0 ? amount1 : amount0;
    }

    /// @dev Creates/initializes the V3 pool and reverts if its live price deviates from the
    /// curve's intended graduation price (front-run / manipulated-price protection).
    function _createAndValidateV3Pool(
        address token0,
        address token1,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) internal {
        uint160 intendedSqrtPrice = _calculateSqrtPriceX96(amount0Desired, amount1Desired);

        address v3Pool = INonfungiblePositionManager(positionManager).createAndInitializePoolIfNecessary(
            token0, token1, v3Fee, intendedSqrtPrice
        );

        (uint160 actualSqrtPrice,,,,,,) = IUniswapV3PoolMinimal(v3Pool).slot0();
        if (!_priceWithinTolerance(actualSqrtPrice, intendedSqrtPrice)) revert UnexpectedPoolPrice();
    }

    /// @dev Mints a full-range position with min-amount slippage protection.
    function _mintFullRange(
        address token0,
        address token1,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) internal returns (uint256 tokenId, uint256 amount0, uint256 amount1) {
        (int24 tickLower, int24 tickUpper) = _getFullRangeTicks(v3Fee);

        uint128 liquidity;
        (tokenId, liquidity, amount0, amount1) = INonfungiblePositionManager(positionManager).mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: v3Fee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: (amount0Desired * (FEE_DENOMINATOR - GRADUATION_SLIPPAGE_BPS)) / FEE_DENOMINATOR,
                amount1Min: (amount1Desired * (FEE_DENOMINATOR - GRADUATION_SLIPPAGE_BPS)) / FEE_DENOMINATOR,
                recipient: address(this),
                deadline: block.timestamp + 900
            })
        );

        if (tokenId == 0 || liquidity == 0) revert LiquidityCreationFailed();
    }

    function _priceWithinTolerance(uint160 actual, uint160 intended) internal pure returns (bool) {
        if (intended == 0) return false;
        uint256 lo = (uint256(intended) * (FEE_DENOMINATOR - GRADUATION_PRICE_TOLERANCE_BPS)) / FEE_DENOMINATOR;
        uint256 hi = (uint256(intended) * (FEE_DENOMINATOR + GRADUATION_PRICE_TOLERANCE_BPS)) / FEE_DENOMINATOR;
        return uint256(actual) >= lo && uint256(actual) <= hi;
    }

    function _sweepLeftovers(uint256 liquidityTokens, uint256 liquidityZil, uint256 usedToken, uint256 usedWeth)
        internal
    {
        uint256 leftoverToken = liquidityTokens - usedToken;
        uint256 leftoverWeth = liquidityZil - usedWeth;

        if (leftoverToken > 0) {
            token.safeTransfer(treasury, leftoverToken);
        }
        if (leftoverWeth > 0) {
            IERC20(wrappedNative).safeTransfer(treasury, leftoverWeth);
        }
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function _calculateSqrtPriceX96(uint256 amount0, uint256 amount1) internal pure returns (uint160) {
        uint256 sqrtAmount1 = _sqrt(amount1);
        uint256 sqrtAmount0 = _sqrt(amount0);
        if (sqrtAmount0 == 0) return type(uint160).max;
        return uint160((sqrtAmount1 << 96) / sqrtAmount0);
    }

    function _getFullRangeTicks(uint24 fee) internal pure returns (int24 tickLower, int24 tickUpper) {
        int24 tickSpacing = _getTickSpacing(fee);
        tickLower = (MIN_TICK / tickSpacing) * tickSpacing;
        tickUpper = (MAX_TICK / tickSpacing) * tickSpacing;
    }

    function _getTickSpacing(uint24 fee) internal pure returns (int24) {
        if (fee == 100) return 1;
        if (fee == 500) return 10;
        if (fee == 2500) return 50;
        if (fee == 10000) return 200;
        revert("Invalid fee");
    }

    receive() external payable {
        if (msg.sender != wrappedNative) revert TransferFailed();
    }
}
