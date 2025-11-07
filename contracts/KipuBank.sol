// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline
    ) external returns (uint[] memory amounts);

    function swapExactETHForTokens(
        uint amountOutMin, address[] calldata path, address to, uint deadline
    ) external payable returns (uint[] memory amounts);

    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);

    function WETH() external pure returns (address);
}

/**
 * @title KipuBankV3
 * @notice Acredita siempre en USDC. Acepta ETH, USDC y ERC20 con par directo a USDC en Uniswap V2.
 *         Respeta bankCap en USD, límite diario por usuario y mantiene pausado/roles.
 */
contract KipuBankV3 is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // -------------------- Roles y const --------------------
    bytes32 public constant ADMIN_ROLE    = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    uint256 private constant SLIPPAGE_TOLERANCE_BPS = 50; // 0.5% por defecto

    // -------------------- Integraciones --------------------
    IUniswapV2Router02 public immutable uniswapRouter;
    address public immutable USDC;
    address public immutable WETH;

    // -------------------- Cap y límites --------------------
    uint256 public immutable bankCapUSD;               // 6 dec
    uint256 public totalDepositedUSD;                  // 6 dec
    uint256 public perUserDailyWithdrawLimitUSD;       // 6 dec, 0 = sin límite

    // -------------------- Balances --------------------
    mapping(address => uint256) public usdcBalances;   // 6 dec por convención de USDC

    // -------------------- Allowlist de swap --------------------
    mapping(address => bool) public allowedForSwap;    // tokens permitidos para deposit/withdraw vía swap

    // -------------------- Price feed solo para USDC --------------------
    AggregatorV3Interface public usdcPriceFeed;        // USDC/USD con 8 dec
    uint8 public constant USDC_DECIMALS = 6;

    // -------------------- Ventana de retiros --------------------
    struct WithdrawWindow { uint64 windowStart; uint192 spentUSD; }
    mapping(address => WithdrawWindow) private _userWithdrawWindow;

    // -------------------- Eventos --------------------
    event Deposit(address indexed user, address indexed tokenIn, uint256 amountIn, uint256 creditedUSDC, uint256 valueUSD);
    event Withdrawal(address indexed user, address indexed tokenOut, uint256 amountOut, uint256 debitedUSDC, uint256 valueUSD);
    event PerUserDailyWithdrawLimitUpdated(uint256 newLimitUSD);
    event PauseStatusChanged(bool isPaused);
    event AllowedForSwapSet(address indexed token, bool allowed);
    event UsdcPriceFeedUpdated(address indexed feed);

    // -------------------- Errores --------------------
    error InvalidAddress();
    error InvalidAmount();
    error TokenNotAllowed();
    error InsufficientBalance();
    error BankCapExceeded();
    error WithdrawLimitExceeded();
    error DeadlineExpired();

    // -------------------- Constructor --------------------
    /**
     * @param _bankCapUSD cap en USD 6 dec
     * @param _usdcAddress token USDC
     * @param _uniswapRouter router Uniswap V2
     * @param _usdcPriceFeed Chainlink USDC/USD (8 dec)
     * @param _perUserDailyWithdrawLimitUSD límite diario por usuario en USD 6 dec (0 = sin límite)
     */
    constructor(
        uint256 _bankCapUSD,
        address _usdcAddress,
        address _uniswapRouter,
        address _usdcPriceFeed,
        uint256 _perUserDailyWithdrawLimitUSD
    ) {
        if (_bankCapUSD == 0) revert InvalidAmount();
        if (_usdcAddress == address(0) || _uniswapRouter == address(0) || _usdcPriceFeed == address(0)) revert InvalidAddress();

        bankCapUSD = _bankCapUSD;
        USDC = _usdcAddress;
        uniswapRouter = IUniswapV2Router02(_uniswapRouter);
        WETH = IUniswapV2Router02(_uniswapRouter).WETH();
        usdcPriceFeed = AggregatorV3Interface(_usdcPriceFeed);
        perUserDailyWithdrawLimitUSD = _perUserDailyWithdrawLimitUSD;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    // =========================================================
    //                      DEPÓSITOS
    // =========================================================

    /// Wrapper con slippage por defecto y deadline 5 min.
    function depositETH() external payable nonReentrant whenNotPaused {
        uint256[] memory quote = _quote(WETH, USDC, msg.value);
        uint256 minUSDC = _applySlippageBps(quote[1], SLIPPAGE_TOLERANCE_BPS);
        _depositETH(minUSDC, block.timestamp + 300);
    }

    function depositETH(uint256 minUSDC, uint256 deadline) external payable nonReentrant whenNotPaused {
        _depositETH(minUSDC, deadline);
    }

    function _depositETH(uint256 minUSDC, uint256 deadline) internal {
        if (msg.value == 0 || minUSDC == 0) revert InvalidAmount();
        if (block.timestamp > deadline) revert DeadlineExpired();

        // Pre-cap con quote
        uint256[] memory quote = _quote(WETH, USDC, msg.value);
        uint256 quotedUSDC = quote[1];
        _assertFitsCap(_usdFromUSDC(quotedUSDC));

        // Swap
        address[] memory path = _path2(WETH, USDC);
        uint256[] memory amounts = uniswapRouter.swapExactETHForTokens{value: msg.value}(
            minUSDC, path, address(this), deadline
        );

        uint256 usdcOut = amounts[1];
        uint256 valueUSD = _usdFromUSDC(usdcOut);
        _assertFitsCap(valueUSD);

        usdcBalances[msg.sender] += usdcOut;
        totalDepositedUSD += valueUSD;

        emit Deposit(msg.sender, address(0), msg.value, usdcOut, valueUSD);
    }

    /// Wrapper con slippage por defecto y deadline 5 min.
    function depositToken(address tokenIn, uint256 amountIn) external nonReentrant whenNotPaused {
        if (tokenIn == address(0) || amountIn == 0) revert InvalidAmount();

        if (tokenIn == USDC) {
            _depositUSDC(amountIn);
            return;
        }

        if (!allowedForSwap[tokenIn]) revert TokenNotAllowed();

        uint256[] memory quote = _quote(tokenIn, USDC, amountIn);
        uint256 minUSDC = _applySlippageBps(quote[1], SLIPPAGE_TOLERANCE_BPS);
        _depositToken(tokenIn, amountIn, minUSDC, block.timestamp + 300);
    }

    function depositToken(address tokenIn, uint256 amountIn, uint256 minUSDC, uint256 deadline)
        external
        nonReentrant
        whenNotPaused
    {
        if (tokenIn == address(0) || amountIn == 0 || minUSDC == 0) revert InvalidAmount();
        if (tokenIn == USDC) {
            _depositUSDC(amountIn);
            return;
        }
        if (!allowedForSwap[tokenIn]) revert TokenNotAllowed();
        _depositToken(tokenIn, amountIn, minUSDC, deadline);
    }

    function _depositUSDC(uint256 amountUSDC) internal {
        // Cap directo con monto exacto
        _assertFitsCap(_usdFromUSDC(amountUSDC));

        IERC20(USDC).safeTransferFrom(msg.sender, address(this), amountUSDC);
        usdcBalances[msg.sender] += amountUSDC;
        totalDepositedUSD += _usdFromUSDC(amountUSDC);

        emit Deposit(msg.sender, USDC, amountUSDC, amountUSDC, _usdFromUSDC(amountUSDC));
    }

    function _depositToken(address tokenIn, uint256 amountIn, uint256 minUSDC, uint256 deadline) internal {
        if (block.timestamp > deadline) revert DeadlineExpired();

        // Pre-cap con cotización
        uint256[] memory quote = _quote(tokenIn, USDC, amountIn);
        _assertFitsCap(_usdFromUSDC(quote[1]));

        // Pull + approve seguro
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(uniswapRouter), 0);
        IERC20(tokenIn).forceApprove(address(uniswapRouter), amountIn);

        // Swap
        address[] memory path = _path2(tokenIn, USDC);
        uint256[] memory amounts = uniswapRouter.swapExactTokensForTokens(
            amountIn, minUSDC, path, address(this), deadline
        );

        uint256 usdcOut = amounts[1];
        uint256 valueUSD = _usdFromUSDC(usdcOut);
        _assertFitsCap(valueUSD);

        usdcBalances[msg.sender] += usdcOut;
        totalDepositedUSD += valueUSD;

        emit Deposit(msg.sender, tokenIn, amountIn, usdcOut, valueUSD);
    }

    // =========================================================
    //                      RETIROS
    // =========================================================

    function withdrawUSDC(uint256 amountUSDC) external nonReentrant whenNotPaused {
        if (amountUSDC == 0) revert InvalidAmount();
        uint256 bal = usdcBalances[msg.sender];
        if (bal < amountUSDC) revert InsufficientBalance();

        uint256 valueUSD = _usdFromUSDC(amountUSDC);
        _consumeWithdrawLimit(msg.sender, valueUSD);

        usdcBalances[msg.sender] = bal - amountUSDC;
        totalDepositedUSD -= valueUSD;

        IERC20(USDC).safeTransfer(msg.sender, amountUSDC);
        emit Withdrawal(msg.sender, USDC, amountUSDC, amountUSDC, valueUSD);
    }

    /// Wrapper con slippage por defecto y deadline 5 min.
    function withdrawAsToken(address tokenOut, uint256 usdcAmount) external nonReentrant whenNotPaused {
        if (tokenOut == address(0) || usdcAmount == 0) revert InvalidAmount();
        if (tokenOut == USDC) { withdrawUSDC(usdcAmount); return; }
        if (!allowedForSwap[tokenOut]) revert TokenNotAllowed();

        uint256[] memory quote = _quote(USDC, tokenOut, usdcAmount);
        uint256 minOut = _applySlippageBps(quote[1], SLIPPAGE_TOLERANCE_BPS);
        _withdrawAsToken(tokenOut, usdcAmount, minOut, block.timestamp + 300);
    }

    function withdrawAsToken(address tokenOut, uint256 usdcAmount, uint256 minOut, uint256 deadline)
        external
        nonReentrant
        whenNotPaused
    {
        if (tokenOut == address(0) || usdcAmount == 0 || minOut == 0) revert InvalidAmount();
        if (tokenOut == USDC) { withdrawUSDC(usdcAmount); return; }
        if (!allowedForSwap[tokenOut]) revert TokenNotAllowed();
        _withdrawAsToken(tokenOut, usdcAmount, minOut, deadline);
    }

    function _withdrawAsToken(address tokenOut, uint256 usdcAmount, uint256 minOut, uint256 deadline) internal {
        if (block.timestamp > deadline) revert DeadlineExpired();

        uint256 bal = usdcBalances[msg.sender];
        if (bal < usdcAmount) revert InsufficientBalance();

        uint256 valueUSD = _usdFromUSDC(usdcAmount);
        _consumeWithdrawLimit(msg.sender, valueUSD);

        usdcBalances[msg.sender] = bal - usdcAmount;
        totalDepositedUSD -= valueUSD;

        IERC20(USDC).forceApprove(address(uniswapRouter), 0);
        IERC20(USDC).forceApprove(address(uniswapRouter), usdcAmount);

        address[] memory path = _path2(USDC, tokenOut);
        uint256[] memory amounts = uniswapRouter.swapExactTokensForTokens(
            usdcAmount, minOut, path, msg.sender, deadline
        );

        emit Withdrawal(msg.sender, tokenOut, amounts[1], usdcAmount, valueUSD);
    }

    // =========================================================
    //                      ADMIN
    // =========================================================

    function setPerUserDailyWithdrawLimitUSD(uint256 newLimitUSD) external onlyRole(ADMIN_ROLE) {
        perUserDailyWithdrawLimitUSD = newLimitUSD;
        emit PerUserDailyWithdrawLimitUpdated(newLimitUSD);
    }

    function setAllowedForSwap(address token, bool allowed) external onlyRole(ADMIN_ROLE) {
        if (token == address(0)) revert InvalidAddress();
        allowedForSwap[token] = allowed;
        emit AllowedForSwapSet(token, allowed);
    }

    function updateUsdcPriceFeed(address newFeed) external onlyRole(ADMIN_ROLE) {
        if (newFeed == address(0)) revert InvalidAddress();
        usdcPriceFeed = AggregatorV3Interface(newFeed);
        emit UsdcPriceFeedUpdated(newFeed);
    }

    function pause() external onlyRole(ADMIN_ROLE) { _pause(); emit PauseStatusChanged(true); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); emit PauseStatusChanged(false); }

    // =========================================================
    //                      VISTAS
    // =========================================================

    function getUserUSDCBalance(address user) external view returns (uint256) { return usdcBalances[user]; }

    function getAvailableCapacity() external view returns (uint256) {
        return totalDepositedUSD >= bankCapUSD ? 0 : (bankCapUSD - totalDepositedUSD);
    }

    function getRemainingWithdrawLimitUSD(address user) external view returns (uint256) {
        uint256 limit = perUserDailyWithdrawLimitUSD;
        if (limit == 0) return type(uint256).max;
        (uint64 start,) = _currentDay();
        WithdrawWindow memory w = _userWithdrawWindow[user];
        uint256 spent = (w.windowStart == start) ? uint256(w.spentUSD) : 0;
        return spent >= limit ? 0 : (limit - spent);
    }

    // =========================================================
    //                      INTERNAS
    // =========================================================

    function _quote(address tokenIn, address tokenOut, uint256 amountIn) internal view returns (uint256[] memory) {
        address[] memory path = _path2(tokenIn, tokenOut);
        return uniswapRouter.getAmountsOut(amountIn, path); // revierte si no hay par
    }

    function _applySlippageBps(uint256 amount, uint256 bps) internal pure returns (uint256) {
        // minOut = amount * (10000 - bps) / 10000
        return amount * (10000 - bps) / 10000;
    }

    function _path2(address a, address b) internal pure returns (address[] memory p) {
        p = new address;
        p[0] = a; p[1] = b;
    }

    function _assertFitsCap(uint256 addUSD) internal view {
        if (totalDepositedUSD + addUSD > bankCapUSD) revert BankCapExceeded();
    }

    function _usdFromUSDC(uint256 amountUSDC) internal view returns (uint256) {
        // USDC (6 dec) * price(8 dec) / 1e8 -> USD con 6 dec
        (uint80 roundId, int256 price,, uint256 updatedAt, uint80 answeredInRound) = usdcPriceFeed.latestRoundData();
        if (price <= 0 || updatedAt == 0 || answeredInRound < roundId) revert("Invalid USDC feed");
        if (block.timestamp - updatedAt > 24 hours) revert("Stale USDC feed");
        return (amountUSDC * uint256(price)) / 1e8;
    }

    function _consumeWithdrawLimit(address user, uint256 valueUSD) internal {
        uint256 limit = perUserDailyWithdrawLimitUSD;
        if (limit == 0) return;

        (uint64 start,) = _currentDay();
        WithdrawWindow storage w = _userWithdrawWindow[user];
        if (w.windowStart != start) { w.windowStart = start; w.spentUSD = 0; }

        uint256 newSpent = uint256(w.spentUSD) + valueUSD;
        if (newSpent > limit) revert WithdrawLimitExceeded();
        w.spentUSD = uint192(newSpent);
    }

    function _currentDay() private view returns (uint64 start, uint64 window) {
        uint256 day = block.timestamp / 1 days;
        start = uint64(day * 1 days);
        window = 86400;
    }

    receive() external payable { revert("Use depositETH(minUSDC,deadline)"); }
}
