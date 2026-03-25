//+------------------------------------------------------------------+
//|                      QuantumAegisV18_Precision.mq5               |
//|          V18 PRECISION — Patch dari hasil diagnosis backtest      |
//|                                                                  |
//| CHANGELOG dari V17:                                              |
//|   FIX-1  : Cooldown berbasis EXIT (bukan entry)                  |
//|   FIX-2  : SL_MULT dinamis per aset (XAU=2.5, BTC=2.0, dll)     |
//|   FIX-3  : Hapus M5 fallback zone (hanya M15 OB/FVG)            |
//|   FIX-4  : Session filter cerdas (Asia/London/NewYork/Overlap)   |
//|   FIX-5  : Liquidity sweep confirmation sebelum entry            |
//|   FIX-6  : Account auto-detector (spread, lot step, min dist)    |
//|   FIX-7  : Max trades per day per symbol (anti-overtrade)        |
//|   FIX-8  : Minimum trade interval setelah loss (cooling period)  |
//+------------------------------------------------------------------+
#property copyright "Andra x Gipi — V18 Precision"
#property version   "18.0"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| 1. INPUT PARAMETERS                                              |
//+------------------------------------------------------------------+
input string   InpSymbols           = "XAUUSDc,BTCUSDc,BTCUSDm,XAUUSDm,BTCUSD,XAUUSD";
input double   InpRiskPercent       = 0.5;
input double   InpMaxDailyLoss      = 3.0;
input ulong    InpMagicNumber       = 181818;
input int      InpDeviation         = 10;

// FIX-1: Cooldown berbasis EXIT — waktu tunggu setelah posisi DITUTUP
input int      InpCooldownAfterExit = 900;   // 15 menit setelah exit

// FIX-2: SL Multiplier per aset (tidak lagi satu nilai untuk semua)
input double   InpSLMultXAU         = 2.5;   // XAU butuh ruang lebih lebar
input double   InpSLMultBTC         = 2.0;   // BTC volatilitas tinggi
input double   InpSLMultDefault     = 1.5;   // Forex/lainnya

// FIX-7: Batas maksimum trade per hari per symbol
input int      InpMaxTradesPerDay   = 4;     // Dari 27/hari → max 4/hari

// FIX-8: Cooling period setelah consecutive losses
input int      InpMaxConsecLoss     = 2;     // Stop sementara setelah 2 loss berturut
input int      InpConsecLossCooldown= 3600;  // Istirahat 1 jam setelah hit limit

// Session filter (WIB = UTC+7)
input bool     InpUseSessionFilter  = true;
input int      InpAsiaStart         = 2;     // 02:00 WIB
input int      InpAsiaEnd           = 9;     // 09:00 WIB
input int      InpLondonStart       = 14;    // 14:00 WIB
input int      InpLondonEnd         = 22;    // 22:00 WIB
input int      InpNYStart           = 19;    // 19:30 WIB (pakai 19)
input int      InpNYEnd             = 24;    // Sampai midnight

// Liquidity sweep
input bool     InpRequireSweep      = true;  // FIX-5: wajib ada sweep sebelum entry
input int      InpSweepLookback     = 5;     // Cari swing dalam 5 candle terakhir

// Indikator
input int      InpSTPeriod          = 10;
input double   InpSTFactor          = 3.0;
input int      InpRSILen            = 14;

//+------------------------------------------------------------------+
//| 2. GLOBAL STATE                                                  |
//+------------------------------------------------------------------+
string   g_symbols[];
int      g_sym_count       = 0;
double   g_equity_start    = 0.0;
int      g_current_day     = -1;
datetime g_circuit_print   = 0;
datetime g_status_print[];

// FIX-1: Tracking waktu EXIT (bukan entry)
datetime g_last_exit_time[];

// FIX-7: Counter trade harian per symbol
int      g_daily_trades[];
int      g_trade_day[];

// FIX-8: Tracking consecutive losses
int      g_consec_losses[];
datetime g_consec_loss_time[];

// FIX-6: Account info cache
double   g_account_spread[];   // Spread rata-rata yang terdeteksi
bool     g_account_detected = false;

CTrade g_trade;

//+------------------------------------------------------------------+
//| 3. HELPERS                                                       |
//+------------------------------------------------------------------+

