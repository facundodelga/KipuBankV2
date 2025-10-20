// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract MockAggregator is AggregatorV3Interface {
    uint8 public override decimals;
    string public override description;
    uint256 public override version = 1;

    int256 private _answer;

    constructor(uint8 _decimals, int256 initialAnswer) {
        decimals = _decimals;
        _answer = initialAnswer;
        description = "Mock Aggregator";
    }

    function setAnswer(int256 a) external {
        _answer = a;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, _answer, block.timestamp, block.timestamp, 1);
    }

    function getRoundData(uint80)
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, _answer, block.timestamp, block.timestamp, 1);
    }
}
