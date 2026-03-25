//+------------------------------------------------------------------+
//|                    QuantumAegisV19_ICT.mq5                       |
//|         V19 ICT PRECISION — Single Symbol Per Chart              |
//|                                                                  |
//| CARA PAKAI:                                                      |
//|   Pasang 1 EA ini di setiap chart symbol yang berbeda.           |
//|   Contoh:                                                        |
//|     Chart XAUUSDc  M1 → pasang EA ini                           |
//|     Chart EURUSDc  M1 → pasang EA ini                           |
//|     Chart GBPUSDc  M1 → pasang EA ini                           |
//|     Chart BTCUSDc  M1 → pasang EA ini                           |
//|   Setiap instance auto-detect symbol dari chart-nya sendiri.     |
//|                                                                  |
//| PERUBAHAN DARI V18:                                              |
//|   FIX-1: EA auto-detect symbol — tidak lagi pakai InpSymbols    |
//|   FIX-2: Session filter berbasis server time (GMT+2/+3)         |
//|          bukan WIB manual yang salah offset                      |
//|   FIX-3: ICT Kill Zone (London 04-07, NY 09-12 server GMT+2)    |
//|   FIX-4: Sweep detection dipindah ke M5 (bukan M1 yang noisy)   |
//|   FIX-5: HTF bias dari D1 PDH/PDL + H4 struktur                 |
//|   FIX-6: Global Circuit Breaker via GlobalVariable MT5           |
//|          (semua instance share 1 limit drawdown harian)          |
//|   NEW-1: ICT EQH/EQL liquidity level detection                  |
//|   NEW-2: Displacement candle confirmation                        |
//|   NEW-3: Dynamic parameter per asset class (XAU/BTC/Forex)      |
//|   NEW-4: PDH/PDL sebagai bias filter tambahan                    |
//+------------------------------------------------------------------+
#property copyright "Andra x Gipi — V19 ICT"
#property version   "19.0"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| 1. INPUT PARAMETERS                                              |
//+------------------------------------------------------------------+
input group    "=== RISK MANAGEMENT ==="
input double   InpRiskPercent        = 0.5;    // Risk per trade (% equity)
input double   InpMaxDailyLossGlobal = 3.0;    // Circuit breaker global (%)
input int      InpMaxTradesPerDay    = 3;       // Max trade per hari per chart
input int      InpMaxConsecLoss      = 2;       // Stop sementara setelah N loss berturut
input int      InpConsecCooldown     = 3600;    // Cooldown setelah hit consec loss (detik)

input group    "=== EXECUTION ==="
input ulong    InpMagicNumber        = 191919;
input int      InpDeviation          = 10;
input int      InpCooldownAfterExit  = 900;    // Detik tunggu setelah posisi EXIT

input group    "=== ICT SESSION (HFM Server = GMT+2 winter / GMT+3 DST) ==="
input bool     InpUseLondonKZ        = true;
input int      InpLondonKZ_Start     = 4;      // 04:00 server = 02:00 UTC (London open)
input int      InpLondonKZ_End       = 7;      // 07:00 server = 05:00 UTC
input bool     InpUseNYKZ            = true;
input int      InpNYKZ_Start         = 9;      // 09:00 server = 07:00 UTC (NY open)
input int      InpNYKZ_End           = 12;     // 12:00 server = 10:00 UTC

input group    "=== ICT METHODOLOGY ==="
input int      InpEQLookback         = 20;     // Candle lookback untuk EQH/EQL di H1
input double   InpEQThreshold        = 0.003;  // Toleransi equal highs/lows (0.3%)
input int      InpSweepLookback      = 10;     // Lookback sweep di M5
input bool     InpRequireDisplacement= true;   // Wajib displacement candle setelah sweep
input double   InpDisplBodyMult      = 1.5;    // Body candle displacement harus > N*ATR

input group    "=== SL/TP MULTIPLIER ==="
input double   InpSLMultXAU          = 2.5;
input double   InpSLMultBTC          = 2.0;
input double   InpSLMultForex        = 1.5;
input double   InpTPRR1              = 2.0;    // Layer 1: RR 1:2
input double   InpTPRR2              = 4.0;    // Layer 2: RR 1:4

