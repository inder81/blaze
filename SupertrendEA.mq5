#property copyright   ""
#property link        ""
#property version     "1.00"
#property strict
#property description "Supertrend Expert Advisor with ATR-based bands, SL/TP, risk-based position sizing, spread filter, and trailing by Supertrend line."

#include <Trade/Trade.mqh>

//=========================
// Inputs
//=========================
input ENUM_TIMEFRAMES InpSignalTimeframe = PERIOD_H1;       // Supertrend signal timeframe
input int              InpATRPeriod       = 10;             // ATR period
input double           InpATRMultiplier   = 3.0;            // ATR multiplier

input bool             InpTradeLong       = true;           // Allow long trades
input bool             InpTradeShort      = true;           // Allow short trades

input bool             InpUseRiskPercent  = false;          // Use risk % instead of fixed lot
input double           InpRiskPercent     = 1.0;            // Risk percent per trade
input double           InpFixedLot        = 0.10;           // Fixed lot when not using risk %

input bool             InpEnableTP        = true;           // Enable take profit
input double           InpRiskReward      = 1.5;            // TP as multiple of SL distance
input bool             InpEnableTrailing  = true;           // Trail SL on Supertrend line

input double           InpMaxSpreadPoints = 30;             // Max allowed spread in points
input int              InpDeviationPoints = 20;             // Order deviation in points

input string           InpSessionStart    = "00:00";        // Session start (broker time, HH:MM)
input string           InpSessionEnd      = "23:59";        // Session end (broker time, HH:MM)

input int              InpLookbackBars    = 1000;           // Lookback bars for Supertrend calc
input ulong            InpMagic           = 20250808;       // Magic number

//=========================
// Globals
//=========================
CTrade         g_trade;
int            g_atrHandle = INVALID_HANDLE;
MqlTick        g_tick;
datetime       g_lastBarTime = 0; // for new bar detection on InpSignalTimeframe

//=========================
// Utility functions
//=========================
bool IsWithinSession()
{
   // Parses HH:MM -> minutes since midnight
   int start_h = 0, start_m = 0, end_h = 0, end_m = 0;
   if(StringLen(InpSessionStart) < 4 || StringLen(InpSessionEnd) < 4)
      return true;

   string s1[]; int parts1 = StringSplit(InpSessionStart, ':', s1);
   string s2[]; int parts2 = StringSplit(InpSessionEnd,   ':', s2);
   if(parts1 < 2 || parts2 < 2) return true;

   start_h = (int)StringToInteger(s1[0]);
   start_m = (int)StringToInteger(s1[1]);
   end_h   = (int)StringToInteger(s2[0]);
   end_m   = (int)StringToInteger(s2[1]);

   datetime now = TimeCurrent();
   MqlDateTime st; TimeToStruct(now, st);
   int minutes_now   = st.hour * 60 + st.min;
   int minutes_start = start_h * 60 + start_m;
   int minutes_end   = end_h * 60 + end_m;

   if(minutes_start <= minutes_end)
      return (minutes_now >= minutes_start && minutes_now <= minutes_end);
   // Overnight session (e.g., 22:00 -> 06:00)
   return (minutes_now >= minutes_start || minutes_now <= minutes_end);
}

bool IsNewBar(const string symbol, ENUM_TIMEFRAMES tf)
{
   datetime t = iTime(symbol, tf, 0);
   if(t == 0) return false;
   if(g_lastBarTime != t)
   {
      g_lastBarTime = t;
      return true;
   }
   return false;
}

int CountOpenPositionsByMagic(const string symbol, const ulong magic)
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); ++i)
   {
      if(!PositionSelectByIndex(i))
         continue;
      string psym = PositionGetString(POSITION_SYMBOL);
      long   pmag = PositionGetInteger(POSITION_MAGIC);
      if(psym == symbol && pmag == (long)magic)
         ++count;
   }
   return count;
}

bool GetPointValuePerLot(const string symbol, double &valuePerPointPerLot)
{
   double tick_size  = 0.0;
   double tick_value = 0.0;
   if(!SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE,  tick_size))  return false;
   if(!SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE, tick_value)) return false;
   if(tick_size <= 0.0) return false;
   valuePerPointPerLot = tick_value * (_Point / tick_size);
   return (valuePerPointPerLot > 0.0);
}

// Rounds lot to broker constraints
double NormalizeLotToStep(const string symbol, double lots)
{
   double min_lot = 0.0, max_lot = 0.0, lot_step = 0.0;
   SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN, min_lot);
   SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX, max_lot);
   SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP, lot_step);
   if(lot_step <= 0.0)
      lot_step = 0.01;
   lots = MathMax(min_lot, MathMin(max_lot, lots));
   return MathFloor(lots / lot_step + 1e-6) * lot_step;
}

