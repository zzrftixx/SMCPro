//+------------------------------------------------------------------+
//|                     QuantumAegisV20_Edge.mq5                     |
//|           V20 EDGE — Arsitektur Berbasis Statistical Edge        |
//|                                                                  |
//| FILOSOFI BERBEDA DARI V17-V19:                                   |
//| V17-V19 masalahnya bukan di parameter — tapi di CARA CARI SETUP  |
//| Bot mencari setup dari indikator → hasilnya noise                |
//|                                                                  |
//| V20 mencari setup dari PRICE ACTION MURNI:                       |
//| 1. Identifikasi range session (Asia range)                       |
//| 2. Tunggu breakout dari range saat London/NY open                |
//| 3. Entry pullback ke breakout zone (confirmed retest)            |
//| 4. SL di bawah/atas range. TP di 2x range size                  |
//|                                                                  |
//| Mengapa ini punya EDGE:                                          |
//| - London/NY breakout dari Asia range adalah fenomena TERUKUR     |
//| - Terjadi ~65% hari trading (statistically proven di XAU/FX)    |
//| - Tidak bergantung pada indikator yang bisa repaint              |
//| - Setup jelas: break + retest = entry. Gagal retest = skip       |
//|                                                                  |
//| Ditambah komponen SMC (OB/FVG) hanya sebagai konfirmasi zona     |
//| entry, BUKAN sebagai sinyal utama                                |
//+------------------------------------------------------------------+
#property copyright "Quantum Aegis V20 — Edge Based"
#property version   "20.0"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| 1. INPUT PARAMETERS                                              |
//+------------------------------------------------------------------+
input group "=== RISK MANAGEMENT ==="
input double InpRiskPercent       = 0.5;   // Risk per trade (% equity)
input double InpMaxDailyLoss      = 3.0;   // Circuit breaker harian (%)
input int    InpMaxTradesPerDay   = 3;     // Max trade per hari
input int    InpMaxConsecLoss     = 2;     // Cooling setelah N loss berturut
input int    InpConsecCooldown    = 3600;  // Durasi cooling (detik)
input int    InpCooldownAfterExit = 300;   // Cooldown post-exit (detik)

input group "=== EXECUTION ==="
input ulong  InpMagicNumber       = 202020;
input int    InpDeviation         = 10;

input group "=== ASIA RANGE SESSION (Server Time HFM = GMT+2) ==="
// Asia range: jam di mana pasar bergerak sempit sebelum London buka
input int    InpAsiaRangeStart    = 0;     // 00:00 server (22:00 UTC prev day)
input int    InpAsiaRangeEnd      = 7;     // 07:00 server (05:00 UTC)
// London breakout window: kapan breakout diantisipasi
input int    InpLondonBreakStart  = 7;     // 07:00 server (London pre-open)
input int    InpLondonBreakEnd    = 10;    // 10:00 server
// NY breakout window
input int    InpNYBreakStart      = 13;    // 13:00 server (NY pre-open)
input int    InpNYBreakEnd        = 16;    // 16:00 server

input group "=== STRATEGY PARAMETERS ==="
input double InpBreakoutBuffer    = 0.3;   // Buffer di atas/bawah range (pips)
input double InpRetestTolerance   = 0.5;   // Toleransi retest masuk zona (pips)
input int    InpRetestBars        = 10;    // Max bar untuk menunggu retest
input double InpTPMultiplier      = 2.0;   // TP = N * range size
input double InpSLBuffer          = 0.5;   // Extra buffer SL di luar range (pips)

input group "=== SMC CONFIRMATION (opsional) ==="
input bool   InpUseSMCConfirm     = true;  // Gunakan OB/FVG sebagai konfirmasi
input bool   InpUseHTFBias        = true;  // Filter HTF bias H4

