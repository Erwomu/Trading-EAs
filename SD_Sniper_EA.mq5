//+------------------------------------------------------------------+
//|                                                  SD Sniper EA.mq5 |
//|                                       Copyright 2025, Erwomu.     |
//|                                             https://www.mql5.com   |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, Erwomu."
#property link      "https://www.mql5.com"
#property version   "2.00"
#property description "SD Sniper EA v2.0"
#property description "Supply & Demand Zones | Liquidity Sweep | Displacement | M5 BOS"
#property description "Single Symbol | 1 Trade Per Day | No 2nd Attempt"
#property strict

//+------------------------------------------------------------------+
//| Includes                                                          |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\PositionInfo.mqh>
#include <Canvas\Canvas.mqh>

//+------------------------------------------------------------------+
//| ═══════════════════════════════════════════════════════════════════|
//| SECTION 1: INPUT PARAMETERS                                       |
//| ═══════════════════════════════════════════════════════════════════|
//+------------------------------------------------------------------+
sinput string            _sep1                  = "══════ General ══════";
input  int               EAMagicNumber          = 240001;
input  ENUM_TIMEFRAMES   SetupTimeframe         = PERIOD_H1;     // H1 — displacement detection
input  ENUM_TIMEFRAMES   EntryTimeframe         = PERIOD_M5;     // M5 — break of structure entry
input  ENUM_TIMEFRAMES   ATRTimeframe           = PERIOD_M30;    // ATR calculation timeframe
input  ENUM_TIMEFRAMES   LevelsTimeframe        = PERIOD_D1;     // PDH/PDL source timeframe
input  bool              UseSniperEntry         = true;          // true=M5 BOS, false=enter on H1 close

sinput string            _sep2                  = "══════ Risk Management ══════";
input  double            RiskPercent            = 0.56;          // Account risk % per trade
input  double            RiskRewardRatio        = 3.0;           // TP = SL × this value
input  int               ATR_Period             = 14;            // ATR lookback
input  double            ATR_StopBuffer         = 0.45;          // ATR × this = SL cushion beyond sweep wick
input  double            MinStopLoss            = 200;           // Minimum SL in points
input  double            MaxStopLoss            = 1000;          // Maximum SL in points
input  double            BreakevenTrigger_R     = 1.5;           // Move SL to BE at this R-multiple

sinput string            _sep3                  = "══════ Displacement & Entry ══════";
input  int               BOS_Timeout            = 36;            // Max M5 bars to wait for BOS (36=3hrs)
input  int               SwingLookback          = 5;             // M5 bars to search for swing points

sinput string            _sep4                  = "══════ Filters ══════";
input  bool              UseADXFilter           = true;
input  int               ADXPeriod              = 14;
input  double            MinADX                 = 25.0;
input  ENUM_TIMEFRAMES   ADXTimeframe           = PERIOD_H1;
input  bool              UseNewsFilter          = true;
input  double            MaxSpread              = 4.5;           // Max spread in pips

sinput string            _sep5                  = "══════ Trading Window ══════";
input  bool              UseTimeFilter          = true;
input  int               StartHour              = 11;
input  int               StartMinute            = 0;
input  int               EndHour                = 14;
input  int               EndMinute              = 0;
input  int               MaxTradesPerDay        = 1;

sinput string            _sep6                  = "══════ S/D Zones ══════";
input  double            ZoneMultiplier         = 0.20;          // ATR × this = zone half-width

sinput string            _sep7                  = "══════ Visualization ══════";
input  bool              DrawLevels             = true;
input  bool              DrawZones              = true;
input  color             ResistanceColor        = clrOrangeRed;  // Resistance level + supply zone
input  color             SupportColor           = clrDodgerBlue; // Support level + demand zone

//+------------------------------------------------------------------+
//| ═══════════════════════════════════════════════════════════════════|
//| SECTION 2: ENUMS & STRUCTURES                                     |
//| ═══════════════════════════════════════════════════════════════════|
//+------------------------------------------------------------------+

//--- EA State Machine
enum ENUM_EA_STATE
{
   STATE_SCANNING,            // Levels set, watching for displacement
   STATE_WAITING_BOS,         // H1 displacement confirmed, waiting M5 BOS
   STATE_TRADE_OPEN,          // Position is live, managing exits
   STATE_DAILY_LOCKED         // Trade taken today — done until tomorrow
};

//--- Daily levels from previous day's D1 candle
struct DailyLevels
{
   double   pdh;              // Previous Day High
   double   pdl;              // Previous Day Low
   double   pdo;              // Previous Day Open
   double   pdc;              // Previous Day Close
   double   currentDayOpen;   // Today's open
   bool     isValid;
   void Reset() { pdh=0; pdl=0; pdo=0; pdc=0; currentDayOpen=0; isValid=false; }
};

//--- Key levels the EA watches (nearest to price)
struct KeyLevels
{
   double   resistance;       // Nearest resistance above price
   double   support;          // Nearest support below price
   string   resistanceType;   // "PDH", "ROUND", "PDH+ROUND"
   string   supportType;      // "PDL", "ROUND", "PDL+ROUND"
   bool     isValid;
   void Reset() { resistance=0; support=0; resistanceType=""; supportType=""; isValid=false; }
};

//--- Displacement setup data — the H1 event that triggers everything
struct DisplacementSetup
{
   bool     isValid;
   int      direction;        // +1 = buy (bullish displacement at support)
                              // -1 = sell (bearish displacement at resistance)
   double   sweepWick;        // Extreme wick level (for SL placement)
   double   keyLevel;         // The institutional level that was swept
   string   levelType;        // e.g., "PDH+ROUND"
   datetime setupTime;        // When displacement H1 bar closed
   
   void Reset()
   {
      isValid = false;
      direction = 0;
      sweepWick = 0;
      keyLevel = 0;
      levelType = "";
      setupTime = 0;
   }
};

//+------------------------------------------------------------------+
//| ═══════════════════════════════════════════════════════════════════|
//| SECTION 3: GLOBAL STATE                                           |
//| ═══════════════════════════════════════════════════════════════════|
//+------------------------------------------------------------------+
ENUM_EA_STATE     g_state              = STATE_SCANNING;
DailyLevels       g_daily;
KeyLevels         g_keyLevels;
DisplacementSetup g_displacement;
double            g_zoneWidth          = 0;       // ATR × ZoneMultiplier
double            g_currentATR         = 0;       // Latest ATR value

//--- Trade objects
CTrade            g_trade;
CSymbolInfo       g_symbolInfo;
CPositionInfo     g_positionInfo;

//--- Indicator handles
int               g_atrHandle          = INVALID_HANDLE;
int               g_adxHandle          = INVALID_HANDLE;

//--- New bar tracking (prevents re-processing the same bar)
datetime          g_lastH1Bar          = 0;
datetime          g_lastM5Bar          = 0;
datetime          g_lastDayBar         = 0;

//--- BOS tracking
int               g_bosBarCount        = 0;       // M5 bars elapsed since displacement
double            g_bosSwingLevel      = 0;       // Pullback extreme tracked after displacement
bool              g_bosPullbackStarted = false;   // True once price pulls back against displacement

//--- Daily trade limit
int               g_tradesOpenedToday  = 0;
bool              g_tradingLockedToday = false;

//--- News filter
bool              g_newsActive         = false;
datetime          g_newsResumeTime     = 0;

