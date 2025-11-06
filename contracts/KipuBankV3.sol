// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

interface IUniswapV2Router02 {
    function WETH() external pure returns (address);

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

/**
 * @title KipuBankV3
 * @author Tu Nombre
 * @notice Banco descentralizado que acepta múltiples tokens, los intercambia por USDC a través de Uniswap V2 y respeta un tope total en USDC.
 */
contract KipuBankV3 is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // =============================================================
    //                      TIPOS Y CONSTANTES
    // =============================================================

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    address public constant ETH_ADDRESS = address(0);

    struct WithdrawWindow {
        uint64 windowStart; // inicio del día (UTC) en segundos
        uint192 spentUSDC; // gastado en la ventana (6 decimales)
    }

    // =============================================================
    //                      VARIABLES DE ESTADO
    // =============================================================

    uint256 public immutable bankCapUSDC;
    uint256 public totalDepositedUSDC;
    uint256 public perUserDailyWithdrawLimitUSDC;

    IERC20 public immutable usdc;
    IUniswapV2Router02 public immutable router;
    address public immutable weth;

    mapping(address => uint256) public balancesUSDC;
    mapping(address => bool) public supportedTokens;
    mapping(address => WithdrawWindow) private _userWithdrawWindow;

    // =============================================================
    //                           EVENTOS
    // =============================================================

    event Deposit(
        address indexed user,
        address indexed inputToken,
        uint256 inputAmount,
        uint256 creditedUSDC
    );
    event Withdrawal(
        address indexed user,
        address indexed outputToken,
        uint256 outputAmount,
        uint256 debitedUSDC
    );
    event SupportedTokenUpdated(address indexed token, bool isSupported);
    event PerUserDailyWithdrawLimitUpdated(uint256 newLimitUSDC);

    // =============================================================
    //                          ERRORES
    // =============================================================

    error InvalidAmount();
    error InvalidAddress();
    error TokenNotSupported();
    error InsufficientBalance();
    error BankCapExceeded();
    error WithdrawLimitExceeded();
    error CannotDisableUSDC();

    // =============================================================
    //                       MODIFICADORES
    // =============================================================

    modifier onlyValidAmount(uint256 amount) {
        if (amount == 0) revert InvalidAmount();
        _;
    }

    modifier onlySupported(address token) {
        if (!supportedTokens[token]) revert TokenNotSupported();
        _;
    }

    // =============================================================
    //                       CONSTRUCTOR
    // =============================================================

    constructor(
        uint256 _bankCapUSDC,
        address _router,
        address _usdc,
        uint256 _perUserDailyWithdrawLimitUSDC
    ) {
        if (_bankCapUSDC == 0) revert InvalidAmount();
        if (_router == address(0) || _usdc == address(0)) revert InvalidAddress();

        bankCapUSDC = _bankCapUSDC;
        router = IUniswapV2Router02(_router);
        weth = router.WETH();
        if (weth == address(0)) revert InvalidAddress();

        usdc = IERC20(_usdc);
        perUserDailyWithdrawLimitUSDC = _perUserDailyWithdrawLimitUSDC;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        supportedTokens[_usdc] = true;
        usdc.forceApprove(_router, type(uint256).max);
    }

    // =============================================================
    //                   FUNCIONES PRINCIPALES - DEPÓSITOS
    // =============================================================

    function depositUSDC(uint256 amount)
        external
        whenNotPaused
        onlyValidAmount(amount)
        nonReentrant
    {
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        _creditUSDC(msg.sender, amount);

        emit Deposit(msg.sender, address(usdc), amount, amount);
    }

    function depositETH(uint256 minUSDCOut, uint256 deadline)
        external
        payable
        whenNotPaused
        onlyValidAmount(msg.value)
        nonReentrant
    {
        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = address(usdc);

        uint256[] memory amounts = router.swapExactETHForTokens{value: msg.value}(
            minUSDCOut,
            path,
            address(this),
            deadline
        );

        uint256 amountUSDC = amounts[amounts.length - 1];
        if (amountUSDC == 0) revert InvalidAmount();

        _creditUSDC(msg.sender, amountUSDC);

        emit Deposit(msg.sender, ETH_ADDRESS, msg.value, amountUSDC);
    }

    function depositToken(
        address token,
        uint256 amount,
        uint256 minUSDCOut,
        uint256 deadline
    )
        external
        whenNotPaused
        onlyValidAmount(amount)
        nonReentrant
    {
        if (token == address(usdc)) {
            usdc.safeTransferFrom(msg.sender, address(this), amount);
            _creditUSDC(msg.sender, amount);
            emit Deposit(msg.sender, address(usdc), amount, amount);
            return;
        }

        if (token == ETH_ADDRESS) revert InvalidAddress();
        if (!supportedTokens[token]) revert TokenNotSupported();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(token).safeIncreaseAllowance(address(router), amount);

        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = address(usdc);

        uint256[] memory amounts = router.swapExactTokensForTokens(
            amount,
            minUSDCOut,
            path,
            address(this),
            deadline
        );

        uint256 amountUSDC = amounts[amounts.length - 1];
        if (amountUSDC == 0) revert InvalidAmount();

        _creditUSDC(msg.sender, amountUSDC);

        emit Deposit(msg.sender, token, amount, amountUSDC);
    }

