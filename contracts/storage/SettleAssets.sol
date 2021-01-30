// SPDX-License-Identifier: GPL-3.0-only
pragma solidity >0.7.0;
pragma experimental ABIEncoderV2;

import "./StorageReader.sol";
import "./PortfolioHandler.sol";
import "../common/ExchangeRate.sol";
import "../math/SafeInt256.sol";

contract SettleAssets is StorageReader {
    using SafeInt256 for int;
    using ExchangeRate for Rate;
    using PortfolioHandler for PortfolioState;

    /**
     * @notice Provisions a balance context array for settling assets
     */
    function getSettleAssetBalanceContext(
        PortfolioState memory portfolioState,
        uint blockTime
    ) internal pure returns (BalanceContext[] memory) {
        uint currenciesSettled;
        uint lastCurrencyId;
        for (uint i; i < portfolioState.storedAssets.length; i++) {
            if (portfolioState.storedAssets[i].maturity > blockTime) continue;
            // Assume that this is sorted by cash group and maturity, currencyId = 0 is unused so this
            // will work for the first asset
            if (lastCurrencyId != portfolioState.storedAssets[i].currencyId) {
                lastCurrencyId = portfolioState.storedAssets[i].currencyId;
                currenciesSettled++;
            }
        }

        return new BalanceContext[](currenciesSettled);
    }

    /**
     * @notice Settles a liquidity token which requires getting the claims on both cash and fCash,
     * converting the fCash portion and also updating the market state (if in stateful version)
     */
    function settleLiquidityToken(
        PortfolioAsset memory asset,
        BalanceContext memory balance,
        Rate memory settlementRate
    ) internal view returns (int, MarketStorage memory, uint80) {
        // Storage Read
        MarketStorage memory marketStorage = marketStateMapping[asset.currencyId][asset.maturity];
        // Storage Read
        int totalLiquidity = marketTotalLiquidityMapping[asset.currencyId][asset.maturity];

        int fCash = int(marketStorage.totalfCash).mul(asset.notional).div(totalLiquidity);
        int cashClaim = int(marketStorage.totalCurrentCash).mul(asset.notional).div(totalLiquidity);
        int assetCash = cashClaim.add(settlementRate.convertInternalFromUnderlying(fCash));

        require(fCash <= int(marketStorage.totalfCash), "S: fCash overflow");
        require(cashClaim <= int(marketStorage.totalCurrentCash), "S: cash overflow");
        require(asset.notional <= totalLiquidity, "S: liquidity overflow");
        marketStorage.totalfCash = marketStorage.totalfCash - uint80(fCash);
        marketStorage.totalCurrentCash = marketStorage.totalCurrentCash - uint80(cashClaim);

        return (
            assetCash,
            marketStorage,
            // No truncation, totalLiquidity is stored as uint80
            uint80(totalLiquidity - asset.notional)
        );
    }

    /**
     * @notice View version of settle asset with a call to getSettlementRateView, the reason here is that
     * in the stateful version we will set the settlement rate if it is not set.
     */
    function getSettleAssetContextView(
        address account,
        PortfolioState memory portfolioState,
        AccountStorage memory accountContext,
        uint blockTime
    ) internal view returns (BalanceContext[] memory) {
        BalanceContext[] memory balanceContext = getSettleAssetBalanceContext(portfolioState, blockTime);
        Rate memory settlementRate;
        BalanceContext memory currentContext;
        uint currencyIndex;
        uint lastCurrencyId;
        uint lastMaturity;

        for (uint i; i < portfolioState.storedAssets.length; i++) {
            PortfolioAsset memory asset = portfolioState.storedAssets[i];
            if (asset.maturity > blockTime) continue;

            if (lastCurrencyId != asset.currencyId) {
                lastCurrencyId = asset.currencyId;
                lastMaturity = 0;
                // Storage Read inside getBalanceContext
                balanceContext[currencyIndex] = getBalanceContext(account, lastCurrencyId, accountContext);
                currentContext = balanceContext[currencyIndex];
                currencyIndex++;
            }

            if (lastMaturity != asset.maturity) {
                // Storage Read inside getSettlementRateView
                settlementRate = getSettlementRateView(asset.currencyId, asset.maturity);
            }

            int assetCash;
            if (asset.assetType == 1 /* FCASH_ASSET_TYPE */) {
                assetCash = settlementRate.convertInternalFromUnderlying(asset.notional);
            } else if (asset.assetType == 2 /* LIQUIDITY_TOKEN_ASSET_TYPE */) {
                (assetCash, /* */, /* */) = settleLiquidityToken(
                    asset,
                    currentContext,
                    settlementRate
                );
            }

            currentContext.cashBalance = currentContext.cashBalance.add(assetCash);
            currentContext.storageState = BalanceStorageState.CashBalanceUpdate;
            portfolioState.deleteAsset(i);
        }

        return balanceContext;
    }

    /**
     * @notice Stateful version of settle asset, the only difference is the call to getSettlementRateStateful
     */
    function getSettleAssetContextStateful(
        address account,
        PortfolioState memory portfolioState,
        AccountStorage memory accountContext,
        uint blockTime
    ) internal returns (BalanceContext[] memory) {
        BalanceContext[] memory balanceContext = getSettleAssetBalanceContext(portfolioState, blockTime);
        Rate memory settlementRate;
        BalanceContext memory currentContext;
        uint currencyIndex;
        uint lastCurrencyId;
        uint lastMaturity;

        for (uint i; i < portfolioState.storedAssets.length; i++) {
            PortfolioAsset memory asset = portfolioState.storedAssets[i];
            if (asset.maturity > blockTime) continue;

            if (lastCurrencyId != asset.currencyId) {
                lastCurrencyId = asset.currencyId;
                lastMaturity = 0;
                // Storage Read inside getBalanceContext
                balanceContext[currencyIndex] = getBalanceContext(account, lastCurrencyId, accountContext);
                currentContext = balanceContext[currencyIndex];
                currencyIndex++;
            }

            if (lastMaturity != asset.maturity) {
                // Storage Read / Write inside getSettlementRateStateful
                settlementRate = getSettlementRateStateful(asset.currencyId, asset.maturity, blockTime);
            }

            int assetCash;
            if (asset.assetType == 1 /* FCASH_ASSET_TYPE */) {
                assetCash = settlementRate.convertInternalFromUnderlying(asset.notional);
            } else if (asset.assetType == 2 /* LIQUIDITY_TOKEN_ASSET_TYPE */) {
                MarketStorage memory marketState;
                uint80 totalLiquidity;
                (assetCash, marketState, totalLiquidity) = settleLiquidityToken(
                    asset,
                    currentContext,
                    settlementRate
                );

                // In stateful we update the market as well.
                // Storage Write
                marketStateMapping[asset.currencyId][asset.maturity] = marketState;
                // Storage Write
                marketTotalLiquidityMapping[asset.currencyId][asset.maturity] = totalLiquidity;
            }

            currentContext.cashBalance = currentContext.cashBalance.add(assetCash);
            currentContext.storageState = BalanceStorageState.CashBalanceUpdate;
            portfolioState.deleteAsset(i);
        }

        return balanceContext;
    }

    /**
     * @dev View version of getSettlementRate, if settlement rate is not set will fetch the most current rate.
     */
    function getSettlementRateView(
        uint currencyId,
        uint maturity
    ) internal view returns (Rate memory) {
        // Storage Read
        SettlementRateStorage memory settlementRate = assetToUnderlyingSettlementRateMapping[currencyId][maturity];

        // Rate has not been set so we fetch the latest exchange rate
        if (settlementRate.timestamp == 0) {
            // Storage Read
            RateStorage memory assetRate = assetToUnderlyingRateMapping[currencyId];
            return ExchangeRate.buildExchangeRate(assetRate);
        }

        return ExchangeRate.buildSettlementRate(
            settlementRate.rate,
            settlementRate.rateDecimalPlaces
        );
    }

    /**
     * @dev View version of getSettlementRate, if settlement rate is not set will set it. Ideally, settlement rates
     * are set as close to maturity as possible but this may not always be possible. As long as all assets at a maturity
     * use the same settlement rate then we know that all balances will net out appropriately.
     */
    function getSettlementRateStateful(
        uint currencyId,
        uint maturity,
        uint blockTime
    ) internal returns (Rate memory) {
        // Storage Read
        SettlementRateStorage memory settlementRate = assetToUnderlyingSettlementRateMapping[currencyId][maturity];

        // Rate has not been set so we fetch the latest exchange rate and set it
        if (settlementRate.timestamp == 0) {
            RateStorage memory assetRate = assetToUnderlyingRateMapping[currencyId];
            Rate memory exchangeRate = ExchangeRate.buildExchangeRate(assetRate);

            require(blockTime != 0 && blockTime <= type(uint40).max, "S: invalid timestamp");
            require(exchangeRate.rate > 0 && exchangeRate.rate <= type(uint128).max, "S: rate overflow");
            
            // Storage Write
            assetToUnderlyingSettlementRateMapping[currencyId][maturity] = SettlementRateStorage({
                rateDecimalPlaces: assetRate.rateDecimalPlaces,
                timestamp: uint40(blockTime),
                rate: uint128(exchangeRate.rate)
            });
            // TODO: emit event here

            return exchangeRate;
        }

        return ExchangeRate.buildSettlementRate(
            settlementRate.rate,
            settlementRate.rateDecimalPlaces
        );
    }

}

