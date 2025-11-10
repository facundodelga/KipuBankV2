# KipuBankV3 🏦

Un contrato bancario descentralizado DeFi que acepta cualquier token soportado por Uniswap V2, lo intercambia automáticamente a USDC y acredita el balance del usuario. Respeta límites de capacidad del banco y mantiene todas las funcionalidades de seguridad de versiones anteriores.

## 🌟 Características Principales

### ✨ Integración con Uniswap V2
- **Swaps Automáticos**: Intercambia automáticamente cualquier token ERC20 a USDC mediante Uniswap V2
- **Soporte Multi-Token**: Acepta ETH, USDC y cualquier token con par directo a USDC en Uniswap V2
- **Gestión de Slippage**: Control de slippage configurable con tolerancia por defecto del 0.5%

### 🔒 Seguridad y Control
- **ReentrancyGuard**: Protección contra ataques de reentrancia en todas las operaciones
- **AccessControl**: Sistema de roles para administración granular
- **Pausable**: Capacidad de pausar operaciones en emergencias
- **SafeERC20**: Uso de SafeERC20 para transferencias seguras de tokens

### 💰 Gestión de Fondos
- **Bank Cap**: Límite global de depósitos totales en USD
- **Límite Diario por Usuario**: Control de retiros máximos por usuario en ventanas de 24 horas
- **Price Feeds**: Integración con Chainlink para precios en tiempo real

### 🎯 Funcionalidades
- **Depósitos**: ETH, USDC directo, o cualquier token ERC20 (con swap a USDC)
- **Retiros**: USDC directo o intercambio a cualquier token permitido
- **Allowlist de Tokens**: Control administrativo de tokens permitidos para swaps

## 📋 Requisitos

- Solidity ^0.8.30
- OpenZeppelin Contracts ^5.5.0
- Foundry (para desarrollo y testing)
- Uniswap V2 Router (en la red destino)
- Chainlink Price Feed para USDC/USD

## 🔧 Instalación

### 1. Clonar el Repositorio

```bash
git clone https://github.com/tu-usuario/KipuBankV3.git
cd KipuBankV3
```

### 2. Instalar Dependencias

#### Opción A: Usando Foundry (Recomendado)

```bash
# Instalar Foundry (si no está instalado)
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Instalar dependencias
forge install foundry-rs/forge-std --no-commit
forge install Uniswap/v2-periphery --no-commit
forge install Uniswap/v2-core --no-commit
forge install smartcontractkit/chainlink-brownie-contracts --no-commit
```

#### Opción B: Usando Scripts

**Windows:**
```bash
install_dependencies.bat
```

**Linux/Mac:**
```bash
chmod +x install_dependencies.sh
./install_dependencies.sh
```

### 3. Configurar Variables de Entorno

Copia el archivo `.env.example` a `.env` y configura las variables:

```bash
cp .env.example .env
```

Edita `.env` con tus valores:
- `SEPOLIA_RPC_URL`: URL del RPC de Sepolia
- `ETHERSCAN_API_KEY`: API key de Etherscan para verificación

## 🚀 Despliegue

### Desplegar en Sepolia Testnet

```bash
# Configurar variables de entorno
export SEPOLIA_RPC_URL=https://rpc.sepolia.org
export ETHERSCAN_API_KEY=tu_api_key

# Desplegar contrato
forge verify-contract \
  --rpc-url sepolia \
  --chain-id 11155111 \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  <DIRECCION_DEL_CONTRATO> contracts/KipuBank.sol:KipuBankV3

# Configurar tokens permitidos
forge script script/Setup.s.sol:SetupKipuBankV3 \
  --rpc-url sepolia \
  --account deployer \
  --sender <TU_DIRECCION> \
  --chain-id 11155111 \
  --broadcast \
  -vvvv
```

### Parámetros de Deployment

El constructor de `KipuBankV3` requiere los siguientes parámetros:

```solidity
constructor(
    uint256 _bankCapUSD,              // Límite total del banco en USD (6 decimales)
    address _usdcAddress,              // Dirección del token USDC
    address _uniswapRouter,            // Dirección del router de Uniswap V2
    address _usdcPriceFeed,            // Dirección del price feed de Chainlink (USDC/USD)
    uint256 _perUserDailyWithdrawLimitUSD  // Límite diario de retiro por usuario (6 decimales, 0 = sin límite)
)
```

### Ejemplo de Deployment

```solidity
KipuBankV3 bank = new KipuBankV3(
    10_000_000e6,        // bankCapUSD: 10M USD
    0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238,  // USDC en Sepolia
    0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008,  // Uniswap V2 Router en Sepolia
    0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E,  // Chainlink USDC/USD feed
    1_000_000e6          // límite diario: 1M USD por usuario
);
```

## 💻 Uso

### Depósito de ETH

```solidity
// Depósito simple (con slippage por defecto y deadline de 5 minutos)
bank.depositETH{value: 1 ether}();

// Depósito con parámetros personalizados
bank.depositETH(minUSDC, deadline);
```

### Depósito de USDC Directo

```solidity
// Aprobar tokens
usdc.approve(address(bank), 1000e6);

// Depositar
bank.depositToken(address(usdc), 1000e6);
```

### Depósito de Token ERC20 (con Swap a USDC)

```solidity
// 1. El token debe estar permitido (solo admin puede hacerlo)
// bank.setAllowedForSwap(tokenAddress, true);

// 2. Aprobar tokens
token.approve(address(bank), 100 ether);

// 3. Depositar (swap automático a USDC)
bank.depositToken(address(token), 100 ether);

// O con parámetros personalizados
bank.depositToken(address(token), 100 ether, minUSDC, deadline);
```

### Retiro de USDC

```solidity
// Retirar USDC directo
bank.withdrawUSDC(500e6);
```

### Retiro como Otro Token

```solidity
// Retirar balance en USDC pero recibir otro token
bank.withdrawAsToken(tokenAddress, usdcAmount);

// O con parámetros personalizados
bank.withdrawAsToken(tokenAddress, usdcAmount, minOut, deadline);
```

### Consultas

```solidity
// Balance de USDC del usuario
uint256 balance = bank.getUserUSDCBalance(userAddress);

// Capacidad disponible del banco
uint256 capacity = bank.getAvailableCapacity();

// Límite restante de retiro diario
uint256 remaining = bank.getRemainingWithdrawLimitUSD(userAddress);
```

## 🧪 Testing

### Ejecutar Tests Locales

```bash
# Todos los tests
forge test

# Tests específicos
forge test --match-test test_DepositUSDC

# Con verbosidad
forge test -vvv
```

### Tests Principales

- ✅ `test_DepositUSDC`: Depósito directo de USDC
- ✅ `test_DepositETH_ToUSDC`: Depósito de ETH con swap a USDC (requiere fork)
- ✅ `test_WithdrawUSDC`: Retiro de USDC
- ✅ `test_BankCap`: Verificación de límite del banco
- ✅ `test_WithdrawLimit`: Verificación de límite diario de retiro
- ✅ `test_Pause`: Funcionalidad de pausa
- ✅ `test_AccessControl`: Control de acceso y roles

## 📊 Arquitectura

### Flujo de Depósito

1. **Usuario aprueba tokens** (si es necesario)
2. **Contrato valida límite de capacidad** (bankCap)
3. **Si es token diferente a USDC**: 
   - Obtiene cotización de Uniswap V2
   - Realiza swap automático a USDC
4. **Acredita balance en USDC** al usuario
5. **Actualiza totalDepositedUSD**
6. **Emite evento `Deposit`**

### Flujo de Retiro

1. **Validación de balance suficiente**
2. **Verificación de límite diario** (si está configurado)
3. **Si es retiro en USDC**:
   - Transfiere USDC directamente
4. **Si es retiro en otro token**:
   - Realiza swap de USDC a token destino
   - Transfiere token al usuario