// FIX-2: SL Multiplier dinamis per aset
double GetSLMult(const string sym)
{
    if(StringFind(sym, "XAU") >= 0 || StringFind(sym, "GOLD") >= 0)
        return InpSLMultXAU;
    if(StringFind(sym, "BTC") >= 0)
        return InpSLMultBTC;
    return InpSLMultDefault;
}

// FIX-6: Spread limit dinamis per aset (lebih realistis dari V17)
int GetSpreadLimit(const string sym)
{
    if(StringFind(sym, "XAU") >= 0) return 120;  // Naik dari 80 → lebih toleran
    if(StringFind(sym, "BTC") >= 0) return 300;
    return 80;
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

// FIX-4: Session classifier
string GetCurrentSession(int hour_wib)
{
    // Overlap London-NY = prioritas tertinggi
    if(hour_wib >= InpNYStart && hour_wib < InpLondonEnd)
        return "OVERLAP_LDN_NY";
    if(hour_wib >= InpNYStart && hour_wib <= InpNYEnd)
        return "NEW_YORK";
    if(hour_wib >= InpLondonStart && hour_wib < InpLondonEnd)
        return "LONDON";
    if(hour_wib >= InpAsiaStart && hour_wib < InpAsiaEnd)
        return "ASIA";
    return "OFF_HOURS";
}

// Bobot risk berdasarkan sesi — Asia lebih konservatif
double GetSessionRiskMult(const string session)
{
    if(session == "OVERLAP_LDN_NY") return 1.0;   // Full risk
    if(session == "NEW_YORK")       return 1.0;   // Full risk
    if(session == "LONDON")         return 0.8;   // 80% risk
    if(session == "ASIA")           return 0.5;   // 50% risk — lebih konservatif
    return 0.0;  // OFF_HOURS = tidak trade
}

//+------------------------------------------------------------------+
//| 4. MATH ENGINE (identik V17 — NO ArraySetAsSeries)               |
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
    for(int i = 0; i < n; i++) st[i] = true;
    if(n < period+1) return;
    double atr[];
    CalcATR(r, period, atr);
    double ub[], lb[];
    ArrayResize(ub, n); ArrayResize(lb, n);
    for(int i = 0; i < n; i++)
    {
        double hl2 = (r[i].high + r[i].low) / 2.0;
        ub[i] = hl2 + mult * atr[i];
        lb[i] = hl2 - mult * atr[i];
    }
    for(int i = 1; i < n; i++)
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
//| 5. REGIME & BIAS                                                 |
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
//| 6. SMC: OB + FVG (hanya M15 — M5 fallback DIHAPUS di V18)       |
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
            for(int j = i-1; j >= (int)MathMax(0.0,(double)(i-8)); j--)
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
            for(int j = i-1; j >= (int)MathMax(0.0,(double)(i-8)); j--)
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
//| 7. FIX-5: LIQUIDITY SWEEP DETECTOR                              |
//| Cek apakah ada sweep equal highs/lows sebelum entry zona        |
//| Sweep = harga spike melewati swing point lalu berbalik kembali  |
//+------------------------------------------------------------------+
bool DetectBullSweep(const MqlRates &m1[], int lookback)
{
    // Bullish sweep: harga spike turun di bawah swing low, lalu close kembali di atasnya
    // Ini adalah stop hunt di bawah equal lows — sinyal reversal bullish
    int n = ArraySize(m1);
    if(n < lookback + 3) return false;

    // Cari swing low dalam lookback candle
    double swing_low = m1[n-2].low;
    for(int i = n-2; i >= n-lookback-2 && i >= 1; i--)
        if(m1[i].low < swing_low) swing_low = m1[i].low;

    // Cek apakah candle terakhir spike ke bawah swing low tapi close di atas
    double last_low   = m1[n-2].low;
    double last_close = m1[n-2].close;
    double last_open  = m1[n-2].open;

    // Sweep terjadi: wick tembus di bawah swing low, body close di atas
    bool wick_swept  = last_low < swing_low;
    bool body_closed = last_close > swing_low;
    bool bull_body   = last_close > last_open;  // Candle reversal bullish

    return (wick_swept && body_closed && bull_body);
}

bool DetectBearSweep(const MqlRates &m1[], int lookback)
{
    // Bearish sweep: harga spike di atas swing high, lalu close kembali di bawahnya
    int n = ArraySize(m1);
    if(n < lookback + 3) return false;

    double swing_high = m1[n-2].high;
    for(int i = n-2; i >= n-lookback-2 && i >= 1; i--)
        if(m1[i].high > swing_high) swing_high = m1[i].high;

    double last_high  = m1[n-2].high;
    double last_close = m1[n-2].close;
    double last_open  = m1[n-2].open;

    bool wick_swept  = last_high > swing_high;
    bool body_closed = last_close < swing_high;
    bool bear_body   = last_close < last_open;

    return (wick_swept && body_closed && bear_body);
}

//+------------------------------------------------------------------+
//| 8. DECISION STRUCT                                               |
//+------------------------------------------------------------------+
struct Decision
{
    string status;
    string reason;
    string direction;
    string regime;
    string bias_h4;
    string session;
    double ask;
    double bid;
    double atr;
    double sl_mult;
    double buy_sl;
    double sell_sl;
    double session_risk_mult;

    void Init()
    {
        status = "BLOCKED"; reason = ""; direction = "";
        regime = ""; bias_h4 = ""; session = "";
        ask = bid = atr = sl_mult = buy_sl = sell_sl = 0.0;
        session_risk_mult = 1.0;
    }
};

//+------------------------------------------------------------------+
//| 9. 6-LAYER GATEKEEPER + SESSION + SWEEP                         |
//+------------------------------------------------------------------+
Decision Analyze(const string sym,
                 const MqlRates &m1[],
                 const MqlRates &m15[],
                 const MqlRates &h1[],
                 const MqlRates &h4[])
{
    Decision d; d.Init();

    double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
    double bid = SymbolInfoDouble(sym, SYMBOL_BID);
    if(ask == 0 || bid == 0) { d.reason = "NO_TICK"; return d; }

    // FIX-4: SESSION FILTER — cek dulu sebelum analisis berat
    MqlDateTime dt_local;
    datetime local_time = TimeCurrent() + 7 * 3600; // Convert ke WIB (UTC+7)
    TimeToStruct(local_time, dt_local);
    string session = GetCurrentSession(dt_local.hour);
    double risk_mult = GetSessionRiskMult(session);

    if(InpUseSessionFilter && risk_mult == 0.0)
        { d.reason = "OFF_HOURS (" + session + ")"; return d; }

    // LAYER 0: H4 BIAS
    string bh4 = BiasH4(h4);
    if(bh4 == "UNKNOWN") { d.reason = "H4_UNKNOWN"; return d; }

    // LAYER 1: H1 REGIME
    string reg = RegimeH1(h1);
    if(reg == "CHOPPY" || reg == "UNKNOWN") { d.reason = "H1=" + reg; return d; }
    if(bh4 != reg) { d.reason = "H4_CONFLICT H4=" + bh4 + " H1=" + reg; return d; }

    // LAYER 2: SUPERTREND M1 [n-2]
    bool st[];
    CalcSupertrend(m1, InpSTPeriod, InpSTFactor, st);
    int nm1 = ArraySize(m1);
    if(nm1 < 3) { d.reason = "M1_SHORT"; return d; }
    bool stb = st[nm1-2];
    if(reg == "BULL" && !stb) { d.reason = "ST_COUNTER"; return d; }
    if(reg == "BEAR" &&  stb) { d.reason = "ST_COUNTER"; return d; }

    // LAYER 3: RSI M1 [n-2]
    double rsi_arr[];
    CalcRSI(m1, InpRSILen, rsi_arr);
    double rsi = rsi_arr[nm1-2];
    if(reg == "BULL" && rsi > 65) { d.reason = "RSI_OB"; return d; }
    if(reg == "BEAR" && rsi < 35) { d.reason = "RSI_OS"; return d; }

    // LAYER 4: ZONA SMC — M15 ONLY (FIX-3: hapus M5 fallback)
    double bo15t, bo15b, bro15t, bro15b;
    DetectOB(m15, bo15t, bo15b, bro15t, bro15b);
    double fv15t, fv15b, fvr15t, fvr15b;
    DetectFVG(m15, fv15t, fv15b, fvr15t, fvr15b);

    bool inBull = (bo15t != 0 && ask >= bo15b && ask <= bo15t) ||
                  (fv15t != 0 && ask >= fv15b  && ask <= fv15t);
    bool inBear = (bro15t != 0 && bid >= bro15b && bid <= bro15t) ||
                  (fvr15t != 0 && bid >= fvr15b  && bid <= fvr15t);

    if(reg == "BULL" && !inBull) { d.reason = "NOT_IN_BULL_ZONE_M15"; return d; }
    if(reg == "BEAR" && !inBear) { d.reason = "NOT_IN_BEAR_ZONE_M15"; return d; }

    // LAYER 5: REJECTION WICK M1
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

    // FIX-5: LAYER 6 — LIQUIDITY SWEEP CONFIRMATION
    // Ini yang membedakan V18: harus ada bukti stop hunt sebelum entry
    if(InpRequireSweep)
    {
        bool sweep_ok = false;
        if(reg == "BULL") sweep_ok = DetectBullSweep(m1, InpSweepLookback);
        if(reg == "BEAR") sweep_ok = DetectBearSweep(m1, InpSweepLookback);

        if(!sweep_ok) { d.reason = "NO_LIQUIDITY_SWEEP"; return d; }
    }

    // SEMUA LAYER LULUS
    double sl_mult = GetSLMult(sym);  // FIX-2: SL dinamis per aset

    d.status             = "VALID_SETUP";
    d.direction          = (reg == "BULL") ? "BUY" : "SELL";
    d.regime             = reg;
    d.bias_h4            = bh4;
    d.session            = session;
    d.ask                = ask;
    d.bid                = bid;
    d.atr                = av;
    d.sl_mult            = sl_mult;
    d.session_risk_mult  = risk_mult;
    d.buy_sl             = ask - av * sl_mult;
    d.sell_sl            = bid + av * sl_mult;
    return d;
}

//+------------------------------------------------------------------+
//| 10. RISK MANAGER (dengan session risk multiplier)               |
//+------------------------------------------------------------------+
double CalcLot(const string sym, double sl_dist, double session_mult)
{
    double minsl = SymbolInfoDouble(sym, SYMBOL_POINT) * 50.0;
    if(sl_dist < minsl) sl_dist = minsl;
    double eq   = AccountInfoDouble(ACCOUNT_EQUITY);
    // Risk disesuaikan dengan sesi
    double rsk  = eq * (InpRiskPercent / 100.0) * session_mult;
    double ts   = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
    double tv   = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
    double lpl  = (sl_dist / ts) * tv;
    if(lpl <= 0) return 0;
    double raw  = rsk / lpl;
    double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
    if(raw < vmin) return 0;
    double vmax = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
    double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
    return MathRound(MathMin(raw, vmax) / step) * step;
}

//+------------------------------------------------------------------+
//| 11. DEFENSE: BREAKEVEN + TRAILING                               |
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
        double sl    = PositionGetDouble(POSITION_SL);
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
//| 12. TRACK CLOSED POSITIONS — Untuk FIX-1 dan FIX-8             |
//+------------------------------------------------------------------+
void CheckClosedPositions(int sym_idx, const string sym)
{
    // Cek deal history untuk mendeteksi posisi yang baru ditutup
    datetime from = TimeCurrent() - 86400; // 24 jam terakhir
    HistorySelect(from, TimeCurrent());

    for(int i = HistoryDealsTotal()-1; i >= 0; i--)
    {
        ulong deal = HistoryDealGetTicket(i);
        if(HistoryDealGetString(deal, DEAL_SYMBOL)  != sym)                  continue;
        if(HistoryDealGetInteger(deal, DEAL_MAGIC)  != (long)InpMagicNumber) continue;
        if(HistoryDealGetInteger(deal, DEAL_ENTRY)  != DEAL_ENTRY_OUT)       continue;

        datetime deal_time = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);

        // Update last exit time jika deal ini lebih baru
        if(deal_time > g_last_exit_time[sym_idx])
        {
            g_last_exit_time[sym_idx] = deal_time;

            // FIX-8: Track consecutive losses
            double profit = HistoryDealGetDouble(deal, DEAL_PROFIT);
            if(profit < 0)
            {
                g_consec_losses[sym_idx]++;
                if(g_consec_losses[sym_idx] >= InpMaxConsecLoss)
                {
                    g_consec_loss_time[sym_idx] = deal_time;
                    Log("CONSEC LOSS LIMIT " + sym + " — Cooling " +
                        (string)(InpConsecLossCooldown/60) + " menit");
                }
            }
            else
            {
                // Reset streak jika profit
                g_consec_losses[sym_idx] = 0;
            }
        }
        break; // Hanya ambil deal terbaru
    }
}

