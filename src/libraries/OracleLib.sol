// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title OracleLib
 * @author Handaya
 * @notice This library is used to check the Chainlink Oracle for stale data
 * If a price is stale, the function will revert and render the DSCEngine Unusable
 * we want the DSCEngine freeze if  porices become stale
 * So if the Chainlink network explode and you have a lot of money in the protocol...
 * shit happens :3
 */
library OracleLib {
    error OracleLib_StalePriceFeed();

    uint256 public constant TIMEOUT = 3 hours;

    function staleCheckLatestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();

        uint256 secondsSince = block.timestamp - updatedAt;

        if (secondsSince > TIMEOUT) {
            revert OracleLib_StalePriceFeed();
        }

        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
