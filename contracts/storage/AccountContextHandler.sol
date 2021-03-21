// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./StorageLayoutV1.sol";
import "./BalanceHandler.sol";
import "./PortfolioHandler.sol";

library AccountContextHandler {
    using PortfolioHandler for PortfolioState;

    bytes18 private constant ZERO = bytes18(0);
    
    function getAccountContext(
        address account
    ) internal view returns (AccountStorage memory) {
        bytes32 slot = keccak256(abi.encode(account, "account.context"));
        bytes32 data;

        assembly { data := sload(slot) }

        return AccountStorage({
            nextMaturingAsset: uint40(uint(data)),
            hasDebt: bytes1(data << 208) == 0x01,
            assetArrayLength: uint8(uint(data >> 48)),
            bitmapCurrencyId: uint16(uint(data >> 56)),
            activeCurrencies: bytes18(data << 40)
        });
    }

    function setAccountContext(
        AccountStorage memory accountContext,
        address account
    ) internal {
        bytes32 slot = keccak256(abi.encode(account, "account.context"));
        bytes32 data = (
            bytes32(uint(accountContext.nextMaturingAsset)) |
            bytes32(accountContext.hasDebt ? bytes1(0x01) : bytes1(0x00)) >> 208 |
            bytes32(uint(accountContext.assetArrayLength)) << 48 |
            bytes32(uint(accountContext.bitmapCurrencyId)) << 56 |
            bytes32(accountContext.activeCurrencies) >> 40
        );

        assembly { sstore (slot, data) }
    }

    /**
     * @notice Checks if a currency id (uint16 max) is in the 9 slots in the account
     * context active currencies list.
     */
    function isActiveCurrency(
        AccountStorage memory accountContext,
        uint currencyId
    ) internal pure returns (bool) {
        bytes18 currencies = accountContext.activeCurrencies;
        require(
            currencyId != 0 && currencyId <= type(uint16).max,
            "AC: invalid currency id"
        );
        
        if (accountContext.bitmapCurrencyId == currencyId) return true;

        while (currencies != ZERO) {
            if (uint(uint16(bytes2(currencies))) == currencyId) return true;
            currencies = currencies << 16;
        }

        return false;
    }

    function getActiveCurrencyBytes(
        AccountStorage memory accountContext
    ) internal pure returns (bytes20) {
        // TODO: we could just make account context 32 bytes and this would be easier...
        if (accountContext.bitmapCurrencyId == 0) {
            return bytes20(accountContext.activeCurrencies);
        } else {
            // Prepend the bitmap currency id if it is set
            return bytes20(
                bytes20(bytes2(accountContext.bitmapCurrencyId)) |
                bytes20(accountContext.activeCurrencies) >> 16
            );
        }
    }

    function storeAssetsAndUpdateContext(
        AccountStorage memory accountContext,
        address account,
        PortfolioState memory portfolioState
    ) internal {
        (
            bool hasDebt,
            bytes32 portfolioCurrencies,
            uint8 assetArrayLength,
            uint40 nextMaturingAsset
        ) = portfolioState.storeAssets(account);
        accountContext.hasDebt = hasDebt || accountContext.hasDebt;
        accountContext.assetArrayLength = assetArrayLength;
        accountContext.nextMaturingAsset = nextMaturingAsset;

        uint lastCurrency;
        while (portfolioCurrencies != 0) {
            uint currencyId = uint(uint16(bytes2(portfolioCurrencies)));
            if (currencyId != lastCurrency) setActiveCurrency(accountContext, currencyId, true);
            lastCurrency = currencyId;

            portfolioCurrencies = portfolioCurrencies << 16;
        }
    }

    /**
     * @notice Iterates through the active currency list and removes, inserts or does nothing
     * to ensure that the active currency list is an ordered byte array of uint16 currency ids
     * that refer to the currencies that an account is active in.
     *
     * This is called to ensure that currencies are active when the account has a non zero cash balance,
     * a non zero perpetual token balance or a portfolio asset.
     */
    function setActiveCurrency(
        AccountStorage memory accountContext,
        uint currencyId,
        bool isActive
    ) internal pure {
        require(
            currencyId != 0 && currencyId <= type(uint16).max,
            "AC: invalid currency id"
        );
        
        // If the bitmapped currency is already set then return here. Turning off the bitmap currency
        // id requires other logical handling so we will do it elsewhere.
        if (isActive && accountContext.bitmapCurrencyId == currencyId) return;

        bytes18 prefix;
        bytes18 suffix = accountContext.activeCurrencies;
        uint shifts;

        /**
         * There are six possible outcomes from this search:
         * 1. The currency id is in the list
         *      - it must be set to active, do nothing
         *      - it must be set to inactive, shift suffix and concatenate
         * 2. The current id is greater than the one in the search:
         *      - it must be set to active, append to prefix and then concatenate the suffix,
         *        ensure that we do not lose the last 2 bytes if set.
         *      - it must be set to inactive, it is not in the list, do nothing
         * 3. Reached the end of the list:
         *      - it must be set to active, check that the last two bytes are not set and then
         *        append to the prefix
         *      - it must be set to inactive, do nothing
         */
        while (suffix != ZERO) {
            uint cid = uint(uint16(bytes2(suffix)));
            // if matches and isActive then return, already in list
            if (cid == currencyId && isActive) return;
            // if matches and not active then shift suffix to remove
            if (cid == currencyId && !isActive) {
                suffix = suffix << 16;
                accountContext.activeCurrencies = prefix | suffix >> (shifts * 16);
                return;
            }

            // if greater than and isActive then insert into prefix
            if (cid > currencyId && isActive) {
                prefix = prefix | bytes18(bytes2(uint16(currencyId))) >> (shifts * 16);
                // check that the total length is not greater than 9
                require(
                    accountContext.activeCurrencies[16] == 0x00 && accountContext.activeCurrencies[17] == 0x00,
                    "AC: too many currencies"
                );

                // append the suffix
                accountContext.activeCurrencies = prefix | suffix >> ((shifts + 1) * 16);
                return;
            }

            // if past the point of the currency id and not active, not in list
            if (cid > currencyId && !isActive) return;

            prefix = prefix | (bytes18(bytes2(suffix)) >> (shifts * 16));
            suffix = suffix << 16;
            shifts += 1;
        }

        // If reached this point and not active then return
        if (!isActive) return;

        // if end and isActive then insert into suffix, check max length
        require(
            accountContext.activeCurrencies[16] == 0x00 && accountContext.activeCurrencies[17] == 0x00,
            "AC: too many currencies"
        );
        accountContext.activeCurrencies = prefix | bytes18(bytes2(uint16(currencyId))) >> (shifts * 16);
    }
}