//=========================
// Supertrend calculation
//=========================
bool CalculateSupertrend(const string symbol,
                         const ENUM_TIMEFRAMES tf,
                         const int atrPeriod,
                         const double atrMult,
                         const int lookback,
                         double &outSupertrend[],
                         bool   &outIsUp[])
{
   ArrayResize(outSupertrend, 0);
   ArrayResize(outIsUp, 0);

   if(atrPeriod <= 0 || atrMult <= 0.0) return false;

   int barsToCopy = MathMax(atrPeriod + 5, lookback);

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(symbol, tf, 0, barsToCopy, rates);
   if(copied <= atrPeriod + 2)
      return false;

   double atr[];
   ArraySetAsSeries(atr, true);

   int atrHandle = iATR(symbol, tf, atrPeriod);
   if(atrHandle == INVALID_HANDLE)
      return false;
   int acopied = CopyBuffer(atrHandle, 0, 0, copied, atr);
   IndicatorRelease(atrHandle);
   if(acopied != copied)
      return false;

   double upperBasic[], lowerBasic[], upperFinal[], lowerFinal[];
   ArrayResize(upperBasic, copied);
   ArrayResize(lowerBasic, copied);
   ArrayResize(upperFinal, copied);
   ArrayResize(lowerFinal, copied);
   ArrayResize(outSupertrend, copied);
   ArrayResize(outIsUp,      copied);

   ArraySetAsSeries(upperBasic, true);
   ArraySetAsSeries(lowerBasic, true);
   ArraySetAsSeries(upperFinal, true);
   ArraySetAsSeries(lowerFinal, true);
   ArraySetAsSeries(outSupertrend, true);
   ArraySetAsSeries(outIsUp, true);

   for(int i = copied - 1; i >= 0; --i)
   {
      double hl2 = (rates[i].high + rates[i].low) * 0.5;
      upperBasic[i] = hl2 + atrMult * atr[i];
      lowerBasic[i] = hl2 - atrMult * atr[i];

      if(i == copied - 1)
      {
         upperFinal[i] = upperBasic[i];
         lowerFinal[i] = lowerBasic[i];
         outIsUp[i]    = true; // seed
         outSupertrend[i] = lowerFinal[i];
      }
      else
      {
         // Final upper band
         if(upperBasic[i] < upperFinal[i+1] || rates[i+1].close > upperFinal[i+1])
            upperFinal[i] = upperBasic[i];
         else
            upperFinal[i] = upperFinal[i+1];

         // Final lower band
         if(lowerBasic[i] > lowerFinal[i+1] || rates[i+1].close < lowerFinal[i+1])
            lowerFinal[i] = lowerBasic[i];
         else
            lowerFinal[i] = lowerFinal[i+1];

         // Trend direction
         if(outIsUp[i+1])
         {
            if(rates[i].close <= upperFinal[i])
               outIsUp[i] = false;
            else
               outIsUp[i] = true;
         }
         else
         {
            if(rates[i].close >= lowerFinal[i])
               outIsUp[i] = true;
            else
               outIsUp[i] = false;
         }

         outSupertrend[i] = outIsUp[i] ? lowerFinal[i] : upperFinal[i];
      }
   }
   return true;
}

//=========================
// Trading logic
//=========================
void UpdateTrailingBySupertrend(const string symbol,
                                const ENUM_TIMEFRAMES tf,
                                const int atrPeriod,
                                const double atrMult)
{
   if(!InpEnableTrailing) return;

   double st[]; bool isUp[];
   if(!CalculateSupertrend(symbol, tf, atrPeriod, atrMult, MathMax(atrPeriod + 20, 200), st, isUp))
      return;

   // Use bar 0 for faster trailing, ensure arrays are set as series
   if(ArraySize(st) < 2) return;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      if(!PositionSelectByIndex(i)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagic) continue;

      ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
      long type = PositionGetInteger(POSITION_TYPE);
      double sl  = PositionGetDouble(POSITION_SL);

      double newSL = sl;
      if(type == POSITION_TYPE_BUY)
      {
         double candidate = st[0];
         if(candidate > sl + (_Point * 1))
            newSL = candidate;
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double candidate = st[0];
         if(candidate < sl - (_Point * 1) || sl == 0.0)
            newSL = candidate;
      }

      if(newSL <= 0.0 || MathIsValidNumber(newSL) == false)
         continue;

      int    stopsLevelPts = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
      double minStopDist   = (stopsLevelPts > 0 ? stopsLevelPts : 0) * _Point;
      double bid = 0, ask = 0; SymbolInfoDouble(symbol, SYMBOL_BID, bid); SymbolInfoDouble(symbol, SYMBOL_ASK, ask);

      if(type == POSITION_TYPE_BUY)
      {
         if(newSL > bid - minStopDist)
            newSL = bid - minStopDist;
         if(newSL > 0.0 && (sl == 0.0 || newSL > sl + _Point))
            g_trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
      }
      else if(type == POSITION_TYPE_SELL)
      {
         if(newSL < ask + minStopDist)
            newSL = ask + minStopDist;
         if(newSL > 0.0 && (sl == 0.0 || newSL < sl - _Point))
            g_trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
      }
   }
}