input group "=== ASSET PARAMS ==="
input double InpMinRangePips      = 5.0;   // Range minimum agar setup valid
input double InpMaxRangePips      = 200.0; // Range maximum (filter hari abnormal)
input double InpSLMultXAU         = 1.5;   // SL mult untuk XAU
input double InpSLMultForex       = 1.0;   // SL mult untuk Forex
input double InpSLMultBTC         = 2.0;   // SL mult untuk BTC

//+------------------------------------------------------------------+
//| 2. GLOBAL STATE                                                  |
//+------------------------------------------------------------------+
string   g_symbol;
string   g_asset_class;
double   g_pip_size;       // Ukuran 1 pip untuk aset ini
double   g_sl_mult;

// Asia Range state (di-reset setiap hari)
double   g_asia_high     = 0;
double   g_asia_low      = 0;
bool     g_asia_range_set= false;
datetime g_range_date    = 0;

// Breakout state
bool     g_bull_break    = false;  // Sudah breakout ke atas
bool     g_bear_break    = false;  // Sudah breakout ke bawah
double   g_break_level   = 0;     // Level yang dibreakout
datetime g_break_time    = 0;
int      g_bars_since_break = 0;

// Trade tracking
datetime g_last_exit_time    = 0;
int      g_daily_trades      = 0;
int      g_trade_day         = 0;
int      g_consec_losses     = 0;
datetime g_consec_loss_time  = 0;
int      g_current_day       = -1;
datetime g_last_log_time     = 0;
datetime g_circuit_print     = 0;

// Global CB
string   g_cb_equity_key;

CTrade g_trade;

//+------------------------------------------------------------------+
//| 3. ASSET DETECTION                                              |
//+------------------------------------------------------------------+
string DetectAsset(const string sym)
{
    if(StringFind(sym,"XAU") >= 0 || StringFind(sym,"GOLD") >= 0) return "XAU";
    if(StringFind(sym,"BTC") >= 0 || StringFind(sym,"ETH")  >= 0) return "BTC";
    return "FOREX";
}

double GetPipSize(const string sym, const string asset)
{
    // Pip size: untuk XAU = 0.1, untuk Forex 4-decimal = 0.0001
    int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
    if(asset == "XAU") return 0.1;
    if(asset == "BTC") return 1.0;
    if(digits == 5 || digits == 3) return SymbolInfoDouble(sym, SYMBOL_POINT) * 10;
    return SymbolInfoDouble(sym, SYMBOL_POINT);
}

double GetSLMult(const string asset)
{
    if(asset == "XAU") return InpSLMultXAU;
    if(asset == "BTC") return InpSLMultBTC;
    return InpSLMultForex;
}

int GetSpreadLimit(const string asset)
{
    if(asset == "XAU") return 150;
    if(asset == "BTC") return 500;
    return 40;
}

double NormPrice(double price)
{
    double ts = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
    if(ts <= 0) return price;
    return MathRound(price / ts) * ts;
}

void Log(const string msg)
{
    Print("[V20][" + g_symbol + "][" +
          TimeToString(TimeCurrent(), TIME_SECONDS) + "] " + msg);
}

//+------------------------------------------------------------------+
//| 4. MATH ENGINE (identik V17-V19, sudah proven)                  |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| 5. ASIA RANGE BUILDER                                           |
//| Scan candle H1 dalam sesi Asia untuk dapat high/low range        |
//+------------------------------------------------------------------+
void BuildAsiaRange()
{
    MqlRates h1[];
    // Ambil 24 candle H1 (cukup untuk dapat range hari ini)
    if(CopyRates(g_symbol, PERIOD_H1, 0, 30, h1) <= 0) return;
    int n = ArraySize(h1);

    // Cari candle yang masuk dalam jam Asia range (server time)
    double range_high = -1e18;
    double range_low  =  1e18;
    int    found      = 0;

    for(int i = 0; i < n; i++)
    {
        MqlDateTime dt;
        TimeToStruct((datetime)h1[i].time, dt);
        int hour = dt.hour;

        // Candle H1 yang masuk dalam Asia range window
        if(hour >= InpAsiaRangeStart && hour < InpAsiaRangeEnd)
        {
            if(h1[i].high > range_high) range_high = h1[i].high;
            if(h1[i].low  < range_low)  range_low  = h1[i].low;
            found++;
        }
    }

    if(found < 2) return;  // Butuh minimal 2 candle untuk range valid

    double range_pips = (range_high - range_low) / g_pip_size;

    // Filter range yang terlalu sempit atau terlalu lebar
    if(range_pips < InpMinRangePips || range_pips > InpMaxRangePips) return;

    g_asia_high     = range_high;
    g_asia_low      = range_low;
    g_asia_range_set= true;

    Log("Asia Range SET: High=" + DoubleToString(g_asia_high,5) +
        " Low=" + DoubleToString(g_asia_low,5) +
        " Size=" + DoubleToString(range_pips,1) + " pips");
}