//--- Dashboard
#define SDS_DASH_PREFIX  "SDS_DASH_"
#define SDS_DASH_X       13
#define SDS_DASH_Y       380
#define SDS_DASH_W       330
#define SDS_DASH_H       90
#define SDS_DASH_R       10
#define CLR_PANEL_BG     C'30,30,30'
#define CLR_PANEL_BORDER C'218,165,32'
#define CLR_DASH_TEXT    C'218,165,32'
#define CLR_DASH_VALUE   C'255,255,255'
#define CLR_DASH_GREEN   C'0,200,100'
#define CLR_DASH_RED     C'220,50,50'
CCanvas           g_dashCanvas;

//+------------------------------------------------------------------+
//| ═══════════════════════════════════════════════════════════════════|
//| SECTION 4: LEVEL CALCULATION                                      |
//| ═══════════════════════════════════════════════════════════════════|
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Get Previous Period High/Low/Open/Close from LevelsTimeframe[1]   |
//+------------------------------------------------------------------+
DailyLevels GetDailyLevels()
{
   DailyLevels levels;
   levels.Reset();

   double high[], low[], open[], close[];

   if(CopyHigh(_Symbol, LevelsTimeframe, 1, 1, high) < 1 ||
      CopyLow(_Symbol, LevelsTimeframe, 1, 1, low) < 1 ||
      CopyOpen(_Symbol, LevelsTimeframe, 1, 1, open) < 1 ||
      CopyClose(_Symbol, LevelsTimeframe, 1, 1, close) < 1)
   {
      PrintFormat("❌ Failed to get %s data", EnumToString(LevelsTimeframe));
      return levels;
   }

   double currentOpen[];
   if(CopyOpen(_Symbol, LevelsTimeframe, 0, 1, currentOpen) < 1)
   {
      Print("❌ Failed to get current period open");
      return levels;
   }

   levels.pdh = high[0];
   levels.pdl = low[0];
   levels.pdo = open[0];
   levels.pdc = close[0];
   levels.currentDayOpen = currentOpen[0];
   levels.isValid = true;

   return levels;
}

//+------------------------------------------------------------------+
//| Get nearest round number to a price                               |
//| Standard pairs (4/5 digit): .XX00 levels (e.g., 1.0800, 1.0900)  |
//| JPY pairs (2/3 digit): X.00 levels (e.g., 150.00, 151.00)        |
//+------------------------------------------------------------------+
double GetNearestRoundNumber(double price, int digits)
{
   if(digits == 2 || digits == 3)  // JPY pairs
      return NormalizeDouble(MathRound(price), digits);
   else  // Standard pairs (4 or 5 digit)
      return NormalizeDouble(MathRound(price * 100.0) / 100.0, digits);
}

//+------------------------------------------------------------------+
//| Get next round number above or below price                        |
//+------------------------------------------------------------------+
double GetNextRoundNumber(double price, bool above, int digits)
{
   double step = (digits == 2 || digits == 3) ? 1.00 : 0.01;
   double rounded = GetNearestRoundNumber(price, digits);
   
   if(above && rounded <= price)
      rounded += step;
   else if(!above && rounded >= price)
      rounded -= step;
   
   return NormalizeDouble(rounded, digits);
}

//+------------------------------------------------------------------+
//| Calculate key levels: nearest resistance & support to current price|
//| Considers PDH/PDL and round numbers, detects confluence           |
//| PDH/PDL sourced from LevelsTimeframe (default D1)                 |
//| Round numbers calculated dynamically from current price            |
//+------------------------------------------------------------------+
KeyLevels CalculateKeyLevels()
{
   KeyLevels kl;
   kl.Reset();

   if(!g_daily.isValid) return kl;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double price = (bid + ask) / 2.0;
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double roundAbove = GetNextRoundNumber(price, true, digits);
   double roundBelow = GetNextRoundNumber(price, false, digits);

   //--- RESISTANCE: nearest level above price (PDH or Round)
   if(g_daily.pdh > price)
   {
      double distPDH   = MathAbs(price - g_daily.pdh);
      double distRound = MathAbs(price - roundAbove);

      // Check confluence first: PDH and round number within 10 pips
      double pipValue = (digits == 5 || digits == 3) ? 0.0001 : 0.01;
      if(MathAbs(g_daily.pdh - roundAbove) < 10.0 * pipValue)
      {
         kl.resistance = g_daily.pdh;
         kl.resistanceType = "PDH+ROUND";
      }
      else if(distPDH < distRound)
      {
         kl.resistance = g_daily.pdh;
         kl.resistanceType = "PDH";
      }
      else
      {
         kl.resistance = roundAbove;
         kl.resistanceType = "ROUND";
      }
   }
   else
   {
      kl.resistance = roundAbove;
      kl.resistanceType = "ROUND";
   }

   //--- SUPPORT: nearest level below price (PDL or Round)
   if(g_daily.pdl < price)
   {
      double distPDL   = MathAbs(price - g_daily.pdl);
      double distRound = MathAbs(price - roundBelow);

      double pipValue = (digits == 5 || digits == 3) ? 0.0001 : 0.01;
      if(MathAbs(g_daily.pdl - roundBelow) < 10.0 * pipValue)
      {
         kl.support = g_daily.pdl;
         kl.supportType = "PDL+ROUND";
      }
      else if(distPDL < distRound)
      {
         kl.support = g_daily.pdl;
         kl.supportType = "PDL";
      }
      else
      {
         kl.support = roundBelow;
         kl.supportType = "ROUND";
      }
   }
   else
   {
      kl.support = roundBelow;
      kl.supportType = "ROUND";
   }

   kl.isValid = (kl.resistance > 0 || kl.support > 0);
   return kl;
}

//+------------------------------------------------------------------+
//| ═══════════════════════════════════════════════════════════════════|
//| SECTION 5: ATR & ZONE LOGIC                                       |
//| ═══════════════════════════════════════════════════════════════════|
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Get current ATR value                                             |
//+------------------------------------------------------------------+
double GetATRValue()
{
   if(g_atrHandle == INVALID_HANDLE) return 0;
   
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_atrHandle, 0, 0, 1, buf) < 1) return 0;
   
   return buf[0];
}

//+------------------------------------------------------------------+
//| Check if price is inside the S/D zone around a key level          |
//+------------------------------------------------------------------+
bool IsPriceInZone(double price, double keyLevel)
{
   if(keyLevel <= 0 || g_zoneWidth <= 0) return false;
   return (price >= keyLevel - g_zoneWidth && price <= keyLevel + g_zoneWidth);
}

