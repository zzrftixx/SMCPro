//+------------------------------------------------------------------+
//|                      QuantumAegisV17_Ultimate.mq5                |
//|          100% Pure Port of Python V17 Ultimate Aegis             |
//|                                                                  |
//| KONVENSI INDEX — identik Python/Pandas (NO ArraySetAsSeries):    |
//|   rates[0]   = candle TERLAMA   == df.iloc[0]                    |
//|   rates[n-1] = candle TERBARU   == df.iloc[-1]                   |
//|   rates[n-2] = closed candle    == df.iloc[-2]  (ANTI-REPAINT)   |
//+------------------------------------------------------------------+
#property copyright "Andra x Gipi"
#property version   "17.2"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| 1. INPUT PARAMETERS                                              |
//+------------------------------------------------------------------+
input string   InpSymbols         = "XAUUSDc,BTCUSDc,BTCUSDm,XAUUSDm,BTCUSD,XAUUSD";
input double   InpRiskPercent     = 0.5;
input double   InpMaxDailyLoss    = 3.0;
input ulong    InpMagicNumber     = 171717;
input int      InpDeviation       = 10;
input int      InpCooldownSeconds = 900;
input int      InpStartHour       = 0;
input int      InpEndHour         = 23;
input int      InpSTPeriod        = 10;
input double   InpSTFactor        = 3.0;
input int      InpRSILen          = 14;
input double   InpSLMult          = 1.5;

//+------------------------------------------------------------------+
//| 2. GLOBAL STATE                                                  |
//+------------------------------------------------------------------+
string   g_symbols[];
int      g_sym_count      = 0;
double   g_equity_start   = 0.0;
int      g_current_day    = -1;
datetime g_circuit_print  = 0;
datetime g_status_print[];
datetime g_last_trade[];

CTrade g_trade;

//+------------------------------------------------------------------+
//| 3. HELPERS                                                       |
//+------------------------------------------------------------------+
int SpreadLimit(const string sym)
{
    if(StringFind(sym, "XAU") >= 0) return 80;
    if(StringFind(sym, "BTC") >= 0) return 200;
    return 50;
}

double NormPrice(const string sym, double price)
{
    double ts = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
    if(ts <= 0.0) return price;
    return MathRound(price / ts) * ts;
}

void Log(const string msg)
{
    Print("[" + TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) + "] " + msg);
}

//+------------------------------------------------------------------+
//| 4. MATH ENGINE                                                   |
//| index 0=lama, n-1=baru — identik Pandas (NO ArraySetAsSeries)    |
//+------------------------------------------------------------------+

void CalcEMA(const MqlRates &r[], int period, double &out[])
{
    int n = ArraySize(r);
    ArrayResize(out, n);
    ArrayInitialize(out, 0.0);
    if(n < period) return;
    double mult = 2.0 / (period + 1.0);
    double seed = 0.0;
    for(int i = 0; i < period; i++) seed += r[i].close;
    out[period-1] = seed / period;
    for(int i = period; i < n; i++)
        out[i] = (r[i].close - out[i-1]) * mult + out[i-1];
}

void CalcATR(const MqlRates &r[], int period, double &out[])
{
    int n = ArraySize(r);
    ArrayResize(out, n);
    ArrayInitialize(out, 0.0);
    if(n < period + 1) return;
    double tr[];
    ArrayResize(tr, n);
    tr[0] = r[0].high - r[0].low;
    for(int i = 1; i < n; i++)
    {
        double hl = r[i].high - r[i].low;
        double hc = MathAbs(r[i].high - r[i-1].close);
        double lc = MathAbs(r[i].low  - r[i-1].close);
        tr[i] = MathMax(hl, MathMax(hc, lc));
    }
    for(int i = period-1; i < n; i++)
    {
        double s = 0.0;
        for(int j = i-period+1; j <= i; j++) s += tr[j];
        out[i] = s / period;
    }
}