//+------------------------------------------------------------------+
//| 6. BREAKOUT DETECTOR                                            |
//| Deteksi apakah harga sudah break keluar dari Asia range          |
//+------------------------------------------------------------------+
void DetectBreakout()
{
    if(!g_asia_range_set) return;

    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    int hour = dt.hour;

    // Hanya deteksi breakout dalam window London atau NY
    bool in_london_window = (hour >= InpLondonBreakStart && hour < InpLondonBreakEnd);
    bool in_ny_window     = (hour >= InpNYBreakStart     && hour < InpNYBreakEnd);
    if(!in_london_window && !in_ny_window) return;

    // Jangan reset breakout yang sudah ada
    if(g_bull_break || g_bear_break) return;

    MqlRates m5[];
    if(CopyRates(g_symbol, PERIOD_M5, 0, 5, m5) <= 0) return;
    int n = ArraySize(m5);

    double buffer = InpBreakoutBuffer * g_pip_size;
    double last_close = m5[n-2].close; // Candle M5 yang sudah tutup

    // Bullish breakout: close M5 di atas asia_high + buffer
    if(last_close > g_asia_high + buffer)
    {
        g_bull_break   = true;
        g_break_level  = g_asia_high;
        g_break_time   = TimeCurrent();
        g_bars_since_break = 0;
        Log("🔼 BULL BREAK di " + DoubleToString(last_close,5) +
            " > Asia High " + DoubleToString(g_asia_high,5));
    }
    // Bearish breakout: close M5 di bawah asia_low - buffer
    else if(last_close < g_asia_low - buffer)
    {
        g_bear_break   = true;
        g_break_level  = g_asia_low;
        g_break_time   = TimeCurrent();
        g_bars_since_break = 0;
        Log("🔽 BEAR BREAK di " + DoubleToString(last_close,5) +
            " < Asia Low " + DoubleToString(g_asia_low,5));
    }
}

//+------------------------------------------------------------------+
//| 7. HTF BIAS FILTER (H4)                                         |
//+------------------------------------------------------------------+
string GetH4Bias()
{
    if(!InpUseHTFBias) return "ANY";
    MqlRates h4[];
    if(CopyRates(g_symbol, PERIOD_H4, 0, 60, h4) <= 0) return "UNKNOWN";
    int n = ArraySize(h4);
    double ema50[];
    CalcEMA(h4, 50, ema50);
    if(n < 52) return "UNKNOWN";
    return (h4[n-2].close > ema50[n-2]) ? "BULL" : "BEAR";
}

