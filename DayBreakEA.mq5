//+------------------------------------------------------------------+
//|                                               DayBreakEA.mq5      |
//|                     PDH/PDL Session Breakout System               |
//|                                                                    |
//|  Trades the current chart symbol.                                  |
//|  Enters on M15 body-conviction breaks of Previous Day High/Low    |
//|  during a configurable session window (default 07:00–15:30 GMT).  |
//|  Exits via failed-break detection, RRR management, or a hard      |
//|  time stop from entry.                                             |
//+------------------------------------------------------------------+
#property copyright   "DayBreak EA"
#property version     "1.02"
#property description "PDH/PDL Session Breakout — Price Action | No Indicators"

#include <Trade\Trade.mqh>
#include <Canvas\Canvas.mqh>

//──────────────────────────────────────────────────────────────────────
//  OBJECT PREFIX & COLOURS
//──────────────────────────────────────────────────────────────────────
#define DB_PREFIX    "DB_"
#define CLR_GOLD     C'218,165,32'   // warm gold
#define CLR_DKGREY   C'45,45,45'     // dark grey panel background

#define DASH_X   13
#define DASH_Y   380
#define DASH_W   420
#define DASH_H   170
#define DASH_R   12

CCanvas  g_DashCanvas;

//──────────────────────────────────────────────────────────────────────
//  INPUT PARAMETERS
//──────────────────────────────────────────────────────────────────────

input group "── TIMEFRAME ──────────────────────────────────────────────"
input ENUM_TIMEFRAMES  InpTimeframe      = PERIOD_H1;  // Signal Timeframe

input group "── SESSION WINDOW (GMT) ────────────────────────────────────"
input int              InpStartTime      = 700;          // Session Start (HHMM, e.g. 700 = 07:00)
input int              InpEndTime        = 1530;         // Session End   (HHMM, e.g. 1530 = 15:30)

input group "── ENTRY FILTERS ──────────────────────────────────────────"
input double           InpBodyRatio      = 0.65;         // Body Dominance Ratio  (0.0–1.0)
input double           InpMaxSpread      = 4.5;          // Max Spread Filter     (pips)

input group "── STOP LOSS ──────────────────────────────────────────────"
input int              InpATR_Period     = 14;           // ATR Period
input double           InpATR_Buffer     = 0.45;         // ATR Stop Buffer Multiplier

input group "── EXIT ────────────────────────────────────────────────────"
// P3 ADJUSTMENT: Breakeven trigger moved to 1.0R (strategy default 1.5R).
// Locking in risk-free status earlier reduces drawdown on trades that
// briefly push into profit before reversing. Trade-off: some runners
// that dip back to 1R before continuing will exit at breakeven instead
// of being stopped for a loss.
input double           InpBE_R           = 1.00;         // Breakeven Trigger     (R multiple)

input double           InpPartial_R      = 1.50;         // Partial close trigger  (R multiple) — closes 50%
input double           InpTrail_R        = 3.00;         // Full close trigger    (R multiple) — closes remainder
input int              InpTimeStopHours  = 6;            // Time Stop             (hours from entry) — extended for room to run

input group "── RISK & IDENTITY ────────────────────────────────────────"
input double           InpRiskPct        = 0.50;         // Risk Per Trade        (% of equity)
input ulong            InpMagic          = 20240101;     // Magic Number

input group "── PROTECTION ─────────────────────────────────────────────────"
// IMPROVEMENT [A]: Daily drawdown cap — prevents cascading same-day losses.
// A non-zero value halts new entries once daily equity loss hits the cap.
input double           InpDailyDDLimit   = 2.00;         // Daily DD Cap          (% of day-start equity, 0 = disabled)

// IMPROVEMENT [B]: One-trade-per-day rule.
// When enabled the EA takes at most one trade per calendar day regardless
// of how that trade exits (time stop, breakeven, P1, or P4). The flag is
// reconstructed from closed deal history + open positions on every EA
// initialisation so it survives parameter changes and chart reloads.
input bool             InpOneTradPerDay  = true;          // One Trade Per Day     (true = max 1 entry per calendar day)

input group "── JOURNAL ─────────────────────────────────────────────────"
input bool             InpJournalEnabled = true;          // Enable trade journal
input string           InpSheetURL       = "";            // Google Apps Script Web App URL

//──────────────────────────────────────────────────────────────────────
//  GLOBAL STATE
//──────────────────────────────────────────────────────────────────────

CTrade   trade;

int      g_ATR          = INVALID_HANDLE; // ATR indicator handle

// Previous Day High / Low
double   g_PDH          = 0.0;
double   g_PDL          = 0.0;
datetime g_LastD1Bar    = 0;

// Bar tracking — new-bar gate used in ManageExit (P1) and CheckEntry
datetime g_LastBar      = 0;

// Open position state
datetime g_EntryTime    = 0;
double   g_EntryPrice   = 0.0;
double   g_InitialSL    = 0.0;
double   g_InitialRisk  = 0.0;
double   g_EntrySpread  = 0.0;     // spread captured at entry
string   g_EntrySession = "";      // session name captured at entry
bool     g_BE_Done      = false;
bool     g_PartialDone  = false;
bool     g_Trail_Done   = false;
int      g_P1_Count     = 0;       // consecutive bars closed back inside PDH/PDL (P1 needs 2)

// Session & failed-break tracking
int      g_SessionID    = 0;     // 0 = outside session | 1 = inside session
bool     g_BullFailed   = false; // true = PDH side consumed this session — no re-entry
bool     g_BearFailed   = false; // true = PDL side consumed this session — no re-entry

// IMPROVEMENT [B]: Daily trade limit state
// Reconstructed from reality on every OnInit() — never blindly reset.
// Only reset to false in RefreshPDHL() on a genuine new calendar day.
bool     g_TradedToday  = false; // true = a trade was taken today — no further entries