void CalcRSI(const MqlRates &r[], int period, double &out[])
{
    int n = ArraySize(r);
    ArrayResize(out, n);
    ArrayInitialize(out, 50.0);
    if(n <= period) return;
    double gain[], loss[];
    ArrayResize(gain, n); ArrayInitialize(gain, 0.0);
    ArrayResize(loss, n); ArrayInitialize(loss, 0.0);
    for(int i = 1; i < n; i++)
    {
        double d = r[i].close - r[i-1].close;
        if(d > 0.0) gain[i] = d; else loss[i] = -d;
    }
    for(int i = period; i < n; i++)
    {
        double ag = 0.0, al = 0.0;
        for(int j = i-period+1; j <= i; j++) { ag += gain[j]; al += loss[j]; }
        ag /= period; al /= period;
        out[i] = (al == 0.0) ? 100.0 : 100.0 - (100.0 / (1.0 + ag / al));
    }
}

void CalcSupertrend(const MqlRates &r[], int period, double mult, bool &st[])
{
    int n = ArraySize(r);
    ArrayResize(st, n);
    int i;
    for(i = 0; i < n; i++) st[i] = true;
    if(n < period+1) return;
    double atr[];
    CalcATR(r, period, atr);
    double ub[], lb[];
    ArrayResize(ub, n); ArrayResize(lb, n);
    for(i = 0; i < n; i++)
    {
        double hl2 = (r[i].high + r[i].low) / 2.0;
        ub[i] = hl2 + mult * atr[i];
        lb[i] = hl2 - mult * atr[i];
    }
    for(i = 1; i < n; i++)
    {
        double c = r[i].close;
        if     (c > ub[i-1]) st[i] = true;
        else if(c < lb[i-1]) st[i] = false;
        else
        {
            st[i] = st[i-1];
            if( st[i] && lb[i] < lb[i-1]) lb[i] = lb[i-1];
            if(!st[i] && ub[i] > ub[i-1]) ub[i] = ub[i-1];
        }
    }
}

//+------------------------------------------------------------------+
//| 5. REGIME & BIAS (ANTI-REPAINT — pakai [n-2])                    |
//+------------------------------------------------------------------+
string BiasH4(const MqlRates &r[])
{
    int n = ArraySize(r);
    if(n < 55) return "UNKNOWN";
    double ema50[];
    CalcEMA(r, 50, ema50);
    return (r[n-2].close > ema50[n-2]) ? "BULL" : "BEAR";
}

string RegimeH1(const MqlRates &r[])
{
    int n = ArraySize(r);
    if(n < 50) return "UNKNOWN";
    double ema20[], ema50[], atr[];
    CalcEMA(r, 20, ema20);
    CalcEMA(r, 50, ema50);
    CalcATR(r, 14, atr);
    if(MathAbs(ema20[n-2] - ema50[n-2]) < atr[n-2] * 0.35) return "CHOPPY";
    return (ema20[n-2] > ema50[n-2]) ? "BULL" : "BEAR";
}

//+------------------------------------------------------------------+
//| 6. SMC: FVG + OB                                                 |
//+------------------------------------------------------------------+
void DetectFVG(const MqlRates &r[],
               double &btop, double &bbot,
               double &rtop, double &rbot)
{
    btop = 0; bbot = 0; rtop = 0; rbot = 0;
    int n = ArraySize(r);
    for(int i = n-3; i >= 2; i--)
    {
        if(btop == 0 && r[i].low > r[i-2].high)
            { btop = r[i].low; bbot = r[i-2].high; }
        if(rtop == 0 && r[i].high < r[i-2].low)
            { rtop = r[i-2].low; rbot = r[i].high; }
        if(btop != 0 && rtop != 0) break;
    }
}

