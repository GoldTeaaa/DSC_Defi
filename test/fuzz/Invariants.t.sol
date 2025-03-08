// SPDX-License-Identifier: MIT
// Have our invariant aka properties
// What are our invariants

// 1. The total supply of DSC should be less than the total value of collateral

// 2. Getter view functions should never revert <- evergreen invariant

pragma solidity ^0.8.0;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "test/fuzz/Handler.t.sol";

contract InavariantTest is StdInvariant, Test{
    DeployDSC deployer;
    DSCEngine engine;
    DecentralizedStableCoin token;
    HelperConfig config;
    Handler handler;

    address weth;
    address wbtc;
    address wBtcUsdPriceFeed;
    address wEthUsdPriceFeed;

    function setUp() external{
        deployer = new DeployDSC();
        (token, engine, config) = deployer.run();
        (wEthUsdPriceFeed, wBtcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();
        handler = new Handler(engine, token);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view{
        // get the value of all the collateral in the protocol
        // compare it to all the debt
        uint256 totalSupply = token.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(engine));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(engine));

        uint256 wethValue = engine.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = engine.getUsdValue(wbtc, totalWbtcDeposited);

        console.log("weth value: %s", totalWethDeposited);
        console.log("wbtc value: %s", totalWbtcDeposited);
        console.log("totalSupply: %s", totalSupply);
        console.log("Times mints runned:", handler.timesMintIsCalled());

        assert(wethValue + wbtcValue >= totalSupply);
    }
}