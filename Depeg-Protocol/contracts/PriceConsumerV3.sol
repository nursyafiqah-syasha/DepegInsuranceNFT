// SPDX-License-Identifier: MIT
// source: https://medium.com/@mkhedry3123/how-to-test-chainlink-oracle-in-hardhat-using-mocks-12691c5d8c1f
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract PriceConsumerV3 {
    AggregatorV3Interface internal priceFeed;

    
    constructor(address _feedAddress) {
        priceFeed = AggregatorV3Interface(
            _feedAddress
        );
    }

    function getLatestPrice() public view returns (int) {
        (
            /* uint80 roundID */,
            int price,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
        ) = priceFeed.latestRoundData();
        return price;
    }
}