5. **Actualiza balances y límites**
6. **Emite evento `Withdrawal`**

## 🔐 Seguridad

### Mecanismos Implementados

- ✅ **ReentrancyGuard**: Protección contra reentrancia en todas las funciones críticas
- ✅ **SafeERC20**: Uso de SafeERC20 para transferencias seguras
- ✅ **Checks-Effects-Interactions**: Patrón aplicado en todas las operaciones
- ✅ **AccessControl**: Sistema de roles para operaciones privilegiadas
- ✅ **Pausable**: Capacidad de pausar en emergencias
- ✅ **Validaciones de Límites**: Verificación de bankCap y límites diarios antes de operaciones
- ✅ **Deadline Validation**: Validación de deadlines en swaps
- ✅ **Slippage Protection**: Protección contra slippage excesivo

### Consideraciones de Seguridad

1. **Aprobaciones de Tokens**: Los usuarios deben aprobar tokens antes de depositar
2. **Allowlist de Tokens**: Solo tokens permitidos por admin pueden ser intercambiados
3. **Price Feed Staleness**: Validación de que el price feed no esté desactualizado (>24 horas)
4. **Bank Cap**: El banco nunca puede exceder el límite configurado
5. **Límites Diarios**: Previene retiros masivos y abusos

## 🛠️ Administración

### Funciones de Admin

```solidity
// Permitir/deshabilitar token para swaps
function setAllowedForSwap(address token, bool allowed) external onlyRole(ADMIN_ROLE);

// Actualizar límite diario de retiro
function setPerUserDailyWithdrawLimitUSD(uint256 newLimitUSD) external onlyRole(ADMIN_ROLE);

// Actualizar price feed
function updateUsdcPriceFeed(address newFeed) external onlyRole(ADMIN_ROLE);

// Pausar/despausar contrato
function pause() external onlyRole(ADMIN_ROLE);
function unpause() external onlyRole(ADMIN_ROLE);
```

## 📝 Licencia

MIT

## 🤝 Contribuciones

Las contribuciones son bienvenidas. Por favor:

1. Fork el proyecto
2. Crea una rama para tu feature (`git checkout -b feature/AmazingFeature`)
3. Commit tus cambios (`git commit -m 'Add some AmazingFeature'`)
4. Push a la rama (`git push origin feature/AmazingFeature`)
5. Abre un Pull Request

## 📞 Contacto

- **Proyecto**: [KipuBankV3](https://github.com/tu-usuario/KipuBankV3)

## 🌐 Block Explorer

Una vez desplegado, puedes verificar el contrato en el block explorer:

### Sepolia Testnet
- **Etherscan**: https://sepolia.etherscan.io/address/[CONTRACT_ADDRESS]
- **Blockscout**: https://sepolia.blockscout.com/address/[CONTRACT_ADDRESS]

### Ejemplo de Contrato Verificado
```
Dirección: [ACTUALIZAR CON DIRECCIÓN DESPLEGADA]
Explorer: [ACTUALIZAR CON ENLACE AL EXPLORER]
```

## ✅ Checklist de Deployment

- [ ] Instalar dependencias
- [ ] Configurar variables de entorno
- [ ] Desplegar contrato en testnet
- [ ] Verificar contrato en Etherscan
- [ ] Configurar tokens permitidos
- [ ] Probar depósitos y retiros
- [ ] Verificar límites y seguridad
- [ ] Documentar direcciones de contratos

## 📚 Referencias

- [Uniswap V2 Documentation](https://docs.uniswap.org/protocol/V2/introduction)
- [Chainlink Price Feeds](https://docs.chain.link/data-feeds/price-feeds)
- [OpenZeppelin Contracts](https://docs.openzeppelin.com/contracts)
- [Foundry Documentation](https://book.getfoundry.sh/)

---

**⚠️ ADVERTENCIA**: Este contrato es para fines educativos y de prueba. Siempre realiza auditorías de seguridad antes de usar en producción.