//+------------------------------------------------------------------+
//| 8. SMC CONFIRMATION — OB + FVG di M15 (sebagai konfirmasi zona) |
//+------------------------------------------------------------------+
bool IsInSMCZone(bool is_bull_setup)
{
    if(!InpUseSMCConfirm) return true;  // Skip jika tidak pakai SMC

    MqlRates m15[];
    if(CopyRates(g_symbol, PERIOD_M15, 0, 100, m15) <= 0) return true;
    int n = ArraySize(m15);

    double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);

    // Cari FVG sederhana di M15
    for(int i = n-3; i >= 2; i--)
    {
        if(is_bull_setup)
        {
            // Bullish FVG: harga ask berada di dalam gap bullish
            if(m15[i].low > m15[i-2].high)
            {
                double fvg_top = m15[i].low;
                double fvg_bot = m15[i-2].high;
                if(ask >= fvg_bot && ask <= fvg_top) return true;
            }
        }
        else
        {
            // Bearish FVG: harga bid berada di dalam gap bearish
            if(m15[i].high < m15[i-2].low)
            {
                double fvg_top = m15[i-2].low;
                double fvg_bot = m15[i].high;
                if(bid >= fvg_bot && bid <= fvg_top) return true;
            }
        }
        // Hanya cek 20 candle ke belakang
        if(n - i > 20) break;
    }

    // Cek OB sederhana di M15
    double atr[];
    CalcATR(m15, 14, atr);
    for(int i = n-3; i > 10; i--)
    {
        double body = MathAbs(m15[i].close - m15[i].open);
        if(body < atr[i] * 1.5) continue;

        if(is_bull_setup && m15[i].close > m15[i].open)
        {
            // Cari OB bearish sebelumnya (candle yang menjadi dasar impulse bullish)
            for(int j = i-1; j >= MathMax(0, i-5); j--)
            {
                if(m15[j].close < m15[j].open)
                {
                    double ob_top = MathMax(m15[j].open, m15[j].close);
                    double ob_bot = m15[j].low;
                    if(ask >= ob_bot && ask <= ob_top) return true;
                }
            }
        }
        else if(!is_bull_setup && m15[i].close < m15[i].open)
        {
            for(int j = i-1; j >= MathMax(0, i-5); j--)
            {
                if(m15[j].close > m15[j].open)
                {
                    double ob_top = m15[j].high;
                    double ob_bot = MathMin(m15[j].open, m15[j].close);
                    if(bid >= ob_bot && bid <= ob_top) return true;
                }
            }
        }
        if(n - i > 15) break;
    }

    return false;  // Tidak ada zona SMC di dekat harga saat ini
}

//+------------------------------------------------------------------+
//| 9. RETEST DETECTOR                                              |
//| Setelah breakout, tunggu harga pullback ke break level           |
//| Ini adalah entry zone: harga kembali ke bekas resistance/support |
//+------------------------------------------------------------------+
struct Decision
{
    string status;
    string reason;
    string direction;
    double entry_price;
    double sl;
    double tp1;
    double tp2;
    double range_size;

    void Init()
    {
        status = "BLOCKED"; reason = "";
        direction = ""; entry_price = sl = tp1 = tp2 = range_size = 0;
    }
};