    // =============================================================
    //                   FUNCIONES PRINCIPALES - RETIROS
    // =============================================================

    function withdrawUSDC(uint256 amount)
        external
        whenNotPaused
        onlyValidAmount(amount)
        nonReentrant
    {
        _debitUSDC(msg.sender, amount);

        usdc.safeTransfer(msg.sender, amount);

        emit Withdrawal(msg.sender, address(usdc), amount, amount);
    }

    function withdrawETH(
        uint256 usdcAmount,
        uint256 minETHOut,
        uint256 deadline
    ) external whenNotPaused onlyValidAmount(usdcAmount) nonReentrant {
        _debitUSDC(msg.sender, usdcAmount);

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = weth;

        uint256[] memory amounts = router.swapExactTokensForETH(
            usdcAmount,
            minETHOut,
            path,
            msg.sender,
            deadline
        );

        emit Withdrawal(msg.sender, ETH_ADDRESS, amounts[amounts.length - 1], usdcAmount);
    }

    function withdrawToken(
        address token,
        uint256 usdcAmount,
        uint256 minTokenOut,
        uint256 deadline
    )
        external
        whenNotPaused
        onlyValidAmount(usdcAmount)
        nonReentrant
        onlySupported(token)
    {
        if (token == address(usdc)) {
            _debitUSDC(msg.sender, usdcAmount);
            usdc.safeTransfer(msg.sender, usdcAmount);
            emit Withdrawal(msg.sender, address(usdc), usdcAmount, usdcAmount);
            return;
        }

        _debitUSDC(msg.sender, usdcAmount);

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = token;

        uint256[] memory amounts = router.swapExactTokensForTokens(
            usdcAmount,
            minTokenOut,
            path,
            msg.sender,
            deadline
        );

        emit Withdrawal(
            msg.sender,
            token,
            amounts[amounts.length - 1],
            usdcAmount
        );
    }

    // =============================================================
    //                   FUNCIONES ADMINISTRATIVAS
    // =============================================================

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function setSupportedToken(address token, bool isSupported)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (token == address(0)) revert InvalidAddress();
        if (token == address(usdc) && !isSupported) revert CannotDisableUSDC();
        supportedTokens[token] = isSupported;
        emit SupportedTokenUpdated(token, isSupported);
    }

    function setPerUserDailyWithdrawLimitUSDC(uint256 newLimitUSDC)
        external
        onlyRole(ADMIN_ROLE)
    {
        perUserDailyWithdrawLimitUSDC = newLimitUSDC;
        emit PerUserDailyWithdrawLimitUpdated(newLimitUSDC);
    }

    // =============================================================
    //                   FUNCIONES DE CONSULTA
    // =============================================================

    function getUserBalanceUSDC(address user) external view returns (uint256) {
        return balancesUSDC[user];
    }

    function getAvailableCapacity() external view returns (uint256) {
        if (totalDepositedUSDC >= bankCapUSDC) return 0;
        return bankCapUSDC - totalDepositedUSDC;
    }

    function getRemainingWithdrawLimitUSDC(address user) external view returns (uint256) {
        if (perUserDailyWithdrawLimitUSDC == 0) return type(uint256).max;
        (uint64 currentStart, ) = _currentDay();
        WithdrawWindow memory w = _userWithdrawWindow[user];
        uint256 spent = (w.windowStart == currentStart) ? uint256(w.spentUSDC) : 0;
        if (spent >= perUserDailyWithdrawLimitUSDC) return 0;
        return perUserDailyWithdrawLimitUSDC - spent;
    }

    // =============================================================
    //                   FUNCIONES INTERNAS
    // =============================================================

    function _ensureCap(uint256 usdcAmount) private view {
        if (totalDepositedUSDC + usdcAmount > bankCapUSDC) revert BankCapExceeded();
    }

    function _creditUSDC(address user, uint256 amount) private {
        _ensureCap(amount);
        balancesUSDC[user] += amount;
        totalDepositedUSDC += amount;
    }

    function _debitUSDC(address user, uint256 amount) private {
        if (balancesUSDC[user] < amount) revert InsufficientBalance();

        _enforceAndConsumeWithdrawLimit(user, amount);

        balancesUSDC[user] -= amount;
        totalDepositedUSDC -= amount;
    }

    function _enforceAndConsumeWithdrawLimit(address user, uint256 usdcAmount) private {
        uint256 limit = perUserDailyWithdrawLimitUSDC;
        if (limit == 0) return;

        (uint64 currentStart, ) = _currentDay();
        WithdrawWindow storage w = _userWithdrawWindow[user];

        if (w.windowStart != currentStart) {
            w.windowStart = currentStart;
            w.spentUSDC = 0;
        }

        uint256 newSpent = uint256(w.spentUSDC) + usdcAmount;
        if (newSpent > limit) revert WithdrawLimitExceeded();

        w.spentUSDC = uint192(newSpent);
    }

    function _currentDay() private view returns (uint64 start, uint64 window) {
        uint256 day = block.timestamp / 1 days;
        start = uint64(day * 1 days);
        window = 86400;
    }

    // =============================================================
    //                         FALLBACKS
    // =============================================================

    receive() external payable {
        revert("Use depositETH");
    }
}
