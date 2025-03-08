// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";
// import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract DSCEngineTest is Test {
    DecentralizedStableCoin token;
    DeployDSC deployer;
    DSCEngine engine;
    HelperConfig config;

    address weth;
    address wbtc;
    address wBtcUsdPriceFeed;
    address wEthUsdPriceFeed;

    address public USER = makeAddr("user");

    uint256 public constant AMOUNT = 1 ether;
    uint256 public constant STARTING_ERC2O_BALANCE = 50 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (token, engine, config) = deployer.run();
        (wEthUsdPriceFeed, wBtcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC2O_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                           CONSTRUCTOR TEST
    //////////////////////////////////////////////////////////////*/
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(wEthUsdPriceFeed);
        priceFeedAddresses.push(wBtcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressAndPriceFeedAdressMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(token));
    }

    /*//////////////////////////////////////////////////////////////
                              PRICE TEST
    //////////////////////////////////////////////////////////////*/
    function testGetUsdValue() public view {
        uint256 usdValue = engine.getUsdValue(weth, AMOUNT);
        uint256 expectedValue = 2000e18;

        assertEq(expectedValue, usdValue);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmountInWei = 10000e18;
        uint256 expectedValue = 5e18;
        uint256 calculatedValue = engine.getTokenAmountFromUsd(weth, usdAmountInWei);
        assertEq(expectedValue, calculatedValue);
    }

    /*//////////////////////////////////////////////////////////////
                            Deposit Collateral Test
    //////////////////////////////////////////////////////////////*/
    function testRevertIfCollateralZero() public {
        vm.prank(USER);
        ERC20Mock(weth);
        console.log(weth);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertIfCollateralUnapproved() public {
        vm.prank(USER);
        // the address produced by this ranToken is something else and not the same as weth
        ERC20Mock ranToken = new ERC20Mock();
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        engine.depositCollateral(address(ranToken), AMOUNT);
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), STARTING_ERC2O_BALANCE);
        engine.depositCollateral(weth, AMOUNT);
        vm.stopPrank();
        _;
    }

    function testDepositAndCollateralExist() public depositedCollateral(){
        uint256 collateralDeposited = engine.getCollateralDeposited(USER, weth);
        assertEq(uint256(collateralDeposited), uint256(AMOUNT));
    }

    modifier depositAndMintDsc(){
        (, int256 price,,,) = MockV3Aggregator(wEthUsdPriceFeed).latestRoundData();
        uint256 MINT_DSC_AMOUNT =
            (AMOUNT / 2) * ((uint256(price) * engine.getAdditionalHealthPrecsion()) / engine.getPrecisions());
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), MINT_DSC_AMOUNT);
        engine.depositCollateralAndMintDSC(weth, AMOUNT, MINT_DSC_AMOUNT);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 UsdValue) = engine.getAccountInformation(USER);
        // uint256 depositedCollateral = engine.getCollateralDeposited(USER, weth);
        console.log(UsdValue);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedUsdValue = engine.getTokenAmountFromUsd(weth, UsdValue);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT, expectedUsdValue);
    }

    /*//////////////////////////////////////////////////////////////
                                 Mint DSC
    //////////////////////////////////////////////////////////////*/

    function testRevertIfMintDscViolateHealthFactor() public depositedCollateral {
        (, int256 price,,,) = MockV3Aggregator(wEthUsdPriceFeed).latestRoundData();
        uint256 MINT_DSC_AMOUNT =
            ((AMOUNT / 2) + 1) * ((uint256(price) * engine.getAdditionalHealthPrecsion()) / engine.getPrecisions());
        console.log(MINT_DSC_AMOUNT);

        vm.startPrank(USER);
        uint256 health = engine.calculateHealthFactor(MINT_DSC_AMOUNT, engine.getAccountCollateralValue(USER));
        vm.expectRevert(abi.encodePacked(DSCEngine.DSCEngine__BreaksHealthFactor.selector, health));
        engine.mintDSC(MINT_DSC_AMOUNT);
        vm.stopPrank();
    }

    function testTokenDscMintedUpdatedInTheDscTokenContract() public depositAndMintDsc(){
        (, int256 price,,,) = MockV3Aggregator(wEthUsdPriceFeed).latestRoundData();
        uint256 MINT_DSC_AMOUNT =
            (AMOUNT / 2) * ((uint256(price) * engine.getAdditionalHealthPrecsion()) / engine.getPrecisions());
        uint256 userBalance = token.balanceOf(USER);
        assertEq(userBalance, MINT_DSC_AMOUNT);
    } 

    /*//////////////////////////////////////////////////////////////
                            Redeem Collateral
    //////////////////////////////////////////////////////////////*/

    function testRevertIfAmountRedeemExceedCollateral() public depositedCollateral(){
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__CollateralNotSufficient.selector);
        engine.redeemCollateral(weth, AMOUNT + 1 ether );
        vm.stopPrank();
    }

    function testRevertIfRedeemBreakHealthFactor() public depositedCollateral(){
        (, int256 price,,,) = MockV3Aggregator(wEthUsdPriceFeed).latestRoundData();
        uint256 MINT_DSC_AMOUNT =
            (AMOUNT / 2) * ((uint256(price) * engine.getAdditionalHealthPrecsion()) / engine.getPrecisions());
        // uint256 DscToWeth = /* engine.getTokenAmountFromUsd(weth, MINT_DSC_AMOUNT); */ MINT_DSC_AMOUNT;
        vm.startPrank(USER);
        engine.mintDSC(MINT_DSC_AMOUNT);
        console.log("MINT_DSC_AMOUNT");
        console.log("Collateral Deposited is: ",engine.getCollateralDeposited(USER, weth));
        vm.expectRevert(DSCEngine.DSCEngine__CollateralNotSufficient.selector);
        engine.redeemCollateral(weth, MINT_DSC_AMOUNT);
        vm.stopPrank();
    }

    function testRedeemPartialCollateralAfterMinting() public depositedCollateral(){
        (, int256 price,,,) = MockV3Aggregator(wEthUsdPriceFeed).latestRoundData();
        //Divide the amount by 3 so the mint ratio is 3,3 : 10
        uint256 MINT_DSC_AMOUNT =
            (AMOUNT / 3) * ((uint256(price) * engine.getAdditionalHealthPrecsion()) / engine.getPrecisions());
        // uint256 DscToWeth = /* engine.getTokenAmountFromUsd(weth, MINT_DSC_AMOUNT); */ MINT_DSC_AMOUNT;
        vm.startPrank(USER);
        engine.mintDSC(MINT_DSC_AMOUNT);
        console.log("MINT_DSC_AMOUNT");
        console.log("Collateral Deposited is: ",engine.getCollateralDeposited(USER, weth));
        engine.redeemCollateral(weth, 0.025 ether);
        vm.stopPrank();
    }

    function testDepositAndCollateralAtSameTime() public{
        (, int256 price,,,) = MockV3Aggregator(wEthUsdPriceFeed).latestRoundData();
        uint256 MINT_DSC_AMOUNT =
            (AMOUNT / 2) * ((uint256(price) * engine.getAdditionalHealthPrecsion()) / engine.getPrecisions());
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(engine), AMOUNT);
        engine.depositCollateralAndMintDSC(weth, AMOUNT, MINT_DSC_AMOUNT);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            Burn DSC
    //////////////////////////////////////////////////////////////*/

    function testBurnDscRevertedWhenAmountIsZero() public depositAndMintDsc(){
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        engine.burnDSC(0);
        vm.stopPrank();
    }

    function testCantBurnDscMoreThanUserHas() public depositAndMintDsc(){
        uint256 exceedAmount = 2 ether;
        vm.startPrank(USER);
        token.approve(address(engine), AMOUNT);
        vm.expectRevert();
        engine.burnDSC(exceedAmount);
        vm.stopPrank();
    }

    function testBalanceIsReducedAterBurnt() public depositAndMintDsc(){
        vm.startPrank(USER);
        (, int256 price,,,) = MockV3Aggregator(wEthUsdPriceFeed).latestRoundData();
        uint256 MINT_DSC_AMOUNT =
            (AMOUNT / 2) * ((uint256(price) * engine.getAdditionalHealthPrecsion()) / engine.getPrecisions());
        // (uint256 totalDscMinted, ) = engine.getAccountInformation(USER);
        token.approve(address(engine), MINT_DSC_AMOUNT);
        engine.burnDSC(MINT_DSC_AMOUNT);
        vm.stopPrank();

        (uint256 totalDscMinted, ) = engine.getAccountInformation(USER);
        assertEq(totalDscMinted, 0);
    }
}
