// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        address wEthUsdPriceFeed;
        address wBtcUsdPriceFeed;
        address wEth;
        address wBtc;
        uint256 deployerKey;
    }

    NetworkConfig public activeNetworkConfig;

    uint8 public constant DECIMALS = 8;
    int256 public constant ETH_USD_PRICE = 2000e8;
    int256 public constant BTC_USD_PRICE = 1000e8;
    uint256 public constant INITIAL_WETH_BALANCE = 1000e8;
    uint256 public constant INITIAL_WBTC_BALANCE = 1000e8;
    uint256 private constant DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    constructor() {
        if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaEthConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilEthConfig();
        }
    }

    function getSepoliaEthConfig() public view returns (NetworkConfig memory) {
        return NetworkConfig({
            wEthUsdPriceFeed: 0x694AA1769357215DE4FAC081bf1f309aDC325306,
            wBtcUsdPriceFeed: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43,
            wEth: 0xdd13E55209Fd76AfE204dBda4007C227904f0a81,
            wBtc: 0xdd13E55209Fd76AfE204dBda4007C227904f0a81,
            deployerKey: vm.envUint("PRIVATE_KEY")
        });
    }

    function getOrCreateAnvilEthConfig() public returns (NetworkConfig memory) {
        if (activeNetworkConfig.wEthUsdPriceFeed != address(0)) {
            return activeNetworkConfig;
        }
        vm.startBroadcast();
        MockV3Aggregator ethUsdPriceFeed = new MockV3Aggregator(DECIMALS, ETH_USD_PRICE);
        ERC20Mock wEthMock = new ERC20Mock( "WETH","WETH",msg.sender,INITIAL_WETH_BALANCE );

        MockV3Aggregator btcUsdPriceFeed = new MockV3Aggregator(DECIMALS, BTC_USD_PRICE);
        ERC20Mock wBtcMock = new ERC20Mock( "WBTS","WBTC",msg.sender,INITIAL_WBTC_BALANCE );
        vm.stopBroadcast();

        return NetworkConfig({
            wEthUsdPriceFeed: address(ethUsdPriceFeed),
            wBtcUsdPriceFeed: address(btcUsdPriceFeed),
            wEth: address(wEthMock),
            wBtc: address(wBtcMock),
            deployerKey: DEFAULT_ANVIL_KEY
        });
    }
}
