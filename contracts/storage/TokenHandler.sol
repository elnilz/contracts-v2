// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../math/SafeInt256.sol";
import "./StorageLayoutV1.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

struct Token {
    address tokenAddress;
    int decimalPlaces;
    bool hasTransferFee;
}

/**
 * @notice Handles deposits and withdraws for ERC20 tokens
 */
library TokenHandler {
    using SafeInt256 for int256;
    using SafeMath for uint256;

    int internal constant INTERNAL_TOKEN_PRECISION = 1e9;
    uint internal constant TOKEN_STORAGE_SLOT = 1;
    // TODO: hardcode this or move it into an internal storage slot
    address internal constant NOTE_TOKEN_ADDRESS = address(0);

    /**
     * @notice Gets token data for a particular currency id
     */
    function getToken(
        uint currencyId
    ) internal view returns (Token memory) {
        bytes32 slot = keccak256(abi.encode(currencyId, TOKEN_STORAGE_SLOT));
        bytes32 data;

        assembly {
            data := sload(slot)
        }
        address assetTokenAddress = address(bytes20(data << 96));
        bool tokenHasTransferFee = bytes1(data << 88) != 0x00;
        uint8 tokenDecimalPlaces = uint8(bytes1(data << 80));

        return Token({
            tokenAddress: assetTokenAddress,
            hasTransferFee: tokenHasTransferFee,
            decimalPlaces: int(10 ** tokenDecimalPlaces)
        });
    }

    /**
     * @notice Handles token deposits into Notional. If there is a transfer fee then we must
     * calculate the net balance after transfer.
     */
    function deposit(
        Token memory token,
        address account,
        uint amount 
    ) private returns (int) {
        if (token.hasTransferFee) {
            // Must deposit from the token and calculate the net transfer
            uint startingBalance = IERC20(token.tokenAddress).balanceOf(address(this));
            SafeERC20.safeTransferFrom(
                IERC20(token.tokenAddress), account, address(this), amount
            );
            uint endingBalance = IERC20(token.tokenAddress).balanceOf(address(this));

            return int(endingBalance.sub(startingBalance));
        }

        SafeERC20.safeTransferFrom(
            IERC20(token.tokenAddress), account, address(this), amount
        );

        return int(amount);
    }

    /**
     * @notice Handles transfers into and out of the system. Crucially we must
     * translate the amount from internal balance precision to the external balance
     * precision.
     */
    function transfer(
        Token memory token,
        address account,
        int netTransfer
    ) internal returns (int) {
        // Convert internal balances in 1e9 to token decimals:
        // balance * tokenDecimals / 1e9
        int transferBalance = netTransfer 
            .mul(token.decimalPlaces)
            .div(INTERNAL_TOKEN_PRECISION);

        if (transferBalance > 0) {
            // Deposits must account for transfer fees.
            transferBalance = deposit(token, account, uint(transferBalance));
        } else {
            SafeERC20.safeTransfer(IERC20(token.tokenAddress), account, uint(transferBalance.neg()));
        }

        // Convert transfer balance back into internal precision
        return transferBalance.mul(INTERNAL_TOKEN_PRECISION).div(token.decimalPlaces);
    }

    function transferIncentive(
        address account,
        uint tokensToTransfer
    ) internal {
        SafeERC20.safeTransfer(IERC20(NOTE_TOKEN_ADDRESS), account, tokensToTransfer);
    }
}