input group    "=== INDICATOR PARAMS ==="
input int      InpSTPeriod           = 10;
input double   InpSTFactor           = 3.0;
input int      InpRSILen             = 14;
input int      InpATRLen             = 14;

//+------------------------------------------------------------------+
//| 2. GLOBAL STATE (per instance — 1 instance = 1 symbol)          |
//+------------------------------------------------------------------+
string   g_symbol;           // Auto-detected dari chart
string   g_asset_class;      // "XAU", "BTC", "FOREX"
double   g_sl_mult;          // SL multiplier sesuai aset

datetime g_last_exit_time    = 0;
int      g_daily_trades      = 0;
int      g_trade_day         = 0;
int      g_consec_losses     = 0;
datetime g_consec_loss_time  = 0;
double   g_equity_start      = 0.0;
int      g_current_day       = -1;
datetime g_last_status_print = 0;
datetime g_circuit_print     = 0;

// Global variable key untuk circuit breaker antar instance
string   g_cb_key;           // "V19_CB_YYYYMMDD"
string   g_cb_equity_key;    // "V19_EQ_START"

CTrade g_trade;

//+------------------------------------------------------------------+
//| 3. ASSET CLASS DETECTION & PARAMETERS                           |
//+------------------------------------------------------------------+
string DetectAssetClass(const string sym)
{
    if(StringFind(sym, "XAU") >= 0 || StringFind(sym, "GOLD") >= 0) return "XAU";
    if(StringFind(sym, "BTC") >= 0 || StringFind(sym, "ETH")  >= 0) return "BTC";
    return "FOREX";
}

double GetSLMult(const string asset_class)
{
    if(asset_class == "XAU") return InpSLMultXAU;
    if(asset_class == "BTC") return InpSLMultBTC;
    return InpSLMultForex;
}

int GetSpreadLimit(const string asset_class)
{
    if(asset_class == "XAU") return 150;  // XAU bisa lebar saat news
    if(asset_class == "BTC") return 400;
    return 30;  // Forex tight spread
}

double GetMinSLPoints(const string asset_class)
{
    // Minimum SL distance dalam points — berbeda per aset
    if(asset_class == "XAU") return 200;   // 20 pip minimum untuk XAU
    if(asset_class == "BTC") return 500;
    return 50;
}

//+------------------------------------------------------------------+
//| 4. HELPERS                                                       |
//+------------------------------------------------------------------+
double NormPrice(double price)
{
    double ts = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
    if(ts <= 0.0) return price;
    return MathRound(price / ts) * ts;
}

void Log(const string msg)
{
    Print("[" + g_symbol + "][" +
          TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) + "] " + msg);
}

//+------------------------------------------------------------------+
//| 5. ICT SESSION FILTER (berbasis server time langsung)           |
//+------------------------------------------------------------------+
bool IsInKillZone()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt); // Server time langsung dari MT5
    int hour = dt.hour;

    bool in_london = InpUseLondonKZ && (hour >= InpLondonKZ_Start && hour < InpLondonKZ_End);
    bool in_ny     = InpUseNYKZ    && (hour >= InpNYKZ_Start     && hour < InpNYKZ_End);

    return (in_london || in_ny);
}

string GetCurrentKillZone()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    int hour = dt.hour;
    if(InpUseLondonKZ && hour >= InpLondonKZ_Start && hour < InpLondonKZ_End)
        return "LONDON_KZ";
    if(InpUseNYKZ && hour >= InpNYKZ_Start && hour < InpNYKZ_End)
        return "NY_KZ";
    return "OUTSIDE_KZ";
}

//+------------------------------------------------------------------+
//| 6. MATH ENGINE (NO ArraySetAsSeries — index 0=lama)             |
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
//| 7. ICT HTF BIAS — D1 PDH/PDL + H4 Structure                    |
//+------------------------------------------------------------------+
struct HTFBias
{
    string direction;    // "BULL" atau "BEAR"
    double pdh;          // Previous Day High
    double pdl;          // Previous Day Low
    double h4_ema50;
    bool   valid;
};