// IMPROVEMENT [A]: Daily drawdown protection state
double   g_DayStartEquity = 0.0;  // equity captured at start of each new day
bool     g_DayBlocked     = false; // true = daily DD cap hit — no new entries today

//──────────────────────────────────────────────────────────────────────
//  HELPER: FILLING MODE DETECTION
//  Queries the symbol for its supported order filling types.
//  Ensures compatibility across brokers and in the Strategy Tester.
//  Declared before OnInit so it is visible at call time.
//──────────────────────────────────────────────────────────────────────

ENUM_ORDER_TYPE_FILLING DetectFillingMode()
{
    uint modes = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
    if((modes & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
    if((modes & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
    return ORDER_FILLING_RETURN;
}

//──────────────────────────────────────────────────────────────────────
//  HELPER: POSITION DETECTION
//  Loops all open positions filtering by _Symbol AND InpMagic.
//  This is the only reliable method on both netting and hedging accounts.
//  PositionSelect(_Symbol) picks the first position on the symbol
//  regardless of magic number — unsafe on shared accounts.
//  Loop runs in reverse so stale indices from recently closed positions
//  do not cause skips.
//──────────────────────────────────────────────────────────────────────

ulong GetPositionTicket()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong t = PositionGetTicket(i); // selects position as a side effect
        if(t == 0) continue;
        if(PositionGetString(POSITION_SYMBOL)  != _Symbol)        continue;
        if(PositionGetInteger(POSITION_MAGIC)  != (long)InpMagic) continue;
        return t;
    }
    return 0;
}

bool HasPosition()
{
    return GetPositionTicket() != 0;
}

//──────────────────────────────────────────────────────────────────────
//  DRAWING: PDH / PDL horizontal lines (warm gold, dashed)
//──────────────────────────────────────────────────────────────────────

void DrawPDHPDL()
{
    string namePDH = DB_PREFIX + "PDH";
    string namePDL = DB_PREFIX + "PDL";
    string lblPDH  = DB_PREFIX + "PDH_LBL";
    string lblPDL  = DB_PREFIX + "PDL_LBL";

    ObjectDelete(0, namePDH);
    ObjectDelete(0, namePDL);
    ObjectDelete(0, lblPDH);
    ObjectDelete(0, lblPDL);

    if(g_PDH == 0.0 || g_PDL == 0.0) return;

    // PDH line
    ObjectCreate(0, namePDH, OBJ_HLINE, 0, 0, g_PDH);
    ObjectSetInteger(0, namePDH, OBJPROP_COLOR, CLR_GOLD);
    ObjectSetInteger(0, namePDH, OBJPROP_STYLE, STYLE_DASH);
    ObjectSetInteger(0, namePDH, OBJPROP_WIDTH, 1);
    ObjectSetInteger(0, namePDH, OBJPROP_BACK, true);
    ObjectSetInteger(0, namePDH, OBJPROP_SELECTABLE, false);

    // PDL line
    ObjectCreate(0, namePDL, OBJ_HLINE, 0, 0, g_PDL);
    ObjectSetInteger(0, namePDL, OBJPROP_COLOR, CLR_GOLD);
    ObjectSetInteger(0, namePDL, OBJPROP_STYLE, STYLE_DASH);
    ObjectSetInteger(0, namePDL, OBJPROP_WIDTH, 1);
    ObjectSetInteger(0, namePDL, OBJPROP_BACK, true);
    ObjectSetInteger(0, namePDL, OBJPROP_SELECTABLE, false);

    // PDH text label anchored at start of today
    datetime tDay = iTime(_Symbol, PERIOD_D1, 0);
    ObjectCreate(0, lblPDH, OBJ_TEXT, 0, tDay, g_PDH);
    ObjectSetString(0, lblPDH, OBJPROP_TEXT, "  PDH");
    ObjectSetInteger(0, lblPDH, OBJPROP_COLOR, CLR_GOLD);
    ObjectSetString(0, lblPDH, OBJPROP_FONT, "Consolas");
    ObjectSetInteger(0, lblPDH, OBJPROP_FONTSIZE, 8);
    ObjectSetInteger(0, lblPDH, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
    ObjectSetInteger(0, lblPDH, OBJPROP_SELECTABLE, false);

    // PDL text label
    ObjectCreate(0, lblPDL, OBJ_TEXT, 0, tDay, g_PDL);
    ObjectSetString(0, lblPDL, OBJPROP_TEXT, "  PDL");
    ObjectSetInteger(0, lblPDL, OBJPROP_COLOR, CLR_GOLD);
    ObjectSetString(0, lblPDL, OBJPROP_FONT, "Consolas");
    ObjectSetInteger(0, lblPDL, OBJPROP_FONTSIZE, 8);
    ObjectSetInteger(0, lblPDL, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
    ObjectSetInteger(0, lblPDL, OBJPROP_SELECTABLE, false);

    ChartRedraw(0);
}

//──────────────────────────────────────────────────────────────────────
//  DRAWING: TimeStop vertical line (red dashed)
//──────────────────────────────────────────────────────────────────────

void DrawTimeStopLine()
{
    string name = DB_PREFIX + "TimeStop_" + IntegerToString((long)g_EntryTime);
    datetime stopTime = g_EntryTime + (datetime)(InpTimeStopHours * 3600);

    ObjectDelete(0, name);
    ObjectCreate(0, name, OBJ_VLINE, 0, stopTime, 0);
    ObjectSetInteger(0, name, OBJPROP_COLOR, clrRed);
    ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
    ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
    ObjectSetInteger(0, name, OBJPROP_BACK, true);
    ObjectSetString(0, name, OBJPROP_TEXT, "TimeStop");
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
    ChartRedraw(0);
}

//──────────────────────────────────────────────────────────────────────
//  DRAWING: Breakout candle marker (warm gold dot)
//──────────────────────────────────────────────────────────────────────

void DrawBreakoutDot(datetime time, double price)
{
    string name = DB_PREFIX + "BKOUT_" + IntegerToString((long)time);
    ObjectDelete(0, name);

    ObjectCreate(0, name, OBJ_ARROW, 0, time, price);
    ObjectSetInteger(0, name, OBJPROP_ARROWCODE, 159); // filled circle
    ObjectSetInteger(0, name, OBJPROP_COLOR, CLR_GOLD);
    ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
    ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_CENTER);
    ObjectSetInteger(0, name, OBJPROP_BACK, false);
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
    ObjectSetString(0, name, OBJPROP_TEXT, "Breakout Signal");
    ChartRedraw(0);
}

//──────────────────────────────────────────────────────────────────────
//  DASHBOARD: Rounded-corner panel via CCanvas, below one-click buttons
//──────────────────────────────────────────────────────────────────────

void FillRoundedRect(CCanvas &canvas, int x, int y, int w, int h, int r, uint clr)
{
    canvas.FillRectangle(x + r, y,     x + w - 1 - r, y + h - 1, clr);
    canvas.FillRectangle(x,     y + r, x + w - 1,     y + h - 1 - r, clr);
    canvas.FillCircle(x + r,         y + r,         r, clr);
    canvas.FillCircle(x + w - 1 - r, y + r,         r, clr);
    canvas.FillCircle(x + r,         y + h - 1 - r, r, clr);
    canvas.FillCircle(x + w - 1 - r, y + h - 1 - r, r, clr);
}

void CreateDashLabel(string name, int x, int y, string text, int fontSize=12)
{
    ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
    ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
    ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
    ObjectSetString(0, name, OBJPROP_TEXT, text);
    ObjectSetInteger(0, name, OBJPROP_COLOR, CLR_GOLD);
    ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
    ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, name, OBJPROP_ZORDER, 10);
}

void CreateDashboard()
{
    string canvasName = DB_PREFIX + "PANEL";
    if(!g_DashCanvas.CreateBitmapLabel(canvasName, DASH_X, DASH_Y, DASH_W, DASH_H, COLOR_FORMAT_ARGB_NORMALIZE))
        return;

    ObjectSetInteger(0, canvasName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(0, canvasName, OBJPROP_SELECTABLE, false);

    g_DashCanvas.Erase(0x00000000);

    uint goldARGB = ColorToARGB(CLR_GOLD, 255);
    uint greyARGB = ColorToARGB(CLR_DKGREY, 245);

    // Outer gold shape (becomes the 2px border)
    FillRoundedRect(g_DashCanvas, 0, 0, DASH_W, DASH_H, DASH_R, goldARGB);
    // Inner grey fill, inset by 2px
    FillRoundedRect(g_DashCanvas, 2, 2, DASH_W - 4, DASH_H - 4, DASH_R - 2, greyARGB);

    g_DashCanvas.Update();

    // Text labels inside the panel
    CreateDashLabel(DB_PREFIX + "LBL_SYM",   DASH_X + 16, DASH_Y + 20, "Symbol: " + _Symbol, 12);
    CreateDashLabel(DB_PREFIX + "LBL_TRADE",  DASH_X + 16, DASH_Y + 75, "Trade: No trade running...", 12);
    CreateDashLabel(DB_PREFIX + "LBL_NPL",    DASH_X + 16, DASH_Y + 130, "NPL: $0.00", 12);

    ChartRedraw(0);
}

void UpdateDashboard()
{
    string tradeText = "No trade running...";
    string nplText   = "$0.00";

    ulong ticket = GetPositionTicket();
    if(ticket != 0 && PositionSelectByTicket(ticket))
    {
        string dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "BUY" : "SELL";
        double vol = PositionGetDouble(POSITION_VOLUME);
        double profit = PositionGetDouble(POSITION_PROFIT);
        tradeText = StringFormat("%s %.2f", dir, vol);
        nplText   = StringFormat("$%.2f", profit);
    }

    ObjectSetString(0, DB_PREFIX + "LBL_TRADE", OBJPROP_TEXT, "Trade: " + tradeText);
    ObjectSetString(0, DB_PREFIX + "LBL_NPL",   OBJPROP_TEXT, "NPL: " + nplText);
}

//──────────────────────────────────────────────────────────────────────
//  CLEANUP: Remove all prefixed objects
//──────────────────────────────────────────────────────────────────────

void DeleteAllDBObjects()
{
    g_DashCanvas.Destroy();
    int total = ObjectsTotal(0);
    for(int i = total - 1; i >= 0; i--)
    {
        string name = ObjectName(0, i);
        if(StringFind(name, DB_PREFIX) == 0)
            ObjectDelete(0, name);
    }
    ChartRedraw(0);
}

//──────────────────────────────────────────────────────────────────────
//  HELPER: RECONSTRUCT g_TradedToday ON INIT
//  Checks two sources of truth in order:
//    1. Running position — if the EA already has a trade open today,
//       the day is spent regardless of when this init runs.
//    2. Closed deal history for today — if a trade opened and closed
//       before this init, the history scan catches it.
//  This makes g_TradedToday survive any restart scenario: live chart
//  reload, parameter tweak, or tester re-run mid-session.
//──────────────────────────────────────────────────────────────────────

void ReconstructTradedToday()
{
    g_TradedToday = false;

    // Source 1: running position belonging to this EA on this symbol
    if(HasPosition())
    {
        g_TradedToday = true;
        Print("DayBreak: [Init] Running position found — g_TradedToday = true");
        return; // no need to scan history
    }

    // Source 2: closed deals today
    // DEAL_ENTRY_IN is the opening leg — one match confirms a trade was taken.
    datetime dayStart = iTime(_Symbol, PERIOD_D1, 0);
    if(dayStart == 0)
    {
        Print("DayBreak: [Init] D1 bar time not available — g_TradedToday left false");
        return;
    }

    if(!HistorySelect(dayStart, TimeCurrent()))
    {
        Print("DayBreak: [Init] HistorySelect failed — g_TradedToday left false");
        return;
    }

    int total = HistoryDealsTotal();
    for(int i = 0; i < total; i++)
    {
        ulong ticket = HistoryDealGetTicket(i);
        if(ticket == 0) continue;
        if(HistoryDealGetString(ticket,  DEAL_SYMBOL)  != _Symbol)        continue;
        if(HistoryDealGetInteger(ticket, DEAL_MAGIC)   != (long)InpMagic) continue;
        if(HistoryDealGetInteger(ticket, DEAL_ENTRY)   != DEAL_ENTRY_IN)  continue;

        g_TradedToday = true;
        PrintFormat("DayBreak: [Init] Deal #%I64u found in today's history — g_TradedToday = true",
                    ticket);
        return; // one match is enough
    }
}

//──────────────────────────────────────────────────────────────────────
//  INIT / DEINIT
//──────────────────────────────────────────────────────────────────────

int OnInit()
{
    //--- Validate inputs
    if(InpBodyRatio <= 0.0 || InpBodyRatio > 1.0)
    {
        Alert("DayBreak: BodyRatio must be between 0.0 and 1.0");
        return INIT_PARAMETERS_INCORRECT;
    }
    if(InpBE_R >= InpTrail_R)
    {
        Alert("DayBreak: BE_R must be strictly less than Trail_R");
        return INIT_PARAMETERS_INCORRECT;
    }
    if(InpStartTime >= InpEndTime)
    {
        Alert("DayBreak: InpStartTime must be earlier than InpEndTime");
        return INIT_PARAMETERS_INCORRECT;
    }
    if(InpRiskPct <= 0.0 || InpRiskPct > 10.0)
    {
        Alert("DayBreak: RiskPct must be between 0.0 and 10.0");
        return INIT_PARAMETERS_INCORRECT;
    }

    //--- ATR handle
    g_ATR = iATR(_Symbol, InpTimeframe, InpATR_Period);
    if(g_ATR == INVALID_HANDLE)
    {
        Alert("DayBreak: Failed to create ATR handle");
        return INIT_FAILED;
    }

    //--- Configure trade object
    trade.SetExpertMagicNumber(InpMagic);
    trade.SetDeviationInPoints(20);
    trade.SetTypeFilling(DetectFillingMode());

    //--- Initialise daily protection state
    // g_DayStartEquity and g_DayBlocked cannot be reconstructed reliably
    // from history so they reset to current values on every init.
    g_DayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    g_DayBlocked     = false;

    //--- Reconstruct g_TradedToday from reality — never blindly reset.
    // IMPROVEMENT [B]: Scans open positions and today's deal history so the
    // one-trade-per-day rule survives chart reloads and parameter changes.
    ReconstructTradedToday();

    //--- Create on-chart dashboard
    CreateDashboard();

    PrintFormat("DayBreak EA ready — %s | TF: %s | Session: %04d–%04d GMT | "
                "OneTradPerDay: %s | TradedToday: %s | Magic: %I64u",
                _Symbol, EnumToString(InpTimeframe), InpStartTime, InpEndTime,
                InpOneTradPerDay ? "ON" : "OFF",
                g_TradedToday    ? "YES" : "NO",
                InpMagic);

    return INIT_SUCCEEDED;
}

//──────────────────────────────────────────────────────────────────────

void OnDeinit(const int reason)
{
    DeleteAllDBObjects();
    if(g_ATR != INVALID_HANDLE)
        IndicatorRelease(g_ATR);
}

//──────────────────────────────────────────────────────────────────────
//  MAIN LOOP
//  Cascade order — cheapest checks first to skip unnecessary logic on
//  non-qualifying ticks.
//
//  Every tick:
//    RefreshPDHL    — O(1) datetime compare, updates PDH/PDL once per day
//    RefreshSession — O(1) integer compare, updates session state
//    HasPosition    — magic+symbol loop, routes to ManageExit if open
//
//  Entry path only (no open position):
//    InpOneTradPerDay + g_TradedToday — plain bool read, cheapest gate
//    IsInSession                       — plain int read
//    IsNewBar                          — iTime() call, only reached after
//                                        all cheaper gates have passed
//    CheckEntry                        — market logic, runs on at most
//                                        one tick per M15 bar
//──────────────────────────────────────────────────────────────────────

void JournalTrade(string exitType, double exitPrice, double pnl)
{
    if(!InpJournalEnabled || StringLen(InpSheetURL) < 10) return;

    double rAchieved = (g_InitialRisk > 0.0)
        ? MathAbs(exitPrice - g_EntryPrice) / g_InitialRisk : 0.0;
    if(pnl < 0) rAchieved *= -1;

    long durMin = (TimeCurrent() - g_EntryTime) / 60;

    bool   isBuy = (g_InitialSL < g_EntryPrice);
    double tp    = isBuy
        ? NormalizeDouble(g_EntryPrice + g_InitialRisk * InpTrail_R, _Digits)
        : NormalizeDouble(g_EntryPrice - g_InitialRisk * InpTrail_R, _Digits);

    string json = StringFormat(
        "{\"date\":\"%s\","
        "\"symbol\":\"%s\","
        "\"direction\":\"%s\","
        "\"session\":\"%s\","
        "\"entry_price\":\"%.5f\","
        "\"sl\":\"%.5f\","
        "\"tp\":\"%.5f\","
        "\"exit_price\":\"%.5f\","
        "\"exit_type\":\"%s\","
        "\"lots\":\"%.2f\","
        "\"spread_pips\":\"%.1f\","
        "\"duration_min\":\"%d\","
        "\"pnl\":\"%.2f\","
        "\"r_achieved\":\"%.2f\"}",
        TimeToString(g_EntryTime, TIME_DATE|TIME_MINUTES),
        _Symbol,
        isBuy ? "BUY" : "SELL",
        g_EntrySession,
        g_EntryPrice,
        g_InitialSL,
        tp,
        exitPrice,
        exitType,
        g_InitialRisk > 0 ? g_EntryPrice : 0.0,
        g_EntrySpread,
        (int)durMin,
        pnl,
        rAchieved
    );

    char   post[];
    char   result[];
    string headers = "Content-Type: application/json\r\n";
    StringToCharArray(json, post, 0, StringLen(json));

    int res = WebRequest("POST", InpSheetURL, headers, 5000, post, result, headers);
    if(res == -1)
        PrintFormat("DayBreak Journal: WebRequest failed [%d]", GetLastError());
    else
        PrintFormat("DayBreak Journal: Logged — %s | P&L: %.2f", exitType, pnl);
}

//──────────────────────────────────────────────────────────────────────

void OnTick()
{
    RefreshPDHL();    // update PDH/PDL on new D1 bar — O(1)
    RefreshSession(); // update session state — O(1)
    UpdateDashboard();

    //--- Position open: manage exits and return immediately
    if(HasPosition())
    {
        ManageExit();
        return;
    }

    //--- No open position beyond this line ---

    // IMPROVEMENT [B]: Daily trade limit — plain bool read, cheapest entry gate
    if(InpOneTradPerDay && g_TradedToday) return;

    // Session gate — plain int read
    if(!IsInSession()) return;

    // New-bar gate — iTime() call, only reached when both gates above pass
    if(!IsNewBar()) return;

    // All pre-conditions satisfied — evaluate market entry signal
    CheckEntry();
}

//──────────────────────────────────────────────────────────────────────
//  PDH / PDL — update once per new D1 bar
//──────────────────────────────────────────────────────────────────────

void RefreshPDHL()
{
    datetime d1Now = iTime(_Symbol, PERIOD_D1, 0);
    if(d1Now == g_LastD1Bar) return;
    g_LastD1Bar = d1Now;

    g_PDH = iHigh(_Symbol, PERIOD_D1, 1);
    g_PDL = iLow (_Symbol, PERIOD_D1, 1);

    g_BullFailed = false;
    g_BearFailed = false;

    g_DayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    g_DayBlocked     = false;
    g_TradedToday    = false;

    DrawPDHPDL();
    PrintFormat("DayBreak: New day — PDH=%.5f | PDL=%.5f", g_PDH, g_PDL);
}

//──────────────────────────────────────────────────────────────────────
//  SESSION MANAGEMENT
//  Single continuous window from InpStartTime to InpEndTime (GMT).
//  Default 07:00–15:30 covers London open through NY mid-session.
//──────────────────────────────────────────────────────────────────────

int CurrentSessionID()
{
    MqlDateTime dt;
    TimeToStruct(TimeGMT(), dt);
    int t = dt.hour * 100 + dt.min;
    return (t >= InpStartTime && t < InpEndTime) ? 1 : 0;
}

void RefreshSession()
{
    int sid = CurrentSessionID();
    if(sid == g_SessionID) return;

    g_SessionID = sid;

    // FIX [4] VERIFIED: Reset failed-break flags only when entering an active
    // session (sid != 0). Flags persist through the dead zone outside the window
    // and clear on each new session open, allowing a fresh attempt per session.
    // NOTE: g_TradedToday is intentionally NOT reset here — a new session
    // opening mid-day does not grant a second trade for that calendar day.
    if(sid != 0)
    {
        g_BullFailed = false;
        g_BearFailed = false;
        PrintFormat("DayBreak: Session opened (%04d–%04d GMT)", InpStartTime, InpEndTime);
    }
    else
    {
        Print("DayBreak: Session closed");
    }
}

bool IsInSession() { return g_SessionID != 0; }

//──────────────────────────────────────────────────────────────────────
//  BAR GATE — true only on the first tick of each new M15 bar.
//  Uses iTime() rather than precomputed arithmetic to handle DST changes
//  and irregular bar spacing correctly.
//──────────────────────────────────────────────────────────────────────

bool IsNewBar()
{
    datetime t = iTime(_Symbol, InpTimeframe, 0);
    if(t == g_LastBar) return false;
    g_LastBar = t;
    return true;
}

//──────────────────────────────────────────────────────────────────────
//  POSITION STATE — stored after entry confirmation
//──────────────────────────────────────────────────────────────────────

void StorePositionState()
{
    // FIX [2]: use GetPositionTicket() + PositionSelectByTicket() to ensure
    //          we read our own position, not an unrelated one on the symbol.
    ulong t = GetPositionTicket();
    if(t == 0 || !PositionSelectByTicket(t)) return;

    g_EntryPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
    g_InitialSL   = PositionGetDouble(POSITION_SL);
    g_InitialRisk = MathAbs(g_EntryPrice - g_InitialSL);
    // FIX [3]: g_EntryTime is set immediately at order confirmation in
    //          CheckEntry(). Do not overwrite it here — StorePositionState()
    //          runs slightly later so TimeCurrent() here is less accurate.
    g_BE_Done      = false;
    g_PartialDone  = false;
    g_Trail_Done   = false;
    g_P1_Count     = 0;

    string dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "BUY" : "SELL";
    PrintFormat("DayBreak: %s  Price=%.5f  SL=%.5f  Risk=%.5f  Time=%s",
                dir, g_EntryPrice, g_InitialSL, g_InitialRisk,
                TimeToString(g_EntryTime, TIME_DATE|TIME_MINUTES));
}

//──────────────────────────────────────────────────────────────────────
//  INDICATORS
//──────────────────────────────────────────────────────────────────────

double GetATR()
{
    double buf[1];
    if(CopyBuffer(g_ATR, 0, 1, 1, buf) != 1) return 0.0;
    return buf[0];
}

//──────────────────────────────────────────────────────────────────────
//  SPREAD CHECK
//  Converts SYMBOL_SPREAD (broker points) to pips.
//  FIX [5] VERIFIED: 5-digit/3-digit symbols → pipFactor = 10.
//  4-digit/2-digit symbols → pipFactor = 1. Standard for all major FX
//  pairs on MT5. Non-standard instruments (CFDs, metals, indices) may
//  need a different factor.
//──────────────────────────────────────────────────────────────────────

bool SpreadOK()
{
    double pipFactor  = (_Digits == 3 || _Digits == 5) ? 10.0 : 1.0;
    double spreadPips = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) / pipFactor;
    return spreadPips <= InpMaxSpread;
}

//──────────────────────────────────────────────────────────────────────
//  LOT SIZING — fixed fractional on equity risk and stop distance
//──────────────────────────────────────────────────────────────────────

double CalcLots(double riskInPrice)
{
    if(riskInPrice <= 0.0) return 0.0;

    double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskAmt = equity * InpRiskPct / 100.0;
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

    // Use OrderCalcProfit() to get accurate dollar risk per lot.
    // This avoids reliance on SYMBOL_TRADE_TICK_VALUE which some brokers
    // report incorrectly for metals/CFDs (e.g. XAUUSD returning 0.10
    // instead of 1.00, causing 10x oversized positions).
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double stopDollars = 0.0;
    double lossAtStop  = 0.0;

    if(OrderCalcProfit(ORDER_TYPE_BUY, _Symbol, 1.0, bid, bid - riskInPrice, lossAtStop))
    {
        stopDollars = MathAbs(lossAtStop);
    }
    else
    {
        // Fallback: tick-based calculation
        double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tickSz  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        if(tickSz <= 0.0 || tickVal <= 0.0) return 0.0;
        stopDollars = riskInPrice / tickSz * tickVal;
    }

    if(stopDollars <= 0.0) return 0.0;

    double lots = riskAmt / stopDollars;
    lots = MathFloor(lots / lotStep) * lotStep;    // align to lot step
    lots = MathMax(minLot, MathMin(maxLot, lots)); // clamp to symbol limits

    PrintFormat("DayBreak LOT CALC: equity=%.2f riskAmt=%.2f riskInPrice=%.5f stopDollars=%.2f lots=%.2f",
                equity, riskAmt, riskInPrice, stopDollars, NormalizeDouble(lots, 2));

    return NormalizeDouble(lots, 2);
}

// P2 (Momentum Exhaustion — three shrinking bodies) — REMOVED.
// Was cutting winners early (avg win vs potential 2R). P3/P4 and P5
// time stop handle all exits instead.

//──────────────────────────────────────────────────────────────────────
//  ENTRY LOGIC
//  Called from OnTick() only when ALL of the following are true:
//    • No position is open
//    • InpOneTradPerDay + g_TradedToday gate passed (if toggle is ON)
//    • Inside session window
//    • First tick of a new M15 bar
//  CheckEntry() therefore contains pure market logic only — no session,
//  bar, or daily-limit gates are needed inside this function.
//
//  Strategy entry criteria (strictly followed):
//    1. PDH and PDL valid (prior day levels loaded)
//    2. No open position (concurrency guard against visibility lag)
//    3. Spread ≤ InpMaxSpread pips
//    4. Daily DD cap not hit
//    5. M15 candle closed BEYOND PDH (bull) or PDL (bear) — close only, not wick
//    6. Body ≥ InpBodyRatio × full candle range (body dominance filter)
//    7. Body direction matches breakout direction (bull: close > open; bear: close < open)
//    8. Direction not already consumed this session (g_BullFailed / g_BearFailed)
//    9. Enter at market on open of next M15 candle
//──────────────────────────────────────────────────────────────────────

void CheckEntry()
{
    //--- Hard concurrency guard — protects against position visibility lag
    // between order confirmation and the position appearing in PositionsTotal().
    // Cost is one loop call; protection is real on slow ticks or fast fills.
    if(HasPosition()) return;

    if(g_PDH == 0.0 || g_PDL == 0.0) return;
    if(!SpreadOK()) return;

    // IMPROVEMENT [A]: Daily drawdown gate
    if(InpDailyDDLimit > 0.0 && g_DayStartEquity > 0.0)
    {
        double todayDD = (g_DayStartEquity - AccountInfoDouble(ACCOUNT_EQUITY))
                         / g_DayStartEquity * 100.0;
        if(todayDD >= InpDailyDDLimit)
        {
            if(!g_DayBlocked)
            {
                g_DayBlocked = true;
                PrintFormat("DayBreak: DAILY DD LIMIT reached (%.2f%%) — no new entries today.",
                            todayDD);
            }
            return;
        }
    }
    if(g_DayBlocked) return;

    double atr = GetATR();
    if(atr <= 0.0) return;

    // Closed signal candle (shift 1)
    double cls = iClose(_Symbol, InpTimeframe, 1);
    double opn = iOpen (_Symbol, InpTimeframe, 1);
    double hgh = iHigh (_Symbol, InpTimeframe, 1);
    double low = iLow  (_Symbol, InpTimeframe, 1);
    double rng = hgh - low;
    if(rng <= 0.0) return;

    // Strategy rule: body ≥ InpBodyRatio × full candle range
    if(MathAbs(cls - opn) / rng < InpBodyRatio) return;

    //── BULL: M15 close above PDH with bullish body ──────────────────
    if(!g_BullFailed && cls > g_PDH && cls > opn)
    {
        // SL: BreakoutCandle body low − (ATR × ATR_Buffer)
        double bodyLow = MathMin(opn, cls);
        double sl      = NormalizeDouble(bodyLow - atr * InpATR_Buffer, _Digits);
        double risk    = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - sl;

        double lots = CalcLots(risk);
        if(lots <= 0.0) { Print("DayBreak: BUY skipped — lot calc failed"); return; }

        // Set ALL blocking flags BEFORE the order is sent.
        // If the broker rejects the order the day is still marked spent —
        // a valid signal was identified and acted on; retrying would be
        // chasing rather than disciplined entry.
        g_TradedToday = true;
        g_BullFailed  = true;
        g_BearFailed  = true;

        double tp = NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_ASK) + risk * InpTrail_R, _Digits);

        if(trade.Buy(lots, _Symbol, 0, sl, tp, "DayBreak"))
        {
            g_EntryTime = TimeCurrent();
            if(HasPosition())
                StorePositionState();

            // Journal: capture spread and session at entry moment
            double _pipFactor    = (_Digits == 3 || _Digits == 5) ? 10.0 : 1.0;
            g_EntrySpread        = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) / _pipFactor;
            MqlDateTime _dt;
            TimeToStruct(TimeGMT(), _dt);
            int _gmt = _dt.hour * 3600 + _dt.min * 60;
            g_EntrySession = (_gmt >= 7*3600 && _gmt < 9*3600) ? "London" : "NewYork";

            // Visual markers
            DrawBreakoutDot(iTime(_Symbol, InpTimeframe, 1), cls);
            DrawTimeStopLine();
        }
        else
        {
            PrintFormat("DayBreak: BUY rejected [%d] %s",
                        trade.ResultRetcode(), trade.ResultRetcodeDescription());
        }
        return; // hard return — nothing else runs this bar
    }

    //── BEAR: M15 close below PDL with bearish body ──────────────────
    if(!g_BearFailed && cls < g_PDL && cls < opn)
    {
        // SL: BreakoutCandle body high + (ATR × ATR_Buffer)
        double bodyHigh = MathMax(opn, cls);
        double sl       = NormalizeDouble(bodyHigh + atr * InpATR_Buffer, _Digits);
        double risk     = sl - SymbolInfoDouble(_Symbol, SYMBOL_BID);

        double lots = CalcLots(risk);
        if(lots <= 0.0) { Print("DayBreak: SELL skipped — lot calc failed"); return; }

        double tp = NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_BID) - risk * InpTrail_R, _Digits);

        // Set ALL blocking flags BEFORE the order is sent.
        g_TradedToday = true;
        g_BearFailed  = true;
        g_BullFailed  = true;

        if(trade.Sell(lots, _Symbol, 0, sl, tp, "DayBreak"))
        {
            g_EntryTime = TimeCurrent();
            if(HasPosition())
                StorePositionState();

            // Journal: capture spread and session at entry moment
            double _pipFactor    = (_Digits == 3 || _Digits == 5) ? 10.0 : 1.0;
            g_EntrySpread        = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) / _pipFactor;
            MqlDateTime _dt;
            TimeToStruct(TimeGMT(), _dt);
            int _gmt = _dt.hour * 3600 + _dt.min * 60;
            g_EntrySession = (_gmt >= 7*3600 && _gmt < 9*3600) ? "London" : "NewYork";

            // Visual markers
            DrawBreakoutDot(iTime(_Symbol, InpTimeframe, 1), cls);
            DrawTimeStopLine();
        }
        else
        {
            PrintFormat("DayBreak: SELL rejected [%d] %s",
                        trade.ResultRetcode(), trade.ResultRetcodeDescription());
        }
        return; // hard return — nothing else runs this bar
    }
}