bool OpenTrade(const string symbol,
               const bool isBuy,
               const double slPrice,
               const double rr,
               const int deviationPts)
{
   if(!SymbolInfoTick(symbol, g_tick)) return false;

   double entry = isBuy ? g_tick.ask : g_tick.bid;

   // Compute lots
   double lots = InpFixedLot;
   if(InpUseRiskPercent)
   {
     double valuePerPoint = 0.0;
     if(GetPointValuePerLot(symbol, valuePerPoint))
     {
        double stopPoints = MathAbs(entry - slPrice) / _Point;
        if(stopPoints >= 1.0)
        {
           double moneyRisk = AccountInfoDouble(ACCOUNT_EQUITY) * (InpRiskPercent / 100.0);
           double rawLots   = moneyRisk / (stopPoints * valuePerPoint);
           lots = NormalizeLotToStep(symbol, rawLots);
        }
     }
   }

   lots = NormalizeLotToStep(symbol, lots);
   if(lots <= 0.0)
      return false;

   // Stops level validation
   int stopsLevelPts = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStopDist = (stopsLevelPts > 0 ? stopsLevelPts : 0) * _Point;

   double sl = slPrice;
   double tp = 0.0;

   if(isBuy)
   {
      if(sl > entry - minStopDist)
         sl = entry - minStopDist;
      if(InpEnableTP && InpRiskReward > 0.0)
      {
         double riskDist = entry - sl;
         tp = entry + (riskDist * rr);
      }
      g_trade.SetExpertMagicNumber(InpMagic);
      g_trade.SetDeviationInPoints(deviationPts);
      return g_trade.Buy(lots, symbol, entry, sl, tp);
   }
   else
   {
      if(sl < entry + minStopDist)
         sl = entry + minStopDist;
      if(InpEnableTP && InpRiskReward > 0.0)
      {
         double riskDist = sl - entry;
         tp = entry - (riskDist * rr);
      }
      g_trade.SetExpertMagicNumber(InpMagic);
      g_trade.SetDeviationInPoints(deviationPts);
      return g_trade.Sell(lots, symbol, entry, sl, tp);
   }
}

//=========================
// Standard handlers
//=========================
int OnInit()
{
   if(InpATRPeriod <= 1 || InpATRMultiplier <= 0.0)
   {
      Print("Invalid ATR inputs");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_atrHandle = iATR(_Symbol, InpSignalTimeframe, InpATRPeriod);
   if(g_atrHandle == INVALID_HANDLE)
   {
      Print("Failed to create ATR handle");
      return INIT_FAILED;
   }

   g_lastBarTime = iTime(_Symbol, InpSignalTimeframe, 0);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_atrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_atrHandle);
      g_atrHandle = INVALID_HANDLE;
   }
}

void OnTick()
{
   if(!SymbolInfoTick(_Symbol, g_tick)) return;

   // Spread filter
   double spreadPoints = (g_tick.ask - g_tick.bid) / _Point;
   if(InpMaxSpreadPoints > 0 && spreadPoints > InpMaxSpreadPoints)
   {
      // Still allow trailing when spread is large
      UpdateTrailingBySupertrend(_Symbol, InpSignalTimeframe, InpATRPeriod, InpATRMultiplier);
      return;
   }

   // Always trail existing positions
   UpdateTrailingBySupertrend(_Symbol, InpSignalTimeframe, InpATRPeriod, InpATRMultiplier);

   if(!IsWithinSession())
      return;

   // Proceed only on a new bar of the signal timeframe
   if(!IsNewBar(_Symbol, InpSignalTimeframe))
      return;

   // Only one position per symbol by this EA
   if(CountOpenPositionsByMagic(_Symbol, InpMagic) > 0)
      return;

   // Calculate Supertrend on signal TF
   double st[]; bool isUp[];
   if(!CalculateSupertrend(_Symbol, InpSignalTimeframe, InpATRPeriod, InpATRMultiplier, InpLookbackBars, st, isUp))
      return;

   if(ArraySize(st) < 3) return;

   // Use closed bar (index 1). Detect trend flip between bar 2 -> bar 1
   bool wasUp = isUp[2];
   bool nowUp = isUp[1];

   // Signal: flip from down to up -> Buy; flip from up to down -> Sell
   if(nowUp && !wasUp && InpTradeLong)
   {
      double slPrice = st[1];
      OpenTrade(_Symbol, true, slPrice, InpRiskReward, InpDeviationPoints);
   }
   else if(!nowUp && wasUp && InpTradeShort)
   {
      double slPrice = st[1];
      OpenTrade(_Symbol, false, slPrice, InpRiskReward, InpDeviationPoints);
   }
}