HTFBias GetHTFBias(const MqlRates &d1[], const MqlRates &h4[])
{
    HTFBias bias;
    bias.valid     = false;
    bias.direction = "UNKNOWN";
    bias.pdh = 0; bias.pdl = 0; bias.h4_ema50 = 0;

    int nd1 = ArraySize(d1);
    int nh4 = ArraySize(h4);
    if(nd1 < 5 || nh4 < 55) return bias;

    // PDH dan PDL = high/low dari candle D1 yang sudah tutup (iloc[-2])
    bias.pdh = d1[nd1-2].high;
    bias.pdl = d1[nd1-2].low;

    // H4 EMA50 untuk bias
    double ema50_h4[];
    CalcEMA(h4, 50, ema50_h4);
    bias.h4_ema50 = ema50_h4[nh4-2];

    double h4_close = h4[nh4-2].close;

    // D1 bias: harga sekarang vs range kemarin
    double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
    double mid = (ask + bid) / 2.0;

    // H4 bias: harga vs EMA50
    bool h4_bull = h4_close > bias.h4_ema50;
    bool h4_bear = h4_close < bias.h4_ema50;

    // Konfirmasi: D1 range direction + H4 EMA
    // Bull: harga di atas PDH atau di upper half range DAN H4 bullish
    // Bear: harga di bawah PDL atau di lower half range DAN H4 bearish
    double d1_range_mid = (bias.pdh + bias.pdl) / 2.0;

    bool d1_bull_zone = mid > d1_range_mid;
    bool d1_bear_zone = mid < d1_range_mid;

    if(d1_bull_zone && h4_bull)      { bias.direction = "BULL"; bias.valid = true; }
    else if(d1_bear_zone && h4_bear) { bias.direction = "BEAR"; bias.valid = true; }

    return bias;
}

//+------------------------------------------------------------------+
//| 8. ICT LIQUIDITY LEVELS — Equal Highs / Equal Lows di H1        |
//+------------------------------------------------------------------+
struct LiqLevel
{
    double price;
    bool   is_high;    // true=EQH, false=EQL
    bool   swept;      // sudah diambil atau belum
};

void FindLiquidityLevels(const MqlRates &h1[], LiqLevel &levels[], int &count)
{
    count = 0;
    int n = ArraySize(h1);
    if(n < InpEQLookback + 5) return;

    ArrayResize(levels, 20);

    // Cari Equal Highs
    for(int i = n-3; i >= n-InpEQLookback-3 && i >= 2; i--)
    {
        for(int j = i-1; j >= n-InpEQLookback-3 && j >= 0; j--)
        {
            double diff_h = MathAbs(h1[i].high - h1[j].high);
            double ref_h  = h1[i].high;
            if(ref_h > 0 && (diff_h / ref_h) < InpEQThreshold)
            {
                // Equal High ditemukan
                if(count < 20)
                {
                    levels[count].price  = (h1[i].high + h1[j].high) / 2.0;
                    levels[count].is_high = true;
                    levels[count].swept  = false;
                    count++;
                }
                break;
            }
        }
    }

    // Cari Equal Lows
    for(int i = n-3; i >= n-InpEQLookback-3 && i >= 2; i--)
    {
        for(int j = i-1; j >= n-InpEQLookback-3 && j >= 0; j--)
        {
            double diff_l = MathAbs(h1[i].low - h1[j].low);
            double ref_l  = h1[i].low;
            if(ref_l > 0 && (diff_l / ref_l) < InpEQThreshold)
            {
                if(count < 20)
                {
                    levels[count].price  = (h1[i].low + h1[j].low) / 2.0;
                    levels[count].is_high = false;
                    levels[count].swept  = false;
                    count++;
                }
                break;
            }
        }
    }
}

