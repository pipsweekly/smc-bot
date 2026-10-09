//+------------------------------------------------------------------+
//|                                           SMC_MTF_StrictRRR.mq5 |
//|                                 Refactored Trading Bot EA         |
//+------------------------------------------------------------------+
#property copyright "Trading Bot"
#property link      ""
#property version   "1.30"
#property strict

#include <Trade\Trade.mqh>

//--- Inputs
input group "--- Risk & Trade Settings ---"
input double   InpRiskPercent    = 1.0;         // Risk per trade (% of equity)
input double   InpMinRRR         = 3.0;         // Minimum required RRR (e.g. 3.0 = 1:3 or better)
input ulong    InpMagicNumber    = 881122;      // EA magic number

input group "--- Synthetic Index Settings ---"
input bool     InpSyntheticMode      = true;        // Optimized for synthetic indices (Volatility / Crash / Boom / Step)
input double   InpMaxSpreadPips      = 12.0;        // Maximum spread allowed before ignoring setup
input double   InpMinEntryGapPips    = 0.8;         // Minimum entry buffer from prior structure
input double   InpSyntheticRiskLimit = 2.0;         // Additional safety soft cap for synthetic index trading

input group "--- Timeframe Settings ---"
input ENUM_TIMEFRAMES InpHTF1    = PERIOD_H4;   // Primary trend timeframe
input ENUM_TIMEFRAMES InpHTF2    = PERIOD_H1;   // Secondary trend timeframe
input ENUM_TIMEFRAMES InpHTF3    = PERIOD_M15;  // Structure timeframe
input bool            InpUseM5    = true;        // Enable M5 entries
input bool            InpUseM1    = true;        // Enable M1 entries

input group "--- SMC Parameters ---"
input int      InpSwingDepth     = 5;           // Swing high/low strength
input double   InpMinFVGPips     = 0.8;         // Minimum FVG size in pips for synthetic indices
input bool     InpUsePriceAction = true;        // Enable price-action confirmation (support/resistance, trendlines, flags)
input int      InpPriceActionLookback = 80;      // Bars used to detect trendline + flag structure

//--- Global variables
CTrade trade;
datetime lastM5Time = 0;
datetime lastM1Time = 0;

struct SMCZone
{
   double   top;
   double   bottom;
   bool     isBullish;
   datetime time;
};

struct PriceActionLevel
{
   double   price;
   datetime time;
   bool     isSupport;
};

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Helper: determine the pip size dynamically                        |
//+------------------------------------------------------------------+
double PipSize()
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   return (digits > 3) ? point * 10.0 : point;
}

//+------------------------------------------------------------------+
//| Helper: detect synthetic indices, including Weltrade names        |
//+------------------------------------------------------------------+
bool IsSyntheticIndex()
{
   string symbol = _Symbol;
   symbol = StringUpper(symbol);
   symbol = StringReplace(symbol, " ", "");
   symbol = StringReplace(symbol, "_", "");
   symbol = StringReplace(symbol, "-", "");
   symbol = StringReplace(symbol, ".", "");

   return StringFind(symbol, "VOL") >= 0 ||
          StringFind(symbol, "CRASH") >= 0 ||
          StringFind(symbol, "BOOM") >= 0 ||
          StringFind(symbol, "STEP") >= 0 ||
          StringFind(symbol, "JUMP") >= 0 ||
          StringFind(symbol, "RANGE") >= 0 ||
          StringFind(symbol, "VIX") >= 0 ||
          StringFind(symbol, "SYN") >= 0 ||
          StringFind(symbol, "INDEX") >= 0 ||
          StringFind(symbol, "WT") >= 0;
}

//+------------------------------------------------------------------+
//| Helper: current spread in pips                                    |
//+------------------------------------------------------------------+
double SpreadInPips()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pipSize = PipSize();
   int spreadPoints = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   if(point <= 0 || pipSize <= 0)
      return 0;

   return (spreadPoints * point) / pipSize;
}

//+------------------------------------------------------------------+
//| Helper: pre-check before executing synthetic index trades         |
//+------------------------------------------------------------------+
bool CanTradeSyntheticSetup()
{
   if(!InpSyntheticMode)
      return true;

   if(!IsSyntheticIndex())
      return true;

   double spreadPips = SpreadInPips();
   return spreadPips <= InpMaxSpreadPips;
}

//+------------------------------------------------------------------+
//| Helper: calculate lot size based on risk percentage              |
//+------------------------------------------------------------------+
double CalculateLotSize(double slPoints)
{
   if(slPoints <= 0)
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount  = equity * (InpRiskPercent / 100.0);
   if(InpSyntheticMode && IsSyntheticIndex())
      riskAmount = MathMin(riskAmount, equity * (InpSyntheticRiskLimit / 100.0));

   double tickSize    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double point       = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(tickSize <= 0 || tickValue <= 0 || point <= 0)
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double valuePerPoint = (tickValue / tickSize) * point;
   double lotSize       = riskAmount / (slPoints * valuePerPoint);

   double minLot        = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot        = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep       = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lotStep <= 0)
      return MathMax(minLot, MathMin(maxLot, lotSize));

   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   return MathMax(minLot, MathMin(maxLot, lotSize));
}

