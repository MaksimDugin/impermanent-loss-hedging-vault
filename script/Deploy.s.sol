// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {ImpermanentLossHedgingVault} from "../src/ImpermanentLossHedgingVault.sol";

contract Deploy is Script {
    function run() external returns (ImpermanentLossHedgingVault vault) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        address router = vm.envAddress("ROUTER");
        address pair = vm.envAddress("PAIR");
        address pool = vm.envAddress("AAVE_POOL");
        address oracle = vm.envAddress("ETH_USD_ORACLE");
        address usdc = vm.envAddress("USDC");
        address weth = vm.envAddress("WETH");

        address deployer = vm.addr(deployerKey);
        vm.startBroadcast(deployerKey);
        vault = new ImpermanentLossHedgingVault(
            deployer,
            router,
            pair,
            pool,
            oracle,
            usdc,
            weth,
            6
        );
        vm.stopBroadcast();
    }
}