//+------------------------------------------------------------------+
//| ═══════════════════════════════════════════════════════════════════|
//| SECTION 6: DISPLACEMENT DETECTION (H1)                            |
//|                                                                    |
//| How a human reads this:                                            |
//| 1. Price approaches a key level                                    |
//| 2. A candle's wick STABS through the level (liquidity sweep)       |
//| 3. That same candle's body SLAMS back the other way (displacement) |
//| 4. The candle clearly "chose a direction" — not a doji or noise    |
//|                                                                    |
//| That single candle tells the whole story: institutions swept       |
//| the level, filled their orders, and reversed aggressively.         |
//| ═══════════════════════════════════════════════════════════════════|
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Detect displacement on the most recently closed H1 bar            |
//+------------------------------------------------------------------+
DisplacementSetup DetectDisplacement()
{
   DisplacementSetup setup;
   setup.Reset();
   
   if(!g_keyLevels.isValid) return setup;
   
   //--- Read the just-closed H1 candle (bar index 1)
   double open1  = iOpen(_Symbol, SetupTimeframe, 1);
   double close1 = iClose(_Symbol, SetupTimeframe, 1);
   double high1  = iHigh(_Symbol, SetupTimeframe, 1);
   double low1   = iLow(_Symbol, SetupTimeframe, 1);
   datetime time1 = iTime(_Symbol, SetupTimeframe, 1);
   double range1 = high1 - low1;
   double body1  = MathAbs(close1 - open1);
   
   // Skip zero-range bars (no price movement at all)
   if(range1 < _Point * 2) return setup;
   
   //--- Displacement requires conviction, not indecision.
   //    A doji that happened to wick through a level is NOT displacement.
   //    A human sees a strong-bodied candle and thinks "that was aggressive."
   //    We check: is the body the dominant part of this candle?
   //    This is not a generic filter — it's what displacement MEANS.
   double bodyRatio = body1 / range1;
   if(bodyRatio < 0.35) return setup;  // Below 35% body = indecision, not displacement
   
   //--- ═══════════════════════════════════════════
   //    CHECK SELL DISPLACEMENT AT RESISTANCE
   //    Human sees: wick stabs above PDH, body slams back below
   //    ═══════════════════════════════════════════
   if(g_keyLevels.resistance > 0)
   {
      bool wickSweptAbove = (high1 > g_keyLevels.resistance);
      bool bodyClosedBelow = (close1 < g_keyLevels.resistance);
      bool isBearishCandle = (close1 < open1);

      if(wickSweptAbove && bodyClosedBelow && isBearishCandle)
      {
         //--- Zone proximity check: was price actually approaching the level?
         //    The candle's open must have been below resistance (approaching from below).
         //    This prevents counting a candle that gapped down through the level.
         bool priceApproached = (open1 < g_keyLevels.resistance + g_zoneWidth);
         
         if(priceApproached)
         {
            setup.isValid    = true;
            setup.direction  = -1;  // SELL
            setup.sweepWick  = high1;
            setup.keyLevel   = g_keyLevels.resistance;
            setup.levelType  = g_keyLevels.resistanceType;
            setup.setupTime  = time1;
            
            PrintFormat("🎯 DISPLACEMENT DETECTED: SELL | Level: %.5f (%s) | Sweep: %.5f | Close: %.5f | Body: %.1f%%",
                       setup.keyLevel, setup.levelType, setup.sweepWick, close1, bodyRatio * 100);
            return setup;
         }
      }
   }
   
   //--- ═══════════════════════════════════════════
   //    CHECK BUY DISPLACEMENT AT SUPPORT
   //    Human sees: wick stabs below PDL, body slams back above
   //    ═══════════════════════════════════════════
   if(g_keyLevels.support > 0)
   {
      bool wickSweptBelow = (low1 < g_keyLevels.support);
      bool bodyClosedAbove = (close1 > g_keyLevels.support);
      bool isBullishCandle = (close1 > open1);

      if(wickSweptBelow && bodyClosedAbove && isBullishCandle)
      {
         bool priceApproached = (open1 > g_keyLevels.support - g_zoneWidth);
         
         if(priceApproached)
         {
            setup.isValid    = true;
            setup.direction  = 1;   // BUY
            setup.sweepWick  = low1;
            setup.keyLevel   = g_keyLevels.support;
            setup.levelType  = g_keyLevels.supportType;
            setup.setupTime  = time1;
            
            PrintFormat("🎯 DISPLACEMENT DETECTED: BUY | Level: %.5f (%s) | Sweep: %.5f | Close: %.5f | Body: %.1f%%",
                       setup.keyLevel, setup.levelType, setup.sweepWick, close1, bodyRatio * 100);
            return setup;
         }
      }
   }
   
   return setup;
}

