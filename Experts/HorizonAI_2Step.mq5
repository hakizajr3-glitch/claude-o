#property copyright "HorizonAI 2026"
#property version   "2.01"
#property strict

#include <Trade/Trade.mqh>

input group "Signal Engine"
input ENUM_TIMEFRAMES SignalTimeframe = PERIOD_M15;
input int FastMAPeriod = 20;
input int SlowMAPeriod = 50;
input int RSIPeriod = 14;
input int ATRPeriod = 14;
input int ADXPeriod = 14;
input int BreakoutLookback = 20;
input double MinimumSetupScore = 70.0;
input double TrendADXMinimum = 22.0;
input double RangeADXMaximum = 18.0;
input double MaximumATRPercent = 1.5;

input group "Risk Control"
input double RiskPerTradePercent = 0.50;
input double StopATRMultiple = 2.0;
input double DailyLossLimitPercent = 5.0; // FTMO 2-Step: max daily loss
input double MaxDrawdownPercent = 10.0; // FTMO 2-Step: max overall loss
input double InitialAccountCapital = 0.0; // FTMO initial simulated capital; 0 = use day-start equity
input int MaxOpenPositions = 1;
input long MagicNumber = 26071301;
input int SlippagePoints = 10;

input group "Winner Management"
input double PartialCloseATRMultiple = 1.5;
input double PartialClosePercent = 50.0;
input double TrailStartATRMultiple = 2.0;
input double TrailATRMultiple = 1.0;

CTrade trade;
int fastMAHandle = INVALID_HANDLE, slowMAHandle = INVALID_HANDLE, rsiHandle = INVALID_HANDLE, atrHandle = INVALID_HANDLE, adxHandle = INVALID_HANDLE;
datetime lastBarTime = 0, currentDay = 0;
double peakEquity = 0.0, dayStartEquity = 0.0;
bool dailyLock = false, drawdownLock = false;

string GVKey(const string suffix)
{
   return "HorizonAI_" + (string)AccountInfoInteger(ACCOUNT_LOGIN) + "_" + suffix;
}

void PersistRiskState()
{
   GlobalVariableSet(GVKey("PeakEquity"), peakEquity);
   GlobalVariableSet(GVKey("DrawdownLock"), drawdownLock ? 1.0 : 0.0);
   GlobalVariableSet(GVKey("DailyLock"), dailyLock ? 1.0 : 0.0);
   GlobalVariableSet(GVKey("CurrentDay"), (double)currentDay);
   GlobalVariableSet(GVKey("DayStartEquity"), dayStartEquity);
}

void RestoreRiskState()
{
   if(GlobalVariableCheck(GVKey("PeakEquity"))) peakEquity = GlobalVariableGet(GVKey("PeakEquity"));
   if(GlobalVariableCheck(GVKey("DrawdownLock"))) drawdownLock = GlobalVariableGet(GVKey("DrawdownLock")) > 0.5;
   if(GlobalVariableCheck(GVKey("DailyLock"))) dailyLock = GlobalVariableGet(GVKey("DailyLock")) > 0.5;
   if(GlobalVariableCheck(GVKey("CurrentDay"))) currentDay = (datetime)GlobalVariableGet(GVKey("CurrentDay"));
   if(GlobalVariableCheck(GVKey("DayStartEquity"))) dayStartEquity = GlobalVariableGet(GVKey("DayStartEquity"));
}

bool Value(const int handle, const int buffer, const int shift, double &value)
{
   double data[];
   ArraySetAsSeries(data, true);
   if(CopyBuffer(handle, buffer, shift, 1, data) != 1) return false;
   value = data[0];
   return true;
}

