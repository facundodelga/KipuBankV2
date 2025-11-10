// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {KipuBankV3} from "../contracts/KipuBank.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

// Interfaz de Uniswap V2 Router
interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint amountIn, 
        uint amountOutMin, 
        address[] calldata path, 
        address to, 
        uint deadline
    ) external returns (uint[] memory amounts);

    function swapExactETHForTokens(
        uint amountOutMin, 
        address[] calldata path, 
        address to, 
        uint deadline
    ) external payable returns (uint[] memory amounts);

    function getAmountsOut(uint amountIn, address[] calldata path) 
        external 
        view 
        returns (uint[] memory amounts);

    function WETH() external pure returns (address);
}

/**
 * @title KipuBankV3ForkTest
 * @notice Tests con fork de Sepolia Testnet para pruebas reales con Uniswap V2
 * @dev Ejecutar con: forge test --fork-url $SEPOLIA_RPC_URL -vvv
 */
contract KipuBankV3ForkTest is Test {
    KipuBankV3 public bank;
    
    // Direcciones de Sepolia Testnet
    address constant SEPOLIA_UNISWAP_V2_ROUTER = 0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008;
    address constant SEPOLIA_USDC = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    address constant SEPOLIA_WETH = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address constant SEPOLIA_USDC_PRICE_FEED = 0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E; // Chainlink USDC/USD
    
    // Usuarios de prueba (usar direcciones con fondos en Sepolia)
    address public alice = makeAddr("alice");
    address public admin = makeAddr("admin");
    
    uint256 constant BANK_CAP_USD = 10_000_000e6; // 10M USD
    uint256 constant DAILY_WITHDRAW_LIMIT = 1_000_000e6; // 1M USD
    
    IERC20 public usdc;
    IERC20 public weth;
    IUniswapV2Router02 public router;
    
    function setUp() public {
        // Fork de Sepolia
        vm.createSelectFork(vm.envString("SEPOLIA_RPC_URL"));
        
        // Inicializar interfaces
        usdc = IERC20(SEPOLIA_USDC);
        weth = IERC20(SEPOLIA_WETH);
        router = IUniswapV2Router02(SEPOLIA_UNISWAP_V2_ROUTER);
        
        // Desplegar banco
        vm.startPrank(admin);
        bank = new KipuBankV3(
            BANK_CAP_USD,
            SEPOLIA_USDC,
            SEPOLIA_UNISWAP_V2_ROUTER,
            SEPOLIA_USDC_PRICE_FEED,
            DAILY_WITHDRAW_LIMIT
        );
        
        // Permitir WETH para swap
        bank.setAllowedForSwap(SEPOLIA_WETH, true);
        vm.stopPrank();
    }
    
    /**
     * @notice Test principal: Depósito de ETH y swap a USDC
     * @dev Este test requiere tener ETH en la cuenta de prueba en Sepolia
     */
    function test_DepositETH_ToUSDC() public {
        // Usar una cuenta con ETH en Sepolia (puede requerir hardcoding)
        address userWithETH = 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045; // Ejemplo: Vitalik's address
        
        // Impersonar usuario con ETH
        vm.startPrank(userWithETH);
        uint256 ethBalance = userWithETH.balance;
        require(ethBalance > 0, "User needs ETH");
        
        // Obtener quote antes del swap
        address[] memory path = new address[](2);
        path[0] = router.WETH();
        path[1] = SEPOLIA_USDC;
        uint256[] memory amountsOut = router.getAmountsOut(0.1 ether, path);
        uint256 expectedUSDC = amountsOut[1];
        console.log("Expected USDC from 0.1 ETH:", expectedUSDC);
        
        // Depositar ETH
        uint256 balanceBefore = usdc.balanceOf(address(bank));
        bank.depositETH{value: 0.1 ether}();
        uint256 balanceAfter = usdc.balanceOf(address(bank));
        
        // Verificar que se recibió USDC
        assertGt(balanceAfter, balanceBefore);
        assertGt(bank.getUserUSDCBalance(userWithETH), 0);
        
        console.log("USDC balance in bank:", balanceAfter);
        console.log("User USDC balance:", bank.getUserUSDCBalance(userWithETH));
        
        vm.stopPrank();
    }
    
    /**
     * @notice Test: Depósito de USDC directo
     */
    function test_DepositUSDC_Direct() public {
        // Usar una cuenta con USDC en Sepolia
        address userWithUSDC = 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045;
        
        vm.startPrank(userWithUSDC);
        
        uint256 depositAmount = 100e6; // 100 USDC
        uint256 balanceBefore = usdc.balanceOf(userWithUSDC);
        
        // Aprobar y depositar
        usdc.approve(address(bank), depositAmount);
        bank.depositToken(address(usdc), depositAmount);
        
        // Verificar balances
        assertEq(bank.getUserUSDCBalance(userWithUSDC), depositAmount);
        assertEq(usdc.balanceOf(userWithUSDC), balanceBefore - depositAmount);
        
        vm.stopPrank();
    }
    
    /**
     * @notice Test: Retiro de USDC
     */
    function test_WithdrawUSDC() public {
        address user = 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045;
        
        vm.startPrank(user);
        
        // Depositar primero
        uint256 depositAmount = 100e6;
        usdc.approve(address(bank), depositAmount);
        bank.depositToken(address(usdc), depositAmount);
        
        // Retirar
        uint256 withdrawAmount = 50e6;
        uint256 balanceBefore = usdc.balanceOf(user);
        bank.withdrawUSDC(withdrawAmount);
        uint256 balanceAfter = usdc.balanceOf(user);
        
        assertEq(balanceAfter, balanceBefore + withdrawAmount);
        assertEq(bank.getUserUSDCBalance(user), depositAmount - withdrawAmount);
        
        vm.stopPrank();
    }
    
    /**
     * @notice Test: Verificar que el banco respeta el cap
     */
    function test_BankCap() public {
        address user = 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045;
        
        vm.startPrank(user);
        
        // Intentar depositar más del cap
        uint256 depositAmount = BANK_CAP_USD + 1;
        
        // Mint USDC si es necesario (solo para tests)
        // En producción, el usuario debe tener USDC real
        usdc.approve(address(bank), depositAmount);
        
        vm.expectRevert(KipuBankV3.BankCapExceeded.selector);
        bank.depositToken(address(usdc), depositAmount);
        
        vm.stopPrank();
    }
    
    /**
     * @notice Test: Verificar capacidad disponible
     */
    function test_GetAvailableCapacity() public {
        address user = 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045;
        
        vm.startPrank(user);
        
        uint256 initialCapacity = bank.getAvailableCapacity();
        assertEq(initialCapacity, BANK_CAP_USD);
        
        // Depositar
        uint256 depositAmount = 1000e6;
        usdc.approve(address(bank), depositAmount);
        bank.depositToken(address(usdc), depositAmount);
        
        uint256 newCapacity = bank.getAvailableCapacity();
        assertLt(newCapacity, initialCapacity);
        
        vm.stopPrank();
    }
}