//+------------------------------------------------------------------+
//| ═══════════════════════════════════════════════════════════════════|
//| SECTION 7: M5 BREAK OF STRUCTURE (SWING POINT)                    |
//|                                                                    |
//| After H1 displacement, we drop to M5 and look for a swing point   |
//| to break:                                                          |
//| 1. For SELL: find the most recent M5 swing low (Low < neighbors)  |
//|    and wait for an M5 bar to close below it.                       |
//| 2. For BUY: find the most recent M5 swing high (High > neighbors) |
//|    and wait for an M5 bar to close above it.                       |
//|                                                                    |
//| A swing point is a bar whose extreme is lower/higher than both     |
//| its left and right neighbors — a genuine structural pivot.         |
//| ═══════════════════════════════════════════════════════════════════|
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Update pullback tracking and check for BOS                        |
//+------------------------------------------------------------------+
bool CheckBOS()
{
   double close1 = iClose(_Symbol, EntryTimeframe, 1);

   if(g_displacement.direction == -1)  // SELL setup — find swing low, close below it
   {
      //--- Find the most recent M5 swing low (a bar whose Low < neighbors)
      //    We need at least 3 bars to define a swing: left neighbor, swing, right neighbor
      //    Search from bar 2 onward (bar 1 is the just-closed bar we're checking)
      for(int i = 2; i <= SwingLookback + 2 && i <= g_bosBarCount; i++)
      {
         double lowI  = iLow(_Symbol, EntryTimeframe, i);
         double lowL  = iLow(_Symbol, EntryTimeframe, i + 1);  // left neighbor (older)
         double lowR  = iLow(_Symbol, EntryTimeframe, i - 1);  // right neighbor (newer)

         if(lowI < lowL && lowI < lowR)  // valid swing low
         {
            //--- BOS: current M5 bar closes below this swing low
            if(close1 < lowI)
            {
               PrintFormat("✅ M5 BOS CONFIRMED: SELL | Swing low: %.5f (bar %d) | M5 close: %.5f | Bars waited: %d",
                          lowI, i, close1, g_bosBarCount);
               return true;
            }
            break;  // only check the most recent swing low
         }
      }
   }
   else if(g_displacement.direction == 1)  // BUY setup — find swing high, close above it
   {
      for(int i = 2; i <= SwingLookback + 2 && i <= g_bosBarCount; i++)
      {
         double highI = iHigh(_Symbol, EntryTimeframe, i);
         double highL = iHigh(_Symbol, EntryTimeframe, i + 1);  // left neighbor (older)
         double highR = iHigh(_Symbol, EntryTimeframe, i - 1);  // right neighbor (newer)

         if(highI > highL && highI > highR)  // valid swing high
         {
            //--- BOS: current M5 bar closes above this swing high
            if(close1 > highI)
            {
               PrintFormat("✅ M5 BOS CONFIRMED: BUY | Swing high: %.5f (bar %d) | M5 close: %.5f | Bars waited: %d",
                          highI, i, close1, g_bosBarCount);
               return true;
            }
            break;  // only check the most recent swing high
         }
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| ═══════════════════════════════════════════════════════════════════|
//| SECTION 8: FILTERS                                                |
//| ═══════════════════════════════════════════════════════════════════|
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Time window filter                                                |
//+------------------------------------------------------------------+
bool IsWithinTradingHours()
{
   if(!UseTimeFilter) return true;
   
   MqlDateTime current;
   TimeToStruct(TimeCurrent(), current);
   
   int currentMin = current.hour * 60 + current.min;
   int startMin   = StartHour * 60 + StartMinute;
   int endMin     = EndHour * 60 + EndMinute;
   
   if(endMin < startMin)
      return (currentMin >= startMin || currentMin < endMin);
   else
      return (currentMin >= startMin && currentMin < endMin);
}

//+------------------------------------------------------------------+
//| Spread filter (pips)                                              |
//+------------------------------------------------------------------+
bool IsSpreadAcceptable()
{
   g_symbolInfo.RefreshRates();
   double spreadPrice = g_symbolInfo.Ask() - g_symbolInfo.Bid();
   
   int digits = (int)g_symbolInfo.Digits();
   double pipValue = (digits == 3 || digits == 2) ? 0.01 : 0.0001;
   double spreadPips = spreadPrice / pipValue;
   
   return (spreadPips <= MaxSpread);
}

//+------------------------------------------------------------------+
//| ADX trend strength and DI alignment                               |
//+------------------------------------------------------------------+
bool CheckADX(int direction)
{
   if(!UseADXFilter) return true;
   if(g_adxHandle == INVALID_HANDLE)
   {
      Print("❌ ADX handle invalid — blocking trade (fail closed)");
      return false;
   }
   
   double adxMain[], plusDI[], minusDI[];
   ArraySetAsSeries(adxMain, true);
   ArraySetAsSeries(plusDI, true);
   ArraySetAsSeries(minusDI, true);
   
   if(CopyBuffer(g_adxHandle, 0, 0, 1, adxMain) < 1 ||
      CopyBuffer(g_adxHandle, 1, 0, 1, plusDI) < 1 ||
      CopyBuffer(g_adxHandle, 2, 0, 1, minusDI) < 1)
   {
      Print("❌ ADX data unavailable — blocking trade (fail closed)");
      return false;
   }
   
   // Market must be trending
   if(adxMain[0] < MinADX)
   {
      PrintFormat("❌ ADX too weak: %.1f < %.1f", adxMain[0], MinADX);
      return false;
   }
   
   // DI must align with trade direction
   if(direction == 1 && plusDI[0] <= minusDI[0])
   {
      PrintFormat("❌ ADX: BUY but +DI(%.1f) ≤ -DI(%.1f)", plusDI[0], minusDI[0]);
      return false;
   }
   if(direction == -1 && minusDI[0] <= plusDI[0])
   {
      PrintFormat("❌ ADX: SELL but -DI(%.1f) ≤ +DI(%.1f)", minusDI[0], plusDI[0]);
      return false;
   }
   
   PrintFormat("✓ ADX OK: %.1f | +DI: %.1f | -DI: %.1f", adxMain[0], plusDI[0], minusDI[0]);
   return true;
}

//+------------------------------------------------------------------+
//| News impact filter (MQL5 Economic Calendar)                       |
//+------------------------------------------------------------------+
void CheckNewsImpact()
{
   if(!UseNewsFilter) { g_newsActive = false; return; }
   
   string extremeEvents[] = {"Nonfarm Payrolls", "FOMC"};
   string highImpactEvents[] = {
      "Consumer Price Index", "Gross Domestic Product", "Interest Rate Decision",
      "Retail Sales", "Unemployment Rate", "ECB Press Conference"
   };
   
   datetime now = TimeCurrent();
   datetime dayStart = iTime(_Symbol, PERIOD_D1, 0);
   datetime dayEnd = dayStart + PeriodSeconds(PERIOD_D1);
   
   MqlCalendarValue values[];
   int eventsCount = CalendarValueHistory(values, dayStart, dayEnd, NULL, NULL);
   
   if(eventsCount <= 0) { g_newsActive = false; return; }
   
   MqlCalendarEvent event;
   
   for(int i = 0; i < eventsCount; i++)
   {
      if(values[i].time > now && CalendarEventById(values[i].event_id, event))
      {
         int timeBuffer = 0;
         
         for(int j = 0; j < ArraySize(extremeEvents); j++)
         {
            if(StringFind(event.name, extremeEvents[j]) >= 0)
            { timeBuffer = 20 * 60; break; }
         }
         
         if(timeBuffer == 0)
         {
            for(int j = 0; j < ArraySize(highImpactEvents); j++)
            {
               if(StringFind(event.name, highImpactEvents[j]) >= 0)
               { timeBuffer = 10 * 60; break; }
            }
         }
         
         if(timeBuffer > 0)
         {
            datetime bufferStart = values[i].time - timeBuffer;
            datetime bufferEnd   = values[i].time + timeBuffer;
            
            if(now >= bufferStart && now <= bufferEnd)
            {
               g_newsActive = true;
               g_newsResumeTime = bufferEnd;
               return;
            }
         }
      }
   }
   
   // Check if previous news period ended
   if(g_newsActive && now > g_newsResumeTime)
      g_newsActive = false;
}

//+------------------------------------------------------------------+
//| Combined filter gate — all conditions must pass before entry      |
//+------------------------------------------------------------------+
bool IsTradingAllowed()
{
   if(!IsWithinTradingHours())
   { PrintFormat("❌ Outside trading hours"); return false; }
   
   if(g_newsActive)
   { PrintFormat("❌ News filter active until %s", TimeToString(g_newsResumeTime, TIME_MINUTES)); return false; }
   
   if(!IsSpreadAcceptable())
   { PrintFormat("❌ Spread exceeds %.1f pips", MaxSpread); return false; }
   
   if(!CheckADX(g_displacement.direction))
      return false;
   
   if(g_tradingLockedToday || g_tradesOpenedToday >= MaxTradesPerDay)
   { return false; }
   
   if(HasOpenPosition())
   { return false; }
   
   return true;
}

//+------------------------------------------------------------------+
//| ═══════════════════════════════════════════════════════════════════|
//| SECTION 9: RISK MANAGEMENT & LOT SIZING                          |
//| ═══════════════════════════════════════════════════════════════════|
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Calculate lot size from risk%, SL distance, and tick value        |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
{
   if(slDistance <= 0) return 0.01;
   
   g_symbolInfo.RefreshRates();
   
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt   = (RiskPercent / 100.0) * balance;
   double tickVal   = g_symbolInfo.TickValue();
   double tickSize  = g_symbolInfo.TickSize();
   
   if(tickVal <= 0 || tickSize <= 0 || balance <= 0) return 0.01;
   
   double slPoints  = slDistance / tickSize;
   if(slPoints <= 0) return 0.01;
   
   double lots = riskAmt / (slPoints * tickVal);
   
   // Clamp to broker limits
   double minLot  = g_symbolInfo.LotsMin();
   double maxLot  = g_symbolInfo.LotsMax();
   double lotStep = g_symbolInfo.LotsStep();
   
   if(minLot <= 0 || maxLot <= 0 || lotStep <= 0) return 0.01;
   
   lots = MathMax(minLot, MathMin(lots, maxLot));
   lots = NormalizeDouble(MathFloor(lots / lotStep) * lotStep, 2);
   lots = MathMax(lots, minLot);
   
   return lots;
}

//+------------------------------------------------------------------+
//| ═══════════════════════════════════════════════════════════════════|
//| SECTION 10: TRADE EXECUTION                                       |
//| ═══════════════════════════════════════════════════════════════════|
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Execute trade based on current displacement setup                 |
//+------------------------------------------------------------------+
bool ExecuteTrade()
{
   if(!g_displacement.isValid) return false;
   
   g_symbolInfo.RefreshRates();
   
   int    digits = (int)g_symbolInfo.Digits();
   double point  = g_symbolInfo.Point();
   
   //--- Calculate stop loss: sweep wick ± (ATR_StopBuffer × ATR)
   //    The sweep wick IS the invalidation point.
   //    ATR-based cushion adapts to volatility — wider in volatile markets, tighter in quiet ones.
   double slBuffer = ATR_StopBuffer * g_currentATR;
   double price, sl, tp;
   ENUM_ORDER_TYPE orderType;
   
   if(g_displacement.direction == 1)  // BUY
   {
      orderType = ORDER_TYPE_BUY;
      price = g_symbolInfo.Ask();
      sl = NormalizeDouble(g_displacement.sweepWick - slBuffer, digits);
      
      double slDist = price - sl;
      
      // Clamp SL distance
      double minSL = MinStopLoss * point;
      double maxSL = MaxStopLoss * point;
      if(slDist < minSL) sl = NormalizeDouble(price - minSL, digits);
      if(slDist > maxSL) sl = NormalizeDouble(price - maxSL, digits);
      slDist = price - sl;
      
      tp = NormalizeDouble(price + (slDist * RiskRewardRatio), digits);
   }
   else  // SELL
   {
      orderType = ORDER_TYPE_SELL;
      price = g_symbolInfo.Bid();
      sl = NormalizeDouble(g_displacement.sweepWick + slBuffer, digits);
      
      double slDist = sl - price;
      
      double minSL = MinStopLoss * point;
      double maxSL = MaxStopLoss * point;
      if(slDist < minSL) sl = NormalizeDouble(price + minSL, digits);
      if(slDist > maxSL) sl = NormalizeDouble(price + maxSL, digits);
      slDist = sl - price;
      
      tp = NormalizeDouble(price - (slDist * RiskRewardRatio), digits);
   }
   
   //--- Lot size
   double slDistance = MathAbs(price - sl);
   double lots = CalculateLotSize(slDistance);
   
   //--- Build trade comment
   string comment = StringFormat("SDS_%s_%s", 
                                 g_displacement.direction == 1 ? "BUY" : "SELL",
                                 g_displacement.levelType);
   
   //--- Send order
   if(g_trade.PositionOpen(_Symbol, orderType, lots, price, sl, tp, comment))
   {
      if(g_trade.ResultRetcode() == TRADE_RETCODE_DONE || 
         g_trade.ResultRetcode() == TRADE_RETCODE_PLACED)
      {
         double slDist = MathAbs(price - sl);
         PrintFormat("✅ TRADE OPENED: %s %.2f lots | Price: %.5f | SL: %.5f | TP: %.5f | R:R = 1:%.1f",
                    (g_displacement.direction == 1 ? "BUY" : "SELL"),
                    lots, price, sl, tp, RiskRewardRatio);
         PrintFormat("   Level: %.5f (%s) | Sweep wick: %.5f | SL distance: %.1f pips",
                    g_displacement.keyLevel, g_displacement.levelType,
                    g_displacement.sweepWick, slDist / point);
         return true;
      }
   }
   
   PrintFormat("❌ Trade failed | Error: %d | %s", g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
   return false;
}

//+------------------------------------------------------------------+
//| ═══════════════════════════════════════════════════════════════════|
//| SECTION 11: EXIT MANAGEMENT                                       |
//|                                                                    |
//| Three outcomes only: Loss at SL, Breakeven, Profit at TP.         |
//| No trailing. Clean and mechanical.                                 |
//| ═══════════════════════════════════════════════════════════════════|
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Manage open position: SL/TP monitoring + breakeven                |
//+------------------------------------------------------------------+
void ManageOpenPosition()
{
   g_symbolInfo.RefreshRates();
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!g_positionInfo.SelectByIndex(i)) continue;
      if(g_positionInfo.Symbol() != _Symbol) continue;
      if(g_positionInfo.Magic() != EAMagicNumber) continue;
      
      double openPrice = g_positionInfo.PriceOpen();
      double currentSL = g_positionInfo.StopLoss();
      double currentTP = g_positionInfo.TakeProfit();
      double point     = g_symbolInfo.Point();
      int    digits    = (int)g_symbolInfo.Digits();
      
      //--- Calculate initial SL distance for BE trigger
      double slDistance = MathAbs(openPrice - currentSL);
      if(slDistance <= 0) continue;
      
      double beTrigger = BreakevenTrigger_R * slDistance;
      
      //--- P3: Move to breakeven at configured R-multiple
      if(g_positionInfo.PositionType() == POSITION_TYPE_BUY)
      {
         double bid = g_symbolInfo.Bid();
         double profit = bid - openPrice;
         
         // If profit >= BE trigger AND SL is still below entry
         if(profit >= beTrigger && currentSL < openPrice)
         {
            double newSL = NormalizeDouble(openPrice + (10 * point), digits);
            if(g_trade.PositionModify(g_positionInfo.Ticket(), newSL, currentTP))
            {
               PrintFormat("🔒 BREAKEVEN: BUY | Moved SL to %.5f | Profit: %.1f pips",
                          newSL, profit / point);
            }
         }
      }
      else if(g_positionInfo.PositionType() == POSITION_TYPE_SELL)
      {
         double ask = g_symbolInfo.Ask();
         double profit = openPrice - ask;
         
         if(profit >= beTrigger && (currentSL == 0 || currentSL > openPrice))
         {
            double newSL = NormalizeDouble(openPrice - (10 * point), digits);
            if(g_trade.PositionModify(g_positionInfo.Ticket(), newSL, currentTP))
            {
               PrintFormat("🔒 BREAKEVEN: SELL | Moved SL to %.5f | Profit: %.1f pips",
                          newSL, profit / point);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| ═══════════════════════════════════════════════════════════════════|
//| SECTION 12: DAILY LIMIT & POSITION HELPERS                       |
//| ═══════════════════════════════════════════════════════════════════|
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Check if new trading day → reset counters                         |
//+------------------------------------------------------------------+
void CheckDailyReset()
{
   datetime currentDayStart = iTime(_Symbol, PERIOD_D1, 0);
   
   if(currentDayStart != g_lastDayBar)
   {
      if(g_tradesOpenedToday > 0)
      {
         PrintFormat("📊 DAILY SUMMARY: %d trade(s) on %s",
                    g_tradesOpenedToday, TimeToString(g_lastDayBar, TIME_DATE));
      }
      
      g_tradesOpenedToday  = 0;
      g_tradingLockedToday = false;
      g_lastDayBar = currentDayStart;
      
      // Reset state if no position open
      if(!HasOpenPosition())
      {
         g_state = STATE_SCANNING;
         g_displacement.Reset();
      }
      
      // Refresh daily levels and key levels
      g_daily = GetDailyLevels();
      g_currentATR = GetATRValue();
      g_zoneWidth = g_currentATR * ZoneMultiplier;
      g_keyLevels = CalculateKeyLevels();
      
      Print("════════════════════════════════════════");
      PrintFormat("🌅 NEW DAY: %s", TimeToString(currentDayStart, TIME_DATE));
      if(g_daily.isValid)
         PrintFormat("   PDH: %.5f | PDL: %.5f | ATR: %.5f", g_daily.pdh, g_daily.pdl, g_currentATR);
      if(g_keyLevels.isValid)
         PrintFormat("   Resistance: %.5f (%s) | Support: %.5f (%s)",
                    g_keyLevels.resistance, g_keyLevels.resistanceType,
                    g_keyLevels.support, g_keyLevels.supportType);
      Print("════════════════════════════════════════");
   }
}

//+------------------------------------------------------------------+
//| Record that a trade was opened today                              |
//+------------------------------------------------------------------+
void RecordTradeOpened()
{
   g_tradesOpenedToday++;
   if(g_tradesOpenedToday >= MaxTradesPerDay)
      g_tradingLockedToday = true;
   
   Print("════════════════════════════════════════");
   PrintFormat("🔒 DAILY LIMIT REACHED (%d/%d) — NO MORE TRADES TODAY", g_tradesOpenedToday, MaxTradesPerDay);
   Print("════════════════════════════════════════");
}

//+------------------------------------------------------------------+
//| Check if EA has an open position (by magic number)                |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(g_positionInfo.SelectByIndex(i))
      {
         if(g_positionInfo.Symbol() == _Symbol && g_positionInfo.Magic() == EAMagicNumber)
            return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| ═══════════════════════════════════════════════════════════════════|
//| SECTION 13: CHART OBJECTS                                         |
//| ═══════════════════════════════════════════════════════════════════|
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Draw key levels and S/D zones on chart                            |
//+------------------------------------------------------------------+
void DrawObjects()
{
   if(!g_keyLevels.isValid) return;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   //--- Key levels: colored dashed lines with visible price labels
   if(DrawLevels)
   {
      // Resistance level
      if(g_keyLevels.resistance > 0)
      {
         string name = "SDS_Level_Resistance";
         ObjectDelete(0, name);
         if(ObjectCreate(0, name, OBJ_HLINE, 0, 0, g_keyLevels.resistance))
         {
            ObjectSetInteger(0, name, OBJPROP_COLOR, ResistanceColor);
            ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
            ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
            ObjectSetInteger(0, name, OBJPROP_BACK, true);
            ObjectSetString(0, name, OBJPROP_TOOLTIP,
                           StringFormat("Resistance: %s @ %.*f", g_keyLevels.resistanceType, digits, g_keyLevels.resistance));
         }

         // Visible text label anchored to the line
         string labelName = "SDS_Label_Resistance";
         ObjectDelete(0, labelName);
         datetime labelTime = iTime(_Symbol, PERIOD_H1, 5);
         if(ObjectCreate(0, labelName, OBJ_TEXT, 0, labelTime, g_keyLevels.resistance))
         {
            ObjectSetString(0, labelName, OBJPROP_TEXT,
                           StringFormat("  %s  %.*f", g_keyLevels.resistanceType, digits, g_keyLevels.resistance));
            ObjectSetInteger(0, labelName, OBJPROP_COLOR, ResistanceColor);
            ObjectSetString(0, labelName, OBJPROP_FONT, "Arial Bold");
            ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 9);
            ObjectSetInteger(0, labelName, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
            ObjectSetInteger(0, labelName, OBJPROP_BACK, false);
            ObjectSetInteger(0, labelName, OBJPROP_SELECTABLE, false);
         }
      }

      // Support level
      if(g_keyLevels.support > 0)
      {
         string name = "SDS_Level_Support";
         ObjectDelete(0, name);
         if(ObjectCreate(0, name, OBJ_HLINE, 0, 0, g_keyLevels.support))
         {
            ObjectSetInteger(0, name, OBJPROP_COLOR, SupportColor);
            ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
            ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
            ObjectSetInteger(0, name, OBJPROP_BACK, true);
            ObjectSetString(0, name, OBJPROP_TOOLTIP,
                           StringFormat("Support: %s @ %.*f", g_keyLevels.supportType, digits, g_keyLevels.support));
         }

         // Visible text label anchored to the line
         string labelName = "SDS_Label_Support";
         ObjectDelete(0, labelName);
         datetime labelTime = iTime(_Symbol, PERIOD_H1, 5);
         if(ObjectCreate(0, labelName, OBJ_TEXT, 0, labelTime, g_keyLevels.support))
         {
            ObjectSetString(0, labelName, OBJPROP_TEXT,
                           StringFormat("  %s  %.*f", g_keyLevels.supportType, digits, g_keyLevels.support));
            ObjectSetInteger(0, labelName, OBJPROP_COLOR, SupportColor);
            ObjectSetString(0, labelName, OBJPROP_FONT, "Arial Bold");
            ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 9);
            ObjectSetInteger(0, labelName, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
            ObjectSetInteger(0, labelName, OBJPROP_BACK, false);
            ObjectSetInteger(0, labelName, OBJPROP_SELECTABLE, false);
         }
      }
   }

   //--- S/D Zones: colored filled rectangles with labels
   if(DrawZones && g_zoneWidth > 0)
   {
      datetime startTime = iTime(_Symbol, PERIOD_H1, 20);
      datetime endTime   = startTime + PeriodSeconds(PERIOD_H1) * 40;

      // Supply zone (at resistance)
      if(g_keyLevels.resistance > 0)
      {
         string name = "SDS_Zone_Supply";
         ObjectDelete(0, name);
         double top = g_keyLevels.resistance + g_zoneWidth;
         double bot = g_keyLevels.resistance - g_zoneWidth;
         if(ObjectCreate(0, name, OBJ_RECTANGLE, 0, startTime, top, endTime, bot))
         {
            ObjectSetInteger(0, name, OBJPROP_COLOR, ResistanceColor);
            ObjectSetInteger(0, name, OBJPROP_FILL, true);
            ObjectSetInteger(0, name, OBJPROP_BACK, true);
            ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
            ObjectSetString(0, name, OBJPROP_TOOLTIP, "Supply Zone");
         }

         // Zone label
         string labelName = "SDS_Label_SupplyZone";
         ObjectDelete(0, labelName);
         if(ObjectCreate(0, labelName, OBJ_TEXT, 0, startTime, top))
         {
            ObjectSetString(0, labelName, OBJPROP_TEXT, "  SUPPLY ZONE");
            ObjectSetInteger(0, labelName, OBJPROP_COLOR, ResistanceColor);
            ObjectSetString(0, labelName, OBJPROP_FONT, "Arial Bold");
            ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 8);
            ObjectSetInteger(0, labelName, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
            ObjectSetInteger(0, labelName, OBJPROP_BACK, false);
            ObjectSetInteger(0, labelName, OBJPROP_SELECTABLE, false);
         }
      }

      // Demand zone (at support)
      if(g_keyLevels.support > 0)
      {
         string name = "SDS_Zone_Demand";
         ObjectDelete(0, name);
         double top = g_keyLevels.support + g_zoneWidth;
         double bot = g_keyLevels.support - g_zoneWidth;
         if(ObjectCreate(0, name, OBJ_RECTANGLE, 0, startTime, top, endTime, bot))
         {
            ObjectSetInteger(0, name, OBJPROP_COLOR, SupportColor);
            ObjectSetInteger(0, name, OBJPROP_FILL, true);
            ObjectSetInteger(0, name, OBJPROP_BACK, true);
            ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
            ObjectSetString(0, name, OBJPROP_TOOLTIP, "Demand Zone");
         }

         // Zone label
         string labelName = "SDS_Label_DemandZone";
         ObjectDelete(0, labelName);
         if(ObjectCreate(0, labelName, OBJ_TEXT, 0, startTime, bot))
         {
            ObjectSetString(0, labelName, OBJPROP_TEXT, "  DEMAND ZONE");
            ObjectSetInteger(0, labelName, OBJPROP_COLOR, SupportColor);
            ObjectSetString(0, labelName, OBJPROP_FONT, "Arial Bold");
            ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 8);
            ObjectSetInteger(0, labelName, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
            ObjectSetInteger(0, labelName, OBJPROP_BACK, false);
            ObjectSetInteger(0, labelName, OBJPROP_SELECTABLE, false);
         }
      }
   }

   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Remove all EA chart objects                                       |
//+------------------------------------------------------------------+
void CleanupObjects()
{
   //--- Delete all objects with SDS_ prefix
   int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--)
   {
      string objName = ObjectName(0, i);
      if(StringFind(objName, "SDS_") == 0)
         ObjectDelete(0, objName);
   }
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| ═══════════════════════════════════════════════════════════════════|
//| SECTION 14: NEW BAR DETECTION                                     |
//| ═══════════════════════════════════════════════════════════════════|
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Check if a new bar formed on the setup timeframe (H1)             |
//+------------------------------------------------------------------+
bool IsNewSetupBar()
{
   datetime barTime = iTime(_Symbol, SetupTimeframe, 0);
   if(barTime != g_lastH1Bar)
   {
      g_lastH1Bar = barTime;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check if a new bar formed on the entry timeframe (M5)             |
//+------------------------------------------------------------------+
bool IsNewEntryBar()
{
   datetime barTime = iTime(_Symbol, EntryTimeframe, 0);
   if(barTime != g_lastM5Bar)
   {
      g_lastM5Bar = barTime;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Detect fill type supported by broker                              |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFillType()
{
   long fillMode = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fillMode & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
   if((fillMode & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
   return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| ═══════════════════════════════════════════════════════════════════|
//| SECTION 15: OnInit / OnDeinit / OnTick                            |
//| ═══════════════════════════════════════════════════════════════════|
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Dashboard: Rounded rectangle fill helper                          |
//+------------------------------------------------------------------+
void DashFillRoundedRect(CCanvas &canvas, int x, int y, int w, int h, int r, uint clr)
{
   canvas.FillRectangle(x+r, y, x+w-r, y+h, clr);
   canvas.FillRectangle(x, y+r, x+r, y+h-r, clr);
   canvas.FillRectangle(x+w-r, y+r, x+w, y+h-r, clr);
   canvas.FillCircle(x+r, y+r, r, clr);
   canvas.FillCircle(x+w-r-1, y+r, r, clr);
   canvas.FillCircle(x+r, y+h-r-1, r, clr);
   canvas.FillCircle(x+w-r-1, y+h-r-1, r, clr);
}

//+------------------------------------------------------------------+
//| Dashboard: Create a text label                                     |
//+------------------------------------------------------------------+
void DashCreateLabel(string name, int x, int y, string text, color clr, int fontSize=10, string font="Consolas")
{
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, font);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 10);
}

//+------------------------------------------------------------------+
//| Dashboard: Create panel and static labels                          |
//+------------------------------------------------------------------+
void CreateDashboard()
{
   int w = SDS_DASH_W, h = SDS_DASH_H;

   g_dashCanvas.CreateBitmapLabel(0, 0, SDS_DASH_PREFIX+"PANEL", SDS_DASH_X, SDS_DASH_Y, w, h, COLOR_FORMAT_ARGB_NORMALIZE);
   ObjectSetInteger(0, SDS_DASH_PREFIX+"PANEL", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, SDS_DASH_PREFIX+"PANEL", OBJPROP_CORNER, CORNER_LEFT_UPPER);

   DashFillRoundedRect(g_dashCanvas, 0, 0, w, h, SDS_DASH_R, ColorToARGB(CLR_PANEL_BORDER, 255));
   DashFillRoundedRect(g_dashCanvas, 2, 2, w-4, h-4, SDS_DASH_R-2, ColorToARGB(CLR_PANEL_BG, 240));
   g_dashCanvas.Update();

   int lx = SDS_DASH_X + 16;
   int vy = SDS_DASH_Y + 12;
   int lineH = 22;

   //--- Symbol
   DashCreateLabel(SDS_DASH_PREFIX+"LBL_SYM",    lx, vy,              "Symbol:", CLR_DASH_TEXT);
   DashCreateLabel(SDS_DASH_PREFIX+"VAL_SYM",     lx+100, vy,         _Symbol,  CLR_DASH_VALUE);
   vy += lineH;

   //--- Trade
   DashCreateLabel(SDS_DASH_PREFIX+"LBL_TRADE",   lx, vy,             "Trade:",  CLR_DASH_TEXT);
   DashCreateLabel(SDS_DASH_PREFIX+"VAL_TRADE",    lx+100, vy,        "None",    CLR_DASH_VALUE);
   vy += lineH;

   //--- P&L
   DashCreateLabel(SDS_DASH_PREFIX+"LBL_PNL",     lx, vy,             "P&L:",    CLR_DASH_TEXT);
   DashCreateLabel(SDS_DASH_PREFIX+"VAL_PNL",      lx+100, vy,        "$0.00",   CLR_DASH_VALUE);

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Dashboard: Update dynamic values every tick                        |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
   string tradeStr = "None";
   string pnlStr   = "$0.00";
   color  pnlClr   = CLR_DASH_VALUE;
   color  tradeClr = CLR_DASH_VALUE;

   if(HasOpenPosition())
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(g_positionInfo.SelectByIndex(i) && g_positionInfo.Magic() == EAMagicNumber && g_positionInfo.Symbol() == _Symbol)
         {
            string dir = (g_positionInfo.PositionType() == POSITION_TYPE_BUY) ? "BUY" : "SELL";
            double vol = g_positionInfo.Volume();
            double profit = g_positionInfo.Profit() + g_positionInfo.Swap();
            tradeStr = StringFormat("%s %.2f", dir, vol);
            tradeClr = (g_positionInfo.PositionType() == POSITION_TYPE_BUY) ? CLR_DASH_GREEN : CLR_DASH_RED;
            pnlStr = StringFormat("$%.2f", profit);
            pnlClr = (profit >= 0) ? CLR_DASH_GREEN : CLR_DASH_RED;
            break;
         }
      }
   }

   ObjectSetString(0, SDS_DASH_PREFIX+"VAL_TRADE", OBJPROP_TEXT, tradeStr);
   ObjectSetInteger(0, SDS_DASH_PREFIX+"VAL_TRADE", OBJPROP_COLOR, tradeClr);
   ObjectSetString(0, SDS_DASH_PREFIX+"VAL_PNL", OBJPROP_TEXT, pnlStr);
   ObjectSetInteger(0, SDS_DASH_PREFIX+"VAL_PNL", OBJPROP_COLOR, pnlClr);
}

//+------------------------------------------------------------------+
//| Dashboard: Delete all dashboard objects                            |
//+------------------------------------------------------------------+
void DeleteDashboard()
{
   g_dashCanvas.Destroy();
   int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(StringFind(name, SDS_DASH_PREFIX) == 0)
         ObjectDelete(0, name);
   }
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Symbol info
   if(!g_symbolInfo.Name(_Symbol))
   {
      Print("❌ Failed to select symbol: ", _Symbol);
      return INIT_FAILED;
   }
   
   //--- Trade settings
   g_trade.SetExpertMagicNumber(EAMagicNumber);
   g_trade.SetDeviationInPoints(10);
   g_trade.SetTypeFilling(GetFillType());
   
   //--- ATR handle
   g_atrHandle = iATR(_Symbol, ATRTimeframe, ATR_Period);
   if(g_atrHandle == INVALID_HANDLE)
   {
      Print("❌ Failed to create ATR handle");
      return INIT_FAILED;
   }
   
   //--- ADX handle
   if(UseADXFilter)
   {
      g_adxHandle = iADX(_Symbol, ADXTimeframe, ADXPeriod);
      if(g_adxHandle == INVALID_HANDLE)
      {
         Print("❌ Failed to create ADX handle — cannot trade with ADX filter enabled");
         return INIT_FAILED;
      }
   }
   
   //--- Initialize state
   g_state = STATE_SCANNING;
   g_displacement.Reset();
   g_tradesOpenedToday  = 0;
   g_tradingLockedToday = false;
   g_lastDayBar = iTime(_Symbol, PERIOD_D1, 0);
   g_lastH1Bar  = 0;
   g_lastM5Bar  = 0;
   g_bosBarCount = 0;
   g_bosSwingLevel = 0;
   g_bosPullbackStarted = false;

   //--- Load initial levels
   g_daily = GetDailyLevels();
   g_currentATR = GetATRValue();
   g_zoneWidth = g_currentATR * ZoneMultiplier;
   g_keyLevels = CalculateKeyLevels();
   
   //--- Check if EA already has an open position (restart/recompile scenario)
   if(HasOpenPosition())
   {
      g_state = STATE_TRADE_OPEN;
      g_tradingLockedToday = true;
      g_tradesOpenedToday = 1;
      Print("⚠️ Existing position detected — resuming trade management");
   }
   
   //--- Draw initial objects
   DrawObjects();

   //--- Dashboard
   CreateDashboard();
   
   //--- Startup log
   Print("════════════════════════════════════════");
   Print("  SD Sniper EA v2.0 — INITIALIZED");
   Print("════════════════════════════════════════");
   PrintFormat("  Symbol:     %s", _Symbol);
   PrintFormat("  Magic:      %d", EAMagicNumber);
   PrintFormat("  Setup TF:   %s (displacement)", EnumToString(SetupTimeframe));
   PrintFormat("  Entry TF:   %s (BOS)", EnumToString(EntryTimeframe));
   PrintFormat("  Levels TF:  %s (PDH/PDL source)", EnumToString(LevelsTimeframe));
   PrintFormat("  Sniper:     %s", UseSniperEntry ? "M5 BOS" : "H1 direct");
   PrintFormat("  Risk:       %.2f%% | R:R = 1:%.1f", RiskPercent, RiskRewardRatio);
   PrintFormat("  SL Buffer:  %.2f × ATR beyond sweep wick", ATR_StopBuffer);
   PrintFormat("  BOS Timeout: %d bars (%d min)", BOS_Timeout, BOS_Timeout * PeriodSeconds(EntryTimeframe) / 60);
   PrintFormat("  Max Spread: %.1f pips", MaxSpread);
   PrintFormat("  ADX Filter: %s (≥%.0f on %s)", UseADXFilter ? "ON" : "OFF", MinADX, EnumToString(ADXTimeframe));
   PrintFormat("  News Filter: %s", UseNewsFilter ? "ON" : "OFF");
   PrintFormat("  Window:     %02d:%02d – %02d:%02d", StartHour, StartMinute, EndHour, EndMinute);
   Print("  ⛔ STRICT: 1 TRADE PER DAY MAXIMUM");
   Print("════════════════════════════════════════");
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   if(g_adxHandle != INVALID_HANDLE) IndicatorRelease(g_adxHandle);

   DeleteDashboard();
   CleanupObjects();
   
   Print("SD Sniper EA deinitialized");
}

//+------------------------------------------------------------------+
//| ═══════════════════════════════════════════════════════════════════|
//| OnTick — STATE MACHINE                                            |
//|                                                                    |
//| STATE_SCANNING      → watch for H1 displacement                   |
//| STATE_WAITING_BOS   → watch for M5 break of structure              |
//| STATE_TRADE_OPEN    → manage exits (SL/TP/BE)                     |
//| STATE_DAILY_LOCKED  → done for today, manage if position still on  |
//| ═══════════════════════════════════════════════════════════════════|
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Always: check for new day, update news
   CheckDailyReset();
   CheckNewsImpact();

   //--- Update dashboard
   UpdateDashboard();
   
   //--- Route to current state handler
   switch(g_state)
   {
      case STATE_DAILY_LOCKED:
         //--- Only manage existing position if one is still open
         if(HasOpenPosition())
            ManageOpenPosition();
         break;
         
      case STATE_TRADE_OPEN:
         //--- Manage exits every tick
         if(HasOpenPosition())
         {
            ManageOpenPosition();
         }
         else
         {
            //--- Position was closed (SL/TP/BE hit by broker or manually)
            PrintFormat("📊 TRADE CLOSED");
            g_state = STATE_DAILY_LOCKED;
         }
         break;
         
      case STATE_WAITING_BOS:
         OnStateWaitingBOS();
         break;
         
      default:  // STATE_SCANNING
         OnStateScanning();
         break;
   }
}

//+------------------------------------------------------------------+
//| STATE_SCANNING: Watch for H1 displacement at key levels           |
//+------------------------------------------------------------------+
void OnStateScanning()
{
   //--- Only analyze on new H1 bar close (not every tick)
   if(!IsNewSetupBar()) return;
   
   //--- Refresh levels and ATR each H1 bar
   g_daily = GetDailyLevels();
   g_currentATR = GetATRValue();
   g_zoneWidth = g_currentATR * ZoneMultiplier;
   g_keyLevels = CalculateKeyLevels();
   DrawObjects();
   
   if(!g_keyLevels.isValid || g_currentATR <= 0) return;
   
   //--- Pre-filter: can we even trade today?
   if(g_tradingLockedToday || g_tradesOpenedToday >= MaxTradesPerDay) return;
   if(!IsWithinTradingHours()) return;
   if(g_newsActive) return;
   
   //--- ═══════════════════════════════════════════
   //    THE CORE CHECK: Did the last H1 bar displace from a key level?
   //    ═══════════════════════════════════════════
   DisplacementSetup setup = DetectDisplacement();
   
   if(!setup.isValid) return;
   
   //--- Displacement confirmed! Store it.
   g_displacement = setup;
   
   if(UseSniperEntry)
   {
      //--- Switch to M5 BOS scanning
      g_state = STATE_WAITING_BOS;
      g_bosBarCount = 0;
      g_bosSwingLevel = 0;
      g_bosPullbackStarted = false;
      g_lastM5Bar = 0;  // Reset M5 tracking to catch next bar
      
      PrintFormat("⏳ Waiting for M5 BOS... (timeout: %d bars / %d min)",
                 BOS_Timeout, BOS_Timeout * PeriodSeconds(EntryTimeframe) / 60);
   }
   else
   {
      //--- Fallback: enter directly on H1 displacement close
      PrintFormat("📍 Direct entry mode (sniper disabled)");
      
      if(IsTradingAllowed())
      {
         if(ExecuteTrade())
         {
            g_state = STATE_TRADE_OPEN;
            RecordTradeOpened();
         }
      }
   }
}

//+------------------------------------------------------------------+
//| STATE_WAITING_BOS: Watch M5 for break of structure                |
//+------------------------------------------------------------------+
void OnStateWaitingBOS()
{
   //--- Only check on new M5 bar close
   if(!IsNewEntryBar()) return;
   
   g_bosBarCount++;
   
   //--- Timeout check: if no BOS within limit, cancel setup
   if(g_bosBarCount > BOS_Timeout)
   {
      PrintFormat("⏰ BOS TIMEOUT after %d M5 bars — setup expired", g_bosBarCount);
      g_displacement.Reset();
      g_state = STATE_SCANNING;
      return;
   }
   
   //--- Check filters before even looking for BOS
   if(!IsWithinTradingHours() || g_newsActive)
   {
      PrintFormat("⏳ BOS scan paused (filter) — bar %d/%d", g_bosBarCount, BOS_Timeout);
      return;
   }
   
   //--- ═══════════════════════════════════════════
   //    THE SNIPER CHECK: Did M5 just break structure?
   //    ═══════════════════════════════════════════
   if(CheckBOS())
   {
      //--- BOS confirmed! Run remaining filters and execute
      if(IsTradingAllowed())
      {
         if(ExecuteTrade())
         {
            g_state = STATE_TRADE_OPEN;
            RecordTradeOpened();
         }
         else
         {
            //--- Trade execution failed (broker error etc.) — don't retry, lock day
            PrintFormat("❌ Trade execution failed after BOS — locking day");
            g_displacement.Reset();
            g_state = STATE_DAILY_LOCKED;
            g_tradingLockedToday = true;
         }
      }
      else
      {
         //--- Filters rejected at entry moment — setup is burned
         PrintFormat("❌ Filters rejected at BOS entry — setup expired");
         g_displacement.Reset();
         g_state = STATE_SCANNING;
      }
   }
}

//+------------------------------------------------------------------+
