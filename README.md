# KipuBankV2 🏦

Un contrato bancario descentralizado multi-token con soporte para ETH y tokens ERC20, controlado por límites de depósito y retiro expresados en USD.

## 🌟 Características Principales

- **Multi-token Support**: Gestiona ETH y múltiples tokens ERC20 simultáneamente
- **Límites en USD**: Control de depósitos y retiros basado en valor en dólares
- **Integración Chainlink**: Precios en tiempo real mediante oráculos
- **Sistema de Roles**: Control de acceso granular con `AccessControl`
- **Pausable**: Capacidad de pausar operaciones en situaciones de emergencia
- **Mock Oracles**: Soporte para testing local sin dependencias externas

## 🚀 Mejoras Implementadas

### 1. Límite Diario por Usuario
Control de retiros máximos en USD por usuario en ventanas de 24 horas:
- ✅ Previene abusos y fugas masivas de fondos
- ✅ Control granular del riesgo operativo
- ✅ Configurable por administrador

### 2. Control de Capacidad del Banco
Límite global (`bankCapUSD`) de depósitos totales:
- ✅ Evita sobrecarga de activos
- ✅ Mantiene liquidez controlada
- ✅ Gestión de riesgo sistémico

### 3. Conversión Dinámica a USD
Implementación de `_convertToUSD()` con soporte para feeds Chainlink:
- ✅ Compatibilidad con feeds de 8 decimales
- ✅ Normalización automática según decimales del token
- ✅ Valores en USD con 6 decimales de precisión

### 4. Mocks para Testing
`MockAggregator` y `MockERC20` incluidos:
- ✅ Testing local y determinista
- ✅ Sin dependencias de redes externas
- ✅ Desarrollo ágil

### 5. Sistema de Seguridad
Roles y pausas para operaciones críticas:
- `ADMIN_ROLE`: Control total del contrato
- `OPERATOR_ROLE`: Operaciones específicas
- Funcionalidad de pausa de emergencia

## 📋 Requisitos

- Solidity ^0.8.30
- OpenZeppelin Contracts
- Chainlink Price Feeds (o mocks equivalentes)

## 🔧 Instalación
```bash
# Clonar el repositorio
git clone https://github.com/tu-usuario/KipuBankV2.git
cd KipuBankV2

# Instalar dependencias
npm install
```

## 🚀 Despliegue

### 1. Desplegar Contratos Mock (Testing)
```solidity
// Desplegar oráculo mock
MockAggregator mockOracle = new MockAggregator(8, 1e8); // $1.00 USD

// Desplegar token mock (opcional)
MockERC20 token = new MockERC20("MockToken", "MKT", 18);
token.mint(YOUR_WALLET, 5_000_000 ether);
```

### 2. Desplegar KipuBankV2
```solidity
KipuBankV2 bank = new KipuBankV2(
    10_000_000e6,        // bankCapUSD: 10M USD con 6 decimales
    address(mockOracle), // feed ETH/USD
    1_000_000e6          // límite diario: 1M USD por usuario
);
```

### 3. Registrar Tokens Adicionales
```solidity
bank.addToken(
    address(token),      // dirección del token ERC20
    address(mockOracle), // feed de precio del token
    18                   // decimales del token
);
```

## 💻 Uso

### Depósito de Tokens ERC20
```solidity
// Aprobar el token
token.approve(address(bank), 100 ether);

// Depositar
bank.depositToken(address(token), 100 ether);
```

### Depósito de ETH
```solidity
bank.depositETH{value: 1 ether}();
```

### Retiro de Tokens
```solidity
// Retirar ERC20
bank.withdrawToken(address(token), 50 ether);

// Retirar ETH
bank.withdrawETH(0.5 ether);
```

### Consultas
```solidity
// Valor en USD de un monto
uint256 valueUSD = bank.getValueInUSD(address(token), 1 ether);

// Límite restante de retiro diario
uint256 remaining = bank.getRemainingWithdrawLimitUSD(msg.sender);

// Balance de un usuario
uint256 balance = bank.getBalance(address(token), userAddress);
```

### Flujo de Depósito

1. Usuario aprueba tokens
2. Contrato valida límite de capacidad
3. Transferencia de tokens
4. Actualización de balances
5. Emisión de evento `Deposit`

### Flujo de Retiro

1. Validación de balance suficiente
2. Verificación de límite diario
3. Actualización de límites y balances
4. Transferencia de tokens/ETH
5. Emisión de evento `Withdrawal`

## ⚖️ Decisiones de Diseño

### Escala Estándar de Chainlink (8 decimales)
- ✅ **Pro**: Compatibilidad total con feeds reales
- ⚠️ **Trade-off**: Complejidad en testing con valores mock

### USD con 6 Decimales
- ✅ **Pro**: Simplifica cálculos y almacenamiento
- ⚠️ **Trade-off**: Pequeña pérdida de precisión en montos muy bajos

### Patrón Transfer-First
- ✅ **Pro**: Seguridad (revert si transferencia falla)
- ⚠️ **Trade-off**: Requiere aprobación previa del usuario

### AccessControl vs Ownable
- ✅ **Pro**: Jerarquía flexible y delegación de permisos
- ⚠️ **Trade-off**: Mayor complejidad en gestión

### Oráculos Mock
- ✅ **Pro**: Testing local sin dependencias externas
- ⚠️ **Trade-off**: No reflejan volatilidad real

## 🔐 Seguridad

- ✅ ReentrancyGuard en todas las operaciones de transferencia
- ✅ Checks-Effects-Interactions pattern
- ✅ Sistema de roles para operaciones privilegiadas
- ✅ Pausable para emergencias
- ✅ Validaciones de límites antes de operaciones

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

- **Proyecto**: [KipuBankV2](https://github.com/facundodelga/KipuBankV2)

## ✅ Verificaciones
KipuBank: 0xd431daA7a264d5603C1Cc362da77f643cc421846

https://sepolia.etherscan.io/address/0xd431daA7a264d5603C1Cc362da77f643cc421846#code

TOKEN: 0xc2c96a14dfca9e5839675bfb0b0134c2843c2542

https://sepolia.etherscan.io/address/0xC2c96a14dfca9E5839675bfB0b0134C2843c2542#code

Mock de feed: 0x459560a22c35b7A945Bd9244c1A724C1Fcb3A474

https://sepolia.etherscan.io/address/0x459560a22c35b7A945Bd9244c1A724C1Fcb3A474#code