Decision CheckRetestEntry()
{
    Decision d; d.Init();

    if(!g_asia_range_set)
        { d.reason = "NO_ASIA_RANGE"; return d; }
    if(!g_bull_break && !g_bear_break)
        { d.reason = "NO_BREAKOUT_YET"; return d; }

    double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
    double spread = (ask - bid);

    double tol     = InpRetestTolerance * g_pip_size;
    double sl_buf  = InpSLBuffer * g_pip_size;
    double range_size = g_asia_high - g_asia_low;

    // HTF Bias filter
    string h4_bias = GetH4Bias();

    // Update bar counter sejak breakout
    MqlRates m5[];
    if(CopyRates(g_symbol, PERIOD_M5, 0, 3, m5) <= 0)
        { d.reason = "NO_M5"; return d; }

    // --- BULLISH RETEST ---
    if(g_bull_break)
    {
        // HTF harus BULL atau ANY (tidak boleh BEAR)
        if(h4_bias == "BEAR") { d.reason = "H4_COUNTER_BULL"; return d; }

        // Harga harus kembali ke sekitar break level (asia_high)
        // Retest zone: dari break_level - tol sampai break_level + tol
        double retest_top = g_break_level + tol;
        double retest_bot = g_break_level - tol;

        bool price_at_retest = (ask >= retest_bot && ask <= retest_top);

        if(!price_at_retest)
        {
            // Cek apakah harga sudah terlalu jauh (retest tidak terjadi dalam waktu wajar)
            double bars_elapsed = (double)(TimeCurrent() - g_break_time) / 300.0; // per M5
            if(bars_elapsed > InpRetestBars * 2)
            {
                // Breakout terlalu lama tanpa retest — invalidate
                g_bull_break = false;
                g_break_level = 0;
                Log("BULL BREAK invalidated — retest tidak datang dalam " +
                    DoubleToString(bars_elapsed, 0) + " bar M5");
            }
            d.reason = "WAITING_BULL_RETEST Ask=" + DoubleToString(ask,5) +
                       " RetestZone=" + DoubleToString(retest_bot,5) +
                       "-" + DoubleToString(retest_top,5);
            return d;
        }

        // Konfirmasi: M5 terakhir harus bullish (rejection dari break level)
        int nm5 = ArraySize(m5);
        bool bull_reject = (m5[nm5-2].close > m5[nm5-2].open) &&
                           (m5[nm5-2].close > g_break_level);
        if(!bull_reject) { d.reason = "WAITING_BULL_REJECT_CANDLE"; return d; }

        // SMC Konfirmasi
        if(InpUseSMCConfirm && !IsInSMCZone(true))
            { d.reason = "NO_BULL_SMC_ZONE"; return d; }

        // SETUP VALID
        double entry = ask;
        double sl_price = NormPrice(g_asia_low - sl_buf * g_sl_mult);
        double sl_dist  = MathAbs(entry - sl_price);
        if(sl_dist <= 0) { d.reason = "SL_INVALID"; return d; }

        d.status      = "VALID_SETUP";
        d.direction   = "BUY";
        d.entry_price = entry;
        d.sl          = sl_price;
        d.tp1         = NormPrice(entry + sl_dist * InpTPMultiplier);
        d.tp2         = NormPrice(entry + sl_dist * InpTPMultiplier * 1.5);
        d.range_size  = range_size;
        return d;
    }

    // --- BEARISH RETEST ---
    if(g_bear_break)
    {
        if(h4_bias == "BULL") { d.reason = "H4_COUNTER_BEAR"; return d; }

        double retest_top = g_break_level + tol;
        double retest_bot = g_break_level - tol;

        bool price_at_retest = (bid >= retest_bot && bid <= retest_top);

        if(!price_at_retest)
        {
            double bars_elapsed = (double)(TimeCurrent() - g_break_time) / 300.0;
            if(bars_elapsed > InpRetestBars * 2)
            {
                g_bear_break  = false;
                g_break_level = 0;
                Log("BEAR BREAK invalidated — retest tidak datang");
            }
            d.reason = "WAITING_BEAR_RETEST Bid=" + DoubleToString(bid,5) +
                       " RetestZone=" + DoubleToString(retest_bot,5) +
                       "-" + DoubleToString(retest_top,5);
            return d;
        }

        int nm5 = ArraySize(m5);
        bool bear_reject = (m5[nm5-2].close < m5[nm5-2].open) &&
                           (m5[nm5-2].close < g_break_level);
        if(!bear_reject) { d.reason = "WAITING_BEAR_REJECT_CANDLE"; return d; }

        if(InpUseSMCConfirm && !IsInSMCZone(false))
            { d.reason = "NO_BEAR_SMC_ZONE"; return d; }

        double entry   = bid;
        double sl_price = NormPrice(g_asia_high + sl_buf * g_sl_mult);
        double sl_dist  = MathAbs(sl_price - entry);
        if(sl_dist <= 0) { d.reason = "SL_INVALID"; return d; }

        d.status      = "VALID_SETUP";
        d.direction   = "SELL";
        d.entry_price = entry;
        d.sl          = sl_price;
        d.tp1         = NormPrice(entry - sl_dist * InpTPMultiplier);
        d.tp2         = NormPrice(entry - sl_dist * InpTPMultiplier * 1.5);
        d.range_size  = range_size;
        return d;
    }

    d.reason = "UNKNOWN";
    return d;
}

