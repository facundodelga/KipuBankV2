@echo off
REM Script para instalar dependencias de Foundry en Windows

echo Instalando dependencias de Foundry...

REM Instalar forge-std
forge install foundry-rs/forge-std --no-commit

REM Instalar Uniswap V2 Periphery
forge install Uniswap/v2-periphery --no-commit

REM Instalar Uniswap V2 Core
forge install Uniswap/v2-core --no-commit

REM Instalar Chainlink contracts
forge install smartcontractkit/chainlink-brownie-contracts --no-commit

echo Dependencias instaladas correctamente!

