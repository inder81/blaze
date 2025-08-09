//+------------------------------------------------------------------+
//|                                                    ATRBreakout.mq5|
//|                         Trend Breakout with ATR risk & filters    |
//+------------------------------------------------------------------+
#include <Trade/Trade.mqh>

// Inputs
input string   InpSymbol               = "";        // Leave empty to use chart symbol
input ENUM_TIMEFRAMES InpTF            = PERIOD_H1;
input int      InpDonchianPeriod       = 55;
input int      InpATRPeriod            = 14;
input double   InpATRStopMultiplier    = 2.5;       // Initial SL in ATRs
input double   InpATRTrailMultiplier   = 3.0;       // Trailing SL in ATRs
input double   InpRiskPerTradePct      = 0.30;      // % of equity per trade
input int      InpMaxSpreadPoints      = 30;        // Max spread (points)
input int      InpSlippagePoints       = 10;        // Slippage (points)
input bool     InpUseTimeWindow        = false;
input int      InpStartHour            = 7;         // Broker time
input int      InpEndHour              = 22;        // Broker time
input bool     InpOneTradePerBreakout  = true;      // Avoid retrigger on same side until re-enter

// Globals
CTrade trade;
MqlTick g_lastTick;

string   g_symbol = "";
int      g_atrHandle = INVALID_HANDLE;
double   g_atrBuffer[];

bool     g_lastBreakoutTradedUp = false;
bool     g_lastBreakoutTradedDn = false;

// Helpers
bool GetPoint(const string symbol, double &point)
{
  return SymbolInfoDouble(symbol, SYMBOL_POINT, point);
}

bool GetSpreadPoints(const string symbol, int &spreadPoints)
{
  long spreadLong = 0;
  if(SymbolInfoInteger(symbol, SYMBOL_SPREAD, spreadLong) && spreadLong > 0)
  {
    spreadPoints = (int)spreadLong;
    return true;
  }
  // Fallback via bid/ask
  double ask = 0.0, bid = 0.0, point = 0.0;
  if(!SymbolInfoDouble(symbol, SYMBOL_ASK, ask)) return false;
  if(!SymbolInfoDouble(symbol, SYMBOL_BID, bid)) return false;
  if(!GetPoint(symbol, point) || point <= 0.0) return false;
  spreadPoints = (int)((ask - bid)/point + 0.5);
  return true;
}

bool CanTradeNow(const string symbol)
{
  if(!SymbolInfoTick(symbol, g_lastTick)) return false;

  int spreadPoints = 0;
  if(!GetSpreadPoints(symbol, spreadPoints)) return false;
  if(spreadPoints > InpMaxSpreadPoints) return false;

  if(InpUseTimeWindow)
  {
    MqlDateTime t; TimeToStruct(TimeCurrent(), t);
    int hour = t.hour;
    if(InpStartHour <= InpEndHour)
    {
      if(hour < InpStartHour || hour >= InpEndHour) return false;
    }
    else // window wraps midnight
    {
      if(hour >= InpEndHour && hour < InpStartHour) return false;
    }
  }
  return true;
}

// Returns latest ATR value or 0 if unavailable
double GetATR(const string symbol, ENUM_TIMEFRAMES tf)
{
  if(g_atrHandle == INVALID_HANDLE)
    g_atrHandle = iATR(symbol, tf, InpATRPeriod);
  if(g_atrHandle == INVALID_HANDLE) return 0.0;
  if(CopyBuffer(g_atrHandle, 0, 0, 3, g_atrBuffer) < 2) return 0.0;
  return g_atrBuffer[0];
}

bool HasOpenPosition(const string symbol)
{
  return PositionSelect(symbol);
}

int CountOpenPositions()
{
  return PositionsTotal();
}

// Calculates lots based on equity risk and stop distance (in points)
double CalculatePositionSizeLots(const string symbol, double stopDistancePoints, double riskPct)
{
  if(stopDistancePoints <= 0.0 || riskPct <= 0.0) return 0.0;

  double equity = AccountInfoDouble(ACCOUNT_EQUITY);
  double riskMoney = MathMax(0.0, equity * (riskPct/100.0));

  double tickValue = 0.0, tickSize = 0.0, point = 0.0;
  if(!SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE, tickValue)) return 0.0;
  if(!SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE,  tickSize))  return 0.0;
  if(!GetPoint(symbol, point))                                      return 0.0;
  if(tickValue <= 0.0 || tickSize <= 0.0 || point <= 0.0)           return 0.0;

  // Approx money per point for 1 lot
  double moneyPerPointPerLot = (tickValue / tickSize) * point;
  double stopMoneyPerLot = moneyPerPointPerLot * stopDistancePoints;
  if(stopMoneyPerLot <= 0.0) return 0.0;

  double lots = riskMoney / stopMoneyPerLot;

  double minLot = 0.0, maxLot = 0.0, step = 0.0;
  SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN,  minLot);
  SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX,  maxLot);
  SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP, step);
  if(step <= 0.0) step = 0.01; // safety default

  lots = MathMax(minLot, MathMin(maxLot, lots));
  lots = MathFloor(lots / step) * step;
  return lots;
}