void DetectOB(const MqlRates &r[],
              double &btop, double &bbot,
              double &rtop, double &rbot)
{
    btop = 0; bbot = 0; rtop = 0; rbot = 0;
    int n = ArraySize(r);
    if(n < 15) return;
    double atr[];
    CalcATR(r, 14, atr);
    double vsma[];
    ArrayResize(vsma, n);
    ArrayInitialize(vsma, 0.0);
    for(int i = 19; i < n; i++)
    {
        double s = 0.0;
        for(int j = i-19; j <= i; j++) s += (double)r[j].tick_volume;
        vsma[i] = s / 20.0;
    }
    for(int i = n-3; i > 10; i--)
    {
        double body = MathAbs(r[i].close - r[i].open);
        if(body < atr[i] * 2.0) continue;
        if((double)r[i].tick_volume < vsma[i] * 1.5) continue;

        if(r[i].close > r[i].open && btop == 0)
        {
            for(int j = i-1; j >= (int)MathMax(0.0, (double)(i-8)); j--)
            {
                if(r[j].close < r[j].open)
                {
                    double top = MathMax(r[j].open, r[j].close);
                    double bot = r[j].low;
                    double ml  = 1e18;
                    for(int k = i+1; k <= n-2; k++)
                        if(r[k].low < ml) ml = r[k].low;
                    if(ml > top) { btop = top; bbot = bot; break; }
                }
            }
        }
        if(r[i].close < r[i].open && rtop == 0)
        {
            for(int j = i-1; j >= (int)MathMax(0.0, (double)(i-8)); j--)
            {
                if(r[j].close > r[j].open)
                {
                    double top = r[j].high;
                    double bot = MathMin(r[j].open, r[j].close);
                    double mh  = -1e18;
                    for(int k = i+1; k <= n-2; k++)
                        if(r[k].high > mh) mh = r[k].high;
                    if(mh < bot) { rtop = top; rbot = bot; break; }
                }
            }
        }
        if(btop != 0 && rtop != 0) break;
    }
}

//+------------------------------------------------------------------+
//| 7. DECISION STRUCT                                               |
//+------------------------------------------------------------------+
struct Decision
{
    string status;
    string reason;
    string direction;
    string regime;
    string bias_h4;
    string zone_src;
    double ask;
    double bid;
    double atr;
    double buy_sl;
    double sell_sl;

    void Init()
    {
        status = "BLOCKED"; reason = ""; direction = ""; regime = "";
        bias_h4 = ""; zone_src = "";
        ask = 0; bid = 0; atr = 0; buy_sl = 0; sell_sl = 0;
    }
};

//+------------------------------------------------------------------+
//| 8. 6-LAYER GATEKEEPER                                            |
//+------------------------------------------------------------------+
Decision Analyze(const string sym,
                 const MqlRates &m1[],
                 const MqlRates &m5[],
                 const MqlRates &m15[],
                 const MqlRates &h1[],
                 const MqlRates &h4[])
{
    Decision d; d.Init();

    double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
    double bid = SymbolInfoDouble(sym, SYMBOL_BID);
    if(ask == 0 || bid == 0) { d.reason = "NO_TICK"; return d; }

    // L0: H4 BIAS
    string bh4 = BiasH4(h4);
    if(bh4 == "UNKNOWN") { d.reason = "H4_UNKNOWN"; return d; }

    // L1: H1 REGIME
    string reg = RegimeH1(h1);
    if(reg == "CHOPPY" || reg == "UNKNOWN") { d.reason = "H1=" + reg; return d; }
    if(bh4 != reg) { d.reason = "H4_CONFLICT H4=" + bh4 + " H1=" + reg; return d; }

    // L2: SUPERTREND M1 [n-2]
    bool st[];
    CalcSupertrend(m1, InpSTPeriod, InpSTFactor, st);
    int nm1 = ArraySize(m1);
    if(nm1 < 3) { d.reason = "M1_SHORT"; return d; }
    bool stb = st[nm1-2];
    if(reg == "BULL" && !stb) { d.reason = "ST_COUNTER"; return d; }
    if(reg == "BEAR" &&  stb) { d.reason = "ST_COUNTER"; return d; }

    // L3: RSI M1 [n-2]
    double rsi_arr[];
    CalcRSI(m1, InpRSILen, rsi_arr);
    double rsi = rsi_arr[nm1-2];
    if(reg == "BULL" && rsi > 65) { d.reason = "RSI_OB"; return d; }
    if(reg == "BEAR" && rsi < 35) { d.reason = "RSI_OS"; return d; }

    // L4: ZONA SMC (M15 primer, M5 fallback)
    double bo15t,bo15b,bro15t,bro15b; DetectOB(m15,bo15t,bo15b,bro15t,bro15b);
    double fv15t,fv15b,fvr15t,fvr15b; DetectFVG(m15,fv15t,fv15b,fvr15t,fvr15b);
    double bo5t,bo5b,bro5t,bro5b;     DetectOB(m5,bo5t,bo5b,bro5t,bro5b);
    double fv5t,fv5b,fvr5t,fvr5b;     DetectFVG(m5,fv5t,fv5b,fvr5t,fvr5b);

    bool ib15 = (bo15t!=0 && ask>=bo15b && ask<=bo15t) || (fv15t!=0 && ask>=fv15b && ask<=fv15t);
    bool ib5  = (bo5t!=0  && ask>=bo5b  && ask<=bo5t)  || (fv5t!=0  && ask>=fv5b  && ask<=fv5t);
    bool ir15 = (bro15t!=0 && bid>=bro15b && bid<=bro15t) || (fvr15t!=0 && bid>=fvr15b && bid<=fvr15t);
    bool ir5  = (bro5t!=0  && bid>=bro5b  && bid<=bro5t)  || (fvr5t!=0  && bid>=fvr5b  && bid<=fvr5t);

    if(reg == "BULL" && !ib15 && !ib5) { d.reason = "NOT_IN_BULL_ZONE"; return d; }
    if(reg == "BEAR" && !ir15 && !ir5) { d.reason = "NOT_IN_BEAR_ZONE"; return d; }

    string zsrc = "M15";
    if(reg == "BULL" && !ib15) zsrc = "M5_FALLBACK";
    if(reg == "BEAR" && !ir15) zsrc = "M5_FALLBACK";

    // L5: REJECTION WICK [n-2]
    double atr_arr[];
    CalcATR(m1, 14, atr_arr);
    double av  = atr_arr[nm1-2];
    double mw  = av * 0.1;
    double cp  = m1[nm1-2].close;
    double op  = m1[nm1-2].open;
    double wd  = (cp > op) ? (op - m1[nm1-2].low)  : (cp - m1[nm1-2].low);
    double wu  = (cp > op) ? (m1[nm1-2].high - cp)  : (m1[nm1-2].high - op);
    if(reg == "BULL" && wd < mw) { d.reason = "NO_BULL_WICK"; return d; }
    if(reg == "BEAR" && wu < mw) { d.reason = "NO_BEAR_WICK"; return d; }

    d.status    = "VALID_SETUP";
    d.direction = (reg == "BULL") ? "BUY" : "SELL";
    d.regime    = reg;
    d.bias_h4   = bh4;
    d.zone_src  = zsrc;
    d.ask       = ask; d.bid = bid; d.atr = av;
    d.buy_sl    = ask - av * InpSLMult;
    d.sell_sl   = bid + av * InpSLMult;
    return d;
}