//──────────────────────────────────────────────────────────────────────
//  EXIT LOGIC
//  Priority order — first condition met closes or modifies the trade.
//  All checks run on every tick for maximum exit precision.
//
//  P1  2 consecutive M15 closes back inside PDH/PDL → full close, mark failed
//  P2  (REMOVED — was cutting winners early via shrinking body check)
//  P3  Price hits InpBE_R (1.0R)      → move stop to breakeven   (every tick)
//      [ADJUSTED from strategy's 1.5R to 1.0R — locks risk-free earlier]
//  P4  Price hits InpTrail_R (2.0R)   → close full position       (every tick)
//      [ADJUSTED from strategy's "trail to lock 1R" to full close at 2R]
//  P5  InpTimeStopHours from entry    → full close                 (every tick)
//──────────────────────────────────────────────────────────────────────

void ManageExit()
{
    // FIX [2]: GetPositionTicket() loop guarantees we operate on the EA's
    //          own position, filtered by symbol + magic number.
    ulong ticket = GetPositionTicket();
    if(ticket == 0 || !PositionSelectByTicket(ticket)) return;

    bool   isBuy  = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
    double curSL  = PositionGetDouble(POSITION_SL);
    double price  = isBuy
                    ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                    : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

    //── P1: 2 consecutive bar-closes back inside PDH/PDL ────────────────
    // A single close back inside can be noise; two consecutive confirms
    // the breakout has genuinely failed. Counter resets if price closes
    // back outside the level, giving the trade room to recover.
    if(IsNewBar())
    {
        double c1 = iClose(_Symbol, InpTimeframe, 1);

        bool failedBull = isBuy  && c1 < g_PDH;
        bool failedBear = !isBuy && c1 > g_PDL;

        if(failedBull || failedBear)
        {
            g_P1_Count++;
            if(g_P1_Count >= 2)
            {
                JournalTrade("P1_FailedBreak", price, PositionGetDouble(POSITION_PROFIT));
                if(trade.PositionClose(ticket))
                {
                    if(isBuy) g_BullFailed = true;
                    else      g_BearFailed = true;
                    PrintFormat("DayBreak: EXIT P1 — Breakout failed (%d consecutive closes). Position closed.", g_P1_Count);
                }
                return;
            }
        }
        else
        {
            g_P1_Count = 0; // price closed back outside — reset counter
        }
    }

    //── P3 & P4: RRR management (every tick) ─────────────────────────
    if(g_InitialRisk > 0.0)
    {
        double pnl = isBuy ? (price - g_EntryPrice) : (g_EntryPrice - price);
        double R   = pnl / g_InitialRisk;

        // P3 — move stop to breakeven at InpBE_R (adjusted to 1.0R)
        // Strategy: "Move stop to entry price + 2 pts buffer. Trade is risk-free."
        if(!g_BE_Done && R >= InpBE_R)
        {
            // FIX [6]: +2 * _Point buffer matches strategy spec exactly.
            double beSL  = isBuy
                ? NormalizeDouble(g_EntryPrice + 2 * _Point, _Digits)
                : NormalizeDouble(g_EntryPrice - 2 * _Point, _Digits);
            bool canMove = isBuy ? beSL > curSL : beSL < curSL;

            double curTP = PositionGetDouble(POSITION_TP);
            if(canMove && trade.PositionModify(ticket, beSL, curTP))
            {
                g_BE_Done = true;
                curSL     = beSL;
                PrintFormat("DayBreak: EXIT P3 — Breakeven set at %.5f (R=%.2f)", beSL, R);
            }
        }

        // P4a — close 50% at InpPartial_R (1.5R)
        if(!g_PartialDone && R >= InpPartial_R)
        {
            double totalLots = PositionGetDouble(POSITION_VOLUME);
            double lotStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
            double halfLots  = MathFloor((totalLots * 0.5) / lotStep) * lotStep;

            if(halfLots >= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN))
            {
                if(trade.PositionClosePartial(ticket, halfLots))
                {
                    g_PartialDone = true;
                    JournalTrade("P4a_Partial50", price, 0.0);
                    PrintFormat("DayBreak: EXIT P4a — 50%% closed (%.2f lots) at %.1fR",
                                halfLots, InpPartial_R);
                }
            }
            else
            {
                // Position too small to split — mark done and let P4b handle full close
                g_PartialDone = true;
            }
        }

        // P4b — close remainder at InpTrail_R (3.0R)
        if(!g_Trail_Done && R >= InpTrail_R)
        {
            JournalTrade("P4b_FullClose", price, PositionGetDouble(POSITION_PROFIT));
            if(trade.PositionClose(ticket))
            {
                g_Trail_Done = true;
                PrintFormat("DayBreak: EXIT P4b — Remainder closed at %.1fR", InpTrail_R);
            }
            return;
        }
    }

    //── P5 — time stop: InpTimeStopHours from entry (every tick) ──────
    // Strategy: "Position closes exactly N hours after entry timestamp."
    if(g_EntryTime > 0 &&
       TimeCurrent() >= g_EntryTime + (datetime)(InpTimeStopHours * 3600))
    {
        JournalTrade("P5_TimeStop", price, PositionGetDouble(POSITION_PROFIT));
        if(trade.PositionClose(ticket))
            PrintFormat("DayBreak: EXIT P5 — Time stop. %d hr(s) elapsed. Position closed.",
                        InpTimeStopHours);
        return;
    }
}