datetime DayStart(datetime value)
{
   MqlDateTime dt;
   TimeToStruct(value, dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   return StructToTime(dt);
}

// FTMO resets max daily loss at midnight CE(S)T, which may differ from broker server time.
datetime FTMODayStart()
{
   datetime utc = TimeGMT();
   MqlDateTime dt;
   TimeToStruct(utc, dt);
   int offset = (dt.mon >= 4 && dt.mon <= 10) ? 2 : 1; // CEST late March-late Oct, CET otherwise (approximate DST edges)
   datetime cet = utc + offset * 3600;
   TimeToStruct(cet, dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   return StructToTime(dt) - offset * 3600;
}

// Account-wide closed P/L since the FTMO day start: daily-loss rules apply to the
// whole account, not just this EA's magic number.
double ClosedProfitToday()
{
   if(!HistorySelect(FTMODayStart(), TimeCurrent())) return 0.0;
   double total = 0.0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket > 0 && HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_IN)
         total += HistoryDealGetDouble(ticket, DEAL_PROFIT) + HistoryDealGetDouble(ticket, DEAL_SWAP) + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
   }
   return total;
}

int OpenPositionsCount()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetTicket(i) > 0 && PositionGetInteger(POSITION_MAGIC) == MagicNumber && PositionGetString(POSITION_SYMBOL) == _Symbol) count++;
   return count;
}

void UpdateRiskLocks()
{
   datetime today = FTMODayStart();
   if(today != currentDay)
   {
      currentDay = today;
      dailyLock = false;
      // Account-wide equity snapshot at the FTMO midnight reset.
      dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      PersistRiskState();
   }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > peakEquity)
   {
      peakEquity = equity;
      PersistRiskState();
   }

   // FTMO max daily loss: equity at the CE(S)T midnight reset minus the limit,
   // with the loss amount fixed to the initial simulated capital (2-Step rule).
   double dayStart = (dayStartEquity > 0.0 ? dayStartEquity : equity);
   double limitAmount = (InitialAccountCapital > 0.0 ? InitialAccountCapital : dayStart) * DailyLossLimitPercent / 100.0;
   if(dayStart > 0.0 && AccountInfoDouble(ACCOUNT_EQUITY) <= dayStart - limitAmount && !dailyLock)
   {
      dailyLock = true;
      PersistRiskState();
   }
   if(peakEquity > 0.0 && equity <= peakEquity * (1.0 - MaxDrawdownPercent / 100.0) && !drawdownLock)
   {
      drawdownLock = true;
      PersistRiskState();
   }
}

double NormalizeVolume(double volume)
{
   double minimum = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), maximum = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0 || volume < minimum) return 0.0;
   int digits = (int)MathCeil(-MathLog10(step));
   if(digits < 0) digits = 0;
   return NormalizeDouble(MathMin(maximum, MathFloor(volume / step) * step), digits);
}

double CalculateVolume(ENUM_ORDER_TYPE type, double entry, double stop)
{
   double loss = 0.0;
   if(!OrderCalcProfit(type, _Symbol, 1.0, entry, stop, loss) || loss >= 0.0) return 0.0;
   return NormalizeVolume(AccountInfoDouble(ACCOUNT_EQUITY) * RiskPerTradePercent / 100.0 / MathAbs(loss));
}

bool HasPartialClosed(const ulong ticket)
{
   string key = "HorizonPartial_" + (string)ticket;
   return GlobalVariableCheck(key);
}

void MarkPartialClosed(const ulong ticket)
{
   GlobalVariableSet("HorizonPartial_" + (string)ticket, (double)TimeCurrent());
}

void CleanupPartialMarkers()
{
   for(int i = GlobalVariablesTotal() - 1; i >= 0; i--)
   {
      string name = GlobalVariableName(i);
      if(StringFind(name, "HorizonPartial_", 0) != 0) continue;
      string ticketStr = StringSubstr(name, StringLen("HorizonPartial_"));
      ulong ticket = StringToInteger(ticketStr);
      bool found = false;
      for(int j = PositionsTotal() - 1; j >= 0; j--)
      {
         if(PositionGetTicket(j) > 0 && (ulong)PositionGetInteger(POSITION_TICKET) == ticket)
         {
            found = true;
            break;
         }
      }
      if(!found) GlobalVariableDel(name);
   }
}

