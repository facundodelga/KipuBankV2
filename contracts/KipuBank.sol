// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title KipuBankV2
 * @author Tu Nombre
 * @notice Banco descentralizado multi-token con control de límites en USD
 * @dev Implementa depósitos/retiros de ETH y ERC20 con conversión a USD usando oráculos Chainlink
 */
contract KipuBankV2 is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // =============================================================
    //                      TIPOS Y CONSTANTES
    // =============================================================

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    address public constant ETH_ADDRESS = address(0);
    uint8 public constant NORMALIZED_DECIMALS = 6;
    uint256 private constant PRECISION = 1e18;

    /// @notice Ventana de retiro por usuario
    struct WithdrawWindow {
        uint64 windowStart;     // inicio del día (UTC) en segundos
        uint192 spentUSD;       // gastado en la ventana (6 decimales)
    }

    // =============================================================
    //                      VARIABLES DE ESTADO
    // =============================================================

    uint256 public immutable bankCapUSD;
    uint256 public totalDepositedUSD;
    uint256 public perUserDailyWithdrawLimitUSD;
    mapping(address => mapping(address => uint256)) public balances;
    mapping(address => AggregatorV3Interface) public priceFeeds;
    mapping(address => bool) public supportedTokens;
    mapping(address => uint8) public tokenDecimals;
    mapping(address => WithdrawWindow) private _userWithdrawWindow;

    // =============================================================
    //                           EVENTOS
    // =============================================================

    event Deposit(address indexed user, address indexed token, uint256 amount, uint256 valueUSD);
    event Withdrawal(address indexed user, address indexed token, uint256 amount, uint256 valueUSD);
    event TokenAdded(address indexed token, address indexed priceFeed, uint8 decimals);
    event PauseStatusChanged(bool isPaused);
    event PriceFeedUpdated(address indexed token, address indexed newPriceFeed);
    event PerUserDailyWithdrawLimitUpdated(uint256 newLimitUSD);

    // =============================================================
    //                          ERRORES
    // =============================================================

    error BankPaused();
    error BankNotPaused();
    error InvalidAmount();
    error InvalidAddress();
    error TokenNotSupported();
    error InsufficientBalance();
    error BankCapExceeded();
    error TransferFailed();
    error InvalidPriceFeed();
    error StalePrice();
    error WithdrawLimitExceeded();

    // =============================================================
    //                       MODIFICADORES
    // =============================================================

    modifier onlyValidAmount(uint256 amount) {
        if (amount == 0) revert InvalidAmount();
        _;
    }

    modifier onlyValidAddress(address addr) {
        if (addr == address(0) && addr != ETH_ADDRESS) revert InvalidAddress();
        _;
    }

    // =============================================================
    //                       CONSTRUCTOR
    // =============================================================

    /**
     * @notice Inicializa el banco con un límite en USD
     * @param _bankCapUSD Límite máximo en USD (con 6 decimales)
     * @param _ethPriceFeed Dirección del oráculo ETH/USD de Chainlink
     * @param _perUserDailyWithdrawLimitUSD Límite diario por usuario en USD (6 decimales). Si es 0, sin límite.
     */
    constructor(uint256 _bankCapUSD, address _ethPriceFeed, uint256 _perUserDailyWithdrawLimitUSD) {
        if (_bankCapUSD == 0) revert InvalidAmount();
        if (_ethPriceFeed == address(0)) revert InvalidAddress();

        bankCapUSD = _bankCapUSD;
        perUserDailyWithdrawLimitUSD = _perUserDailyWithdrawLimitUSD;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        _addToken(ETH_ADDRESS, _ethPriceFeed, 18);
    }

    // =============================================================
    //                   FUNCIONES PRINCIPALES
    // =============================================================

    function depositETH() 
        external 
        payable 
        whenNotPaused 
        onlyValidAmount(msg.value) 
        nonReentrant 
    {
        uint256 valueUSD = _convertToUSD(ETH_ADDRESS, msg.value);
        if (totalDepositedUSD + valueUSD > bankCapUSD) revert BankCapExceeded();

        balances[msg.sender][ETH_ADDRESS] += msg.value;
        totalDepositedUSD += valueUSD;

        emit Deposit(msg.sender, ETH_ADDRESS, msg.value, valueUSD);
    }

    function depositToken(address token, uint256 amount)
        external
        whenNotPaused
        onlyValidAmount(amount)
        onlyValidAddress(token)
        nonReentrant
    {
        if (!supportedTokens[token]) revert TokenNotSupported();
        if (token == ETH_ADDRESS) revert InvalidAddress();

        uint256 valueUSD = _convertToUSD(token, amount);
        if (totalDepositedUSD + valueUSD > bankCapUSD) revert BankCapExceeded();

        balances[msg.sender][token] += amount;
        totalDepositedUSD += valueUSD;

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        emit Deposit(msg.sender, token, amount, valueUSD);
    }

    function withdrawETH(uint256 amount)
        external
        whenNotPaused
        onlyValidAmount(amount)
        nonReentrant
    {
        if (balances[msg.sender][ETH_ADDRESS] < amount) revert InsufficientBalance();

        uint256 valueUSD = _convertToUSD(ETH_ADDRESS, amount);

        _enforceAndConsumeWithdrawLimit(msg.sender, valueUSD);
     

        balances[msg.sender][ETH_ADDRESS] -= amount;
        totalDepositedUSD -= valueUSD;

        (bool success, ) = msg.sender.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit Withdrawal(msg.sender, ETH_ADDRESS, amount, valueUSD);
    }

    function withdrawToken(address token, uint256 amount)
        external
        whenNotPaused
        onlyValidAmount(amount)
        onlyValidAddress(token)
        nonReentrant
    {
        if (!supportedTokens[token]) revert TokenNotSupported();
        if (token == ETH_ADDRESS) revert InvalidAddress();
        if (balances[msg.sender][token] < amount) revert InsufficientBalance();

        uint256 valueUSD = _convertToUSD(token, amount);

        _enforceAndConsumeWithdrawLimit(msg.sender, valueUSD);

        balances[msg.sender][token] -= amount;
        totalDepositedUSD -= valueUSD;

        IERC20(token).safeTransfer(msg.sender, amount);

        emit Withdrawal(msg.sender, token, amount, valueUSD);
    }

    // =============================================================
    //                   FUNCIONES ADMINISTRATIVAS
    // =============================================================

    function addToken(address token, address priceFeed, uint8 decimals)
        external
        onlyRole(ADMIN_ROLE)
    {
        _addToken(token, priceFeed, decimals);
    }

    function updatePriceFeed(address token, address newPriceFeed)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (!supportedTokens[token]) revert TokenNotSupported();
        if (newPriceFeed == address(0)) revert InvalidAddress();

        priceFeeds[token] = AggregatorV3Interface(newPriceFeed);
        emit PriceFeedUpdated(token, newPriceFeed);
    }

        function pause() external onlyRole(ADMIN_ROLE) { _pause(); }


        function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    // --------- NUEVO: gestión del límite ----------
    /**
     * @notice Actualiza el límite diario por usuario en USD (6 decimales). 0 desactiva el límite.
     */
    function setPerUserDailyWithdrawLimitUSD(uint256 newLimitUSD) external onlyRole(ADMIN_ROLE) {
        perUserDailyWithdrawLimitUSD = newLimitUSD;
        emit PerUserDailyWithdrawLimitUpdated(newLimitUSD);
    }
    // ----------------------------------------------

    // =============================================================
    //                   FUNCIONES DE CONSULTA
    // =============================================================

    function getUserBalance(address user, address token)
        external
        view
        returns (uint256)
    {
        return balances[user][token];
    }

    function getValueInUSD(address token, uint256 amount)
        external
        view
        returns (uint256)
    {
        return _convertToUSD(token, amount);
    }

    function getTokenPrice(address token) external view returns (uint256) {
        if (!supportedTokens[token]) revert TokenNotSupported();
        return _getLatestPrice(token);
    }

    function getAvailableCapacity() external view returns (uint256) {
        if (totalDepositedUSD >= bankCapUSD) return 0;
        return bankCapUSD - totalDepositedUSD;
    }

    /**
     * @notice Devuelve cuánto queda disponible para retirar hoy para un usuario, en USD (6 decimales).
     * @dev Si el límite está desactivado (0), devuelve type(uint256).max.
     */
    function getRemainingWithdrawLimitUSD(address user) external view returns (uint256) {
        if (perUserDailyWithdrawLimitUSD == 0) return type(uint256).max;
        (uint64 currentStart, ) = _currentDay();
        WithdrawWindow memory w = _userWithdrawWindow[user];
        uint256 spent = (w.windowStart == currentStart) ? uint256(w.spentUSD) : 0;
        if (spent >= perUserDailyWithdrawLimitUSD) return 0;
        return perUserDailyWithdrawLimitUSD - spent;
    }

    // =============================================================
    //                   FUNCIONES INTERNAS
    // =============================================================

    function _addToken(address token, address priceFeed, uint8 decimals) private {
        if (priceFeed == address(0)) revert InvalidAddress();
        if (supportedTokens[token]) return;

        priceFeeds[token] = AggregatorV3Interface(priceFeed);
        supportedTokens[token] = true;
        tokenDecimals[token] = decimals;

        emit TokenAdded(token, priceFeed, decimals);
    }

    function _convertToUSD(address token, uint256 amount)
        private
        view
        returns (uint256)
    {
        uint256 price = _getLatestPrice(token); // 8 decimales
        uint8 tokenDec = tokenDecimals[token];

        uint256 normalizedAmount = tokenDec <= 18
            ? amount * (10 ** (18 - tokenDec))
            : amount / (10 ** (tokenDec - 18));

        uint256 valueUSD = (normalizedAmount * price) / 1e20; // resultado en 6 decimales
        return valueUSD;
    }

    function _getLatestPrice(address token) private view returns (uint256) {
        AggregatorV3Interface priceFeed = priceFeeds[token];
        (uint80 roundId, int256 price, , uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();

        if (price <= 0) revert InvalidPriceFeed();
        if (answeredInRound < roundId) revert StalePrice();
        if (updatedAt == 0) revert StalePrice();
        if (block.timestamp - updatedAt > 24 hours) revert StalePrice();

        return uint256(price);
    }

    function _enforceAndConsumeWithdrawLimit(address user, uint256 valueUSD) private {
        uint256 limit = perUserDailyWithdrawLimitUSD;
        if (limit == 0) return; // sin límite

        (uint64 currentStart, ) = _currentDay();
        WithdrawWindow storage w = _userWithdrawWindow[user];

        if (w.windowStart != currentStart) {
            // nueva ventana
            w.windowStart = currentStart;
            w.spentUSD = 0;
        }

        uint256 newSpent = uint256(w.spentUSD) + valueUSD;
        if (newSpent > limit) revert WithdrawLimitExceeded();

        // cast seguro: perUserDailyWithdrawLimitUSD y valueUSD usan 6 decimales, caben en uint192
        w.spentUSD = uint192(newSpent);
    }

    /// @dev Retorna el inicio del día UTC y el tamaño de la ventana (24h)
    function _currentDay() private view returns (uint64 start, uint64 window) {
        uint256 day = block.timestamp / 1 days;
        start = uint64(day * 1 days);
        window = 86400;
    }
    // -------------------------------------------------------

    /**
     * @notice Permite al contrato recibir ETH
     */
    receive() external payable {
        revert("Use depositETH() function");
    }
}