//+------------------------------------------------------------------+
//| 9. RISK MANAGER                                                  |
//+------------------------------------------------------------------+
double CalcLot(const string sym, double sl_dist)
{
    double minsl = SymbolInfoDouble(sym, SYMBOL_POINT) * 50.0;
    if(sl_dist < minsl) sl_dist = minsl;
    double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
    double rsk = eq * (InpRiskPercent / 100.0);
    double ts  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
    double tv  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
    double lpl = (sl_dist / ts) * tv;
    if(lpl <= 0) return 0;
    double raw  = rsk / lpl;
    double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
    if(raw < vmin) return 0;
    double vmax = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
    double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
    return MathRound(MathMin(raw, vmax) / step) * step;
}

//+------------------------------------------------------------------+
//| 10. DEFENSE: BREAKEVEN + TRAILING                                |
//+------------------------------------------------------------------+
void Defend(const string sym)
{
    MqlRates m1[];
    if(CopyRates(sym, PERIOD_M1, 0, 50, m1) <= 0) return;
    int n = ArraySize(m1);
    if(n < 16) return;
    double atr_arr[];
    CalcATR(m1, 14, atr_arr);
    double trail = atr_arr[n-2] * 2.0;

    for(int i = PositionsTotal()-1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(!PositionSelectByTicket(ticket)) continue;
        if(PositionGetString(POSITION_SYMBOL)  != sym)                  continue;
        if(PositionGetInteger(POSITION_MAGIC)  != (long)InpMagicNumber) continue;
        double sl = PositionGetDouble(POSITION_SL);
        if(sl == 0) continue;
        double entry = PositionGetDouble(POSITION_PRICE_OPEN);
        double price = PositionGetDouble(POSITION_PRICE_CURRENT);
        double tp    = PositionGetDouble(POSITION_TP);

        if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
        {
            if(price >= entry + (entry - sl) * 1.5 && sl != entry)
            {
                double nsl = NormPrice(sym, entry);
                if(g_trade.PositionModify(ticket, nsl, tp))
                    Log("BREAKEVEN BUY " + sym + " #" + (string)ticket);
            }
            else if(price - trail > sl && price > entry)
            {
                double nsl = NormPrice(sym, price - trail);
                if(nsl > sl && nsl > entry) g_trade.PositionModify(ticket, nsl, tp);
            }
        }
        else if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
        {
            if(price <= entry - (sl - entry) * 1.5 && sl != entry)
            {
                double nsl = NormPrice(sym, entry);
                if(g_trade.PositionModify(ticket, nsl, tp))
                    Log("BREAKEVEN SELL " + sym + " #" + (string)ticket);
            }
            else if(price + trail < sl && price < entry)
            {
                double nsl = NormPrice(sym, price + trail);
                if(nsl < sl && nsl < entry) g_trade.PositionModify(ticket, nsl, tp);
            }
        }
    }
}