void ManageTrailingSL(const string symbol, double atr)
{
  if(!PositionSelect(symbol)) return;

  long   type   = PositionGetInteger(POSITION_TYPE);
  double sl     = PositionGetDouble(POSITION_SL);
  double tp     = PositionGetDouble(POSITION_TP);
  double point  = 0.0; GetPoint(symbol, point);

  double trailDistance = InpATRTrailMultiplier * atr;
  double newSL = sl;

  if(type == POSITION_TYPE_BUY)
  {
    newSL = (sl <= 0.0) ? (g_lastTick.bid - trailDistance) : MathMax(sl, g_lastTick.bid - trailDistance);
  }
  else if(type == POSITION_TYPE_SELL)
  {
    newSL = (sl <= 0.0) ? (g_lastTick.ask + trailDistance) : MathMin(sl, g_lastTick.ask + trailDistance);
  }

  if(newSL > 0.0 && newSL != sl)
  {
    trade.PositionModify(symbol, newSL, tp);
  }
}

// Lifecycle
int OnInit()
{
  g_symbol = InpSymbol;
  if(g_symbol == "")
    g_symbol = _Symbol; // set at runtime, not as input default

  g_atrHandle = iATR(g_symbol, InpTF, InpATRPeriod);
  ArraySetAsSeries(g_atrBuffer, true);
  return(INIT_SUCCEEDED);
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
  // Use chart symbol's tick stream; operate on g_symbol
  if(!SymbolInfoTick(g_symbol, g_lastTick)) return;
  if(!CanTradeNow(g_symbol)) return;

  // Compute Donchian channel on selected timeframe
  const int lookback = InpDonchianPeriod;
  const int barsNeeded = lookback + 2;

  MqlRates rates[];
  ArraySetAsSeries(rates, true);
  if(CopyRates(g_symbol, InpTF, 0, barsNeeded, rates) < barsNeeded) return;

  double highest = rates[1].high;
  double lowest  = rates[1].low;
  for(int i = 1; i <= lookback; ++i)
  {
    highest = MathMax(highest, rates[i].high);
    lowest  = MathMin(lowest,  rates[i].low);
  }

  double atr = GetATR(g_symbol, InpTF);
  if(atr <= 0.0) return;

  double point = 0.0; if(!GetPoint(g_symbol, point) || point <= 0.0) return;
  double stopDistancePoints = (InpATRStopMultiplier * atr) / point;

  // Trailing management if in position
  if(HasOpenPosition(g_symbol))
  {
    ManageTrailingSL(g_symbol, atr);
    return;
  }

  // Reset breakout flags when price re-enters channel
  if(rates[0].close < highest && rates[0].close > lowest)
  {
    g_lastBreakoutTradedUp = false;
    g_lastBreakoutTradedDn = false;
  }

  // Entry levels
  double buyStop  = highest + point; // 1 point buffer
  double sellStop = lowest  - point;

  // Optional: one trade per breakout side
  if(InpOneTradePerBreakout && g_lastBreakoutTradedUp && rates[0].close < highest)
    g_lastBreakoutTradedUp = false;
  if(InpOneTradePerBreakout && g_lastBreakoutTradedDn && rates[0].close > lowest)
    g_lastBreakoutTradedDn = false;

  // Cancel existing pending stops for this symbol before placing new ones
  for(int i = OrdersTotal() - 1; i >= 0; --i)
  {
    ulong ticket = OrderGetTicket(i);
    if(ticket == 0) continue;
    if(!OrderSelect(ticket)) continue;

    string osym = OrderGetString(ORDER_SYMBOL);
    if(osym != g_symbol) continue;

    ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
    if(type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP)
    {
      trade.OrderDelete(ticket);
    }
  }

  // Position sizing
  double lots = CalculatePositionSizeLots(g_symbol, stopDistancePoints, InpRiskPerTradePct);
  if(lots <= 0.0) return;

  double slBuy  = buyStop  - InpATRStopMultiplier * atr;
  double slSell = sellStop + InpATRStopMultiplier * atr;

  trade.SetDeviationInPoints(InpSlippagePoints);

  // Place new pending orders (guard by breakout flags)
  if(rates[0].close <= highest && (!InpOneTradePerBreakout || !g_lastBreakoutTradedUp))
  {
    if(trade.BuyStop(lots, buyStop, g_symbol, slBuy, 0.0))
      g_lastBreakoutTradedUp = true;
  }

  if(rates[0].close >= lowest && (!InpOneTradePerBreakout || !g_lastBreakoutTradedDn))
  {
    if(trade.SellStop(lots, sellStop, g_symbol, slSell, 0.0))
      g_lastBreakoutTradedDn = true;
  }
}