//+------------------------------------------------------------------+
//| 9. ICT SWEEP + DISPLACEMENT DETECTION (di M5)                  |
//+------------------------------------------------------------------+
bool DetectBullSweepM5(const MqlRates &m5[], double liq_level)
{
    // Sweep bullish: harga spike di bawah EQL, lalu close kembali di atas
    int n = ArraySize(m5);
    if(n < 5) return false;

    // Cek 3 candle terakhir yang sudah tutup
    for(int i = n-2; i >= n-InpSweepLookback && i >= 1; i--)
    {
        bool wick_swept = m5[i].low < liq_level;
        bool body_above = m5[i].close > liq_level;

        if(wick_swept && body_above)
        {
            // Cek displacement: candle sesudah sweep harus bullish dan besar
            if(!InpRequireDisplacement) return true;

            if(i+1 < n)
            {
                double atr_arr[];
                CalcATR(m5, InpATRLen, atr_arr);
                double atr = atr_arr[i];
                double body = MathAbs(m5[i+1].close - m5[i+1].open);
                bool displace = (m5[i+1].close > m5[i+1].open) &&
                                (body > atr * InpDisplBodyMult);
                if(displace) return true;
            }
            else return !InpRequireDisplacement;
        }
    }
    return false;
}

bool DetectBearSweepM5(const MqlRates &m5[], double liq_level)
{
    // Sweep bearish: harga spike di atas EQH, lalu close kembali di bawah
    int n = ArraySize(m5);
    if(n < 5) return false;

    for(int i = n-2; i >= n-InpSweepLookback && i >= 1; i--)
    {
        bool wick_swept = m5[i].high > liq_level;
        bool body_below = m5[i].close < liq_level;

        if(wick_swept && body_below)
        {
            if(!InpRequireDisplacement) return true;

            if(i+1 < n)
            {
                double atr_arr[];
                CalcATR(m5, InpATRLen, atr_arr);
                double atr = atr_arr[i];
                double body = MathAbs(m5[i+1].close - m5[i+1].open);
                bool displace = (m5[i+1].close < m5[i+1].open) &&
                                (body > atr * InpDisplBodyMult);
                if(displace) return true;
            }
            else return !InpRequireDisplacement;
        }
    }
    return false;
}

//+------------------------------------------------------------------+
//| 10. SMC: OB + FVG di M15 (sama dengan V17 yang sudah proven)   |
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
//| 11. DECISION STRUCT                                             |
//+------------------------------------------------------------------+
struct Decision
{
    string status;
    string reason;
    string direction;
    string kill_zone;
    double ask;
    double bid;
    double atr_m1;
    double buy_sl;
    double sell_sl;

    void Init()
    {
        status = "BLOCKED"; reason = ""; direction = "";
        kill_zone = ""; ask = bid = atr_m1 = buy_sl = sell_sl = 0.0;
    }
};