contract MockSettleAssets is SettleAssets {
    using PortfolioHandler for PortfolioState;

    function setMaxCurrencyId(uint16 num) external {
        maxCurrencyId = num;
    }

    function setAssetArray(
        address account,
        AssetStorage[] memory a
    ) external {
        // Clear array
        delete assetArrayMapping[account];

        AssetStorage[] storage s = assetArrayMapping[account];
        for (uint i; i < a.length; i++) {
            s.push(a[i]);
        }
    }

    function setAssetRateMapping(
        uint id,
        RateStorage calldata rs
    ) external {
        require(id <= maxCurrencyId, "invalid currency id");
        assetToUnderlyingRateMapping[id] = rs;
    }

    function setMarketState(
        uint id,
        uint maturity,
        MarketStorage calldata ms,
        uint80 totalLiquidity
    ) external {
        require(id <= maxCurrencyId, "invalid currency id");
        marketStateMapping[id][maturity] = ms;
        marketTotalLiquidityMapping[id][maturity] = totalLiquidity;
    }

    function getAssetArray(address account) external view returns (AssetStorage[] memory) {
        return assetArrayMapping[account];
    }

    function setAccountContext(
        address account,
        AccountStorage memory a
    ) external {
        accountContextMapping[account] = a;
    }

    function setAssetBitmap(
        address account,
        uint id,
        bytes memory bitmap
    ) external {
        assetBitmapMapping[account][id] = bitmap;
    }

    function setifCash(
        address account,
        uint id,
        uint maturity,
        int notional
    ) external {
        ifCashMapping[account][id][maturity] = notional;
    }

    function setBalance(
        address account,
        uint id,
        BalanceStorage calldata bs
    ) external {
        accountBalanceMapping[account][id] = bs;
    }

    function setSettlementRate(
        uint id,
        uint maturity,
        SettlementRateStorage calldata sr
    ) external {
        assetToUnderlyingSettlementRateMapping[id][maturity] = sr;
    }

    function _getSettleAssetContextView(
        address account,
        uint blockTime
    ) public view returns (
        BalanceContext[] memory,
        AccountStorage memory
    ) {
        (AccountStorage memory aContextView,
            PortfolioState memory pStateView) = getInitializeContext(account, blockTime, 0);

        BalanceContext[] memory bContextView = getSettleAssetContextView(
            account,
            pStateView,
            aContextView,
            blockTime
        );

        return (bContextView, aContextView);
    }

    function testSettleAssetArray(
        address account,
        uint blockTime
    ) public returns (
        BalanceContext[] memory,
        AccountStorage memory
    ) {
        (AccountStorage memory aContextView,
            PortfolioState memory pStateView) = getInitializeContext(account, blockTime, 0);
        (AccountStorage memory aContext,
            PortfolioState memory pState) = getInitializeContext(account, blockTime, 0);

        BalanceContext[] memory bContextView = getSettleAssetContextView(
            account,
            pStateView,
            aContextView,
            blockTime
        );

        BalanceContext[] memory bContext = getSettleAssetContextStateful(
            account,
            pState,
            aContext,
            blockTime
        );

        // assert(aContext.activeCurrencies == aContextView.activeCurrencies);
        // assert(aContext.nextMaturingAsset == aContextView.nextMaturingAsset);
        // assert(aContext.nextMaturingAsset > blockTime);

        assert(pStateView.storedAssetLength == pState.storedAssetLength);
        assert(pStateView.storedAssets.length == pState.storedAssets.length);
        // Assert that portfolio state is equal
        for (uint i; i < pStateView.storedAssets.length; i++) {
            assert(pStateView.storedAssets[i].currencyId == pState.storedAssets[i].currencyId);
            assert(pStateView.storedAssets[i].assetType == pState.storedAssets[i].assetType);
            assert(pStateView.storedAssets[i].maturity == pState.storedAssets[i].maturity);
            assert(pStateView.storedAssets[i].notional == pState.storedAssets[i].notional);
            assert(pStateView.storedAssets[i].storageState == pState.storedAssets[i].storageState);
        }

        // This will change the stored asset array
        pState.storeAssets(assetArrayMapping[account]);

        // Assert that balance context is equal
        assert(bContextView.length == bContext.length);
        for (uint i; i < bContextView.length; i++) {
            assert(bContextView[i].currencyId == bContext[i].currencyId);
            assert(bContextView[i].cashBalance == bContext[i].cashBalance);
            assert(bContextView[i].perpetualTokenBalance == bContext[i].perpetualTokenBalance);
            assert(bContextView[i].storageState == bContext[i].storageState);
        }

        return (bContext, aContext);
    }

}