//+------------------------------------------------------------------+
//| 11. EXECUTION ENGINE                                             |
//+------------------------------------------------------------------+
void Execute(const string sym, Decision &d, int idx)
{
    if((int)(TimeCurrent() - g_last_trade[idx]) < InpCooldownSeconds) return;

    for(int i = 0; i < PositionsTotal(); i++)
        if(PositionGetSymbol(i) == sym &&
           PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber) return;

    int spread = (int)SymbolInfoInteger(sym, SYMBOL_SPREAD);
    if(spread > SpreadLimit(sym))
    { Log("SPREAD " + sym + " (" + (string)spread + ") > limit. Skip."); return; }

    double price = (d.direction == "BUY") ? d.ask : d.bid;
    double sl    = (d.direction == "BUY") ? d.buy_sl : d.sell_sl;
    price = NormPrice(sym, price);
    sl    = NormPrice(sym, sl);

    double sld  = MathAbs(price - sl);
    double msl  = SymbolInfoDouble(sym, SYMBOL_POINT) * 50.0;
    if(sld < msl)
    {
        sld = msl;
        sl  = NormPrice(sym, (d.direction == "BUY") ? price - sld : price + sld);
    }

    double total = CalcLot(sym, sld);
    if(total == 0)
    {
        Log("SKIPPED $" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2) +
            " tidak cukup " + DoubleToString(InpRiskPercent,1) + "% " + sym);
        return;
    }

    double step  = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
    double vmin  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
    double layer = MathRound((total / 3.0) / step) * step;
    int    lays  = (layer >= vmin) ? 3 : 1;
    if(layer < vmin) layer = total;

    double tps[3];
    if(d.direction == "BUY")
    {
        tps[0] = NormPrice(sym, price + sld * 2);
        tps[1] = NormPrice(sym, price + sld * 3);
        tps[2] = NormPrice(sym, price + sld * 5);
    }
    else
    {
        tps[0] = NormPrice(sym, price - sld * 2);
        tps[1] = NormPrice(sym, price - sld * 3);
        tps[2] = NormPrice(sym, price - sld * 5);
    }

    int rr[3]; rr[0] = 2; rr[1] = 3; rr[2] = 5;

    Log("FIRE! " + d.direction + " " + sym +
        " H4:" + d.bias_h4 + " H1:" + d.regime +
        " Zone:" + d.zone_src +
        " Layers:" + (string)lays +
        " Lot:" + DoubleToString(layer,2));

    int ok = 0;
    for(int i = 0; i < lays; i++)
    {
        double tpi = (lays > 1) ? tps[i] : tps[0];
        bool   res = false;
        if(d.direction == "BUY")
            res = g_trade.Buy(layer, sym, price, sl, tpi, "V17B_L" + (string)(i+1));
        else
            res = g_trade.Sell(layer, sym, price, sl, tpi, "V17S_L" + (string)(i+1));

        if(res && g_trade.ResultRetcode() == TRADE_RETCODE_DONE)
        {
            Log("  L" + (string)(i+1) + " OK #" + (string)g_trade.ResultOrder() +
                " RR=1:" + (string)rr[i]);
            ok++;
        }
        else
        {
            Log("  L" + (string)(i+1) + " FAIL code=" +
                (string)g_trade.ResultRetcode() + " " + g_trade.ResultComment());
        }
    }
    if(ok > 0) g_last_trade[idx] = TimeCurrent();
}

