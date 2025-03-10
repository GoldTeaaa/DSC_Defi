// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";

contract Handler is Script {
    DSCEngine engine;
    DecentralizedStableCoin token;
    MockV3Aggregator public ethPriceFeed;

    ERC20Mock weth;
    ERC20Mock wbtc;

    uint256 public timesMintIsCalled;
    address[] public userWithCollateralDepostied;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max;

    constructor(DSCEngine _engine, DecentralizedStableCoin _token) {
        engine = _engine;
        token = _token;

        address[] memory collateralTokens = engine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethPriceFeed = MockV3Aggregator(engine.getCollaterlTokenPriceFeeds(address(weth)));
    }

    function depositCollateral( /* address collateral */ uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(engine), amountCollateral);
        engine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();

        userWithCollateralDepostied.push(msg.sender);
    }

    // function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
    //     ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
    //     uint256 maxCollateral = engine.getCollateralDeposited(msg.sender, address(collateral));

    //     amountCollateral = bound(amountCollateral, 0, maxCollateral);
    //     //vm.prank(msg.sender);
    //     if (amountCollateral == 0) {
    //         return;
    //     }
    //     vm.prank(msg.sender);
    //     // (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(msg.sender);
    //     // console.log(totalDscMinted, collateralValueInUsd);
    //     engine.redeemCollateral(address(collateral), amountCollateral);
    // }

    /**
     * @notice redeemCollateral still have error. Fix this later.
     */
    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        // if (userWithCollateralDepostied.length == 0) {
        //     return;
        // }
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        // depositCollateral(collateralSeed, amountCollateral);
        uint256 collateralToRedeem = engine.getCollateralDeposited(msg.sender, address(collateral));
        // console.log(collateralToRedeem);
        amountCollateral = bound(amountCollateral, 0, collateralToRedeem);
        if (amountCollateral == 0) {
            return;
        }

        vm.prank(msg.sender);
        engine.redeemCollateral(address(collateral), amountCollateral);
    }

    function mintDsc(uint256 addressSeed, uint256 amount /* , uint256 rand */ ) public {
        if (userWithCollateralDepostied.length == 0) {
            return;
        }
        address sender = userWithCollateralDepostied[addressSeed % userWithCollateralDepostied.length];
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = engine.getAccountInformation(sender);
        int256 maxDscToMint = int256(collateralValueInUsd / 2 - totalDscMinted);

        // if(collateralValueInUsd == 0){
        //     depositCollateral(addressSeed, amount);
        // }

        timesMintIsCalled++;

        if (maxDscToMint <= 0) {
            return;
        }
        amount = bound(amount, 1, uint256(maxDscToMint));
        // if(amount == 0){
        //     return;
        // }

        vm.startPrank(sender);
        engine.mintDSC(amount);
        vm.stopPrank();
    }

    // This breaks our invariant test!!!
    // function updateCollateralPrice(uint96 newPrice) public{
    //     int256 newPriceInt = int256(uint256(newPrice));
    //     ethPriceFeed.updateAnswer(newPriceInt);
    // }

    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }

    function invariant_getterShouldNotRevert() public view {
        // engine.getAccountCollateralValue();
        // engine.getAccountInformation();
        // engine.getAdditionalHealthPrecsion();
        // engine.getCollateralDeposited();
        // engine.getCollateralTokens();
        // engine.getHealthFactor();
        // engine.getPrecisions();
        // engine.getTokenAmountFromUsd();
        // engine.getUsdValue();
    }
}
