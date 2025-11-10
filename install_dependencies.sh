#!/bin/bash

# Script para instalar dependencias de Foundry

echo "Instalando dependencias de Foundry..."

# Instalar forge-std
forge install foundry-rs/forge-std --no-commit

# Instalar Uniswap V2 Periphery
forge install Uniswap/v2-periphery --no-commit

# Instalar Uniswap V2 Core
forge install Uniswap/v2-core --no-commit

# Instalar Chainlink contracts
forge install smartcontractkit/chainlink-brownie-contracts --no-commit

echo "Dependencias instaladas correctamente!"

