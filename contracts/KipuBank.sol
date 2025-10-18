// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title KipuBank
 * @author -
 * @notice Simple vault-like bank donde usuarios depositan ETH en bóvedas personales.
 * @dev Implementa buenas prácticas: errores personalizados, checks-effects-interactions,
 *      transferencias nativas seguras, modificadores y NatSpec.
 * @custom:dev-run-script scripts/deploy_with_ethers.ts
 */
contract KipuBank is Ownable2Step {
    /* ========== CONSTANTS & IMMUTABLES ========== */
    uint256 public immutable WITHDRAW_LIMIT;
    uint256 public immutable BANK_CAP;
    string public constant VERSION = "KipuBank v2";

    /* ========== STRUCTS ========== */
    struct Contact {
        string alias_;
        uint256 limit;
        bool exists;
    }

    /* ========== MAPPINGS ========== */
    mapping(address => mapping(address => Contact)) private _contacts; // owner => contacto => datos
    mapping(address => mapping(bytes32 => address)) private _aliasIndex; // owner => hash(alias) => contacto
    mapping(address => address[]) private _contactList;
    mapping(address => uint256) private _balances;

    /* ========== STATE ========== */
    uint256 private _totalVaultBalance;
    uint256 public depositCount;
    uint256 public withdrawCount;
    bool private isPaused;

    /* ========== EVENTS ========== */
    event Deposit(address indexed user, uint256 amount, uint256 newBalance);
    event Withdrawal(address indexed user, uint256 amount, uint256 newBalance);
    event ContactSet(
        address indexed owner,
        address indexed contact,
        string alias_,
        uint256 limit
    );
    event ContactLimitUpdated(
        address indexed owner,
        address indexed contact,
        uint256 newLimit
    );
    event ContactRemoved(
        address indexed owner,
        address indexed contact,
        string alias_
    );
    event InternalTransfer(
        address indexed from,
        address indexed to,
        uint256 amount
    );

    /* ========== ERRORS ========== */
    error ErrZeroDeposit();
    error ErrBankCapExceeded(uint256 attempted, uint256 available);
    error ErrInsufficientBalance(uint256 available, uint256 requested);
    error ErrWithdrawLimitExceeded(uint256 limit, uint256 requested);
    error ErrNativeTransferFailed();
    error ErrPaused();
    error ErrInvalidContact();
    error ErrContactNotFound();
    error ErrAliasTaken();

    /* ========== MODIFIERS ========== */
    modifier positive(uint256 amount) {
        if (amount == 0) revert ErrZeroDeposit();
        _;
    }

    /* ========== CONSTRUCTOR ========== */
    /// @param initialOwner dueño inicial que deberá aceptar si se usa transferOwnership luego
    /// @param withdrawLimit límite por retiro
    /// @param bankCap tope global del banco
    constructor(
        address initialOwner,
        uint256 withdrawLimit,
        uint256 bankCap
    ) Ownable(initialOwner) {
        require(initialOwner != address(0), "owner is zero");
        require(withdrawLimit > 0, "withdrawLimit must be > 0");
        require(bankCap > 0, "bankCap must be > 0");

        _transferOwnership(initialOwner); // Ownable2Step

        WITHDRAW_LIMIT = withdrawLimit;
        BANK_CAP = bankCap;
        isPaused = false;
    }

    /* ========== EXTERNAL & PUBLIC FUNCTIONS ========== */
    function deposit() external payable positive(msg.value) {
        uint256 amount = msg.value;
        uint256 available = BANK_CAP - _totalVaultBalance;
        if (isPaused) revert ErrPaused();
        if (amount > available) revert ErrBankCapExceeded(amount, available);

        _balances[msg.sender] += amount;
        _totalVaultBalance += amount;
        _incrementDepositCount();

        emit Deposit(msg.sender, amount, _balances[msg.sender]);
    }

    function withdraw(uint256 amount) external positive(amount) {
        if (amount > WITHDRAW_LIMIT)
            revert ErrWithdrawLimitExceeded(WITHDRAW_LIMIT, amount);

        uint256 userBalance = _balances[msg.sender];
        if (userBalance < amount)
            revert ErrInsufficientBalance(userBalance, amount);

        _balances[msg.sender] = userBalance - amount;
        _totalVaultBalance -= amount;
        _incrementWithdrawCount();

        _safeTransfer(payable(msg.sender), amount);

        emit Withdrawal(msg.sender, amount, _balances[msg.sender]);
    }

    // setear/actualizar contacto con límite
    function setContact(
        address contact,
        string calldata alias_,
        uint256 limit
    ) external {
        if (contact == address(0)) revert ErrInvalidContact();
        bytes32 k = _aliasKey(alias_);
        address current = _aliasIndex[msg.sender][k];
        if (current != address(0) && current != contact) revert ErrAliasTaken();

        Contact storage prev = _contacts[msg.sender][contact];
        if (prev.exists) {
            bytes32 oldK = _aliasKey(prev.alias_);
            if (oldK != k && _aliasIndex[msg.sender][oldK] == contact)
                delete _aliasIndex[msg.sender][oldK];
        }

        _contacts[msg.sender][contact] = Contact({
            alias_: alias_,
            limit: limit,
            exists: true
        });
        _aliasIndex[msg.sender][k] = contact;
        emit ContactSet(msg.sender, contact, alias_, limit);
    }

    function updateContactLimit(address contact, uint256 newLimit) external {
        Contact storage c = _contacts[msg.sender][contact];
        if (!c.exists) revert ErrContactNotFound();
        c.limit = newLimit;
        emit ContactLimitUpdated(msg.sender, contact, newLimit);
    }

    // transferencia interna por contacto
    function transferToContact(
        address contact,
        uint256 amount
    ) external positive(amount) {
        Contact storage c = _contacts[msg.sender][contact];
        if (!c.exists) revert ErrContactNotFound();
        if (c.limit != 0 && amount > c.limit)
            revert ErrWithdrawLimitExceeded(c.limit, amount); // reutilizo error
        uint256 sb = _balances[msg.sender];
        if (sb < amount) revert ErrInsufficientBalance(sb, amount);

        _balances[msg.sender] = sb - amount;
        _balances[contact] += amount;
        emit InternalTransfer(msg.sender, contact, amount);
    }

    // transferencia interna por alias
    function transferToAlias(
        string calldata alias_,
        uint256 amount
    ) external positive(amount) {
        address contact = _aliasIndex[msg.sender][_aliasKey(alias_)];
        Contact storage c = _contacts[msg.sender][contact];
        if (!c.exists) revert ErrContactNotFound();
        if (c.limit != 0 && amount > c.limit)
            revert ErrWithdrawLimitExceeded(c.limit, amount);
        uint256 sb = _balances[msg.sender];
        if (sb < amount) revert ErrInsufficientBalance(sb, amount);

        _balances[msg.sender] = sb - amount;
        _balances[contact] += amount;
        emit InternalTransfer(msg.sender, contact, amount);
    }

    function removeContact(address contact) external {
        Contact storage c = _contacts[msg.sender][contact];
        if (!c.exists) revert ErrContactNotFound();
        bytes32 k = _aliasKey(c.alias_);
        if (_aliasIndex[msg.sender][k] == contact)
            delete _aliasIndex[msg.sender][k];
        string memory aliasLocal = c.alias_;
        delete _contacts[msg.sender][contact];
        emit ContactRemoved(msg.sender, contact, aliasLocal);
    }

    function getContact(
        address owner,
        address contact
    ) external view returns (string memory alias_, bool exists) {
        Contact storage c = _contacts[owner][contact];
        return (c.alias_, c.exists);
    }

    function getContactByAlias(
        address owner,
        string calldata alias_
    ) external view returns (address contact, bool exists) {
        address who = _aliasIndex[owner][_aliasKey(alias_)];
        Contact storage c = _contacts[owner][who];
        return (who, c.exists);
    }

    function getVaultBalance(address user) external view returns (uint256) {
        return _balances[user];
    }

    function getBankTotalBalance() external view returns (uint256) {
        return _totalVaultBalance;
    }

    /* ========== PRIVATE ========== */
    function _incrementDepositCount() private {
        depositCount += 1;
    }
    function _incrementWithdrawCount() private {
        withdrawCount += 1;
    }

    function _safeTransfer(address payable to, uint256 amount) private {
        (bool success, ) = to.call{value: amount}("");
        if (!success) revert ErrNativeTransferFailed();
    }

    function _aliasKey(string memory a) private pure returns (bytes32) {
        return keccak256(bytes(a));
    }

    /* ========== RECEIVE / FALLBACK ========== */
    receive() external payable {
        revert ErrZeroDeposit();
    }
    fallback() external payable {
        revert ErrZeroDeposit();
    }
}
