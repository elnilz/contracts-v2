// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "../common/ExchangeRate.sol";
import "../common/CashGroup.sol";
import "../common/AssetRate.sol";
import "../common/PerpetualToken.sol";
import "../storage/TokenHandler.sol";
import "../storage/StorageLayoutV1.sol";

contract Views is StorageLayoutV1 {
    using CashGroup for CashGroupParameters;
    using TokenHandler for Token;

    function getMaxCurrencyId() external view returns (uint16) {
        return maxCurrencyId;
    }

    function getCurrency(uint16 currencyId) external view returns (Token memory) {
        return TokenHandler.getToken(currencyId, false);
    }

    function getUnderlying(uint16 currencyId) external view returns (Token memory) {
        return TokenHandler.getToken(currencyId, true);
    }

    function getETHRateStorage(uint16 currencyId) external view returns (ETHRateStorage memory) {
        return underlyingToETHRateMapping[currencyId];
    }

    function getETHRate(uint16 currencyId) external view returns (ETHRate memory) {
        return ExchangeRate.buildExchangeRate(currencyId);
    }

    function getCurrencyAndRate(uint16 currencyId) external view returns (Token memory, ETHRate memory) {
        return (
            TokenHandler.getToken(currencyId, false),
            ExchangeRate.buildExchangeRate(currencyId)
        );
    }

    function getCashGroup(uint16 currencyId) external view returns (CashGroupParameterStorage memory) {
        return cashGroupMapping[currencyId];
    }

    function getAssetRateStorage(uint16 currencyId) external view returns (AssetRateStorage memory) {
        return assetToUnderlyingRateMapping[currencyId];
    }

    function getAssetRate(uint16 currencyId) external view returns (AssetRateParameters memory) {
        return AssetRate.buildAssetRate(currencyId);
    }

    function getCashGroupAndRate(
        uint16 currencyId
    ) external view returns (CashGroupParameterStorage memory, AssetRateParameters memory) {
        CashGroupParameterStorage memory cg = cashGroupMapping[currencyId];
        if (cg.maxMarketIndex == 0) {
            // No markets listed for the currency id
            return (cg, AssetRateParameters(address(0), 0, 0));
        }

        return (cg, AssetRate.buildAssetRate(currencyId));
    }

    function getActiveMarkets(uint16 currencyId) external view returns (MarketParameters[] memory) {
        uint blockTime = block.timestamp;
        return _getActiveMarketsAtBlockTime(currencyId, blockTime);
    }

    function getActiveMarketsAtBlockTime(
        uint16 currencyId,
        uint32 blockTime
    ) external view returns (MarketParameters[] memory) {
        return _getActiveMarketsAtBlockTime(currencyId, blockTime);
    }

    function _getActiveMarketsAtBlockTime(
        uint currencyId,
        uint blockTime
    ) internal view returns (MarketParameters[] memory) {
        (
            CashGroupParameters memory cashGroup,
            MarketParameters[] memory markets
        ) = CashGroup.buildCashGroup(currencyId);

        for (uint i = 1; i <= cashGroup.maxMarketIndex; i++) {
            cashGroup.getMarket(markets, i, blockTime, true);
        }

        return markets;
    }

    function getInitializationParameters(
        uint16 currencyId
    ) external view returns (int[] memory, int[] memory) {
        CashGroupParameterStorage memory cg = cashGroupMapping[currencyId];
        return PerpetualToken.getInitializationParameters(currencyId, cg.maxMarketIndex);
    }

    function getPerpetualDepositParameters(
        uint16 currencyId
    ) external view returns (int[] memory, int[] memory) {
        CashGroupParameterStorage memory cg = cashGroupMapping[currencyId];
        return PerpetualToken.getDepositParameters(currencyId, cg.maxMarketIndex);
    }

    function getPerpetualTokenAddress(uint16 currencyId) external view returns (address) {
        return PerpetualToken.getPerpetualTokenAddress(currencyId);
    }

    function getOwner() external view returns (address) { return owner; }

    function getAccountContext(
        address account
    ) external view returns (AccountStorage memory) {
        return accountContextMapping[account];
    }

    function getAccountBalance(
        uint16 currencyId,
        address account
    ) external view returns (int, int) {
        return BalanceHandler.getBalanceStorage(account, currencyId);
    }

    function getAccountPortfolio(
        address account
    ) external view returns (PortfolioAsset[] memory) {
        PortfolioState memory portfolioState = PortfolioHandler.buildPortfolioState(account, 0);
        return portfolioState.storedAssets;
    }

    function getifCashAssets(
        address account
    ) external view returns (PortfolioAsset[] memory) {
        AccountStorage memory accountContext = accountContextMapping[account];

        if (accountContext.bitmapCurrencyId == 0) {
            return new PortfolioAsset[](0);
        }

        return BitmapAssetsHandler.getifCashArray(
            account,
            accountContext.bitmapCurrencyId,
            accountContext.nextMaturingAsset
        );
    }

    function calculatePerpetualTokensToMint(
        uint16 currencyId,
        uint88 amountToDepositExternalPrecision
    ) external view returns (uint) {
        Token memory token = TokenHandler.getToken(currencyId, false);
        int amountToDepositInternal = token.convertToInternal(int(amountToDepositExternalPrecision));
        PerpetualTokenPortfolio memory perpToken = PerpetualToken.buildPerpetualTokenPortfolio(currencyId);
        AccountStorage memory accountContext = accountContextMapping[perpToken.tokenAddress];

        (int tokensToMint, /* */) = PerpetualToken.calculateTokensToMint(
            perpToken,
            accountContext,
            amountToDepositInternal,
            block.timestamp
        );

        return SafeCast.toUint256(tokensToMint);
    }

    fallback() external {
        revert("Method not found");
    }
}