void ManagePositions()
{
   double atr = 0.0;
   if(!Value(atrHandle, 0, 0, atr) || atr <= 0.0) return;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID), ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || PositionGetInteger(POSITION_MAGIC) != MagicNumber || PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN), volume = PositionGetDouble(POSITION_VOLUME), sl = PositionGetDouble(POSITION_SL), tp = PositionGetDouble(POSITION_TP);
      double profitDistance = (type == POSITION_TYPE_BUY ? bid - open : open - ask);

      if(profitDistance >= atr * PartialCloseATRMultiple && !HasPartialClosed(ticket))
      {
         double closeVolume = NormalizeVolume(volume * PartialClosePercent / 100.0);
         double minimum = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
         if(closeVolume >= minimum && volume - closeVolume >= minimum)
         {
            // Only mark as partially closed when the server actually accepted the
            // request, so a rejection can be retried on the next tick.
            if(trade.PositionClosePartial(ticket, closeVolume) && trade.ResultRetcode() == TRADE_RETCODE_DONE)
               MarkPartialClosed(ticket);
            else
               Print("Partial close failed for ticket ", ticket, ", retcode=", trade.ResultRetcode(), ", comment=", trade.ResultComment());
         }
      }

      // Break-even: retried every tick until the server accepts it, instead of
      // being skipped forever after a single failed modify.
      if(HasPartialClosed(ticket))
      {
         double breakEven = NormalizeDouble(open, _Digits);
         bool needsBE = (type == POSITION_TYPE_BUY && (sl == 0.0 || breakEven > sl)) || (type == POSITION_TYPE_SELL && (sl == 0.0 || breakEven < sl));
         if(needsBE && !trade.PositionModify(ticket, breakEven, tp))
            Print("Break-even modify failed for ticket ", ticket, ", retcode=", trade.ResultRetcode(), ", will retry");
      }

      if(profitDistance >= atr * TrailStartATRMultiple)
      {
         double candidate = NormalizeDouble(type == POSITION_TYPE_BUY ? bid - atr * TrailATRMultiple : ask + atr * TrailATRMultiple, _Digits);
         if((type == POSITION_TYPE_BUY && candidate > sl) || (type == POSITION_TYPE_SELL && (sl == 0.0 || candidate < sl)))
            if(trade.PositionModify(ticket, candidate, tp)) sl = candidate;
      }
   }
}

void EvaluateEntry()
{
   if(dailyLock || drawdownLock || OpenPositionsCount() >= MaxOpenPositions) return;

   double fast, slow, rsi, atr, adx, plusDI, minusDI;
   if(!Value(fastMAHandle, 0, 1, fast) || !Value(slowMAHandle, 0, 1, slow) || !Value(rsiHandle, 0, 1, rsi) || !Value(atrHandle, 0, 1, atr) || !Value(adxHandle, 0, 1, adx) || !Value(adxHandle, 1, 1, plusDI) || !Value(adxHandle, 2, 1, minusDI) || atr <= 0.0) return;

   double close = iClose(_Symbol, SignalTimeframe, 1);
   if(close <= 0.0 || atr / close * 100.0 > MaximumATRPercent) return;

   double highs[], lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);
   if(CopyHigh(_Symbol, SignalTimeframe, 2, BreakoutLookback, highs) != BreakoutLookback || CopyLow(_Symbol, SignalTimeframe, 2, BreakoutLookback, lows) != BreakoutLookback) return;

   int hi = ArrayMaximum(highs), lo = ArrayMinimum(lows);
   bool trendBuy = adx >= TrendADXMinimum && fast > slow && plusDI > minusDI && rsi >= 55.0;
   bool trendSell = adx >= TrendADXMinimum && fast < slow && minusDI > plusDI && rsi <= 45.0;
   bool rangeBuy = adx <= RangeADXMaximum && rsi <= 30.0 && close <= lows[lo] + atr * 0.35;
   bool rangeSell = adx <= RangeADXMaximum && rsi >= 70.0 && close >= highs[hi] - atr * 0.35;
   bool breakBuy = adx >= TrendADXMinimum && close > highs[hi] && plusDI > minusDI;
   bool breakSell = adx >= TrendADXMinimum && close < lows[lo] && minusDI > plusDI;
   bool buy = trendBuy || rangeBuy || breakBuy, sell = trendSell || rangeSell || breakSell;

   double rsiBuyBonus = (rsi >= 50.0 && rsi <= 75.0 ? 15.0 : (rangeBuy && rsi <= 30.0 ? 15.0 : 0.0));
   double rsiSellBonus = (rsi <= 50.0 && rsi >= 25.0 ? 15.0 : (rangeSell && rsi >= 70.0 ? 15.0 : 0.0));
   double buyScore = (trendBuy ? 40 : 0) + (rangeBuy ? 35 : 0) + (breakBuy ? 40 : 0) + (fast > slow ? 15 : 0) + (plusDI > minusDI ? 15 : 0) + rsiBuyBonus;
   double sellScore = (trendSell ? 40 : 0) + (rangeSell ? 35 : 0) + (breakSell ? 40 : 0) + (fast < slow ? 15 : 0) + (minusDI > plusDI ? 15 : 0) + rsiSellBonus;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK), bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(buy && buyScore >= MinimumSetupScore)
   {
      double sl = NormalizeDouble(ask - atr * StopATRMultiple, _Digits), volume = CalculateVolume(ORDER_TYPE_BUY, ask, sl);
      if(volume > 0.0)
      {
         trade.Buy(volume, _Symbol, 0.0, sl, 0.0, "Autonomous scored buy");
         if(trade.ResultRetcode() != TRADE_RETCODE_DONE)
            Print("Buy rejected, retcode=", trade.ResultRetcode(), ", comment=", trade.ResultComment());
      }
   }
   else if(sell && sellScore >= MinimumSetupScore)
   {
      double sl = NormalizeDouble(bid + atr * StopATRMultiple, _Digits), volume = CalculateVolume(ORDER_TYPE_SELL, bid, sl);
      if(volume > 0.0)
      {
         trade.Sell(volume, _Symbol, 0.0, sl, 0.0, "Autonomous scored sell");
         if(trade.ResultRetcode() != TRADE_RETCODE_DONE)
            Print("Sell rejected, retcode=", trade.ResultRetcode(), ", comment=", trade.ResultComment());
      }
   }
}