//+------------------------------------------------------------------+
//| 12. ONINIT                                                       |
//+------------------------------------------------------------------+
int OnInit()
{
    g_trade.SetExpertMagicNumber(InpMagicNumber);
    g_trade.SetDeviationInPoints(InpDeviation);

    ushort sep = StringGetCharacter(",", 0);
    StringSplit(InpSymbols, sep, g_symbols);
    g_sym_count = ArraySize(g_symbols);

    int valid = 0;
    for(int i = 0; i < g_sym_count; i++)
    {
        StringTrimLeft(g_symbols[i]);
        StringTrimRight(g_symbols[i]);
        if(SymbolSelect(g_symbols[i], true)) valid++;
        else Log("Symbol tidak ada: " + g_symbols[i]);
    }
    if(valid == 0) { Log("Tidak ada pair valid."); return INIT_FAILED; }

    ArrayResize(g_status_print, g_sym_count); ArrayInitialize(g_status_print, 0);
    ArrayResize(g_last_trade,   g_sym_count); ArrayInitialize(g_last_trade,   0);

    double eq = AccountInfoDouble(ACCOUNT_EQUITY);
    g_equity_start = (eq > 0) ? eq : 0.0;

    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    g_current_day = dt.day;

    Log("Active: " + InpSymbols);
    Log("QUANTUM V17 ULTIMATE AEGIS NATIVE MQL5 LIVE");
    Log("6-Layer | H4+H1 | M15+M5 SMC | CB=" +
        DoubleToString(InpMaxDailyLoss,1) + "% | CD=" +
        (string)InpCooldownSeconds + "s");

    EventSetMillisecondTimer(200);
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 13. ONDEINIT                                                     |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    EventKillTimer();
    Log("V17 dimatikan. Reason=" + (string)reason);
}

//+------------------------------------------------------------------+
//| 14. ONTIMER — 200ms identik Python time.sleep(0.2)               |
//+------------------------------------------------------------------+
void OnTimer()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);

    // Reset CB tiap hari baru
    if(dt.day != g_current_day)
    {
        double eq = AccountInfoDouble(ACCOUNT_EQUITY);
        g_equity_start = (eq > 0) ? eq : g_equity_start;
        g_current_day  = dt.day;
        Log("Hari baru. Reset CB. Equity=$" + DoubleToString(g_equity_start,2));
    }

    // Circuit breaker
    if(g_equity_start > 0)
    {
        double eq = AccountInfoDouble(ACCOUNT_EQUITY);
        double dd = ((g_equity_start - eq) / g_equity_start) * 100.0;
        if(dd >= InpMaxDailyLoss)
        {
            if(TimeCurrent() - g_circuit_print > 300)
            {
                Log("CIRCUIT BREAKER DD=" + DoubleToString(dd,2) + "% Bot dikunci.");
                g_circuit_print = TimeCurrent();
            }
            for(int i = 0; i < g_sym_count; i++) Defend(g_symbols[i]);
            return;
        }
    }

    for(int i = 0; i < g_sym_count; i++) Defend(g_symbols[i]);

    if(dt.hour < InpStartHour || dt.hour > InpEndHour) return;

    for(int i = 0; i < g_sym_count; i++)
    {
        string sym = g_symbols[i];
        MqlRates m1[], m5[], m15[], h1[], h4[];
        // NO ArraySetAsSeries — index 0=lama, identik Python
        if(CopyRates(sym, PERIOD_M1,  0, 300, m1)  <= 0) continue;
        if(CopyRates(sym, PERIOD_M5,  0, 300, m5)  <= 0) continue;
        if(CopyRates(sym, PERIOD_M15, 0, 300, m15) <= 0) continue;
        if(CopyRates(sym, PERIOD_H1,  0, 300, h1)  <= 0) continue;
        if(CopyRates(sym, PERIOD_H4,  0, 300, h4)  <= 0) continue;

        Decision d = Analyze(sym, m1, m5, m15, h1, h4);

        if(d.status == "BLOCKED")
        {
            if(TimeCurrent() - g_status_print[i] > 60)
            {
                Log(sym + " Memantau (" + d.reason + ")");
                g_status_print[i] = TimeCurrent();
            }
        }
        else if(d.status == "VALID_SETUP")
        {
            Execute(sym, d, i);
        }
    }
}
//+------------------------------------------------------------------+