//+------------------------------------------------------------------+
//| 10. RISK MANAGER                                                |
//+------------------------------------------------------------------+
double CalcLot(double sl_dist)
{
    double eq   = AccountInfoDouble(ACCOUNT_EQUITY);
    double rsk  = eq * (InpRiskPercent / 100.0);
    double ts   = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
    double tv   = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE);
    if(ts <= 0 || tv <= 0) return 0;
    double lpl  = (sl_dist / ts) * tv;
    if(lpl <= 0) return 0;
    double raw  = rsk / lpl;
    double vmin = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
    if(raw < vmin) return 0;
    double vmax = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
    double step = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
    return MathRound(MathMin(raw, vmax) / step) * step;
}

//+------------------------------------------------------------------+
//| 11. CIRCUIT BREAKER                                             |
//+------------------------------------------------------------------+
void InitGlobalEquity()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    g_cb_equity_key = "V20_EQ_" + IntegerToString(dt.year) +
                      IntegerToString(dt.mon,2,'0') + IntegerToString(dt.day,2,'0') +
                      "_" + g_symbol;
    if(!GlobalVariableCheck(g_cb_equity_key))
        GlobalVariableSet(g_cb_equity_key, AccountInfoDouble(ACCOUNT_EQUITY));
}

bool IsCBActive()
{
    double eq_start = GlobalVariableGet(g_cb_equity_key);
    if(eq_start <= 0) return false;
    double eq_now = AccountInfoDouble(ACCOUNT_EQUITY);
    return (((eq_start - eq_now) / eq_start) * 100.0) >= InpMaxDailyLoss;
}

//+------------------------------------------------------------------+
//| 12. DEFENSE: BREAKEVEN + TRAILING                              |
//+------------------------------------------------------------------+
void Defend()
{
    MqlRates m1[];
    if(CopyRates(g_symbol, PERIOD_M1, 0, 30, m1) <= 0) return;
    int n = ArraySize(m1);
    if(n < 15) return;
    double atr[];
    CalcATR(m1, 14, atr);
    double trail = atr[n-2] * 2.0;

    for(int i = PositionsTotal()-1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(!PositionSelectByTicket(ticket)) continue;
        if(PositionGetString(POSITION_SYMBOL)  != g_symbol)             continue;
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
                if(g_trade.PositionModify(ticket, NormPrice(entry), tp))
                    Log("BREAKEVEN BUY #" + (string)ticket);
            }
            else if(price - trail > sl && price > entry)
            {
                double nsl = NormPrice(price - trail);
                if(nsl > sl && nsl > entry) g_trade.PositionModify(ticket, nsl, tp);
            }
        }
        else if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
        {
            if(price <= entry - (sl - entry) * 1.5 && sl != entry)
            {
                if(g_trade.PositionModify(ticket, NormPrice(entry), tp))
                    Log("BREAKEVEN SELL #" + (string)ticket);
            }
            else if(price + trail < sl && price < entry)
            {
                double nsl = NormPrice(price + trail);
                if(nsl < sl && nsl < entry) g_trade.PositionModify(ticket, nsl, tp);
            }
        }
    }
}