//+------------------------------------------------------------------+
//| 12. MAIN ANALYSIS — ICT 6-LAYER FRAMEWORK                      |
//+------------------------------------------------------------------+
Decision Analyze()
{
    Decision d; d.Init();

    double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
    if(ask == 0 || bid == 0) { d.reason = "NO_TICK"; return d; }

    // ── LAYER 0: ICT KILL ZONE ────────────────────────────────────
    if(!IsInKillZone()) { d.reason = "OUTSIDE_KZ"; return d; }
    string kz = GetCurrentKillZone();

    // ── Ambil semua data yang dibutuhkan ───────────────────────────
    MqlRates m1[], m5[], m15[], h1[], h4[], d1[];
    if(CopyRates(g_symbol, PERIOD_M1,  0, 200, m1)  <= 0) { d.reason = "NO_M1";  return d; }
    if(CopyRates(g_symbol, PERIOD_M5,  0, 100, m5)  <= 0) { d.reason = "NO_M5";  return d; }
    if(CopyRates(g_symbol, PERIOD_M15, 0, 200, m15) <= 0) { d.reason = "NO_M15"; return d; }
    if(CopyRates(g_symbol, PERIOD_H1,  0, 100, h1)  <= 0) { d.reason = "NO_H1";  return d; }
    if(CopyRates(g_symbol, PERIOD_H4,  0, 100, h4)  <= 0) { d.reason = "NO_H4";  return d; }
    if(CopyRates(g_symbol, PERIOD_D1,  0, 10,  d1)  <= 0) { d.reason = "NO_D1";  return d; }

    // ── LAYER 1: HTF BIAS (D1 PDH/PDL + H4) ──────────────────────
    HTFBias bias = GetHTFBias(d1, h4);
    if(!bias.valid) { d.reason = "HTF_BIAS_UNCLEAR"; return d; }

    // ── LAYER 2: H1 SUPERTREND searah HTF bias ───────────────────
    bool st_h1[];
    CalcSupertrend(h1, InpSTPeriod, InpSTFactor, st_h1);
    int nh1 = ArraySize(h1);
    bool st_bull_h1 = st_h1[nh1-2];
    if(bias.direction == "BULL" && !st_bull_h1) { d.reason = "H1_ST_COUNTER"; return d; }
    if(bias.direction == "BEAR" &&  st_bull_h1) { d.reason = "H1_ST_COUNTER"; return d; }

    // ── LAYER 3: RSI M1 tidak ekstrem di arah yang salah ─────────
    double rsi_m1[];
    CalcRSI(m1, InpRSILen, rsi_m1);
    int nm1 = ArraySize(m1);
    double rsi = rsi_m1[nm1-2];
    if(bias.direction == "BULL" && rsi > 70) { d.reason = "RSI_OB"; return d; }
    if(bias.direction == "BEAR" && rsi < 30) { d.reason = "RSI_OS"; return d; }

    // ── LAYER 4: ICT LIQUIDITY SWEEP di M5 ───────────────────────
    LiqLevel levels[];
    int liq_count = 0;
    FindLiquidityLevels(h1, levels, liq_count);

    bool sweep_confirmed = false;
    double swept_level   = 0;

    if(liq_count > 0)
    {
        for(int i = 0; i < liq_count; i++)
        {
            if(bias.direction == "BULL" && !levels[i].is_high)
            {
                // Cari EQL yang sudah di-sweep (bullish setup)
                if(DetectBullSweepM5(m5, levels[i].price))
                {
                    sweep_confirmed = true;
                    swept_level     = levels[i].price;
                    break;
                }
            }
            else if(bias.direction == "BEAR" && levels[i].is_high)
            {
                // Cari EQH yang sudah di-sweep (bearish setup)
                if(DetectBearSweepM5(m5, levels[i].price))
                {
                    sweep_confirmed = true;
                    swept_level     = levels[i].price;
                    break;
                }
            }
        }
    }

    // Jika tidak ada EQL/EQH yang di-sweep, cek apakah harga ada di zona OB/FVG M15
    // sebagai trigger alternatif (tetap butuh displacement di M5)
    bool in_pd_array = false;
    double ob15t, ob15b, ro15t, ro15b;
    double fv15t, fv15b, fvr15t, fvr15b;
    DetectOB(m15,  ob15t, ob15b, ro15t,  ro15b);
    DetectFVG(m15, fv15t, fv15b, fvr15t, fvr15b);

    if(bias.direction == "BULL")
        in_pd_array = (ob15t != 0 && ask >= ob15b && ask <= ob15t) ||
                      (fv15t != 0 && ask >= fv15b  && ask <= fv15t);
    else
        in_pd_array = (ro15t != 0 && bid >= ro15b  && bid <= ro15t) ||
                      (fvr15t != 0 && bid >= fvr15b && bid <= fvr15t);

    if(!sweep_confirmed && !in_pd_array)
        { d.reason = "NO_SWEEP_NO_PDARRAY"; return d; }

    // ── LAYER 5: M1 CONFIRMATION — Wick rejection ────────────────
    double atr_m1[];
    CalcATR(m1, InpATRLen, atr_m1);
    double av = atr_m1[nm1-2];
    double cp = m1[nm1-2].close;
    double op = m1[nm1-2].open;
    double wd = (cp > op) ? (op - m1[nm1-2].low)  : (cp - m1[nm1-2].low);
    double wu = (cp > op) ? (m1[nm1-2].high - cp)  : (m1[nm1-2].high - op);

    if(bias.direction == "BULL" && wd < av * 0.1) { d.reason = "NO_BULL_WICK"; return d; }
    if(bias.direction == "BEAR" && wu < av * 0.1) { d.reason = "NO_BEAR_WICK"; return d; }

    // ── SEMUA LAYER LULUS ─────────────────────────────────────────
    d.status    = "VALID_SETUP";
    d.direction = bias.direction == "BULL" ? "BUY" : "SELL";
    d.kill_zone = kz;
    d.ask       = ask;
    d.bid       = bid;
    d.atr_m1    = av;
    d.buy_sl    = ask - av * g_sl_mult;
    d.sell_sl   = bid + av * g_sl_mult;

    return d;
}

