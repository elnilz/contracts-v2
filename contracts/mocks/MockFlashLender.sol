// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "interfaces/aave/IFlashLoanReceiver.sol";

contract MockFlashLender {
    function executeFlashLoan(
        address[] calldata assets,
        uint256[] calldata amounts,
        IFlashLoanReceiver receiver,
        bytes calldata params
    ) external {
        uint256[] memory premiums = new uint256[](assets.length);

        for (uint256 i; i < assets.length; i++) {
            // 9 basis point fee
            premiums[i] = (amounts[i] * 9) / 10000;
            IERC20(assets[i]).transfer(address(receiver), amounts[i]);
        }

        bool success = receiver.executeOperation(assets, amounts, premiums, msg.sender, params);
        require(success);

        for (uint256 i; i < assets.length; i++) {
            IERC20(assets[i]).transferFrom(
                address(receiver),
                address(this),
                amounts[i] + premiums[i]
            );
        }
    }
}