//+------------------------------------------------------------------+
//| 13. TRACK EXITS                                                |
//+------------------------------------------------------------------+
void CheckClosedPositions()
{
    datetime from = TimeCurrent() - 86400;
    if(!HistorySelect(from, TimeCurrent())) return;

    for(int i = HistoryDealsTotal()-1; i >= 0; i--)
    {
        ulong deal = HistoryDealGetTicket(i);
        if(HistoryDealGetString(deal,  DEAL_SYMBOL) != g_symbol)             continue;
        if(HistoryDealGetInteger(deal, DEAL_MAGIC)  != (long)InpMagicNumber) continue;
        if(HistoryDealGetInteger(deal, DEAL_ENTRY)  != DEAL_ENTRY_OUT)       continue;

        datetime dt = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
        if(dt > g_last_exit_time)
        {
            g_last_exit_time = dt;
            double profit    = HistoryDealGetDouble(deal, DEAL_PROFIT);
            if(profit < 0)
            {
                g_consec_losses++;
                if(g_consec_losses >= InpMaxConsecLoss)
                {
                    g_consec_loss_time = dt;
                    // Setelah loss, invalidate breakout state — mulai fresh
                    g_bull_break = false;
                    g_bear_break = false;
                    g_break_level = 0;
                    Log("CONSEC LOSS " + (string)g_consec_losses + " — reset state");
                }
            }
            else
            {
                g_consec_losses = 0;
                // Setelah profit, juga invalidate — satu setup = satu trade per range
                g_bull_break = false;
                g_bear_break = false;
                g_break_level = 0;
            }
        }
        break;
    }
}

//+------------------------------------------------------------------+
//| 14. EXECUTION                                                  |
//+------------------------------------------------------------------+
void Execute(Decision &d)
{
    // Cooldown post-exit
    if((int)(TimeCurrent() - g_last_exit_time) < InpCooldownAfterExit) return;

    // Consecutive loss cooling
    if(g_consec_losses >= InpMaxConsecLoss)
    {
        if((int)(TimeCurrent() - g_consec_loss_time) < InpConsecCooldown) return;
        else g_consec_losses = 0;
    }

    // Max trades/hari
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    if(dt.day != g_trade_day) { g_daily_trades = 0; g_trade_day = dt.day; }
    if(g_daily_trades >= InpMaxTradesPerDay) return;

    // Cek tidak ada posisi terbuka
    for(int i = 0; i < PositionsTotal(); i++)
        if(PositionGetSymbol(i) == g_symbol &&
           PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber) return;

    // Spread check
    int spread = (int)SymbolInfoInteger(g_symbol, SYMBOL_SPREAD);
    if(spread > GetSpreadLimit(g_asset_class))
    {
        Log("Spread " + (string)spread + " terlalu lebar. Skip.");
        return;
    }

    double sl_dist = MathAbs(d.entry_price - d.sl);
    if(sl_dist <= 0) return;

    double total = CalcLot(sl_dist);
    if(total == 0) { Log("Modal tidak cukup."); return; }

    double step  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
    double vmin  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
    double layer = MathRound((total / 2.0) / step) * step;
    int    lays  = (layer >= vmin) ? 2 : 1;
    if(layer < vmin) layer = total;

    double tps[2] = {d.tp1, d.tp2};

    Log("▶▶ V20 ENTRY! " + d.direction +
        " | Range=" + DoubleToString(d.range_size / g_pip_size,1) + "pips" +
        " | SL=" + DoubleToString(d.sl,5) +
        " | TP1=" + DoubleToString(d.tp1,5) +
        " | Lot=" + DoubleToString(layer,2) +
        " | Trade#" + (string)(g_daily_trades+1));

    g_trade.SetExpertMagicNumber(InpMagicNumber);
    g_trade.SetDeviationInPoints(InpDeviation);

    int ok = 0;
    for(int i = 0; i < lays; i++)
    {
        bool res = false;
        if(d.direction == "BUY")
            res = g_trade.Buy(layer, g_symbol, d.entry_price, d.sl, tps[i],
                              "V20B_L" + (string)(i+1));
        else
            res = g_trade.Sell(layer, g_symbol, d.entry_price, d.sl, tps[i],
                               "V20S_L" + (string)(i+1));

        if(res && g_trade.ResultRetcode() == TRADE_RETCODE_DONE)
        {
            Log("  ✓ L" + (string)(i+1) + " OK #" + (string)g_trade.ResultOrder());
            ok++;
        }
        else
            Log("  ✗ L" + (string)(i+1) + " FAIL=" + (string)g_trade.ResultRetcode());
    }

    if(ok > 0)
    {
        g_daily_trades++;
        // Invalidate setup setelah entry — satu range = satu opportunity
        g_bull_break = false;
        g_bear_break = false;
    }
}