//+------------------------------------------------------------------+
//| 13. EXECUTION ENGINE                                             |
//+------------------------------------------------------------------+
void Execute(const string sym, Decision &d, int idx)
{
    // FIX-1: Cooldown berbasis EXIT — bukan entry
    int time_since_exit = (int)(TimeCurrent() - g_last_exit_time[idx]);
    if(time_since_exit < InpCooldownAfterExit)
    {
        int remaining = InpCooldownAfterExit - time_since_exit;
        // Silent — hanya log setiap 5 menit
        if(remaining % 300 < 10)
            Log(sym + " Cooldown post-exit: " + (string)(remaining/60) + " menit lagi");
        return;
    }

    // FIX-8: Consecutive loss cooling
    if(g_consec_losses[idx] >= InpMaxConsecLoss)
    {
        int time_since_consec = (int)(TimeCurrent() - g_consec_loss_time[idx]);
        if(time_since_consec < InpConsecLossCooldown) return;
        else g_consec_losses[idx] = 0; // Reset setelah cooling selesai
    }

    // FIX-7: Max trades per day
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    if(dt.day != g_trade_day[idx])
    {
        g_daily_trades[idx] = 0;
        g_trade_day[idx]    = dt.day;
    }
    if(g_daily_trades[idx] >= InpMaxTradesPerDay)
    {
        return; // Silent — sudah cukup trade hari ini
    }

    // Posisi terbuka?
    for(int i = 0; i < PositionsTotal(); i++)
        if(PositionGetSymbol(i) == sym &&
           PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber) return;

    // Spread filter
    int spread = (int)SymbolInfoInteger(sym, SYMBOL_SPREAD);
    if(spread > GetSpreadLimit(sym))
    {
        Log("SPREAD " + sym + " (" + (string)spread + ") > limit. Skip.");
        return;
    }

    double tick_size = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
    double price     = (d.direction == "BUY") ? d.ask : d.bid;
    double sl        = (d.direction == "BUY") ? d.buy_sl : d.sell_sl;
    price = NormPrice(sym, price);
    sl    = NormPrice(sym, sl);

    double sld  = MathAbs(price - sl);
    double msl  = SymbolInfoDouble(sym, SYMBOL_POINT) * 50.0;
    if(sld < msl)
    {
        sld = msl;
        sl  = NormPrice(sym, (d.direction == "BUY") ? price - sld : price + sld);
    }

    // FIX-2 + Session: Lot dengan risk disesuaikan sesi
    double total = CalcLot(sym, sld, d.session_risk_mult);
    if(total == 0)
    {
        Log("SKIPPED $" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2) +
            " tidak cukup untuk " + sym);
        return;
    }

    double step  = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
    double vmin  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);

    // V18: Maksimum 2 layer (bukan 3) untuk kurangi overtrade
    double layer = MathRound((total / 2.0) / step) * step;
    int    lays  = (layer >= vmin) ? 2 : 1;
    if(layer < vmin) layer = total;

    double tps[2];
    if(d.direction == "BUY")
    {
        tps[0] = NormPrice(sym, price + sld * 2.0);  // RR 1:2
        tps[1] = NormPrice(sym, price + sld * 4.0);  // RR 1:4
    }
    else
    {
        tps[0] = NormPrice(sym, price - sld * 2.0);
        tps[1] = NormPrice(sym, price - sld * 4.0);
    }

    int rr[2]; rr[0] = 2; rr[1] = 4;

    Log("V18 FIRE! " + d.direction + " " + sym +
        " | H4:" + d.bias_h4 + " H1:" + d.regime +
        " | Sesi:" + d.session +
        " | SL_Mult:" + DoubleToString(d.sl_mult,1) +
        " | Layers:" + (string)lays +
        " | Lot:" + DoubleToString(layer,2) +
        " | DailyTrade:" + (string)(g_daily_trades[idx]+1) + "/" + (string)InpMaxTradesPerDay);

    g_trade.SetExpertMagicNumber(InpMagicNumber);
    g_trade.SetDeviationInPoints(InpDeviation);

    int ok = 0;
    for(int i = 0; i < lays; i++)
    {
        double tpi = tps[i];
        bool   res = false;
        if(d.direction == "BUY")
            res = g_trade.Buy(layer, sym, price, sl, tpi, "V18B_L" + (string)(i+1));
        else
            res = g_trade.Sell(layer, sym, price, sl, tpi, "V18S_L" + (string)(i+1));

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
    if(ok > 0)
    {
        g_daily_trades[idx]++;
        // FIX-1: Reset exit timer saat entry berhasil
        // (akan di-update lagi saat posisi benar-benar ditutup)
    }
}

