// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";


interface IInsurancePool {
    function totalActiveCover() external view returns (uint256);
    function getPoolLiquidity() external view returns (uint256);
    function getUtilization() external view returns (uint256);


    function receivePremiumAndCover(uint256 _newCoverAmount) external payable;
    function executePayout ( address payable _recipient, uint256 _amount) external;
    function reduceActiveCover (uint256 _expiredCoverAmount) external;
}

contract DepegInsuranceNFT is ERC721, Ownable {
    uint256 private _nextTokenId;

    enum Severity {Mild, Moderate, Severe}

    address public insurancePool;

    struct PolicyData{
        address stablecoin; //asset being covered, stablecoin, S
        uint256 coverageAmount;//coverage amount, C
        uint256 expiryTimestamp; //when coverage ends (start time + duration)
        Severity severity; // tier of risk covered
        bool isActive; // policy of status
    }

    mapping(uint256 => PolicyData) public policies;
    mapping(address => address) public stablecoinPriceFeeds;

    //logged events to search using indexed parameter as filter
    event PolicyMinted(uint256 indexed tokenId, address indexed holder, address stablecoin, uint256 amount);
    event PolicyClaimed (uint256 indexed tokenId);

    function setInsurancePool (address _poolAddress) public onlyOwner{
        require(_poolAddress != address(0), "Pool address cannot be zero");
        insurancePool = _poolAddress;
    }

    //name and symbol of the token
    constructor() ERC721( "DepegInsurance" ,"INSURE") Ownable (msg.sender){
        _nextTokenId = 1;
    }

    function calculatePremium (uint256 _coverageAmount, uint256 _duration, Severity _severity)
    public view returns (uint256) {

        require(insurancePool != address(0), "Insurance pool address not set");

        IInsurancePool pool = IInsurancePool(insurancePool);

        uint256 severityMult = _severity == Severity.Mild ? 1
        : (_severity == Severity.Moderate ? 2 : 4);

        // 1 ether = 1e^18, base rate of 2%
        uint256 baseRate = 20000000000000000 * severityMult;
        uint256 durationFactor = (_duration * 1e18) / 30 days;

        //minimum factor should be 1
        if (durationFactor < 1e18) durationFactor = 1e18;

        uint256 utilization = pool.getUtilization();

        require(utilization <= 800000000000000000, "Pool utilization too high");

        // make premium more expensive when pool runs out of money
        uint256 utilizationFactor = (1e18 * 1e18) / (1e18 - utilization);

        uint requiredPremium = (_coverageAmount * baseRate * durationFactor * utilizationFactor)/ (1e18 * 1e18 * 1e18);

        return requiredPremium;

    }


    function purchasePolicy (address _stablecoin, uint256 _coverageAmount, uint256 _durationInDays, Severity _severity)
    public payable returns (uint256) {
 
        uint256 _durationInSeconds = _durationInDays * 1 days;
        uint256 requiredPremium = calculatePremium(
            _coverageAmount,
            _durationInSeconds,
            _severity
        );

        require(msg.value == requiredPremium, "Incorrect premium amount sent");

        uint256 expiry = block.timestamp + _durationInSeconds;

        uint256 newTokenId = _nextTokenId++;

        //mint nft to buyer
        _safeMint(msg.sender,newTokenId);

        policies[newTokenId] = PolicyData({
            stablecoin: _stablecoin,
            coverageAmount: _coverageAmount,
            expiryTimestamp: expiry,
            severity: _severity,
            isActive: true
        });

        require(insurancePool != address(0), "Insurance pool address not set");

        IInsurancePool pool = IInsurancePool(insurancePool);

        pool.receivePremiumAndCover{value: msg.value}(_coverageAmount);

        emit PolicyMinted(newTokenId, msg.sender, _stablecoin, _coverageAmount);

        return newTokenId;
    }

    //view policy details, memory used when variable only needed temporarily
    function getPolicyDetails(uint256 _tokenId) public view returns (PolicyData memory){
        //make sure token exists and do not expire

        require(policies[_tokenId].expiryTimestamp != 0, "Policy does not exist");
        return policies[_tokenId];
    }

    function setPriceFeed (address _stablecoin, address _priceFeedAddress) public onlyOwner {
        stablecoinPriceFeeds[_stablecoin] = _priceFeedAddress;
    }

    function _getPriceFeed(address _stablecoin) internal view returns (AggregatorV3Interface) {
        address feedAddress = stablecoinPriceFeeds[_stablecoin];
        require(feedAddress != address(0), "Price feed not set up for this stablecoin");
        return AggregatorV3Interface(feedAddress);
    }

    function _getPricePercentage(address _stablecoin) internal view returns (uint256){
        AggregatorV3Interface priceFeed = _getPriceFeed(_stablecoin);

        //latestRoundData returns : (roundId, answer, startedAt, updatedAt, answeredInRound)
        //https://docs.chain.link/chainlink-local/api-reference/v022/aggregator-v3-interface
        (/*uint80 _roundId*/,
        int256 answer, // we want only the price
        /*uint256 _startedAt*/,
        /*uint256 _updatedAt*/,
        /*uint80 _answeredInRound*/
        )  = priceFeed.latestRoundData();

        // price returrned by chain link is scaled by 10^8
        //stablecoin is pegged to 1 usd, feed is X/USD (DAI/USD)
        // if peg is 10^8 a price of 0.95 USD would be 95,000,000
        //number of decimals the value will have
        uint256 decimals = priceFeed.decimals();

        uint256 pegValue = 10**decimals;

        require(answer >0, "Chainlink price is invalid or zero");

        uint256 pricePercentage = (uint256(answer) * 100)/pegValue;
        return pricePercentage;
    }

    function testGetPricePercentage(address _stablecoin) public view returns (uint256) {
        return _getPricePercentage(_stablecoin);
    }

    function testGetPayoutPercentage(Severity _severity, uint256 _currentPricePercent) 
    public pure returns (uint256) {
        return _getPayoutPercentage(_severity, _currentPricePercent); 
    }

    function _getDepegThreshold (Severity _severity) internal pure returns (uint256) {
        if (_severity == Severity.Mild) {
            return 97;
        }
        if (_severity == Severity.Moderate) {
            return 90;
        }
        if (_severity == Severity.Severe) {
            return 80;
        }
        return 100;
    }


    // owner NFT can file a claim
    function fileClaim (uint256 _tokenId) public {
        //check ownership
        require(ownerOf(_tokenId) == msg.sender, "Not policy owner");

        PolicyData storage policy = policies[_tokenId];

        require(policy.isActive, "Policy inactive or already claimed");
        require(block.timestamp <= policy.expiryTimestamp, "Policy expired");

        //verify depeg chainlink oracle price /depeg detection

        uint256 currentPricePercent = _getPricePercentage(policy.stablecoin);
        uint256 payoutPercent = _getPayoutPercentage(policy.severity,currentPricePercent);

        require (payoutPercent > 0, "Depeg condition not met for policy severity tier");

        //calculate final payout (coverage amount * payment percentage) /100
        uint256 payoutAmount = (policy.coverageAmount * payoutPercent)/100;

        require(insurancePool != address(0), "Insurance pool address not set");

        IInsurancePool pool = IInsurancePool(insurancePool);

        //mark as inactive to prevent double claims
        policy.isActive = false;

        pool.executePayout(payable(msg.sender),payoutAmount);

        //notify pool that the cover is no longer active
        pool.reduceActiveCover(policy.coverageAmount);

        emit PolicyClaimed(_tokenId);
    }


    function _getPayoutPercentage (Severity _severity, uint256 _currentPricePercent) 
    internal pure returns (uint256){

        uint256 depegThreshold = _getDepegThreshold(_severity);

        if (_currentPricePercent > depegThreshold) {
            return 0;
        }

        return depegThreshold - _currentPricePercent;
    }

    // process the expiry of a policy without a claim
    //user or bot calls expiryPolicy(_tokenId) on DepegInsuranceNFT
    function expirePolicy(uint256 _tokenId) public {
        PolicyData storage policy = policies[_tokenId];

        require(policy.isActive, "Policy is already inactive (claimed or expired");

        require(block.timestamp > policy.expiryTimestamp, "Policy has not yet expired");

        policy.isActive = false;

        require(insurancePool != address(0), "Insurance pool address not set");

        IInsurancePool pool = IInsurancePool (insurancePool);
        // reduce liability by coverage amount
        pool.reduceActiveCover(policy.coverageAmount);
    }

}