//+------------------------------------------------------------------+
//| Helper: find recent swing liquidity target                       |
//+------------------------------------------------------------------+
double GetTargetLiquidity(bool findHigh)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   int barsToCheck = InpSwingDepth * 2 + 50;
   if(CopyRates(_Symbol, PERIOD_M15, 0, barsToCheck, rates) < barsToCheck)
      return 0;

   for(int i = InpSwingDepth; i < barsToCheck - InpSwingDepth; i++)
   {
      bool isExtremum = true;
      for(int j = 1; j <= InpSwingDepth; j++)
      {
         if(findHigh)
         {
            if(rates[i].high <= rates[i - j].high || rates[i].high <= rates[i + j].high)
            {
               isExtremum = false;
               break;
            }
         }
         else
         {
            if(rates[i].low >= rates[i - j].low || rates[i].low >= rates[i + j].low)
            {
               isExtremum = false;
               break;
            }
         }
      }

      if(isExtremum)
         return findHigh ? rates[i].high : rates[i].low;
   }

   return 0;
}

//+------------------------------------------------------------------+
//| Helper: detect valid HTF FVG / SMC zone                           |
//+------------------------------------------------------------------+
bool GetHTFZone(ENUM_TIMEFRAMES tf, SMCZone &outZone)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   int barsNeeded = 12;
   if(CopyRates(_Symbol, tf, 1, barsNeeded, rates) < barsNeeded)
      return false;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minGap = InpMinFVGPips * PipSize();

   for(int i = 0; i < 7; i++)
   {
      // Bullish FVG: current low is above the high from two bars earlier
      if((rates[i].low - rates[i + 2].high) >= minGap)
      {
         outZone.bottom    = rates[i + 2].high;
         outZone.top       = rates[i].low;
         outZone.isBullish = true;
         outZone.time      = rates[i].time;
         return true;
      }

      // Bearish FVG: current high is below the low from two bars earlier
      if((rates[i + 2].low - rates[i].high) >= minGap)
      {
         outZone.bottom    = rates[i].high;
         outZone.top       = rates[i + 2].low;
         outZone.isBullish = false;
         outZone.time      = rates[i].time;
         return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| Helper: check if the symbol already has an open position         |
//+------------------------------------------------------------------+
bool HasOpenPositionForMagic()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Helper: determine if current price is inside the active zone       |
//+------------------------------------------------------------------+
bool IsPriceInZone(double price, const SMCZone &zone)
{
   return price >= zone.bottom && price <= zone.top;
}

//+------------------------------------------------------------------+
//| Helper: identify nearest valid support/resistance pivot            |
//+------------------------------------------------------------------+
bool FindNearestTrendline(bool support, double &level)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int lookback = MathMax(30, InpPriceActionLookback);

   if(CopyRates(_Symbol, PERIOD_M15, 0, lookback, rates) < lookback)
      return false;

   for(int i = InpSwingDepth; i < lookback - InpSwingDepth; i++)
   {
      bool isPivot = true;
      for(int j = 1; j <= InpSwingDepth; j++)
      {
         if(support)
         {
            if(rates[i].low >= rates[i - j].low || rates[i].low >= rates[i + j].low)
            {
               isPivot = false;
               break;
            }
         }
         else
         {
            if(rates[i].high <= rates[i - j].high || rates[i].high <= rates[i + j].high)
            {
               isPivot = false;
               break;
            }
         }
      }

      if(isPivot)
      {
         level = support ? rates[i].low : rates[i].high;
         return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| Helper: detect bullish or bearish continuation flag               |
//+------------------------------------------------------------------+
bool DetectFlagPattern(bool bullishFlag)
{
   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   int lookback = 40;
   if(CopyRates(_Symbol, PERIOD_M15, 0, lookback, rates) < lookback)
      return false;

   double impulseMove = MathAbs(rates[0].close - rates[10].close);
   double flagHigh = 0.0;
   double flagLow = 0.0;
   double rangeSize = 0.0;

   for(int i = 10; i < 25; i++)
   {
      if(i == 10)
      {
         flagHigh = rates[i].high;
         flagLow = rates[i].low;
      }
      else
      {
         flagHigh = MathMax(flagHigh, rates[i].high);
         flagLow = MathMin(flagLow, rates[i].low);
      }
   }

   rangeSize = flagHigh - flagLow;
   if(impulseMove <= 0 || rangeSize <= 0)
      return false;

   bool validFlag = rangeSize < (impulseMove * 0.75);
   if(bullishFlag)
      return validFlag && rates[0].close > rates[10].close && rates[0].close > flagLow;

   return validFlag && rates[0].close < rates[10].close && rates[0].close < flagHigh;
}

//+------------------------------------------------------------------+
//| Helper: combine price-action confirmation with SMC zone            |
//+------------------------------------------------------------------+
bool HasPriceActionConfirmation(bool bullishZone, double currentPrice, double marketAsk, double marketBid)
{
   if(!InpUsePriceAction)
      return true;

   double supportLevel = 0.0;
   double resistanceLevel = 0.0;
   bool hasSupport = FindNearestTrendline(true, supportLevel);
   bool hasResistance = FindNearestTrendline(false, resistanceLevel);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tolerance = MathMax(5.0 * point, 1.5 * PipSize());

   bool nearSupport = hasSupport && (MathAbs(currentPrice - supportLevel) <= tolerance);
   bool nearResistance = hasResistance && (MathAbs(currentPrice - resistanceLevel) <= tolerance);

   if(bullishZone)
   {
      if(nearSupport || DetectFlagPattern(true))
         return true;
   }
   else
   {
      if(nearResistance || DetectFlagPattern(false))
         return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Core execution logic                                              |
//+------------------------------------------------------------------+
void EvaluateExecution(ENUM_TIMEFRAMES ltf)
{
    if(HasOpenPositionForMagic())
      return;

    if(!CanTradeSyntheticSetup())
       return;

    ENUM_TIMEFRAMES htfList[3] = {InpHTF1, InpHTF2, InpHTF3};
   SMCZone activeZone;
   bool zoneFound = false;

   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   for(int k = 0; k < 3; k++)
   {
      SMCZone tempZone;
      if(GetHTFZone(htfList[k], tempZone))
      {
         if(tempZone.isBullish && IsPriceInZone(currentBid, tempZone))
         {
            activeZone = tempZone;
            zoneFound = true;
            break;
         }

         if(!tempZone.isBullish && IsPriceInZone(currentAsk, tempZone))
         {
            activeZone = tempZone;
            zoneFound = true;
            break;
         }
      }
   }

   if(!zoneFound)
      return;

   MqlRates ltfRates[];
   ArraySetAsSeries(ltfRates, true);
   if(CopyRates(_Symbol, ltf, 1, 3, ltfRates) < 3)
      return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double syntheticMinEntryGap = InpMinEntryGapPips * PipSize();

   bool priceActionConfirmed = HasPriceActionConfirmation(activeZone.isBullish, activeZone.isBullish ? currentBid : currentAsk,
                                                        currentAsk, currentBid);
   if(!priceActionConfirmed)
      return;

   //--- Bullish setup ---
   if(activeZone.isBullish && ltfRates[0].close > ltfRates[0].open)
   {
      double slPrice = ltfRates[0].low - (MathMax(5.0, syntheticMinEntryGap / point) * point);
      double slPoints = (currentAsk - slPrice) / point;

      if(slPoints > 0)
      {
         double targetTP = GetTargetLiquidity(true);
         double tpPoints = (targetTP > currentAsk) ? (targetTP - currentAsk) / point : 0;

         if(tpPoints <= 0 || (tpPoints / slPoints) < InpMinRRR)
         {
            tpPoints = slPoints * InpMinRRR;
            targetTP = currentAsk + (tpPoints * point);
         }

         double calculatedRRR = tpPoints / slPoints;
         if(calculatedRRR >= InpMinRRR)
         {
            double lot = CalculateLotSize(slPoints);
            trade.Buy(lot, _Symbol, currentAsk, slPrice, targetTP,
                      StringFormat("SMC %s (RRR 1:%.2f)", EnumToString(ltf), calculatedRRR));
         }
      }
   }
   //--- Bearish setup ---
   else if(!activeZone.isBullish && ltfRates[0].close < ltfRates[0].open)
   {
      double slPrice = ltfRates[0].high + (MathMax(5.0, syntheticMinEntryGap / point) * point);
      double slPoints = (slPrice - currentBid) / point;

      if(slPoints > 0)
      {
         double targetTP = GetTargetLiquidity(false);
         double tpPoints = (targetTP > 0 && targetTP < currentBid) ? (currentBid - targetTP) / point : 0;

         if(tpPoints <= 0 || (tpPoints / slPoints) < InpMinRRR)
         {
            tpPoints = slPoints * InpMinRRR;
            targetTP = currentBid - (tpPoints * point);
         }

         double calculatedRRR = tpPoints / slPoints;
         if(calculatedRRR >= InpMinRRR)
         {
            double lot = CalculateLotSize(slPoints);
            trade.Sell(lot, _Symbol, currentBid, slPrice, targetTP,
                       StringFormat("SMC %s (RRR 1:%.2f)", EnumToString(ltf), calculatedRRR));
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(InpUseM5)
   {
      datetime currentM5 = iTime(_Symbol, PERIOD_M5, 0);
      if(currentM5 != lastM5Time)
      {
         lastM5Time = currentM5;
         EvaluateExecution(PERIOD_M5);
      }
   }

   if(InpUseM1)
   {
      datetime currentM1 = iTime(_Symbol, PERIOD_M1, 0);
      if(currentM1 != lastM1Time)
      {
         lastM1Time = currentM1;
         EvaluateExecution(PERIOD_M1);
      }
   }
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Intentionally kept empty for clean shutdown.
}