//──────────────────────────────────────────────────────────────────────
//  CUSTOM OPTIMISATION FITNESS FUNCTION
//  Used by Strategy Tester (OptimizationCriterion = Custom) to guide
//  the genetic algorithm toward parameter sets meeting all five targets:
//    PF 2.0–2.5 | MaxDD ≤15% | Recovery 2.0–3.5 | Sharpe 2.0–3.0 | ~2%/mo
//  Also enforces: ≥100 trades, InpBE_R < InpTrail_R.
//──────────────────────────────────────────────────────────────────────

double OnTester()
{
    int    trades   = (int)TesterStatistics(STAT_TRADES);
    double pf       = TesterStatistics(STAT_PROFIT_FACTOR);
    double maxDD    = TesterStatistics(STAT_EQUITYDD_PERCENT);
    double sharpe   = TesterStatistics(STAT_SHARPE_RATIO);
    double recovery = TesterStatistics(STAT_RECOVERY_FACTOR);
    double profit   = TesterStatistics(STAT_PROFIT);
    double deposit  = TesterStatistics(STAT_INITIAL_DEPOSIT);

    // Hard disqualifiers
    if(trades < 100)            return -10000.0;
    if(InpBE_R >= InpTrail_R)   return -10000.0;
    if(pf <= 0.0 || maxDD <= 0) return -10000.0;

    // Average monthly return (assume 12-month optimisation window)
    double monthRet = (deposit > 0) ? (profit / deposit * 100.0) / 12.0 : 0.0;

    // Composite score: PF × Sharpe × Recovery, penalised by excess DD
    double ddPenalty = (maxDD > 15.0) ? (maxDD / 15.0) * (maxDD / 15.0) : 1.0;
    double score     = pf * MathMax(sharpe, 0.01) * MathMax(recovery, 0.01) / ddPenalty;

    // Bonus for positive monthly return
    if(monthRet > 0.0) score *= (1.0 + monthRet / 5.0);

    return score;
}
//+------------------------------------------------------------------+
