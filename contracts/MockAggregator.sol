// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// Interfaz de Chainlink Price Feed (local hasta que se instale la dependencia)
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);
    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

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
