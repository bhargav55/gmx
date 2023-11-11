// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "../libraries/math/SafeMath.sol";
import "../libraries/token/IERC20.sol";
import "../libraries/token/SafeERC20.sol";
import "../libraries/utils/ReentrancyGuard.sol";

import "../tokens/interfaces/IUSDG.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IVaultUtils.sol";
import "./interfaces/IVaultPriceFeed.sol";

contract Vault is ReentrancyGuard, IVault {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct Position {
        uint256 size;
        uint256 collateral;
        uint256 averagePrice;
        uint256 entryFundingRate;
        uint256 reserveAmount;
        int256 realisedPnl;
        uint256 lastIncreasedTime;
    }

    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public constant FUNDING_RATE_PRECISION = 1000000;
    uint256 public constant PRICE_PRECISION = 10 ** 30;
    uint256 public constant MIN_LEVERAGE = 10000; // 1x
    uint256 public constant USDG_DECIMALS = 18;
    uint256 public constant MAX_FEE_BASIS_POINTS = 500; // 5%
    uint256 public constant MAX_LIQUIDATION_FEE_USD = 100 * PRICE_PRECISION; // 100 USD
    uint256 public constant MIN_FUNDING_RATE_INTERVAL = 1 hours;
    uint256 public constant MAX_FUNDING_RATE_FACTOR = 10000; // 1%

    bool public override isInitialized;
    bool public override isSwapEnabled = true;
    bool public override isLeverageEnabled = true;

    IVaultUtils public vaultUtils;

    address public errorController;

    address public override router;
    address public override priceFeed;

    address public override usdg;
    address public override gov;

    uint256 public override whitelistedTokenCount;

    uint256 public override maxLeverage = 50 * 10000; // 50x

    uint256 public override liquidationFeeUsd;
    uint256 public override taxBasisPoints = 50; // 0.5%
    uint256 public override stableTaxBasisPoints = 20; // 0.2%
    uint256 public override mintBurnFeeBasisPoints = 30; // 0.3%
    uint256 public override swapFeeBasisPoints = 30; // 0.3%
    uint256 public override stableSwapFeeBasisPoints = 4; // 0.04%
    uint256 public override marginFeeBasisPoints = 10; // 0.1%

    uint256 public override minProfitTime;
    bool public override hasDynamicFees = false;

    uint256 public override fundingInterval = 8 hours;
    uint256 public override fundingRateFactor;
    uint256 public override stableFundingRateFactor;
    uint256 public override totalTokenWeights;

    bool public includeAmmPrice = true;
    bool public useSwapPricing = false;

    bool public override inManagerMode = false;
    bool public override inPrivateLiquidationMode = false;

    uint256 public override maxGasPrice;

    mapping (address => mapping (address => bool)) public override approvedRouters;
    mapping (address => bool) public override isLiquidator;
    mapping (address => bool) public override isManager;

    address[] public override allWhitelistedTokens;

    mapping (address => bool) public override whitelistedTokens;
    mapping (address => uint256) public override tokenDecimals;
    mapping (address => uint256) public override minProfitBasisPoints;
    mapping (address => bool) public override stableTokens;
    mapping (address => bool) public override shortableTokens;

    // tokenBalances is used only to determine _transferIn values
    mapping (address => uint256) public override tokenBalances;

    // tokenWeights allows customisation of index composition
    mapping (address => uint256) public override tokenWeights;

    // usdgAmounts tracks the amount of USDG debt for each whitelisted token
    mapping (address => uint256) public override usdgAmounts;

    // maxUsdgAmounts allows setting a max amount of USDG debt for a token
    mapping (address => uint256) public override maxUsdgAmounts;

    // poolAmounts tracks the number of received tokens that can be used for leverage
    // this is tracked separately from tokenBalances to exclude funds that are deposited as margin collateral
    mapping (address => uint256) public override poolAmounts;

    // reservedAmounts tracks the number of tokens reserved for open leverage positions
    mapping (address => uint256) public override reservedAmounts;

    // bufferAmounts allows specification of an amount to exclude from swaps
    // this can be used to ensure a certain amount of liquidity is available for leverage positions
    mapping (address => uint256) public override bufferAmounts;

    // guaranteedUsd tracks the amount of USD that is "guaranteed" by opened leverage positions
    // this value is used to calculate the redemption values for selling of USDG
    // this is an estimated amount, it is possible for the actual guaranteed value to be lower
    // in the case of sudden price decreases, the guaranteed value should be corrected
    // after liquidations are carried out
    mapping (address => uint256) public override guaranteedUsd;

    // cumulativeFundingRates tracks the funding rates based on utilization
    mapping (address => uint256) public override cumulativeFundingRates;
    // lastFundingTimes tracks the last time funding was updated for a token
    mapping (address => uint256) public override lastFundingTimes;

    // positions tracks all open positions
    mapping (bytes32 => Position) public positions;

    // feeReserves tracks the amount of fees per token
    mapping (address => uint256) public override feeReserves;

    mapping (address => uint256) public override globalShortSizes;
    mapping (address => uint256) public override globalShortAveragePrices;
    mapping (address => uint256) public override maxGlobalShortSizes;

    mapping (uint256 => string) public errors;

    event BuyUSDG(address account, address token, uint256 tokenAmount, uint256 usdgAmount, uint256 feeBasisPoints);
    event SellUSDG(address account, address token, uint256 usdgAmount, uint256 tokenAmount, uint256 feeBasisPoints);
    event Swap(address account, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, uint256 amountOutAfterFees, uint256 feeBasisPoints);

    event IncreasePosition(
        bytes32 key,
        address account,
        address collateralToken,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 price,
        uint256 fee
    );
    event DecreasePosition(
        bytes32 key,
        address account,
        address collateralToken,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 price,
        uint256 fee
    );
    event LiquidatePosition(
        bytes32 key,
        address account,
        address collateralToken,
        address indexToken,
        bool isLong,
        uint256 size,
        uint256 collateral,
        uint256 reserveAmount,
        int256 realisedPnl,
        uint256 markPrice
    );
    event UpdatePosition(
        bytes32 key,
        uint256 size,
        uint256 collateral,
        uint256 averagePrice,
        uint256 entryFundingRate,
        uint256 reserveAmount,
        int256 realisedPnl,
        uint256 markPrice
    );
    event ClosePosition(
        bytes32 key,
        uint256 size,
        uint256 collateral,
        uint256 averagePrice,
        uint256 entryFundingRate,
        uint256 reserveAmount,
        int256 realisedPnl
    );

    event UpdateFundingRate(address token, uint256 fundingRate);
    event UpdatePnl(bytes32 key, bool hasProfit, uint256 delta);

    event CollectSwapFees(address token, uint256 feeUsd, uint256 feeTokens);
    event CollectMarginFees(address token, uint256 feeUsd, uint256 feeTokens);

    event DirectPoolDeposit(address token, uint256 amount);
    event IncreasePoolAmount(address token, uint256 amount);
    event DecreasePoolAmount(address token, uint256 amount);
    event IncreaseUsdgAmount(address token, uint256 amount);
    event DecreaseUsdgAmount(address token, uint256 amount);
    event IncreaseReservedAmount(address token, uint256 amount);
    event DecreaseReservedAmount(address token, uint256 amount);
    event IncreaseGuaranteedUsd(address token, uint256 amount);
    event DecreaseGuaranteedUsd(address token, uint256 amount);

    // once the parameters are verified to be working correctly,
    // gov should be set to a timelock contract or a governance contract
    constructor() public {
        gov = msg.sender;
    }

    function initialize(
        address _router,
        address _usdg,
        address _priceFeed,
        uint256 _liquidationFeeUsd,
        uint256 _fundingRateFactor,
        uint256 _stableFundingRateFactor
    ) external {
        _onlyGov();
        _validate(!isInitialized, 1);
        isInitialized = true;

        router = _router;
        usdg = _usdg;
        priceFeed = _priceFeed;
        liquidationFeeUsd = _liquidationFeeUsd;
        fundingRateFactor = _fundingRateFactor;
        stableFundingRateFactor = _stableFundingRateFactor;
    }

    function setVaultUtils(IVaultUtils _vaultUtils) external override {
        _onlyGov();
        vaultUtils = _vaultUtils;
    }

    function setErrorController(address _errorController) external {
        _onlyGov();
        errorController = _errorController;
    }

    function setError(uint256 _errorCode, string calldata _error) external override {
        require(msg.sender == errorController, "Vault: invalid errorController");
        errors[_errorCode] = _error;
    }

    function allWhitelistedTokensLength() external override view returns (uint256) {
        return allWhitelistedTokens.length;
    }

    function setInManagerMode(bool _inManagerMode) external override {
        _onlyGov();
        inManagerMode = _inManagerMode;
    }

    function setManager(address _manager, bool _isManager) external override {
        _onlyGov();
        isManager[_manager] = _isManager;
    }

    function setInPrivateLiquidationMode(bool _inPrivateLiquidationMode) external override {
        _onlyGov();
        inPrivateLiquidationMode = _inPrivateLiquidationMode;
    }

    function setLiquidator(address _liquidator, bool _isActive) external override {
        _onlyGov();
        isLiquidator[_liquidator] = _isActive;
    }

    function setIsSwapEnabled(bool _isSwapEnabled) external override {
        _onlyGov();
        isSwapEnabled = _isSwapEnabled;
    }

    function setIsLeverageEnabled(bool _isLeverageEnabled) external override {
        _onlyGov();
        isLeverageEnabled = _isLeverageEnabled;
    }

    function setMaxGasPrice(uint256 _maxGasPrice) external override {
        _onlyGov();
        maxGasPrice = _maxGasPrice;
    }

    function setGov(address _gov) external {
        _onlyGov();
        gov = _gov;
    }

    function setPriceFeed(address _priceFeed) external override {
        _onlyGov();
        priceFeed = _priceFeed;
    }

    function setMaxLeverage(uint256 _maxLeverage) external override {
        _onlyGov();
        _validate(_maxLeverage > MIN_LEVERAGE, 2);
        maxLeverage = _maxLeverage;
    }

    function setBufferAmount(address _token, uint256 _amount) external override {
        _onlyGov();
        bufferAmounts[_token] = _amount;
    }

    function setMaxGlobalShortSize(address _token, uint256 _amount) external override {
        _onlyGov();
        maxGlobalShortSizes[_token] = _amount;
    }


    function withdrawFees(address _token, address _receiver) external override returns (uint256) {
        _onlyGov();
        uint256 amount = feeReserves[_token];
        if(amount == 0) { return 0; }
        feeReserves[_token] = 0;
        _transferOut(_token, amount, _receiver);
        return amount;
    }

    function addRouter(address _router) external {
        approvedRouters[msg.sender][_router] = true;
    }

    function removeRouter(address _router) external {
        approvedRouters[msg.sender][_router] = false;
    }

    function setUsdgAmount(address _token, uint256 _amount) external override {
        _onlyGov();

        uint256 usdgAmount = usdgAmounts[_token];
        if (_amount > usdgAmount) {
            _increaseUsdgAmount(_token, _amount.sub(usdgAmount));
            return;
        }

        _decreaseUsdgAmount(_token, usdgAmount.sub(_amount));
    }

    // the governance controlling this function should have a timelock
    function upgradeVault(address _newVault, address _token, uint256 _amount) external {
        _onlyGov();
        IERC20(_token).safeTransfer(_newVault, _amount);
    }

    // deposit into the pool without minting USDG tokens
    // useful in allowing the pool to become over-collaterised
    function directPoolDeposit(address _token) external override nonReentrant {
        _validate(whitelistedTokens[_token], 14);
        uint256 tokenAmount = _transferIn(_token);
        _validate(tokenAmount > 0, 15);
        _increasePoolAmount(_token, tokenAmount);
        emit DirectPoolDeposit(_token, tokenAmount);
    }
   
    function swap(address _tokenIn, address _tokenOut, address _receiver) external override nonReentrant returns (uint256) {
        _validate(isSwapEnabled, 23);
        _validate(whitelistedTokens[_tokenIn], 24);
        _validate(whitelistedTokens[_tokenOut], 25);
        _validate(_tokenIn != _tokenOut, 26);

        useSwapPricing = true;

        updateCumulativeFundingRate(_tokenIn, _tokenIn);
        updateCumulativeFundingRate(_tokenOut, _tokenOut);

        uint256 amountIn = _transferIn(_tokenIn);
        _validate(amountIn > 0, 27);

        uint256 priceIn = getMinPrice(_tokenIn);
        uint256 priceOut = getMaxPrice(_tokenOut);

        uint256 amountOut = amountIn.mul(priceIn).div(priceOut);
        amountOut = adjustForDecimals(amountOut, _tokenIn, _tokenOut);

        // adjust usdgAmounts by the same usdgAmount as debt is shifted between the assets
        uint256 usdgAmount = amountIn.mul(priceIn).div(PRICE_PRECISION);
        usdgAmount = adjustForDecimals(usdgAmount, _tokenIn, usdg);

        uint256 feeBasisPoints = vaultUtils.getSwapFeeBasisPoints(_tokenIn, _tokenOut, usdgAmount);
        uint256 amountOutAfterFees = _collectSwapFees(_tokenOut, amountOut, feeBasisPoints);

        _increaseUsdgAmount(_tokenIn, usdgAmount);
        _decreaseUsdgAmount(_tokenOut, usdgAmount);

        _increasePoolAmount(_tokenIn, amountIn);
        _decreasePoolAmount(_tokenOut, amountOut);

        _validateBufferAmount(_tokenOut);

        _transferOut(_tokenOut, amountOutAfterFees, _receiver);

        emit Swap(_receiver, _tokenIn, _tokenOut, amountIn, amountOut, amountOutAfterFees, feeBasisPoints);

        useSwapPricing = false;
        return amountOutAfterFees;
    }


    function adjustForDecimals(uint256 _amount, address _tokenDiv, address _tokenMul) public view returns (uint256) {
        uint256 decimalsDiv = _tokenDiv == usdg ? USDG_DECIMALS : tokenDecimals[_tokenDiv];
        uint256 decimalsMul = _tokenMul == usdg ? USDG_DECIMALS : tokenDecimals[_tokenMul];
        return _amount.mul(10 ** decimalsMul).div(10 ** decimalsDiv);
    }

    function updateCumulativeFundingRate(address _collateralToken, address _indexToken) public {
        bool shouldUpdate = vaultUtils.updateCumulativeFundingRate(_collateralToken, _indexToken);
        if (!shouldUpdate) {
            return;
        }

        if (lastFundingTimes[_collateralToken] == 0) {
            lastFundingTimes[_collateralToken] = block.timestamp.div(fundingInterval).mul(fundingInterval);
            return;
        }

        if (lastFundingTimes[_collateralToken].add(fundingInterval) > block.timestamp) {
            return;
        }

        uint256 fundingRate = getNextFundingRate(_collateralToken);
        cumulativeFundingRates[_collateralToken] = cumulativeFundingRates[_collateralToken].add(fundingRate);
        lastFundingTimes[_collateralToken] = block.timestamp.div(fundingInterval).mul(fundingInterval);

        emit UpdateFundingRate(_collateralToken, cumulativeFundingRates[_collateralToken]);
    }

    function getNextFundingRate(address _token) public override view returns (uint256) {
        if (lastFundingTimes[_token].add(fundingInterval) > block.timestamp) { return 0; }

        uint256 intervals = block.timestamp.sub(lastFundingTimes[_token]).div(fundingInterval);
        uint256 poolAmount = poolAmounts[_token];
        if (poolAmount == 0) { return 0; }

        uint256 _fundingRateFactor = stableTokens[_token] ? stableFundingRateFactor : fundingRateFactor;
        return _fundingRateFactor.mul(reservedAmounts[_token]).mul(intervals).div(poolAmount);
    }


    function _collectSwapFees(address _token, uint256 _amount, uint256 _feeBasisPoints) private returns (uint256) {
        uint256 afterFeeAmount = _amount.mul(BASIS_POINTS_DIVISOR.sub(_feeBasisPoints)).div(BASIS_POINTS_DIVISOR);
        uint256 feeAmount = _amount.sub(afterFeeAmount);
        feeReserves[_token] = feeReserves[_token].add(feeAmount);
        emit CollectSwapFees(_token, tokenToUsdMin(_token, feeAmount), feeAmount);
        return afterFeeAmount;
    }

    function _transferIn(address _token) private returns (uint256) {
        uint256 prevBalance = tokenBalances[_token];
        uint256 nextBalance = IERC20(_token).balanceOf(address(this));
        tokenBalances[_token] = nextBalance;

        return nextBalance.sub(prevBalance);
    }

    function _transferOut(address _token, uint256 _amount, address _receiver) private {
        IERC20(_token).safeTransfer(_receiver, _amount);
        tokenBalances[_token] = IERC20(_token).balanceOf(address(this));
    }


    function _increasePoolAmount(address _token, uint256 _amount) private {
        poolAmounts[_token] = poolAmounts[_token].add(_amount);
        uint256 balance = IERC20(_token).balanceOf(address(this));
        _validate(poolAmounts[_token] <= balance, 49);
        emit IncreasePoolAmount(_token, _amount);
    }

    function _decreasePoolAmount(address _token, uint256 _amount) private {
        poolAmounts[_token] = poolAmounts[_token].sub(_amount, "Vault: poolAmount exceeded");
        _validate(reservedAmounts[_token] <= poolAmounts[_token], 50);
        emit DecreasePoolAmount(_token, _amount);
    }

    function _validateBufferAmount(address _token) private view {
        if (poolAmounts[_token] < bufferAmounts[_token]) {
            revert("Vault: poolAmount < buffer");
        }
    }

    function _increaseUsdgAmount(address _token, uint256 _amount) private {
        usdgAmounts[_token] = usdgAmounts[_token].add(_amount);
        uint256 maxUsdgAmount = maxUsdgAmounts[_token];
        if (maxUsdgAmount != 0) {
            _validate(usdgAmounts[_token] <= maxUsdgAmount, 51);
        }
        emit IncreaseUsdgAmount(_token, _amount);
    }

    function _decreaseUsdgAmount(address _token, uint256 _amount) private {
        uint256 value = usdgAmounts[_token];
        // since USDG can be minted using multiple assets
        // it is possible for the USDG debt for a single asset to be less than zero
        // the USDG debt is capped to zero for this case
        if (value <= _amount) {
            usdgAmounts[_token] = 0;
            emit DecreaseUsdgAmount(_token, value);
            return;
        }
        usdgAmounts[_token] = value.sub(_amount);
        emit DecreaseUsdgAmount(_token, _amount);
    }


    // we have this validation as a function instead of a modifier to reduce contract size
    function _onlyGov() private view {
        _validate(msg.sender == gov, 53);
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    function _validateManager() private view {
        if (inManagerMode) {
            _validate(isManager[msg.sender], 54);
        }
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    function _validateGasPrice() private view {
        if (maxGasPrice == 0) { return; }
        _validate(tx.gasprice <= maxGasPrice, 55);
    }

    function _validate(bool _condition, uint256 _errorCode) private view {
        require(_condition, errors[_errorCode]);
    }
}
