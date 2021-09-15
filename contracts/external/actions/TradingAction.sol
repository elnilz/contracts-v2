// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.7.0;
pragma abicoder v2;

import "../FreeCollateralExternal.sol";
import "../SettleAssetsExternal.sol";
import "../../internal/markets/Market.sol";
import "../../internal/markets/CashGroup.sol";
import "../../internal/markets/AssetRate.sol";
import "../../internal/balances/BalanceHandler.sol";
import "../../internal/portfolio/PortfolioHandler.sol";
import "../../internal/portfolio/TransferAssets.sol";
import "../../math/SafeInt256.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

library TradingAction {
    using PortfolioHandler for PortfolioState;
    using AccountContextHandler for AccountContext;
    using Market for MarketParameters;
    using CashGroup for CashGroupParameters;
    using AssetRate for AssetRateParameters;
    using SafeInt256 for int256;
    using SafeMath for uint256;

    event LendBorrowTrade(
        address indexed account,
        uint16 indexed currencyId,
        uint40 maturity,
        int256 netAssetCash,
        int256 netfCash
    );

    event AddRemoveLiquidity(
        address indexed account,
        uint16 indexed currencyId,
        uint40 maturity,
        int256 netAssetCash,
        int256 netfCash,
        int256 netLiquidityTokens
    );

    event SettledCashDebt(
        address indexed settledAccount,
        uint16 indexed currencyId,
        int256 amountToSettleAsset,
        int256 fCashAmount
    );

    event nTokenResidualPurchase(
        uint16 indexed currencyId,
        uint40 indexed maturity,
        int256 fCashAmountToPurchase,
        int256 netAssetCashNToken
    );

    /// @dev Used internally to manage stack issues
    struct TradeContext {
        int256 cash;
        int256 fCashAmount;
        int256 fee;
        int256 netCash;
        int256 totalFee;
        uint256 blockTime;
    }

    /// @notice Executes trades for a bitmapped portfolio, cannot be called directly
    /// @param account account to put fCash assets in
    /// @param bitmapCurrencyId currency id of the bitmap
    /// @param nextSettleTime used to calculate the relative positions in the bitmap
    /// @param trades tightly packed array of trades, schema is defined in global/Types.sol
    /// @return int256 netCash generated by trading, bool didIncurDebt if the bitmap had an fCash position go negative
    function executeTradesBitmapBatch(
        address account,
        uint16 bitmapCurrencyId,
        uint40 nextSettleTime,
        bytes32[] calldata trades
    ) external returns (int256, bool) {
        CashGroupParameters memory cashGroup = CashGroup.buildCashGroupStateful(bitmapCurrencyId);
        MarketParameters memory market;
        bool didIncurDebt;
        TradeContext memory c;
        c.blockTime = block.timestamp;

        for (uint256 i = 0; i < trades.length; i++) {
            uint256 maturity;
            (maturity, c.cash, c.fCashAmount) = _executeTrade(
                account,
                cashGroup,
                market,
                trades[i],
                c.blockTime
            );

            c.fCashAmount = BitmapAssetsHandler.addifCashAsset(
                account,
                bitmapCurrencyId,
                maturity,
                nextSettleTime,
                c.fCashAmount
            );

            didIncurDebt = didIncurDebt || (c.fCashAmount < 0);
            c.netCash = c.netCash.add(c.cash);
        }

        return (c.netCash, didIncurDebt);
    }

    /// @notice Executes trades for a bitmapped portfolio, cannot be called directly
    /// @param account account to put fCash assets in
    /// @param currencyId currency id to trade
    /// @param portfolioState used to update the positions in the portfolio
    /// @param trades tightly packed array of trades, schema is defined in global/Types.sol
    /// @return resulting portfolio state, int256 netCash generated by trading
    function executeTradesArrayBatch(
        address account,
        uint16 currencyId,
        PortfolioState memory portfolioState,
        bytes32[] calldata trades
    ) external returns (PortfolioState memory, int256) {
        CashGroupParameters memory cashGroup = CashGroup.buildCashGroupStateful(currencyId);
        MarketParameters memory market;
        TradeContext memory c;
        c.blockTime = block.timestamp;

        for (uint256 i = 0; i < trades.length; i++) {
            TradeActionType tradeType = TradeActionType(uint256(uint8(bytes1(trades[i]))));

            if (
                tradeType == TradeActionType.AddLiquidity ||
                tradeType == TradeActionType.RemoveLiquidity
            ) {
                revert("Disabled");
                /**
                 * Manual adding and removing of liquidity is currently disabled.
                 *
                 *  // Liquidity tokens can only be added by array portfolio
                 *  c.cash = _executeLiquidityTrade(
                 *      account,
                 *      cashGroup,
                 *      market,
                 *      tradeType,
                 *      trades[i],
                 *      portfolioState,
                 *      c.netCash
                 *  );
                 */
            } else {
                uint256 maturity;
                (maturity, c.cash, c.fCashAmount) = _executeTrade(
                    account,
                    cashGroup,
                    market,
                    trades[i],
                    c.blockTime
                );
                // Stack issues here :(
                _addfCashAsset(portfolioState, currencyId, maturity, c.fCashAmount);
            }

            c.netCash = c.netCash.add(c.cash);
        }

        return (portfolioState, c.netCash);
    }

    /// @dev Adds an fCash asset to the portfolio, used to clear the stack
    function _addfCashAsset(
        PortfolioState memory portfolioState,
        uint256 currencyId,
        uint256 maturity,
        int256 notional
    ) private pure {
        portfolioState.addAsset(currencyId, maturity, Constants.FCASH_ASSET_TYPE, notional);
    }

    /// @notice Executes a non-liquidity token trade
    /// @param account the initiator of the trade
    /// @param cashGroup parameters for the trade
    /// @param market market memory location to use
    /// @param trade bytes32 encoding of the particular trade
    /// @param blockTime the current block time
    /// Will Return:
    ///     maturity: maturity of the asset that was traded
    ///     cashAmount: a positive or negative cash amount accrued to the account
    ///     fCashAmount: a positive or negative fCash amount accrued to the account
    ///     fee: a positive fee balance that accrues to the reserve
    function _executeTrade(
        address account,
        CashGroupParameters memory cashGroup,
        MarketParameters memory market,
        bytes32 trade,
        uint256 blockTime
    )
        private
        returns (
            uint256 maturity,
            int256 cashAmount,
            int256 fCashAmount
        )
    {
        TradeActionType tradeType = TradeActionType(uint256(uint8(bytes1(trade))));
        if (tradeType == TradeActionType.PurchaseNTokenResidual) {
            (maturity, cashAmount, fCashAmount) = _purchaseNTokenResidual(
                cashGroup,
                blockTime,
                trade
            );
        } else if (tradeType == TradeActionType.SettleCashDebt) {
            (maturity, cashAmount, fCashAmount) = _settleCashDebt(account, cashGroup, blockTime, trade);
        } else if (tradeType == TradeActionType.Lend || tradeType == TradeActionType.Borrow) {
            (cashAmount, fCashAmount) = _executeLendBorrowTrade(
                cashGroup,
                market,
                tradeType,
                blockTime,
                trade
            );

            // This is a little ugly but required to deal with stack issues. We know the market is loaded with the proper
            // maturity inside _executeLendBorrowTrade
            maturity = market.maturity;
            emit LendBorrowTrade(
                account,
                uint16(cashGroup.currencyId),
                uint40(maturity),
                cashAmount,
                fCashAmount
            );
        } else {
            revert("Invalid trade type");
        }
    }

    /// @notice Executes a liquidity token trade, no fees incurred and only array portfolios may hold
    /// liquidity tokens.
    /// @param account the initiator of the trade
    /// @param cashGroup parameters for the trade
    /// @param market market memory location to use
    /// @param tradeType whether this is add or remove liquidity
    /// @param trade bytes32 encoding of the particular trade
    /// @param portfolioState the current account's portfolio state
    /// @param netCash the current net cash accrued in this batch of trades, can be
    //  used for adding liquidity
    /// @return cashAmount: a positive or negative cash amount accrued to the account
    function _executeLiquidityTrade(
        address account,
        CashGroupParameters memory cashGroup,
        MarketParameters memory market,
        TradeActionType tradeType,
        bytes32 trade,
        PortfolioState memory portfolioState,
        int256 netCash
    ) private returns (int256) {
        uint256 marketIndex = uint8(bytes1(trade << 8));
        // NOTE: this loads the market in memory
        cashGroup.loadMarket(market, marketIndex, true, block.timestamp);

        int256 cashAmount;
        int256 fCashAmount;
        int256 tokens;
        if (tradeType == TradeActionType.AddLiquidity) {
            cashAmount = int256((uint256(trade) >> 152) & type(uint88).max);
            // Setting cash amount to zero will deposit all net cash accumulated in this trade into
            // liquidity. This feature allows accounts to borrow in one maturity to provide liquidity
            // in another in a single transaction without dust. It also allows liquidity providers to
            // sell off the net cash residuals and use the cash amount in the new market without dust
            if (cashAmount == 0) cashAmount = netCash;

            // Add liquidity will check cash amount is positive
            (tokens, fCashAmount) = market.addLiquidity(cashAmount);
            cashAmount = cashAmount.neg(); // Report a negative cash amount in the event
        } else {
            tokens = int256((uint256(trade) >> 152) & type(uint88).max);
            (cashAmount, fCashAmount) = market.removeLiquidity(tokens);
            tokens = tokens.neg(); // Report a negative amount tokens in the event
        }

        {
            uint256 minImpliedRate = uint32(uint256(trade) >> 120);
            uint256 maxImpliedRate = uint32(uint256(trade) >> 88);
            // If minImpliedRate is not set then it will be zero
            require(market.lastImpliedRate >= minImpliedRate, "Trade failed, slippage");
            if (maxImpliedRate != 0)
                require(market.lastImpliedRate <= maxImpliedRate, "Trade failed, slippage");
        }

        // Add the assets in this order so they are sorted
        portfolioState.addAsset(
            cashGroup.currencyId,
            market.maturity,
            Constants.FCASH_ASSET_TYPE,
            fCashAmount
        );
        // Adds the liquidity token asset
        portfolioState.addAsset(
            cashGroup.currencyId,
            market.maturity,
            marketIndex + 1,
            tokens
        );

        emit AddRemoveLiquidity(
            account,
            cashGroup.currencyId,
            // This will not overflow for a long time
            uint40(market.maturity),
            cashAmount,
            fCashAmount,
            tokens
        );

        return cashAmount;
    }

    /// @notice Executes a lend or borrow trade
    /// @param cashGroup parameters for the trade
    /// @param market market memory location to use
    /// @param tradeType whether this is add or remove liquidity
    /// @param blockTime the current block time
    /// @param trade bytes32 encoding of the particular trade
    /// Returns (cashAmount, fCashAmount)
    ///     cashAmount: a positive or negative cash amount accrued to the account
    ///     fCashAmount: a positive or negative fCash amount accrued to the account
    function _executeLendBorrowTrade(
        CashGroupParameters memory cashGroup,
        MarketParameters memory market,
        TradeActionType tradeType,
        uint256 blockTime,
        bytes32 trade
    )
        private
        returns (
            int256 cashAmount,
            int256 fCashAmount
        )
    {
        uint256 marketIndex = uint256(uint8(bytes1(trade << 8)));
        // NOTE: this updates the market in memory
        cashGroup.loadMarket(market, marketIndex, false, blockTime);

        fCashAmount = int256(uint88(bytes11(trade << 16)));
        // fCash to account will be negative here
        if (tradeType == TradeActionType.Borrow) fCashAmount = fCashAmount.neg();

        cashAmount = market.executeTrade(
            cashGroup,
            fCashAmount,
            market.maturity.sub(blockTime),
            marketIndex
        );
        require(cashAmount != 0, "Trade failed, liquidity");

        uint256 rateLimit = uint256(uint32(bytes4(trade << 104)));
        if (rateLimit != 0) {
            if (tradeType == TradeActionType.Borrow) {
                // Do not allow borrows over the rate limit
                require(market.lastImpliedRate <= rateLimit, "Trade failed, slippage");
            } else {
                // Do not allow lends under the rate limit
                require(market.lastImpliedRate >= rateLimit, "Trade failed, slippage");
            }
        }
    }

    /// @notice If an account has a negative cash balance we allow anyone to lend to to that account at a penalty
    /// rate to the 3 month market.
    /// @param account the account initiating the trade, used to check that self settlement is not possible
    /// @param cashGroup parameters for the trade
    /// @param blockTime the current block time
    /// @param trade bytes32 encoding of the particular trade
    /// @return 
    ///     maturity: the date of the three month maturity where fCash will be exchanged
    ///     cashAmount: a negative cash amount that the account must pay to the settled account
    ///     fCashAmount: a positive fCash amount that the account will receive
    function _settleCashDebt(
        address account,
        CashGroupParameters memory cashGroup,
        uint256 blockTime,
        bytes32 trade
    )
        internal
        returns (
            uint256,
            int256,
            int256
        )
    {
        address counterparty = address(uint256(trade) >> 88);
        // Allowing an account to settle itself would result in strange outcomes
        require(account != counterparty, "Cannot settle self");
        int256 amountToSettleAsset = int256(uint88(uint256(trade)));

        AccountContext memory counterpartyContext =
            AccountContextHandler.getAccountContext(counterparty);

        if (counterpartyContext.mustSettleAssets()) {
            counterpartyContext = SettleAssetsExternal.settleAccount(counterparty, counterpartyContext);
        }

        // This will check if the amountToSettleAsset is valid and revert if it is not. Amount to settle is a positive
        // number denominated in asset terms. If amountToSettleAsset is set equal to zero on the input, will return the
        // max amount to settle. This will update the balance storage on the counterparty.
        amountToSettleAsset = BalanceHandler.setBalanceStorageForSettleCashDebt(
            counterparty,
            cashGroup,
            amountToSettleAsset,
            counterpartyContext
        );

        // Settled account must borrow from the 3 month market at a penalty rate. This will fail if the market
        // is not initialized.
        uint256 threeMonthMaturity = DateTime.getReferenceTime(blockTime) + Constants.QUARTER;
        int256 fCashAmount =
            _getfCashSettleAmount(cashGroup, threeMonthMaturity, blockTime, amountToSettleAsset);
        // Defensive check to ensure that we can't inadvertently cause the settler to lose fCash.
        require(fCashAmount > 0);

        // It's possible that this action will put an account into negative free collateral. In this case they
        // will immediately become eligible for liquidation and the account settling the debt can also liquidate
        // them in the same transaction. Do not run a free collateral check here to allow this to happen.
        {
            PortfolioAsset[] memory assets = new PortfolioAsset[](1);
            assets[0].currencyId = cashGroup.currencyId;
            assets[0].maturity = threeMonthMaturity;
            assets[0].notional = fCashAmount.neg(); // This is the debt the settled account will incur
            assets[0].assetType = Constants.FCASH_ASSET_TYPE;
            // Can transfer assets, we have settled above
            counterpartyContext = TransferAssets.placeAssetsInAccount(
                counterparty,
                counterpartyContext,
                assets
            );
        }
        counterpartyContext.setAccountContext(counterparty);

        emit SettledCashDebt(
            counterparty,
            uint16(cashGroup.currencyId),
            amountToSettleAsset,
            fCashAmount.neg()
        );

        return (threeMonthMaturity, amountToSettleAsset.neg(), fCashAmount);
    }

    /// @dev Helper method to calculate the fCashAmount from the penalty settlement rate
    function _getfCashSettleAmount(
        CashGroupParameters memory cashGroup,
        uint256 threeMonthMaturity,
        uint256 blockTime,
        int256 amountToSettleAsset
    ) private view returns (int256) {
        uint256 oracleRate = cashGroup.calculateOracleRate(threeMonthMaturity, blockTime);

        int256 exchangeRate =
            Market.getExchangeRateFromImpliedRate(
                oracleRate.add(cashGroup.getSettlementPenalty()),
                threeMonthMaturity.sub(blockTime)
            );

        // Amount to settle is positive, this returns the fCashAmount that the settler will
        // receive as a positive number
        return
            cashGroup.assetRate
                .convertToUnderlying(amountToSettleAsset)
                // Exchange rate converts from cash to fCash when multiplying
                .mulInRatePrecision(exchangeRate);
    }

    /// @notice Allows an account to purchase ntoken residuals
    /// @param cashGroup parameters for the trade
    /// @param blockTime the current block time
    /// @param trade bytes32 encoding of the particular trade
    /// @return 
    ///     maturity: the date of the idiosyncratic maturity where fCash will be exchanged
    ///     cashAmount: a positive or negative cash amount that the account will receive or pay
    ///     fCashAmount: a positive or negative fCash amount that the account will receive
    function _purchaseNTokenResidual(
        CashGroupParameters memory cashGroup,
        uint256 blockTime,
        bytes32 trade
    )
        internal
        returns (
            uint256,
            int256,
            int256
        )
    {
        uint256 maturity = uint256(uint32(uint256(trade) >> 216));
        int256 fCashAmountToPurchase = int88(uint88(uint256(trade) >> 128));
        require(maturity > blockTime, "Invalid maturity");
        // Require that the residual to purchase does not fall on an existing maturity (i.e.
        // it is an idiosyncratic maturity)
        require(
            !DateTime.isValidMarketMaturity(cashGroup.maxMarketIndex, maturity, blockTime),
            "Non idiosyncratic maturity"
        );

        address nTokenAddress = nTokenHandler.nTokenAddress(cashGroup.currencyId);
        // prettier-ignore
        (
            /* currencyId */,
            /* incentiveRate */,
            uint256 lastInitializedTime,
            /* assetArrayLength */,
            bytes5 parameters
        ) = nTokenHandler.getNTokenContext(nTokenAddress);

        // Restrict purchasing until some amount of time after the last initialized time to ensure that arbitrage
        // opportunities are not available (by generating residuals and then immediately purchasing them at a discount)
        // This is always relative to the last initialized time which is set at utc0 when initialized, not the
        // reference time. Therefore we will always restrict residual purchase relative to initialization, not reference.
        // This is safer, prevents an attack if someone forces residuals and then somehow prevents market initialization
        // until the residual time buffer passes.
        require(
            blockTime >
                lastInitializedTime.add(
                    uint256(uint8(parameters[Constants.RESIDUAL_PURCHASE_TIME_BUFFER])) * 1 hours
                ),
            "Insufficient block time"
        );

        int256 notional =
            BitmapAssetsHandler.getifCashNotional(nTokenAddress, cashGroup.currencyId, maturity);
        // Check if amounts are valid and set them to the max available if necessary
        if (notional < 0 && fCashAmountToPurchase < 0) {
            // Does not allow purchasing more negative notional than available
            if (fCashAmountToPurchase < notional) fCashAmountToPurchase = notional;
        } else if (notional > 0 && fCashAmountToPurchase > 0) {
            // Does not allow purchasing more positive notional than available
            if (fCashAmountToPurchase > notional) fCashAmountToPurchase = notional;
        } else {
            // Does not allow moving notional in the opposite direction
            revert("Invalid amount");
        }

        // If fCashAmount > 0 then this will return netAssetCash > 0, if fCashAmount < 0 this will return
        // netAssetCash < 0. fCashAmount will go to the purchaser and netAssetCash will go to the nToken.
        int256 netAssetCashNToken =
            _getResidualPriceAssetCash(
                cashGroup,
                maturity,
                blockTime,
                fCashAmountToPurchase,
                parameters
            );

        _updateNTokenPortfolio(
            nTokenAddress,
            cashGroup.currencyId,
            maturity,
            lastInitializedTime,
            fCashAmountToPurchase,
            netAssetCashNToken
        );

        emit nTokenResidualPurchase(
            uint16(cashGroup.currencyId),
            uint40(maturity),
            fCashAmountToPurchase,
            netAssetCashNToken
        );

        return (maturity, netAssetCashNToken.neg(), fCashAmountToPurchase);
    }

    /// @notice Returns the amount of asset cash required to purchase the nToken residual
    function _getResidualPriceAssetCash(
        CashGroupParameters memory cashGroup,
        uint256 maturity,
        uint256 blockTime,
        int256 fCashAmount,
        bytes6 parameters
    ) internal view returns (int256) {
        uint256 oracleRate = cashGroup.calculateOracleRate(maturity, blockTime);
        // Residual purchase incentive is specified in ten basis point increments
        uint256 purchaseIncentive =
            uint256(uint8(parameters[Constants.RESIDUAL_PURCHASE_INCENTIVE])) *
                Constants.TEN_BASIS_POINTS;

        if (fCashAmount > 0) {
            // When fCash is positive then we add the purchase incentive, the purchaser
            // can pay less cash for the fCash relative to the oracle rate
            oracleRate = oracleRate.add(purchaseIncentive);
        } else if (oracleRate > purchaseIncentive) {
            // When fCash is negative, we reduce the interest rate that the purchaser will
            // borrow at, we do this check to ensure that we floor the oracle rate at zero.
            oracleRate = oracleRate.sub(purchaseIncentive);
        } else {
            // If the oracle rate is less than the purchase incentive floor the interest rate at zero
            oracleRate = 0;
        }

        int256 exchangeRate =
            Market.getExchangeRateFromImpliedRate(oracleRate, maturity.sub(blockTime));

        // Returns the net asset cash from the nToken perspective, which is the same sign as the fCash amount
        return
            cashGroup.assetRate.convertFromUnderlying(fCashAmount.divInRatePrecision(exchangeRate));
    }

    function _updateNTokenPortfolio(
        address nTokenAddress,
        uint256 currencyId,
        uint256 maturity,
        uint256 lastInitializedTime,
        int256 fCashAmountToPurchase,
        int256 netAssetCashNToken
    ) private {
        int256 finalNotional = BitmapAssetsHandler.addifCashAsset(
            nTokenAddress,
            currencyId,
            maturity,
            lastInitializedTime,
            fCashAmountToPurchase.neg() // the nToken takes on the negative position
        );

        // Defensive check to ensure that fCash amounts do not flip signs
        require(
            (fCashAmountToPurchase > 0 && finalNotional >= 0) ||
            (fCashAmountToPurchase < 0 && finalNotional <= 0)
        );

        // prettier-ignore
        (
            int256 nTokenCashBalance,
            /* storedNTokenBalance */,
            /* lastClaimTime */,
            /* lastClaimIntegralSupply */
        ) = BalanceHandler.getBalanceStorage(nTokenAddress, currencyId);
        nTokenCashBalance = nTokenCashBalance.add(netAssetCashNToken);

        // This will ensure that the cash balance is not negative
        BalanceHandler.setBalanceStorageForNToken(nTokenAddress, currencyId, nTokenCashBalance);
    }
}