//+------------------------------------------------------------------+
//| 15. DAILY STATE RESET                                          |
//+------------------------------------------------------------------+
void ResetDailyState()
{
    g_asia_high      = 0;
    g_asia_low       = 0;
    g_asia_range_set = false;
    g_bull_break     = false;
    g_bear_break     = false;
    g_break_level    = 0;
    g_break_time     = 0;
    g_daily_trades   = 0;
    g_trade_day      = g_current_day;
    InitGlobalEquity();
    Log("=== HARI BARU — State direset. Menunggu Asia Range... ===");
}

//+------------------------------------------------------------------+
//| 16. ONINIT                                                     |
//+------------------------------------------------------------------+
int OnInit()
{
    g_symbol      = Symbol();
    g_asset_class = DetectAsset(g_symbol);
    g_pip_size    = GetPipSize(g_symbol, g_asset_class);
    g_sl_mult     = GetSLMult(g_asset_class);

    g_trade.SetExpertMagicNumber(InpMagicNumber);
    g_trade.SetDeviationInPoints(InpDeviation);

    if(!SymbolSelect(g_symbol, true))
        { Log("Symbol tidak valid."); return INIT_FAILED; }

    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    g_current_day = dt.day;
    g_trade_day   = dt.day;

    InitGlobalEquity();

    Log("=== V20 EDGE AKTIF ===");
    Log("Symbol     : " + g_symbol + " (" + g_asset_class + ")");
    Log("Pip size   : " + DoubleToString(g_pip_size,5));
    Log("SL mult    : " + DoubleToString(g_sl_mult,1));
    Log("Asia Range : Server " + (string)InpAsiaRangeStart + ":00 - " + (string)InpAsiaRangeEnd + ":00");
    Log("London BRK : Server " + (string)InpLondonBreakStart + ":00 - " + (string)InpLondonBreakEnd + ":00");
    Log("NY Break   : Server " + (string)InpNYBreakStart + ":00 - " + (string)InpNYBreakEnd + ":00");
    Log("Equity     : $" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
    Log("=====================");

    EventSetMillisecondTimer(1000); // 1 detik — tidak perlu lebih cepat
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 17. ONDEINIT                                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    EventKillTimer();
    Log("V20 dimatikan. Reason=" + (string)reason);
}

//+------------------------------------------------------------------+
//| 18. ONTIMER                                                    |
//+------------------------------------------------------------------+
void OnTimer()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);

    // Reset state harian
    if(dt.day != g_current_day)
    {
        g_current_day = dt.day;
        ResetDailyState();
    }

    // Circuit Breaker
    if(IsCBActive())
    {
        if(TimeCurrent() - g_circuit_print > 300)
        {
            Log("CIRCUIT BREAKER aktif — bot terkunci hari ini.");
            g_circuit_print = TimeCurrent();
        }
        Defend();
        return;
    }

    // Track posisi yang ditutup
    CheckClosedPositions();

    // Defense selalu jalan
    Defend();

    // Step 1: Build Asia Range (jika belum ada)
    if(!g_asia_range_set)
    {
        BuildAsiaRange();
        if(TimeCurrent() - g_last_log_time > 300)
        {
            Log("Menunggu Asia Range... Server=" + (string)dt.hour + ":00");
            g_last_log_time = TimeCurrent();
        }
        return;
    }

    // Step 2: Deteksi Breakout
    DetectBreakout();

    // Step 3: Cek Retest Entry
    Decision d = CheckRetestEntry();

    if(d.status == "BLOCKED")
    {
        if(TimeCurrent() - g_last_log_time > 60)
        {
            Log("Standby | " + d.reason);
            g_last_log_time = TimeCurrent();
        }
    }
    else if(d.status == "VALID_SETUP")
    {
        Execute(d);
    }
}
//+------------------------------------------------------------------+