//+------------------------------------------------------------------+
//| 14. ONINIT                                                       |
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

    // Init arrays
    ArrayResize(g_status_print,    g_sym_count); ArrayInitialize(g_status_print,    0);
    ArrayResize(g_last_exit_time,  g_sym_count); ArrayInitialize(g_last_exit_time,  0);
    ArrayResize(g_daily_trades,    g_sym_count); ArrayInitialize(g_daily_trades,    0);
    ArrayResize(g_trade_day,       g_sym_count); ArrayInitialize(g_trade_day,       0);
    ArrayResize(g_consec_losses,   g_sym_count); ArrayInitialize(g_consec_losses,   0);
    ArrayResize(g_consec_loss_time,g_sym_count); ArrayInitialize(g_consec_loss_time,0);
    ArrayResize(g_account_spread,  g_sym_count); ArrayInitialize(g_account_spread,  0);

    double eq = AccountInfoDouble(ACCOUNT_EQUITY);
    g_equity_start = (eq > 0) ? eq : 0.0;

    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    g_current_day = dt.day;

    // FIX-6: Log account info saat start
    Log("=== ACCOUNT AUTO-DETECT ===");
    Log("Broker  : " + AccountInfoString(ACCOUNT_COMPANY));
    Log("Account : " + (string)AccountInfoInteger(ACCOUNT_LOGIN));
    Log("Currency: " + AccountInfoString(ACCOUNT_CURRENCY));
    Log("Equity  : $" + DoubleToString(eq, 2));
    Log("Leverage: 1:" + (string)AccountInfoInteger(ACCOUNT_LEVERAGE));
    Log("Server  : " + AccountInfoString(ACCOUNT_SERVER));
    Log("===========================");

    Log("Active: " + InpSymbols);
    Log("QUANTUM V18 PRECISION LIVE");
    Log("Fixes: Cooldown-EXIT | SL_Dynamic | M15-Only | Session | Sweep | MaxTrades");

    EventSetMillisecondTimer(500); // 0.5s — lebih lambat dari V17 karena lebih selektif
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 15. ONDEINIT                                                     |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    EventKillTimer();
    Log("V18 Precision dimatikan. Reason=" + (string)reason);
}

