// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";

contract DeployDSC is Script {
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function run() public returns (DecentralizedStableCoin, DSCEngine, HelperConfig) {
        HelperConfig config = new HelperConfig();
        (address wEthUsdPriceFeed, address wBtcUsdPriceFeed, address wEth, address wBtc, uint256 deployerKey) =
            config.activeNetworkConfig();

        tokenAddresses = [wEth, wBtc];
        priceFeedAddresses = [wEthUsdPriceFeed, wBtcUsdPriceFeed];

        vm.startBroadcast();
        DecentralizedStableCoin dsc = new DecentralizedStableCoin();
        DSCEngine engine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
        // We put ownable in the decentralizedStableCoin contract. Which the current owner of it
        // now is this DeployDSC.s.sol. We want the owner is the engine, so we have to add transferOwnership to the engine
        dsc.transferOwnership(address(engine));
        vm.stopBroadcast();

        return (dsc, engine, config);
    }
}
