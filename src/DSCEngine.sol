// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volatility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "lib/openzepplin-contracts/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "lib/openzepplin-contracts/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Sahil Soni
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of
 * all collateral < the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */


contract DSCEngine is ReentrancyGuard {
    /*********************************************Errors****************************************/
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    
    /*********************************************State Variables********************************/
    uint256 private constant  ADDITIONAL_COLLATERAL_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // means 200% over collaterlised
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1; 

    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDSCToMint) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    /**********************************************Events****************************************/
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);                                                                                             
    event CollateralRedeemed(address indexed user, address indexed token, uint256 indexed amount);

    /**********************************************Modifiers*************************************/
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
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

    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {
        // USD price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        // for example ETH/USD, BTC/USD, MKR/USD

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);


    }
    /**
    * @param tokenCollateralAddress The address of the token to deposit as collateral
    * @param amountCollateral The amount of collateral to deposit
    * @param amountDscToMint The amount of Descetralize stable coin to mint
    * @notice this function will deposit your collateral and mint DSC in one transaction 
     */
    function depositCollateralAndMintDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToMint) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     *@param tokenCollateralAddress The address of the token to deposit as collateral
     *@param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if(!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
    * @param tokenCollateralAddress The address of the token to redeem as collateral
    * @param amountCollateral The amount of collateral to redeem
    * @param amountDscToBurn The amount of Descetralize stable coin to burn
    * @notice this function will redeem your collateral and burn DSC in one transaction which is actually two transaction process
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeem collateral alredy check health factor
    }

    // in order to redeem collateral :
    // 1. health factor  must be over 1 after collateral pulled
    function redeemCollateral(address  tokenCollateralAddress, uint256 amountCollateral) external moreThanZero(amountCollateral) nonReentrant{
        s_collateralDeposited[msg.sender][tokenCollateralAddress] -=  amountCollateral;
        emit CollateralRedeemed(msg.sender,tokenCollateralAddress,amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(msg.sender,amountCollateral);
        if(!success){
            revert DSCEngine__TransferFailed();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
    @notice follows CEI
    @param amountDSCToMint The amount of Descetralize stable coin to mint
    @notice they must have more collateral value than the minimum  threshold
     */
    function mintDsc(uint256 amountDSCToMint) public moreThanZero(amountDSCToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDSCToMint;
        // if they minted too much 
        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, amountDSCToMint);
        if(!minted){
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        s_DSCMinted[msg.sender] -= amount;
        bool success = i_dsc.transferFrom(msg.sender, address(this), amount);
        // this condition is hypothetically unrechable
        if(!success){
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amount);
        _revertIfHealthFactorIsBroken(msg.sender); // I don't think this would ever hit...
    }

    function liquidate() external {}
    function getHealthFactor() external view {}

    /**********************************************private and Internal Function*************************************/

    function _getAccountInformation(address user) private view returns(uint256 totalDscMinted, uint256 collateralValueInUsd) {
        // total DSC minted
        totalDscMinted = s_DSCMinted[user];
        // total collateral VALUE

        collateralValueInUsd = getAccountCollateralValue(user);
    }
    /**
    Returns how close to liquidation the user is
    if a user goes below 1, then they can get liquidated
     */
    function _healthFactor(address user) private view returns(uint256){
        // total DSC minted
        // total collateral VALUE
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_PRECISION) / LIQUIDATION_THRESHOLD;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }
    function _revertIfHealthFactorIsBroken(address user) internal view {
        // check health factor ( do they have enough collateral)
        // revert if they don't 

        uint256 userHealthFactor = _healthFactor(user);
        if(userHealthFactor < MIN_HEALTH_FACTOR){
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }

    }

    /**********************************************public and external view Function*************************************/
    function getAccountCollateralValue(address user) public view returns(uint256 totalCollateralValueInUsd){
        // loop through each collateral token, get the amount they have deposited
        // map it to the price to get the USD value

        for(uint256 i =0; i< s_collateralTokens.length; i++){
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += amount * getUsdValue(token, amount);
        }

        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns(uint256){
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price,,,) = priceFeed.latestRoundData();
        // 1 eth = 1000$
        // The returned value from CL will be 1000* 1e8

        return ((uint256(price) * ADDITIONAL_COLLATERAL_PRECISION)*amount)/PRECISION;
    }
}