//+------------------------------------------------------------------+
//| 16. ONTIMER — Main Loop                                         |
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

    // Circuit Breaker
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

    // FIX-1: Update exit tracking sebelum defense
    for(int i = 0; i < g_sym_count; i++)
        CheckClosedPositions(i, g_symbols[i]);

    // Defense selalu jalan
    for(int i = 0; i < g_sym_count; i++) Defend(g_symbols[i]);

    // Scan semua symbol
    for(int i = 0; i < g_sym_count; i++)
    {
        string sym = g_symbols[i];
        MqlRates m1[], m15[], h1[], h4[];

        // NO ArraySetAsSeries — index 0=lama, identik Python
        if(CopyRates(sym, PERIOD_M1,  0, 300, m1)  <= 0) continue;
        if(CopyRates(sym, PERIOD_M15, 0, 300, m15) <= 0) continue;
        if(CopyRates(sym, PERIOD_H1,  0, 300, h1)  <= 0) continue;
        if(CopyRates(sym, PERIOD_H4,  0, 300, h4)  <= 0) continue;

        Decision d = Analyze(sym, m1, m15, h1, h4);

        if(d.status == "BLOCKED")
        {
            if(TimeCurrent() - g_status_print[i] > 120) // Log setiap 2 menit
            {
                Log(sym + " Standby (" + d.reason + ")");
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