int OnInit()
{
   if(FastMAPeriod >= SlowMAPeriod || RiskPerTradePercent <= 0.0 || StopATRMultiple <= 0.0 || MaxOpenPositions < 1 || MinimumSetupScore > 100.0) return INIT_PARAMETERS_INCORRECT;
   fastMAHandle = iMA(_Symbol, SignalTimeframe, FastMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   slowMAHandle = iMA(_Symbol, SignalTimeframe, SlowMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   rsiHandle = iRSI(_Symbol, SignalTimeframe, RSIPeriod, PRICE_CLOSE);
   atrHandle = iATR(_Symbol, SignalTimeframe, ATRPeriod);
   adxHandle = iADX(_Symbol, SignalTimeframe, ADXPeriod);
   if(fastMAHandle == INVALID_HANDLE || slowMAHandle == INVALID_HANDLE || rsiHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE || adxHandle == INVALID_HANDLE) return INIT_FAILED;

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   // Restore risk state so a re-init cannot reset a prior max-drawdown breach
   // (peakEquity must not restart from reduced equity) or the daily lock.
   RestoreRiskState();
   currentDay = FTMODayStart();
   if(GlobalVariableCheck(GVKey("CurrentDay")) && (datetime)GlobalVariableGet(GVKey("CurrentDay")) == currentDay)
   {
      if(dayStartEquity <= 0.0) dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   }
   else
   {
      dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      currentDay = FTMODayStart();
      PersistRiskState();
   }
   if(peakEquity <= 0.0) peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   lastBarTime = iTime(_Symbol, SignalTimeframe, 0);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   IndicatorRelease(fastMAHandle);
   IndicatorRelease(slowMAHandle);
   IndicatorRelease(rsiHandle);
   IndicatorRelease(atrHandle);
   IndicatorRelease(adxHandle);
   CleanupPartialMarkers();
}

void OnTick()
{
   UpdateRiskLocks();
   ManagePositions();
   datetime bar = iTime(_Symbol, SignalTimeframe, 0);
   if(bar == 0 || bar == lastBarTime) return;
   lastBarTime = bar;
   EvaluateEntry();
}
