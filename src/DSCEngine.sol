// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/* 
    @title DSCEngine
    @author Handay
    The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg

    This stablecoin fas the properties:
    - Exogenous Collateral
    - Dollar Pegged
    - Algoritmically Stable

    This DSC must be always "overCollateralized". At no point, should the value of the collateral <= the $ backed value of all the DSC.

    It is similar to DAI if DAI had no governance, no fees, and was only backed by wETH and wBTC

    @notice This contract is the core of the DSC System. It handles all the logic for mining and redeeming DSC, as well as depositing & withdrawing collateral

    @notice This contract is VERY loosely  based on the MakerDAO DSS (DAI) system
*/

import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {console} from "forge-std/console.sol";
import {OracleLib} from "src/libraries/OracleLib.sol";

contract DSCEngine is ReentrancyGuard {
    ////////////////////////////////////
    // ERRORS                         //
    ////////////////////////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressAndPriceFeedAdressMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSC__EngineTransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256);
    error DSCEngine__MintFailed();
    error DSCEngine__TransferFailed();
    error DSCEngine__HealthFactorOk();
    error DSC_Engine__HealthFactorNotImproved();
    error DSCEngine__CollateralNotSufficient();

    ////////////////////////////////////
    // ERRORS                         //
    ////////////////////////////////////
    using OracleLib for AggregatorV3Interface;

    ////////////////////////////////////
    // STATE VARIABLES                //
    ////////////////////////////////////
    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;

    // These are use for decimals. Most of the price feed are 10e8 by default
    // To remove the decimal and make sure no math bug occurs, better remove the decimal with precision
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 100;

    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_DSC;

    //////////////////////////////////////
    // EVENTS                      //
    ////////////////////////////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemFrom, address indexed redeemTo, address indexed token, uint256 amount
    );

    ////////////////////////////////////
    // MODIFIERS                      //
    ////////////////////////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    /* 
    From the start, we have to pass the tokenAddress that we want to use as the collateral
    Then, so that our code can read the current situation of the market, we need an oracle to do the job
    The solution is using chainlink priceFeed
     */
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressAndPriceFeedAdressMustBeSameLength();
        }

        // For example ETH/USD, BTC/USD, etc... We mainly use BTC and ETH in this project
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_DSC = DecentralizedStableCoin(dscAddress);
    }

    ////////////////////////////////////
    // EXTERNAL FUNCTION              //
    ////////////////////////////////////

    /**
     * @param tokenCollateralAddress the address of the token to deposit Collateral
     * @param amountCollateral the amount of deposited collateral
     * @param amountDSC the amount of DSC token that want to be minted
     * @notice this function will deposit your collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDSC)
        external
    {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDSC(amountDSC);
    }

    /*
    @notice follows CEI (Check, Effects, Interaction)
    @param tokenCollateralAddress is the address of the collateral the user want to deposit
    @param amountCollateral is the amount of token the user want to deposit
    */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSC__EngineTransferFailed();
        }
    }

    /**
     * @param tokenCollateralAddress the collateral addres to redeem
     * @param amountCollateral the amount of collateral to redeem
     * @param amountDSCToBurn the amount of DSC to burn
     * @notice this function use to redeem the collateral and burn the DSC token to ashes
     */
    function redeemCollateralForDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDSCToBurn)
        external
    {
        _burnDsc(amountDSCToBurn, msg.sender, msg.sender);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    // To redeen collateral
    // 1. health factor must be over 1 after collateral pulled
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // 1. Check if the collateral > mint
    // for example, for a collateral of $100, can only mint $10
    // @param amountDscToMint the amount of the decentralized stablecoin to mint
    // @notice they must have collateral value than the minimum threshold
    function mintDSC(uint256 amountDscToMint) public nonReentrant {
        s_DSCMinted[msg.sender] = s_DSCMinted[msg.sender] + amountDscToMint;
        // If they minted too much ($150 DSC, $100 ETH) <--- THIS SHOULD BE NOT ALLOWED
        // $50DSC , $100 ETH <-- this is allowed
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_DSC.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDSC(uint256 amount) external moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        // Patrick think this would evert hit.. Maybe you can figure this out
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // If the collateral exceed the determined ratio, we need someone to liquidate it
    // If someone is undercollateralized, we will pay you to liquidate them!
    // Case : $75 back $50 DSC
    // Liquidatior can hunt and liquidate them and get the collateral of $75.
    /**
     * @param collateral is the erc20 collateral address we want to liquidate
     * @param user is the user that had violated the healthFactor
     * @param debtToCover the amount of DSC you want to burn to improve the user healthFactor
     * @notice you can partially liquidate a user
     * @notice you will get a liquidation bonus for taking the users funds
     * @notice This function working assumes the protocol will be roughly 200% overcollateralized in order for this to work
     * @notice A known bug would be if the protocol were 100% or less collateralized, then we wouldnt be able to incentive the liquidators
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        // 1. Check the healthFactor for the targeted user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        // 2. Pull the Collateral
        // Bad user: $140ETH, $100ETH. Which violate the 1.5 : 1 ratio
        // debtToCover : $100 DSC
        // $100 DSC == ?? ETH?
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // Also give them extra 10% for their fee.
        // @NOTE solidity cant handle decimals, dont divide the LIQUIDATION_BONUS directly with precision
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        // This is the amount the user will get
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);

        // 3. Burn the DSC
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSC_Engine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(user);
    }

    ////////////////////////////////////////////////
    // PRIVATE and INTERNAL FUNCTION              //
    ////////////////////////////////////////////////

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        // Okay, we got the DSC minted token amount, but it still in wBTC or wETH or etc!
        // We also need to add information about the USD value. Lets create a function to convert it
        collateralValueInUsd = getAccountCollateralValue(user); //1e23 for 50 eth collateral
    }

    /* 
    Returns how close to liquidation a user is
    If a user goes below 1, then they can get liquidated
     */
    // Using health factor calculation from other
    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // Total collateral Value
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user); //collateralValueInUsd = 1e23
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        // In case this is the first time the user deposit money, it means they have no debt
        // If not define by this, the division of the collateral will be error because it divided by 0
        if (totalDscMinted == 0) return type(uint256).max;

        // let say collateral ratio is 2:1. With 200 I can get 100. But if the liquidation also
        // follow the normal ratio which it will be liquidated if the 200 goes down to 100,
        // it will be too late. So, we want to make a safe threshold which the money will be liquidated
        // if it below 1.5 of the collateral ratio. For 200, the liquidation is 150 not 100.
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION; // times with 1/2 for max mint/Collateral
        // 1e23 / 2 = 5e22
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted; //
    }
    // 2000000000000000000

    function _revertIfHealthFactorIsBroken(address user) internal view {
        // Check if the health factor is healthy (have enough collateral?)
        // Revert if the dont
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        // 100 - 120, IT SHOULD BE REVERT
        if (amountCollateral > s_collateralDeposited[from][tokenCollateralAddress]) {
            revert DSCEngine__CollateralNotSufficient();
        }

        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @dev low-level internalfunction, do not call unlesss the function calling it is
     * checking the health factors being broken.
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address DscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_DSC.transferFrom(DscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        // Burn the token address to follow the standard.
        i_DSC.burn(amountDscToBurn);
    }

    ////////////////////////////////////////////////
    // Public and External FUNCTION              //
    ////////////////////////////////////////////////

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
        //1e21 * 1e18 / 2000e8 *
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            // amount is in e18
            totalCollateralValueInUsd += getUsdValue(token, amount); //1e23
        }
        return totalCollateralValueInUsd;
    }

    // To get the latest USD value, we use chainlink pricefeeds
    // Download the pricefeeds first
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();

        // @IMPORTANT Beware of decimals, let say 1 ETH = 1000$
        // The returned value from chainlink will be 1000 * 10^8
        return ((amount * (uint256(price) * ADDITIONAL_FEED_PRECISION)) / PRECISION); // 50e18 * (( 2000e8 * 10e10) / 1e18) = 100000e18 = 1e23
            // ()
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
        return (totalDscMinted, collateralValueInUsd);
    }

    function getCollateralDeposited(address user, address token) public view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return (_healthFactor(user));
    }

    function getCollaterlTokenPriceFeeds(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getAdditionalHealthPrecsion() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getPrecisions() external pure returns (uint256) {
        return PRECISION;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }
}
