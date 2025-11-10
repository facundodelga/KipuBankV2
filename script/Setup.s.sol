// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {KipuBankV3} from "../contracts/KipuBank.sol";

/**
 * @title SetupKipuBankV3
 * @notice Script para configurar tokens permitidos en KipuBankV3 después del deployment
 * @dev Ejecutar con: forge script script/Setup.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast
 */
contract SetupKipuBankV3 is Script {
    // Direcciones de Sepolia Testnet
    address constant SEPOLIA_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    
    // Dirección del contrato desplegado (actualizar después del deployment)
    address payable constant KIPU_BANK_V3 = payable(0xaEbBe67972A4FD9165D6f41Af2B32B3093E12F1b);
    
    function run() external {
        vm.startBroadcast();
        
        if (KIPU_BANK_V3 == address(0)) {
            revert("Please update KIPU_BANK_V3 with the deployed contract address");
        }
        
        KipuBankV3 bank = KipuBankV3(KIPU_BANK_V3);
        
        console.log("Configurando KipuBankV3...");
        console.log("Direccion del contrato:", address(bank));
        
        // Permitir WETH para swaps
        console.log("Permitiendo WETH para swaps...");
        bank.setAllowedForSwap(SEPOLIA_WETH, true);
        console.log("WETH permitido:", bank.allowedForSwap(SEPOLIA_WETH));
        
        // Aquí se pueden agregar más tokens según sea necesario
        // Ejemplo:
        // bank.setAllowedForSwap(OTRO_TOKEN, true);
        
        console.log("Configuracion completada!");
        
        vm.stopBroadcast();
    }
}