//+------------------------------------------------------------------+
//| 13. GLOBAL CIRCUIT BREAKER (shared antar semua instance)        |
//+------------------------------------------------------------------+
void UpdateGlobalCBKey()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    g_cb_key        = "V19_CB_" + IntegerToString(dt.year) +
                      IntegerToString(dt.mon,2,'0') + IntegerToString(dt.day,2,'0');
    g_cb_equity_key = "V19_EQ_" + IntegerToString(dt.year) +
                      IntegerToString(dt.mon,2,'0') + IntegerToString(dt.day,2,'0');
}

bool IsGlobalCBActive()
{
    UpdateGlobalCBKey();
    double eq_start = GlobalVariableGet(g_cb_equity_key);
    if(eq_start <= 0) return false;
    double eq_now = AccountInfoDouble(ACCOUNT_EQUITY);
    double dd = ((eq_start - eq_now) / eq_start) * 100.0;
    return dd >= InpMaxDailyLossGlobal;
}

void InitGlobalEquity()
{
    UpdateGlobalCBKey();
    if(!GlobalVariableCheck(g_cb_equity_key))
    {
        double eq = AccountInfoDouble(ACCOUNT_EQUITY);
        GlobalVariableSet(g_cb_equity_key, eq);
    }
}

//+------------------------------------------------------------------+
//| 14. RISK MANAGER                                                |
//+------------------------------------------------------------------+
double CalcLot(double sl_dist)
{
    double min_sl_points = GetMinSLPoints(g_asset_class);
    double point         = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
    double min_sl_dist   = min_sl_points * point;
    if(sl_dist < min_sl_dist) sl_dist = min_sl_dist;

    double eq   = AccountInfoDouble(ACCOUNT_EQUITY);
    double rsk  = eq * (InpRiskPercent / 100.0);
    double ts   = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
    double tv   = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE);
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
//| 15. DEFENSE: BREAKEVEN + TRAILING                              |
//+------------------------------------------------------------------+
void Defend()
{
    MqlRates m1[];
    if(CopyRates(g_symbol, PERIOD_M1, 0, 50, m1) <= 0) return;
    int n = ArraySize(m1);
    if(n < 16) return;
    double atr_arr[];
    CalcATR(m1, InpATRLen, atr_arr);
    double trail = atr_arr[n-2] * 2.0;

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
                double nsl = NormPrice(entry);
                if(g_trade.PositionModify(ticket, nsl, tp))
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
                double nsl = NormPrice(entry);
                if(g_trade.PositionModify(ticket, nsl, tp))
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
//| 16. TRACK EXITS untuk cooldown berbasis EXIT                   |
//+------------------------------------------------------------------+
void CheckClosedPositions()
{
    datetime from = TimeCurrent() - 86400;
    HistorySelect(from, TimeCurrent());

    for(int i = HistoryDealsTotal()-1; i >= 0; i--)
    {
        ulong deal = HistoryDealGetTicket(i);
        if(HistoryDealGetString(deal,  DEAL_SYMBOL)  != g_symbol)             continue;
        if(HistoryDealGetInteger(deal, DEAL_MAGIC)   != (long)InpMagicNumber) continue;
        if(HistoryDealGetInteger(deal, DEAL_ENTRY)   != DEAL_ENTRY_OUT)       continue;

        datetime deal_time = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
        if(deal_time > g_last_exit_time)
        {
            g_last_exit_time = deal_time;
            double profit    = HistoryDealGetDouble(deal, DEAL_PROFIT);
            if(profit < 0)
            {
                g_consec_losses++;
                if(g_consec_losses >= InpMaxConsecLoss)
                {
                    g_consec_loss_time = deal_time;
                    Log("CONSEC LOSS " + (string)g_consec_losses +
                        " — cooling " + (string)(InpConsecCooldown/60) + " menit");
                }
            }
            else g_consec_losses = 0;
        }
        break;
    }
}

//+------------------------------------------------------------------+
//| 17. EXECUTION ENGINE                                           |
//+------------------------------------------------------------------+
void Execute(Decision &d)
{
    // Cooldown berbasis EXIT
    int elapsed_exit = (int)(TimeCurrent() - g_last_exit_time);
    if(elapsed_exit < InpCooldownAfterExit) return;

    // Consecutive loss cooling
    if(g_consec_losses >= InpMaxConsecLoss)
    {
        int elapsed_consec = (int)(TimeCurrent() - g_consec_loss_time);
        if(elapsed_consec < InpConsecCooldown) return;
        else g_consec_losses = 0;
    }

    // Max trades per day
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    if(dt.day != g_trade_day) { g_daily_trades = 0; g_trade_day = dt.day; }
    if(g_daily_trades >= InpMaxTradesPerDay) return;

    // Posisi terbuka cek
    for(int i = 0; i < PositionsTotal(); i++)
        if(PositionGetSymbol(i) == g_symbol &&
           PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber) return;

    // Spread
    int spread = (int)SymbolInfoInteger(g_symbol, SYMBOL_SPREAD);
    if(spread > GetSpreadLimit(g_asset_class))
    {
        Log("SPREAD " + (string)spread + " > limit. Skip.");
        return;
    }

    double price = (d.direction == "BUY") ? d.ask : d.bid;
    double sl    = (d.direction == "BUY") ? d.buy_sl : d.sell_sl;
    price = NormPrice(price);
    sl    = NormPrice(sl);

    double sld = MathAbs(price - sl);
    double min_sld = GetMinSLPoints(g_asset_class) * SymbolInfoDouble(g_symbol, SYMBOL_POINT);
    if(sld < min_sld)
    {
        sld = min_sld;
        sl  = NormPrice((d.direction == "BUY") ? price - sld : price + sld);
    }

    double total = CalcLot(sld);
    if(total == 0)
    {
        Log("SKIP — modal tidak cukup untuk " + g_symbol);
        return;
    }

    double step  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
    double vmin  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
    double layer = MathRound((total / 2.0) / step) * step;
    int    lays  = (layer >= vmin) ? 2 : 1;
    if(layer < vmin) layer = total;

    double tps[2];
    if(d.direction == "BUY")
    {
        tps[0] = NormPrice(price + sld * InpTPRR1);
        tps[1] = NormPrice(price + sld * InpTPRR2);
    }
    else
    {
        tps[0] = NormPrice(price - sld * InpTPRR1);
        tps[1] = NormPrice(price - sld * InpTPRR2);
    }

    int rr[2]; rr[0] = (int)InpTPRR1; rr[1] = (int)InpTPRR2;

    Log("▶ V19 FIRE! " + d.direction + " | KZ:" + d.kill_zone +
        " | SLMult:" + DoubleToString(g_sl_mult,1) +
        " | Layers:" + (string)lays +
        " | Lot:" + DoubleToString(layer,2) +
        " | Trade#" + (string)(g_daily_trades+1) + "/" + (string)InpMaxTradesPerDay);

    g_trade.SetExpertMagicNumber(InpMagicNumber);
    g_trade.SetDeviationInPoints(InpDeviation);

    int ok = 0;
    for(int i = 0; i < lays; i++)
    {
        bool res = false;
        if(d.direction == "BUY")
            res = g_trade.Buy(layer, g_symbol, price, sl, tps[i], "V19B_L"+(string)(i+1));
        else
            res = g_trade.Sell(layer, g_symbol, price, sl, tps[i], "V19S_L"+(string)(i+1));

        if(res && g_trade.ResultRetcode() == TRADE_RETCODE_DONE)
        {
            Log("  ✓ L" + (string)(i+1) + " #" + (string)g_trade.ResultOrder() +
                " RR=1:" + (string)rr[i]);
            ok++;
        }
        else
            Log("  ✗ L" + (string)(i+1) + " FAIL=" + (string)g_trade.ResultRetcode());
    }
    if(ok > 0) g_daily_trades++;
}

//+------------------------------------------------------------------+
//| 18. ONINIT                                                     |
//+------------------------------------------------------------------+
int OnInit()
{
    // AUTO-DETECT symbol dari chart ini
    g_symbol      = Symbol();
    g_asset_class = DetectAssetClass(g_symbol);
    g_sl_mult     = GetSLMult(g_asset_class);

    g_trade.SetExpertMagicNumber(InpMagicNumber);
    g_trade.SetDeviationInPoints(InpDeviation);

    if(!SymbolSelect(g_symbol, true))
    {
        Log("ERROR: Symbol " + g_symbol + " tidak bisa dipilih.");
        return INIT_FAILED;
    }

    InitGlobalEquity();

    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    g_current_day = dt.day;
    g_trade_day   = dt.day;

    double eq = AccountInfoDouble(ACCOUNT_EQUITY);
    g_equity_start = eq;

    Log("=== V19 ICT PRECISION AKTIF ===");
    Log("Symbol      : " + g_symbol);
    Log("Asset Class : " + g_asset_class);
    Log("SL Mult     : " + DoubleToString(g_sl_mult,1) + "x ATR");
    Log("Broker      : " + AccountInfoString(ACCOUNT_COMPANY));
    Log("Server Time : " + TimeToString(TimeCurrent()));
    Log("Equity      : $" + DoubleToString(eq,2));
    Log("London KZ   : Server " + (string)InpLondonKZ_Start + ":00-" + (string)InpLondonKZ_End + ":00");
    Log("NY KZ       : Server " + (string)InpNYKZ_Start     + ":00-" + (string)InpNYKZ_End     + ":00");
    Log("================================");

    EventSetMillisecondTimer(500);
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 19. ONDEINIT                                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    EventKillTimer();
    Log("V19 " + g_symbol + " dimatikan. Reason=" + (string)reason);
}

//+------------------------------------------------------------------+
//| 20. ONTIMER — Main Loop 500ms                                  |
//+------------------------------------------------------------------+
void OnTimer()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);

    // Reset harian
    if(dt.day != g_current_day)
    {
        InitGlobalEquity(); // Set equity start hari baru
        g_current_day  = dt.day;
        g_daily_trades = 0;
        g_trade_day    = dt.day;
        Log("Hari baru. Reset counter. Equity=$" +
            DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2));
    }

    // Global Circuit Breaker
    if(IsGlobalCBActive())
    {
        if(TimeCurrent() - g_circuit_print > 300)
        {
            Log("GLOBAL CB AKTIF — semua instance terkunci hari ini.");
            g_circuit_print = TimeCurrent();
        }
        Defend(); // Defense tetap jalan
        return;
    }

    // Update exit tracking
    CheckClosedPositions();

    // Defense
    Defend();

    // Analisis
    Decision d = Analyze();

    if(d.status == "BLOCKED")
    {
        if(TimeCurrent() - g_last_status_print > 120)
        {
            Log("Standby (" + d.reason + ")");
            g_last_status_print = TimeCurrent();
        }
    }
    else if(d.status == "VALID_SETUP")
    {
        Execute(d);
    }
}
//+------------------------------------------------------------------+
