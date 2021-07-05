methods {
    getRateScalar(uint256 timeToMaturity) returns (int256) envfree;
    getRateOracleTimeWindow() returns (uint256) envfree;
    getLastImpliedRate() returns (uint256) envfree;
    getStoredOracleRate() returns (uint256) envfree;
    getPreviousTradeTime() returns (uint256) envfree;
    getMarketfCash() returns (int256) envfree;
    getMarketAssetCash() returns (int256) envfree;
    getMarketLiquidity() returns (int256) envfree;
    getMarketOracleRate() returns (uint256) envfree;
    MATURITY() returns (uint256) envfree;
}

definition isBetween(uint256 x, uint256 y, uint256 z) returns bool = (y <= x && x <= z) || (z <= x && x <= y);
definition absDiff(uint256 x, uint256 y) returns uint256 = x > y ? x - y : y - x;
definition basisPoint() returns uint256 = 100000;
definition QUARTER() returns uint256 = 86400 * 90;
definition getMarketProportion() returns mathint = (getMarketfCash() * 10^9) / (getMarketfCash() + getMarketAssetCash());

/**
 * Oracle rates are blended into the rate window given the rate oracle time window.
 */
invariant oracleRatesAreBlendedIntoTheRateWindow(
    uint256 blockTime,
    uint256 previousTradeTime
)
    (previousTradeTime + getRateOracleTimeWindow() >= blockTime) ?
        getMarketOracleRate() == getLastImpliedRate() :
        isBetween(
            getMarketOracleRate(),
            getPreviousTradeTime(),
            getLastImpliedRate()
        )

rule executeTradeMovesImpliedRates(
    int256 fCashToAccount,
    uint256 timeToMaturity
) {
    env e;
    require fCashToAccount != 0;
    require getRateScalar(timeToMaturity) > 0;
    uint256 lastImpliedRate = getLastImpliedRate();
    int256 marketfCashBefore = getMarketfCash();
    int256 marketAssetCashBefore = getMarketAssetCash();
    int256 assetCashToAccount;
    int256 assetCashToReserve;

    assetCashToAccount, assetCashToReserve = executeTrade(e, timeToMaturity, fCashToAccount);
    assert fCashToAccount > 0 ? 
        // When fCashToAccount > 0 then lending, implied rates should decrease
        lastImpliedRate > getLastImpliedRate() :
        // When fCashToAccount < 0 then borrowing, implied rates should increase
        lastImpliedRate < getLastImpliedRate(),
        "last trade rate did not move in correct direction";
    assert fCashToAccount > 0 ? assetCashToAccount < 0 : assetCashToAccount > 0, "incorrect asset cash for fCash";
    assert assetCashToReserve >= 0, "asset cash to reserve cannot be negative";
    assert getPreviousTradeTime() == e.block.timestamp, "previous trade time did not update";
    assert getMarketfCash() - fCashToAccount == marketfCashBefore, "Market fCash does not net out";
    assert getMarketAssetCash() - assetCashToAccount - assetCashToReserve == marketAssetCashBefore,
        "Market asset cash does not net out";
}

rule impliedRatesDoNotChangeOnAddLiquidity(
    int256 cashAmount
) {
    env e;
    require getMarketProportion() > 0;
    require cashAmount > 0;
    uint256 previousTradeTime = getPreviousTradeTime();
    uint256 lastImpliedRate = getLastImpliedRate();
    mathint marketProportion = getMarketProportion();

    addLiquidity(e, cashAmount);
    assert getPreviousTradeTime() == previousTradeTime, "previous trade time did update";
    assert getLastImpliedRate() == lastImpliedRate, "last trade rate did update";
    assert getMarketProportion() == marketProportion, "market proportion changed on add liquidity";
}

rule impliedRatesDoNotChangeOnRemoveLiquidity(
    int256 tokenAmount
) {
    env e;
    require tokenAmount > 0;
    int256 marketLiquidityBefore = getMarketLiquidity();
    require marketLiquidityBefore >= tokenAmount;
    uint256 previousTradeTime = getPreviousTradeTime();
    uint256 lastImpliedRate = getLastImpliedRate();
    mathint marketProportion = getMarketProportion();

    removeLiquidity(e, tokenAmount);
    assert getPreviousTradeTime() == previousTradeTime, "previous trade time did update";
    assert getLastImpliedRate() == lastImpliedRate, "last trade rate did update";
    // Check this or it will fail on remove down to zero
    assert marketLiquidityBefore > tokenAmount =>
        getMarketProportion() == marketProportion, "market proportion changed on remove liquidity";
}

// The amount of slippage for a given size of trade should not change in terms of the implied rate
// over the course of the market. If this is the case then arbitrage opportunities could arise. In the V2
// liquidity curve this is not perfect so we show that the slippage is below some tolerable epsilon over
// the course of a quarter.
rule impliedRateSlippageDoesNotChangeWithTime(
    int256 fCashToAccount,
    uint256 timeDelta
) {
    env e;
    // Ensure that the block time is within the tradeable region
    require timeDelta <= QUARTER() && e.block.timestamp + timeDelta < MATURITY();
    require fCashToAccount != 0;
    uint256 timeToMaturity_first = MATURITY() - e.block.timestamp;
    uint256 timeToMaturity_second = MATURITY() - e.block.timestamp - timeDelta;
    require getRateScalar(timeToMaturity_first) > 0;
    require getRateScalar(timeToMaturity_second) > 0;

    storage initStorage = lastStorage;
    executeTrade(e, timeToMaturity_first, fCashToAccount);
    uint256 lastImpliedRate_first = getLastImpliedRate();

    executeTrade(e, timeToMaturity_second, fCashToAccount) at initStorage;
    uint256 lastImpliedRate_second = getLastImpliedRate();

    assert absDiff(lastImpliedRate_first, lastImpliedRate_second) < basisPoint(),
        "Last implied rate slippage increases with time";
}

// invariant fCashAndCashAmountsConverge