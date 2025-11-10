// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console2 as console} from "forge-std/Script.sol";
import {KipuBankV3} from "../contracts/KipuBank.sol";

contract DeployKipuBankV3 is Script {
    address constant DEFAULT_ROUTER = 0xeE567Fe1712Faf6149d80dA1E6934E354124CfE3; // Uniswap V2 Sepolia
    address constant DEFAULT_USDC   = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238; // USDC Sepolia
    address constant DEFAULT_USDC_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6; //https://etherscan.io/address/0x8fffffd4afb6115b954bd326cbe7b4ba576818f6

    uint256 constant BANK_CAP_USD = 10_000_000e6;
    uint256 constant DAILY_WITHDRAW_LIMIT = 1_000_000e6;

    function run() external returns (KipuBankV3) {
        vm.startBroadcast();

        address usdc   = _envAddr("SEPOLIA_USDC", DEFAULT_USDC);
        address router = _envAddr("SEPOLIA_UNISWAP_V2_ROUTER", DEFAULT_ROUTER);
        address usdcFeed = _envAddr("SEPOLIA_USDC_PRICE_FEED", DEFAULT_USDC_FEED);

        console.log("Desplegando KipuBankV3");
        console.log("USDC:", usdc);
        console.log("Router:", router);
        console.log("USDC Feed:", usdcFeed);

        KipuBankV3 bank = new KipuBankV3(
            BANK_CAP_USD,
            usdc,
            router,
            usdcFeed,
            DAILY_WITHDRAW_LIMIT
        );

        console.log("KipuBankV3:", address(bank));
        vm.stopBroadcast();
        return bank;
    }

    function _envAddr(string memory key, address fallback_) internal view returns (address v) {
        try vm.envAddress(key) returns (address tmp) { v = tmp; } catch { v = fallback_; }
    }
}