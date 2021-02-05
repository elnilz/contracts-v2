// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;

contract MockCToken {
    uint private _answer;
    uint private _supplyRate;
    uint8 public decimals;
    string public symbol = "cMock";

    constructor(uint8 _decimals) {
        decimals = _decimals;
    }

    function setAnswer(uint a) external {
        _answer = a;
    }

    function setSupplyRate(uint a) external {
        _supplyRate = a;
    }

    function exchangeRateCurrent() external view returns (uint) {
        return _answer;
    }

    function supplyRatePerBlock() external view returns (uint) {
        return _supplyRate;
    }
}


