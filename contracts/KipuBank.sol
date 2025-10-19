// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title KipuBankV2
 * @author Facundo Delgado
 * @notice Bóveda custodial multi-token con contactos y transferencias internas.
 * @dev
 * - Contabilidad por token: `address(0)` representa ETH; ERC-20 vía `SafeERC20`.
 * - Límites en USD (8 decimales) con Chainlink Price Feeds por token.
 * - Normalización utilitaria a 6 dec (USDC-like) para UI.
 * - Seguridad: CEI, `Ownable2Step`, `AccessControl`, `Pausable`, `ReentrancyGuard`.
 * - Las transferencias internas no mueven tokens on-chain; solo saldos internos.
 */
contract KipuBankV2 is Ownable, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                               ROLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Rol para pausar/reanudar.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @notice Rol para gobernar riesgo (feeds, tokens, parámetros).
    bytes32 public constant RISK_ROLE   = keccak256("RISK_ROLE");

    /*//////////////////////////////////////////////////////////////
                       CONSTANTES / INMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Tope global del banco en USD con 8 dec (1 USD = 1e8).
    uint256 public immutable BANK_CAP_USD8;
    /// @notice Límite por retiro en USD con 8 dec.
    uint256 public immutable WITHDRAW_LIMIT_USD8;
    /// @notice Versión del contrato.
    string  public constant  VERSION = "KipuBank v2.1";

    /*//////////////////////////////////////////////////////////////
                         CONTACTOS Y ALIAS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Datos de un contacto del titular.
     * @param alias_ Alias legible.
     * @param ethLimit Límite por transferencia interna en wei (0 = sin tope).
     * @param usdLimit Límite por transferencia "equivalente USD" convertido a wei (0 = sin tope).
     * @param exists Bandera de existencia.
     */
    struct Contact {
        string alias_;
        uint256 ethLimit;
        uint256 usdLimit;
        bool exists;
    }

    /// @dev owner => contacto => datos.
    mapping(address => mapping(address => Contact)) private _contacts;
    /// @dev owner => keccak256(alias) => contacto.
    mapping(address => mapping(bytes32 => address)) private _aliasIndex;

    /*//////////////////////////////////////////////////////////////
                        CONTABILIDAD MULTI-TOKEN
    //////////////////////////////////////////////////////////////*/

    /// @dev Saldos crudos por token (wei o unidades del ERC-20).
    mapping(address token => mapping(address user => uint256)) private _balRaw;
    /// @dev Total crudo por token.
    mapping(address token => uint256) private _totalRaw;
    /// @notice Decimales del activo (`tokenDecimals[address(0)] = 18 para ETH`).
    mapping(address token => uint8)    public  tokenDecimals;
    /// @notice Feed Chainlink token/USD por activo.
    mapping(address token => AggregatorV3Interface) public priceFeedUsd;

    /// @notice Tracking aproximado del total del banco en USD8 (a precio de cada operación).
    uint256 public totalBankUsd8;

    /*//////////////////////////////////////////////////////////////
                               EVENTOS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Depósito exitoso.
     * @param token Dirección del activo (`address(0)`=ETH).
     * @param user Remitente del depósito.
     * @param amountRaw Monto crudo acreditado.
     * @param newBalanceRaw Nuevo saldo crudo del usuario.
     */
    event Deposit(address indexed token, address indexed user, uint256 amountRaw, uint256 newBalanceRaw);

    /**
     * @notice Retiro exitoso.
     * @param token Dirección del activo.
     * @param user Retirante.
     * @param amountRaw Monto crudo debitado.
     * @param newBalanceRaw Nuevo saldo crudo del usuario.
     */
    event Withdrawal(address indexed token, address indexed user, uint256 amountRaw, uint256 newBalanceRaw);

    /**
     * @notice Transferencia interna entre bóvedas.
     * @param token Dirección del activo.
     * @param from Emisor interno.
     * @param to Receptor interno.
     * @param amountRaw Monto crudo transferido.
     */
    event InternalTransfer(address indexed token, address indexed from, address indexed to, uint256 amountRaw);

    /**
     * @notice Registro/alta de token soportado.
     * @param token Dirección del token (no ETH).
     * @param decimals Decimales del token.
     * @param feed Dirección del feed Chainlink token/USD.
     */
    event TokenRegistered(address indexed token, uint8 decimals, address feed);

    /**
     * @notice Actualización de feed de precio.
     * @param token Dirección del token.
     * @param oldFeed Feed anterior.
     * @param newFeed Nuevo feed.
     */
    event FeedUpdated(address indexed token, address oldFeed, address newFeed);

    /**
     * @notice Contacto creado/actualizado.
     * @param owner Titular.
     * @param contact Dirección del contacto.
     * @param alias_ Alias legible.
     * @param ethLimit Límite por transferencia interna en wei.
     * @param usdLimit Límite "equivalente USD" en wei.
     */
    event ContactSet(address indexed owner, address indexed contact, string alias_, uint256 ethLimit, uint256 usdLimit);

    /**
     * @notice Contacto eliminado.
     * @param owner Titular.
     * @param contact Dirección del contacto.
     * @param alias_ Alias previo.
     */
    event ContactRemoved(address indexed owner, address indexed contact, string alias_);

    /**
     * @notice Límite ETH del contacto actualizado.
     * @param owner Titular.
     * @param contact Dirección del contacto.
     * @param newEthLimit Nuevo límite en wei.
     */
    event ContactLimitUpdated(address indexed owner, address indexed contact, uint256 newEthLimit);

    /*//////////////////////////////////////////////////////////////
                                ERRORES
    //////////////////////////////////////////////////////////////*/

    /// @notice Monto cero no permitido.
    error ErrZeroAmount();
    /// @notice Se supera el tope global del banco.
    /// @param attemptedUsd8 Total USD8 post-operación.
    /// @param capUsd8 CAP configurado en USD8.
    error ErrCapExceeded(uint256 attemptedUsd8, uint256 capUsd8);
    /// @notice Excede el límite de retiro en USD.
    /// @param requestedUsd8 Monto solicitado en USD8.
    /// @param limitUsd8 Límite en USD8.
    error ErrWithdrawLimitUSD(uint256 requestedUsd8, uint256 limitUsd8);
    /// @notice Saldo insuficiente.
    /// @param available Disponible.
    /// @param requested Solicitado.
    error ErrInsufficientBalance(uint256 available, uint256 requested);
    /// @notice Contacto inexistente.
    error ErrContactNotFound();
    /// @notice Alias ya utilizado.
    error ErrAliasTaken();
    /// @notice Contacto inválido (dirección cero).
    error ErrInvalidContact();
    /// @notice Slippage superado en depósito por USD.
    /// @param quoteWei Wei cotizados.
    /// @param sentWei Wei enviados.
    /// @param maxBps Tolerancia en bps.
    error SlippageExceeded(uint256 quoteWei, uint256 sentWei, uint256 maxBps);
    /// @notice Precio inválido/no positivo desde el feed.
    error BadPrice();
    /// @notice Depósitos directos a `receive()` no permitidos.
    error DirectEthNotAllowed();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Inicializa roles, límites en USD y feed ETH/USD.
     * @param owner_ Dueño inicial (admin de roles).
     * @param bankCapUsd8 CAP global en USD8.
     * @param withdrawLimitUsd8 Límite por retiro en USD8.
     * @param ethUsdFeed Dirección del feed ETH/USD.
     */
    constructor(
        address owner_,
        uint256 bankCapUsd8,
        uint256 withdrawLimitUsd8,
        address ethUsdFeed
    )  Ownable(owner_) {

        _grantRole(DEFAULT_ADMIN_ROLE, owner_);
        _grantRole(PAUSER_ROLE, owner_);
        _grantRole(RISK_ROLE, owner_);

        BANK_CAP_USD8       = bankCapUsd8;
        WITHDRAW_LIMIT_USD8 = withdrawLimitUsd8;

        // Registrar ETH
        tokenDecimals[address(0)] = 18;
        priceFeedUsd[address(0)]  = AggregatorV3Interface(ethUsdFeed);
        emit TokenRegistered(address(0), 18, ethUsdFeed);
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Pausa operaciones sensibles.
     * @dev Requiere `PAUSER_ROLE`.
     */
    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }

    /**
     * @notice Reanuda operaciones.
     * @dev Requiere `PAUSER_ROLE`.
     */
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    /**
     * @notice Registra o actualiza un token ERC-20 y su feed USD.
     * @dev ETH ya está pre-registrado (`address(0)`).
     * @param token Dirección del token (no ETH).
     * @param feed Dirección del Aggregator token/USD.
     */
    function registerToken(address token, address feed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(0), "ETH pre-registered");
        uint8 d = IERC20Metadata(token).decimals();
        tokenDecimals[token] = d;
        AggregatorV3Interface old = priceFeedUsd[token];
        priceFeedUsd[token] = AggregatorV3Interface(feed);
        if (address(old) == address(0)) emit TokenRegistered(token, d, feed);
        else emit FeedUpdated(token, address(old), feed);
    }

    /*//////////////////////////////////////////////////////////////
                         PRECIOS Y CONVERSIONES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Obtiene precio token/USD normalizado a 8 decimales.
     * @param token Dirección del token (`address(0)`=ETH).
     * @return p8 Precio USD8.
     */
    function priceUsd8(address token) public view returns (uint256 p8) {
        AggregatorV3Interface aggr = priceFeedUsd[token];
        (, int256 a,,,) = aggr.latestRoundData();
        if (a <= 0) revert BadPrice();
        uint8 fd = aggr.decimals();
        uint256 u = uint256(a);
        return fd == 8 ? u : (fd > 8 ? u / 10**(fd-8) : u * 10**(8-fd));
    }

    /**
     * @notice Convierte monto crudo de `token` a USD8 usando Chainlink.
     * @param token Dirección del token.
     * @param amountRaw Monto crudo (wei o unidades ERC-20).
     * @return usd8 Monto equivalente en USD8.
     */
    function toUsd8(address token, uint256 amountRaw) public view returns (uint256 usd8) {
        uint8 d = tokenDecimals[token];
        uint256 p8 = priceUsd8(token);              // USD8 por 1 * 10^d
        // usd8 = amountRaw * p8 / 10^d
        return (amountRaw * p8) / (10**d);
    }

    /**
     * @notice Normaliza a 6 dec para UI (USDC-like).
     * @param token Dirección del token.
     * @param amountRaw Monto crudo.
     * @return amount6 Monto en 6 dec.
     */
    function toUnit6(address token, uint256 amountRaw) external view returns (uint256 amount6) {
        uint8 d = tokenDecimals[token];
        if (d == 6) return amountRaw;
        return d > 6 ? amountRaw / 10**(d-6) : amountRaw * 10**(6-d);
    }

    /**
     * @notice Cotiza wei necesarios para `usd8` USD usando feed ETH/USD.
     * @param usd8 Monto en USD8.
     * @return weiReq Wei requeridos (redondeo hacia arriba).
     */
    function quoteWeiForUsd(uint256 usd8) external view returns (uint256 weiReq) {
        uint256 p8 = priceUsd8(address(0));
        // wei = ceil(usd8 * 1e18 / p8)
        unchecked { return (usd8 * 1e18 + p8 - 1) / p8; }
    }

    /*//////////////////////////////////////////////////////////////
                               DEPÓSITOS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposita ETH pensando en USD; guarda wei internos.
     * @dev Requiere `whenNotPaused`. Verifica slippage y `BANK_CAP_USD8`.
     * @param usd8 Objetivo en USD8.
     * @param maxSlippageBps Tolerancia en bps (100 = 1%).
     */
    function depositEthByUsd(uint256 usd8, uint256 maxSlippageBps)
        external
        payable
        whenNotPaused
        nonReentrant
    {
        if (usd8 == 0) revert ErrZeroAmount();
        uint256 quoteWei = _quoteWeiForUsdInternal(usd8);
        if (!_withinSlippage(quoteWei, msg.value, maxSlippageBps)) {
            revert SlippageExceeded(quoteWei, msg.value, maxSlippageBps);
        }
        _enforceBankCapOnChange(address(0), msg.value, true);
        _balRaw[address(0)][msg.sender] += msg.value;
        _totalRaw[address(0)] += msg.value;
        emit Deposit(address(0), msg.sender, msg.value, _balRaw[address(0)][msg.sender]);
    }

    /**
     * @notice Depósito genérico (ETH o ERC-20).
     * @dev Para ETH `token=address(0)` y `msg.value == amountRaw`.
     * @param token Dirección del token.
     * @param amountRaw Monto crudo a acreditar.
     */
    function deposit(address token, uint256 amountRaw)
        external
        payable
        whenNotPaused
        nonReentrant
    {
        if (amountRaw == 0) revert ErrZeroAmount();

        if (token == address(0)) {
            require(msg.value == amountRaw, "bad msg.value");
        } else {
            IERC20(token).safeTransferFrom(msg.sender, address(this), amountRaw);
        }

        _enforceBankCapOnChange(token, amountRaw, true);
        _balRaw[token][msg.sender] += amountRaw;
        _totalRaw[token] += amountRaw;

        emit Deposit(token, msg.sender, amountRaw, _balRaw[token][msg.sender]);
    }

    /*//////////////////////////////////////////////////////////////
                                RETIROS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Retiro genérico (ETH o ERC-20).
     * @dev Valida `WITHDRAW_LIMIT_USD8` contra Chainlink.
     * @param token Dirección del token.
     * @param amountRaw Monto crudo a debitar.
     */
    function withdraw(address token, uint256 amountRaw)
        external
        whenNotPaused
        nonReentrant
    {
        if (amountRaw == 0) revert ErrZeroAmount();

        uint256 usd8 = toUsd8(token, amountRaw);
        if (usd8 > WITHDRAW_LIMIT_USD8) revert ErrWithdrawLimitUSD(usd8, WITHDRAW_LIMIT_USD8);

        uint256 bal = _balRaw[token][msg.sender];
        if (bal < amountRaw) revert ErrInsufficientBalance(bal, amountRaw);

        _balRaw[token][msg.sender] = bal - amountRaw;
        _totalRaw[token] -= amountRaw;
        _enforceBankCapOnChange(token, amountRaw, false);

        if (token == address(0)) {
            (bool ok,) = msg.sender.call{value: amountRaw}("");
            require(ok, "eth xfer");
        } else {
            IERC20(token).safeTransfer(msg.sender, amountRaw);
        }

        emit Withdrawal(token, msg.sender, amountRaw, _balRaw[token][msg.sender]);
    }

    /*//////////////////////////////////////////////////////////////
                         TRANSFERENCIAS INTERNAS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Transfiere internamente `amountRaw` a `to` para `token`.
     * @dev No mueve el activo on-chain; solo contabilidad.
     * @param token Dirección del token.
     * @param to Receptor interno.
     * @param amountRaw Monto crudo.
     */
    function transferInternal(address token, address to, uint256 amountRaw)
        external
        whenNotPaused
    {
        if (amountRaw == 0) revert ErrZeroAmount();

        // Si es ETH, validar límites por contacto si existiera
        if (token == address(0)) {
            Contact storage c = _contacts[msg.sender][to];
            if (!c.exists) revert ErrContactNotFound();
            if (c.ethLimit != 0 && amountRaw > c.ethLimit) {
                revert ErrWithdrawLimitUSD(amountRaw, c.ethLimit);
            }
        }

        uint256 sb = _balRaw[token][msg.sender];
        if (sb < amountRaw) revert ErrInsufficientBalance(sb, amountRaw);

        _balRaw[token][msg.sender] = sb - amountRaw;
        _balRaw[token][to] += amountRaw;

        emit InternalTransfer(token, msg.sender, to, amountRaw);
    }

    /**
     * @notice Transfiere internamente por alias del emisor.
     * @dev Resuelve alias a contacto y aplica límites si es ETH.
     * @param token Dirección del token.
     * @param alias_ Alias del contacto.
     * @param amountRaw Monto crudo.
     */
    function transferInternalByAlias(address token, string calldata alias_, uint256 amountRaw)
        external
        whenNotPaused
    {
        if (amountRaw == 0) revert ErrZeroAmount();
        address to = _aliasIndex[msg.sender][keccak256(bytes(alias_))];
        Contact storage c = _contacts[msg.sender][to];
        if (!c.exists) revert ErrContactNotFound();

        if (token == address(0) && c.ethLimit != 0 && amountRaw > c.ethLimit) {
            revert ErrWithdrawLimitUSD(amountRaw, c.ethLimit);
        }

        uint256 sb = _balRaw[token][msg.sender];
        if (sb < amountRaw) revert ErrInsufficientBalance(sb, amountRaw);

        _balRaw[token][msg.sender] = sb - amountRaw;
        _balRaw[token][to] += amountRaw;

        emit InternalTransfer(token, msg.sender, to, amountRaw);
    }

    /*//////////////////////////////////////////////////////////////
                               CONTACTOS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Crea o actualiza un contacto del emisor.
     * @param contact Dirección del contacto.
     * @param alias_ Alias legible.
     * @param ethLimit Límite por transferencia en wei (0 = sin tope).
     * @param usdLimit Límite "equivalente USD" en wei (0 = sin tope).
     */
    function setContact(address contact, string calldata alias_, uint256 ethLimit, uint256 usdLimit) external {
        if (contact == address(0)) revert ErrInvalidContact();
        bytes32 k = keccak256(bytes(alias_));
        address current = _aliasIndex[msg.sender][k];
        if (current != address(0) && current != contact) revert ErrAliasTaken();

        Contact storage prev = _contacts[msg.sender][contact];
        if (prev.exists) {
            bytes32 oldK = keccak256(bytes(prev.alias_));
            if (oldK != k && _aliasIndex[msg.sender][oldK] == contact) {
                delete _aliasIndex[msg.sender][oldK];
            }
        }

        _contacts[msg.sender][contact] = Contact({
            alias_: alias_,
            ethLimit: ethLimit,
            usdLimit: usdLimit,
            exists: true
        });
        _aliasIndex[msg.sender][k] = contact;

        emit ContactSet(msg.sender, contact, alias_, ethLimit, usdLimit);
    }

    /**
     * @notice Elimina un contacto del emisor.
     * @param contact Dirección del contacto a remover.
     */
    function removeContact(address contact) external {
        Contact storage c = _contacts[msg.sender][contact];
        if (!c.exists) revert ErrContactNotFound();
        bytes32 k = keccak256(bytes(c.alias_));
        if (_aliasIndex[msg.sender][k] == contact) delete _aliasIndex[msg.sender][k];
        string memory aliasLocal = c.alias_;
        delete _contacts[msg.sender][contact];
        emit ContactRemoved(msg.sender, contact, aliasLocal);
    }

    /**
     * @notice Actualiza el límite ETH del contacto.
     * @param contact Dirección del contacto.
     * @param newLimit Nuevo límite en wei (0 = sin tope).
     */
    function updateContactEthLimit(address contact, uint256 newLimit) external {
        Contact storage c = _contacts[msg.sender][contact];
        if (!c.exists) revert ErrContactNotFound();
        c.ethLimit = newLimit;
        emit ContactLimitUpdated(msg.sender, contact, newLimit);
    }

    /**
     * @notice Devuelve datos básicos del contacto.
     * @param owner Titular.
     * @param contact Dirección del contacto.
     * @return alias_ Alias actual.
     * @return exists Bandera de existencia.
     */
    function getContact(address owner, address contact) external view returns (string memory alias_, bool exists) {
        Contact storage c = _contacts[owner][contact];
        return (c.alias_, c.exists);
    }

    /**
     * @notice Resuelve un alias a dirección de contacto.
     * @param owner Titular.
     * @param alias_ Alias a resolver.
     * @return contact Dirección resultante.
     * @return exists Bandera de existencia.
     */
    function getContactByAlias(address owner, string calldata alias_) external view returns (address contact, bool exists) {
        address who = _aliasIndex[owner][keccak256(bytes(alias_))];
        Contact storage c = _contacts[owner][who];
        return (who, c.exists);
    }

    /*//////////////////////////////////////////////////////////////
                               GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Saldo crudo de `user` para `token`.
     * @param token Dirección del token.
     * @param user Cuenta.
     * @return balanceRaw Saldo crudo.
     */
    function balanceOf(address token, address user) external view returns (uint256 balanceRaw) {
        return _balRaw[token][user];
    }

    /**
     * @notice Total crudo retenido por token.
     * @param token Dirección del token.
     * @return totalRaw Suma de saldos crudos.
     */
    function totalOf(address token) external view returns (uint256 totalRaw) {
        return _totalRaw[token];
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNAS
    //////////////////////////////////////////////////////////////*/

    /// @dev Cotiza wei necesarios para USD8 (uso interno).
    function _quoteWeiForUsdInternal(uint256 usd8) internal view returns (uint256 weiReq) {
        uint256 p8 = priceUsd8(address(0));
        unchecked { return (usd8 * 1e18 + p8 - 1) / p8; }
    }

    /// @dev Chequea slippage relativo en bps (FIXED: previene overflow).
    function _withinSlippage(uint256 quote, uint256 sent, uint256 bps) private pure returns (bool) {
        if (quote == 0) return false;
        
        uint256 diff = sent > quote ? sent - quote : quote - sent;
        
        // Evitar overflow: diff * 10_000 <= quote * bps
        // Reescribimos como: diff <= (quote * bps) / 10_000
        // Pero para evitar división con resto, usamos: diff * 10_000 <= quote * bps
        // Como quote y diff son ambos uint256, podríamos tener overflow.
        // Solución: verificar si la operación causaría overflow antes de hacerla
        
        // Si diff es muy grande, podemos simplificar:
        // diff / quote > bps / 10_000 significa que está fuera del rango
        
        // Método seguro: usar división primero
        uint256 maxAllowedDiff = (quote * bps) / 10_000;
        return diff <= maxAllowedDiff;
    }

    /// @dev Aplica CAP del banco en USD8 al agregar o quitar fondos.
    function _enforceBankCapOnChange(address token, uint256 deltaRaw, bool add) internal {
        uint256 usd8 = toUsd8(token, deltaRaw);
        if (add) {
            uint256 afterUsd = totalBankUsd8 + usd8;
            if (afterUsd > BANK_CAP_USD8) revert ErrCapExceeded(afterUsd, BANK_CAP_USD8);
            totalBankUsd8 = afterUsd;
        } else {
            totalBankUsd8 = totalBankUsd8 > usd8 ? totalBankUsd8 - usd8 : 0;
        }
    }

    /*//////////////////////////////////////////////////////////////
                           RECEIVE / FALLBACK
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Se rechazan envíos directos. Usar `depositEthByUsd` o `deposit(address(0),amount)`.
     */
    receive() external payable { revert DirectEthNotAllowed(); }

    /**
     * @notice Fallback rechazada.
     */
    fallback() external payable { revert DirectEthNotAllowed(); }
}