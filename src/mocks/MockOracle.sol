// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";

contract MockOracle is AggregatorV3Interface {
    int256 private _answer;
    uint8 private immutable _DECIMALS;
    string private _description;

    constructor(int256 answer_, uint8 decimals_, string memory description_) {
        _answer = answer_;
        _DECIMALS = decimals_;
        _description = description_;
    }

    function setAnswer(int256 answer_) external {
        _answer = answer_;
    }

    function decimals() external view override returns (uint8) { return _DECIMALS; }
    function description() external view override returns (string memory) { return _description; }
    function version() external pure override returns (uint256) { return 1; }

    function getRoundData(uint80 _roundId)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, block.timestamp, block.timestamp, _roundId);
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, _answer, block.timestamp, block.timestamp, 1);
    }
}
