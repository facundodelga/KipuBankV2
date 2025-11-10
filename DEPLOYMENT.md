# Guía de Deployment de KipuBankV3

Esta guía te ayudará a desplegar KipuBankV3 en una testnet (Sepolia) paso a paso.

## Prerrequisitos

1. **Foundry instalado**: Sigue las instrucciones en [Foundry Book](https://book.getfoundry.sh/getting-started/installation)
2. **Wallet con fondos**: Necesitas ETH en Sepolia para gas
3. **RPC URL**: Obtén una RPC URL de Sepolia (Alchemy, Infura, etc.)
4. **Etherscan API Key**: Para verificar el contrato (opcional pero recomendado)

## Paso 1: Configurar Variables de Entorno

Crea un archivo `.env` en la raíz del proyecto:

```bash
PRIVATE_KEY=tu_clave_privada_sin_0x
SEPOLIA_RPC_URL=https://rpc.sepolia.org
ETHERSCAN_API_KEY=tu_api_key_de_etherscan
```

**⚠️ IMPORTANTE**: Nunca subas el archivo `.env` al repositorio. Está incluido en `.gitignore`.

## Paso 2: Instalar Dependencias

```bash
# Instalar Foundry (si no está instalado)
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Instalar dependencias del proyecto
forge install foundry-rs/forge-std --no-commit
forge install Uniswap/v2-periphery --no-commit
forge install Uniswap/v2-core --no-commit
forge install smartcontractkit/chainlink-brownie-contracts --no-commit
```

## Paso 3: Compilar el Contrato

```bash
forge build
```

## Paso 4: Desplegar el Contrato

### Opción A: Deployment Interactivo

```bash
forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --verify -vvvv
```

### Opción B: Deployment con Verificación Manual

```bash
# 1. Desplegar
forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast -vvvv

# 2. Verificar manualmente en Etherscan
forge verify-contract <CONTRACT_ADDRESS> contracts/KipuBank.sol:KipuBankV3 --chain-id 11155111 --etherscan-api-key $ETHERSCAN_API_KEY
```

## Paso 5: Configurar el Contrato

Después del deployment, necesitas configurar los tokens permitidos:

```bash
# Actualizar script/Setup.s.sol con la dirección del contrato desplegado
# Luego ejecutar:
forge script script/Setup.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast -vvvv
```

O manualmente:

```bash
# Usar cast para llamar al contrato
cast send <CONTRACT_ADDRESS> "setAllowedForSwap(address,bool)" <WETH_ADDRESS> true --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
```

## Paso 6: Verificar el Deployment

### Verificar en Etherscan

1. Ve a https://sepolia.etherscan.io/address/<CONTRACT_ADDRESS>
2. Verifica que el contrato esté verificado
3. Revisa las transacciones de deployment

### Verificar Funcionalidad

```bash
# Verificar capacidad disponible
cast call <CONTRACT_ADDRESS> "getAvailableCapacity()" --rpc-url $SEPOLIA_RPC_URL

# Verificar tokens permitidos
cast call <CONTRACT_ADDRESS> "allowedForSwap(address)" <TOKEN_ADDRESS> --rpc-url $SEPOLIA_RPC_URL
```

## Direcciones de Contratos en Sepolia

### Uniswap V2
- **Router**: `0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008`
- **Factory**: Verificar en Uniswap docs

### Tokens
- **USDC**: `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`
- **WETH**: `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14`

### Chainlink Price Feeds
- **USDC/USD**: `0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E`

## Troubleshooting

### Error: "insufficient funds"
- Asegúrate de tener suficiente ETH en tu wallet para gas

### Error: "nonce too low"
- Espera unos segundos y vuelve a intentar, o incrementa el nonce manualmente

### Error: "contract verification failed"
- Verifica que todos los parámetros del constructor sean correctos
- Asegúrate de que la versión de Solidity coincida

### Error: "execution reverted"
- Verifica que las direcciones de los contratos sean correctas
- Asegúrate de que los parámetros del constructor sean válidos

## Próximos Pasos

1. **Configurar tokens permitidos**: Usa `setAllowedForSwap` para permitir tokens adicionales
2. **Configurar límites**: Ajusta `bankCapUSD` y `perUserDailyWithdrawLimitUSD` según necesites
3. **Probar funcionalidad**: Realiza depósitos y retiros de prueba
4. **Monitorear**: Usa Etherscan para monitorear las transacciones

## Seguridad

- ⚠️ **NUNCA** compartas tu clave privada
- ⚠️ **SIEMPRE** verifica las direcciones de los contratos antes de interactuar
- ⚠️ **REVISA** el código antes de desplegar en mainnet
- ⚠️ **CONSIDERA** realizar una auditoría de seguridad antes de producción

## Recursos

- [Foundry Documentation](https://book.getfoundry.sh/)
- [Etherscan Sepolia](https://sepolia.etherscan.io/)
- [Uniswap V2 Documentation](https://docs.uniswap.org/protocol/V2/introduction)
- [Chainlink Price Feeds](https://docs.chain.link/data-feeds/price-feeds)

