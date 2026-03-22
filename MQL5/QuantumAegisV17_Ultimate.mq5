//+------------------------------------------------------------------+
//|                          QuantumAegisV17_Ultimate.mq5            |
//|           100% Pure Port of Python V17 Ultimate Aegis            |
//|                                                                  |
//| KONVENSI INDEX (identik dengan Python/Pandas):                   |
//|   rates[0]   = candle TERLAMA   (== df.iloc[0])                  |
//|   rates[n-1] = candle TERBARU   (== df.iloc[-1])                 |
//|   rates[n-2] = closed candle    (== df.iloc[-2])  ← ANTI-REPAINT |
//|                                                                  |
//| FIX UTAMA vs versi sebelumnya:                                   |
//|   - HAPUS semua ArraySetAsSeries(true) — root cause semua bug    |
//|   - EMA: loop dari index 0 (lama) ke n-1 (baru), identik Pandas  |
//|   - RSI: diff = rates[i].close - rates[i-1].close (bukan terbalik)|
//|   - OB : scan unmitigated dari i+1 ke n-2 (identik iloc[i+1:-1]) |
//|   - FVG: iloc[i] vs iloc[i-2] menggunakan index yang sama        |
//|   - Supertrend: loop dari 1 ke n-1, identik Python range(1,len)  |
//+------------------------------------------------------------------+
#property copyright "Andra x Gipi"
#property version   "17.1"
#property strict

#include <Trade\Trade.mqh>

// ==========================================
// 1. KONFIGURASI MASTER
// ==========================================
input string   InpSymbols            = "XAUUSDc,BTCUSDc,BTCUSDm,XAUUSDm,BTCUSD,XAUUSD";
input double   InpRiskPercent        = 0.5;
input double   InpMaxDailyLoss       = 3.0;
input ulong    InpMagicNumber        = 171717;
input ulong    InpDeviation          = 10;
input int      InpCooldownSeconds    = 900;
input int      InpStartHour          = 0;
input int      InpEndHour            = 23;
input int      InpSTPeriod           = 10;
input double   InpSTFactor           = 3.0;
input int      InpRSILen             = 14;
input double   InpSLMult             = 1.5;

// ==========================================
// 2. GLOBAL STATE
// ==========================================
string   TargetSymbols[];
int      SymbolCount   = 0;
double   EquityAtStart = 0.0;
int      CurrentDay    = -1;
datetime LastCircuitPrint = 0;
datetime LastStatusPrint[];
datetime LastTradeTime[];

CTrade trade;

// ==========================================
// 3. HELPERS
// ==========================================
int GetSpreadLimit(string sym)
{
    if(StringFind(sym,"XAU") >= 0) return 80;
    if(StringFind(sym,"BTC") >= 0) return 200;
    return 50;
}

double NormalizePrice(string sym, double price)
{
    double ts = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
    if(ts <= 0) return price;
    return MathRound(price / ts) * ts;
}

void WriteLog(string msg)
{
    string ts = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);
    Print("[" + ts + "] " + msg);
}

// ==========================================
// 4. MATH ENGINE
// Konvensi: rates[0]=lama, rates[n-1]=baru  (NO ArraySetAsSeries)
// Identik 1:1 dengan Pandas rolling pada Python V17
// ==========================================

// --- EMA (identik pandas ewm span, adjust=False) ---
// Python: series.ewm(span=length, adjust=False).mean()
// Proses dari index 0 (lama) ke n-1 (baru)
void CalcEMA(MqlRates &rates[], int period, double &out[])
{
    int n = ArraySize(rates);
    ArrayResize(out, n);
    ArrayInitialize(out, 0.0);
    if(n < period) return;

    double mult = 2.0 / (period + 1.0);

    // Seed: SMA dari candle 0..period-1
    double seed = 0;
    for(int i = 0; i < period; i++) seed += rates[i].close;
    out[period-1] = seed / period;

    // EMA dari index period ke n-1 (dari lama ke baru)
    for(int i = period; i < n; i++)
        out[i] = (rates[i].close - out[i-1]) * mult + out[i-1];
}

// --- ATR (identik pandas rolling SMA of TR) ---
// Python: tr.rolling(window=length).mean()
void CalcATR(MqlRates &rates[], int period, double &out[])
{
    int n = ArraySize(rates);
    ArrayResize(out, n);
    ArrayInitialize(out, 0.0);
    if(n < period + 1) return;

    // True Range (identik pandas: high-low, abs(high-prev_close), abs(low-prev_close))
    double tr[];
    ArrayResize(tr, n);
    tr[0] = rates[0].high - rates[0].low;
    for(int i = 1; i < n; i++)
    {
        double hl = rates[i].high - rates[i].low;
        double hc = MathAbs(rates[i].high - rates[i-1].close);  // prev close = rates[i-1]
        double lc = MathAbs(rates[i].low  - rates[i-1].close);
        tr[i] = MathMax(hl, MathMax(hc, lc));
    }

    // SMA dari TR — identik pandas rolling(window=period).mean()
    // Hasil valid mulai index period-1
    for(int i = period-1; i < n; i++)
    {
        double sum = 0;
        for(int j = i - period + 1; j <= i; j++) sum += tr[j];
        out[i] = sum / period;
    }
}

// --- RSI (identik pandas rolling SMA gain/loss) ---
// Python: delta = series.diff() → rates[i].close - rates[i-1].close
void CalcRSI(MqlRates &rates[], int period, double &out[])
{
    int n = ArraySize(rates);
    ArrayResize(out, n);
    ArrayInitialize(out, 50.0);
    if(n <= period) return;

    double gain[], loss[];
    ArrayResize(gain, n); ArrayInitialize(gain, 0.0);
    ArrayResize(loss, n); ArrayInitialize(loss, 0.0);

    // diff = rates[i].close - rates[i-1].close  (identik pandas .diff())
    for(int i = 1; i < n; i++)
    {
        double diff = rates[i].close - rates[i-1].close;
        if(diff > 0) gain[i] = diff;
        else         loss[i] = -diff;
    }

    // Rolling SMA — identik pandas rolling(window=period).mean()
    for(int i = period; i < n; i++)
    {
        double ag = 0, al = 0;
        for(int j = i - period + 1; j <= i; j++)
        {
            ag += gain[j];
            al += loss[j];
        }
        ag /= period; al /= period;
        if(al == 0) out[i] = 100.0;
        else        out[i] = 100.0 - (100.0 / (1.0 + ag / al));
    }
}

// --- Supertrend (identik Python calc_supertrend) ---
// Python: for i in range(1, len(df))  → dari index 1 maju ke n-1
void CalcSupertrend(MqlRates &rates[], int period, double mult, bool &st[])
{
    int n = ArraySize(rates);
    ArrayResize(st, n);
    ArrayInitialize(st, true);
    if(n < period + 1) return;

    double atr[];
    CalcATR(rates, period, atr);

    double final_ub[], final_lb[];
    ArrayResize(final_ub, n);
    ArrayResize(final_lb, n);

    // Inisialisasi band awal (identik Python hl2 +/- mult*atr)
    for(int i = 0; i < n; i++)
    {
        double hl2  = (rates[i].high + rates[i].low) / 2.0;
        final_ub[i] = hl2 + (mult * atr[i]);
        final_lb[i] = hl2 - (mult * atr[i]);
    }

    // Loop identik Python: for i in range(1, len(df))
    for(int i = 1; i < n; i++)
    {
        double c = rates[i].close;

        if     (c > final_ub[i-1]) st[i] = true;
        else if(c < final_lb[i-1]) st[i] = false;
        else
        {
            st[i] = st[i-1];
            // Identik Python:
            // if st[i] and final_lb[i] < final_lb[i-1]: final_lb[i] = final_lb[i-1]
            if( st[i] && final_lb[i] < final_lb[i-1]) final_lb[i] = final_lb[i-1];
            // if not st[i] and final_ub[i] > final_ub[i-1]: final_ub[i] = final_ub[i-1]
            if(!st[i] && final_ub[i] > final_ub[i-1]) final_ub[i] = final_ub[i-1];
        }
    }
}

// ==========================================
// 5. REGIME & BIAS ENGINE (ANTI-REPAINT)
// iloc[-2] = rates[n-2] (candle tertutup terakhir)
// ==========================================

// Python: detect_bias_h4 — EMA50, close vs ema50, pakai iloc[-2]
string DetectBiasH4(MqlRates &rates[])
{
    int n = ArraySize(rates);
    if(n < 55) return "UNKNOWN";
    double ema50[];
    CalcEMA(rates, 50, ema50);
    double close = rates[n-2].close;  // iloc[-2]
    return (close > ema50[n-2]) ? "BULL" : "BEAR";
}

// Python: detect_regime_h1 — EMA20, EMA50, ATR, pakai iloc[-2]
string DetectRegimeH1(MqlRates &rates[])
{
    int n = ArraySize(rates);
    if(n < 50) return "UNKNOWN";
    double ema20[], ema50[], atr[];
    CalcEMA(rates, 20, ema20);
    CalcEMA(rates, 50, ema50);
    CalcATR(rates, 14, atr);
    if(MathAbs(ema20[n-2] - ema50[n-2]) < (atr[n-2] * 0.35)) return "CHOPPY";
    return (ema20[n-2] > ema50[n-2]) ? "BULL" : "BEAR";
}

// ==========================================
// 6. SMC ENGINE (OB + FVG) — ANTI-REPAINT
// Python: scan dari len(df)-3 mundur ke 2
// MQL5 tanpa ArraySetAsSeries: scan dari n-3 mundur ke 2
// ==========================================

// Python detect_fvg:
// for i in range(len(df)-3, 2, -1):
//     if df['low'].iloc[i] > df['high'].iloc[i-2]:  ← i vs i-2 (lebih lama)
void DetectFVG(MqlRates &rates[],
               double &bull_top, double &bull_bot,
               double &bear_top, double &bear_bot)
{
    bull_top = 0; bull_bot = 0;
    bear_top = 0; bear_bot = 0;
    int n = ArraySize(rates);

    // Bullish FVG
    for(int i = n-3; i >= 2; i--)
    {
        // Python: df['low'].iloc[i] > df['high'].iloc[i-2]
        if(rates[i].low > rates[i-2].high)
        {
            bull_top = rates[i].low;
            bull_bot = rates[i-2].high;
            break;
        }
    }

    // Bearish FVG
    for(int i = n-3; i >= 2; i--)
    {
        // Python: df['high'].iloc[i] < df['low'].iloc[i-2]
        if(rates[i].high < rates[i-2].low)
        {
            bear_top = rates[i-2].low;
            bear_bot = rates[i].high;
            break;
        }
    }
}

// Python detect_ob:
// for i in range(len(df)-3, 10, -1):
//   unmitigated: df['low'].iloc[i+1:-1].min() > top  ← dari i+1 sampai n-2
void DetectOB(MqlRates &rates[],
              double &bull_top, double &bull_bot,
              double &bear_top, double &bear_bot)
{
    bull_top = 0; bull_bot = 0;
    bear_top = 0; bear_bot = 0;
    int n = ArraySize(rates);
    if(n < 15) return;

    double atr[];
    CalcATR(rates, 14, atr);

    // Volume SMA-20 (identik Python tick_volume.rolling(20).mean())
    double vol_sma[];
    ArrayResize(vol_sma, n);
    ArrayInitialize(vol_sma, 0.0);
    for(int i = 19; i < n; i++)
    {
        double sum = 0;
        for(int j = i-19; j <= i; j++) sum += rates[j].tick_volume;
        vol_sma[i] = sum / 20.0;
    }

    // Scan: identik Python for i in range(len(df)-3, 10, -1)
    for(int i = n-3; i > 10; i--)
    {
        double body = MathAbs(rates[i].close - rates[i].open);
        if(body < atr[i] * 2.0) continue;
        if(rates[i].tick_volume < vol_sma[i] * 1.5) continue;

        // Bullish impulse candle
        if(rates[i].close > rates[i].open && bull_top == 0)
        {
            // Cari candle bearish sebelumnya: for j in range(i-1, max(0,i-8), -1)
            for(int j = i-1; j >= MathMax(0, i-8); j--)
            {
                if(rates[j].close < rates[j].open)
                {
                    double top = MathMax(rates[j].open, rates[j].close);
                    double bot = rates[j].low;

                    // Unmitigated: df['low'].iloc[i+1:-1].min() > top
                    // = rates[i+1] sampai rates[n-2] harus semua low > top
                    double min_low = DBL_MAX;
                    for(int k = i+1; k <= n-2; k++)
                        if(rates[k].low < min_low) min_low = rates[k].low;

                    if(min_low > top)
                    {
                        bull_top = top;
                        bull_bot = bot;
                        break;
                    }
                }
            }
        }

        // Bearish impulse candle
        if(rates[i].close < rates[i].open && bear_top == 0)
        {
            for(int j = i-1; j >= MathMax(0, i-8); j--)
            {
                if(rates[j].close > rates[j].open)
                {
                    double top = rates[j].high;
                    double bot = MathMin(rates[j].open, rates[j].close);

                    // Unmitigated: df['high'].iloc[i+1:-1].max() < bot
                    double max_high = -DBL_MAX;
                    for(int k = i+1; k <= n-2; k++)
                        if(rates[k].high > max_high) max_high = rates[k].high;

                    if(max_high < bot)
                    {
                        bear_top = top;
                        bear_bot = bot;
                        break;
                    }
                }
            }
        }

        if(bull_top != 0 && bear_top != 0) break;
    }
}

// ==========================================
// 7. THE 6-LAYER GATEKEEPER
// Identik Python calculate_ultimate_logic()
// ==========================================
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
};

Decision CalculateUltimateLogic(string sym,
                                 MqlRates &m1[],
                                 MqlRates &m5[],
                                 MqlRates &m15[],
                                 MqlRates &h1[],
                                 MqlRates &h4[])
{
    Decision res;
    res.status = "BLOCKED";
    res.reason = "INIT";

    double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
    double bid = SymbolInfoDouble(sym, SYMBOL_BID);
    if(ask == 0 || bid == 0) { res.reason = "NO_TICK"; return res; }

    // LAYER 0: H4 BIAS (Python: detect_bias_h4)
    string bias_h4 = DetectBiasH4(h4);
    if(bias_h4 == "UNKNOWN") { res.reason = "H4_UNKNOWN"; return res; }

    // LAYER 1: H1 REGIME (Python: detect_regime_h1)
    string regime = DetectRegimeH1(h1);
    if(regime == "CHOPPY" || regime == "UNKNOWN")
        { res.reason = "H1_REGIME=" + regime; return res; }
    if(bias_h4 != regime)
        { res.reason = "H4_CONFLICT: H4=" + bias_h4 + " H1=" + regime; return res; }

    // LAYER 2: SUPERTREND M1 — st[-2] = st[n-2]
    bool st[];
    CalcSupertrend(m1, InpSTPeriod, InpSTFactor, st);
    int nm1 = ArraySize(m1);
    if(nm1 < 3) { res.reason = "M1_DATA_SHORT"; return res; }
    bool st_bull = st[nm1-2];  // iloc[-2]

    if(regime == "BULL" && !st_bull) { res.reason = "ST_COUNTER_TREND"; return res; }
    if(regime == "BEAR" &&  st_bull) { res.reason = "ST_COUNTER_TREND"; return res; }

    // LAYER 3: RSI M1 — iloc[-2] = rsi[n-2]
    double rsi[];
    CalcRSI(m1, InpRSILen, rsi);
    double rsi_val = rsi[nm1-2];

    if(regime == "BULL" && rsi_val > 65) { res.reason = "RSI_OVERBOUGHT"; return res; }
    if(regime == "BEAR" && rsi_val < 35) { res.reason = "RSI_OVERSOLD";   return res; }

    // LAYER 4: ZONA SMC — M15 primer, M5 fallback
    double b_top15, b_bot15, br_top15, br_bot15;
    DetectOB(m15, b_top15, b_bot15, br_top15, br_bot15);

    double fb_top15, fb_bot15, fbr_top15, fbr_bot15;
    DetectFVG(m15, fb_top15, fb_bot15, fbr_top15, fbr_bot15);

    double b_top5, b_bot5, br_top5, br_bot5;
    DetectOB(m5, b_top5, b_bot5, br_top5, br_bot5);

    double fb_top5, fb_bot5, fbr_top5, fbr_bot5;
    DetectFVG(m5, fb_top5, fb_bot5, fbr_top5, fbr_bot5);

    // Cek zona bull
    bool in_ob_bull_m15  = (b_top15  != 0 && ask >= b_bot15  && ask <= b_top15);
    bool in_fvg_bull_m15 = (fb_top15 != 0 && ask >= fb_bot15 && ask <= fb_top15);
    bool in_ob_bull_m5   = (b_top5   != 0 && ask >= b_bot5   && ask <= b_top5);
    bool in_fvg_bull_m5  = (fb_top5  != 0 && ask >= fb_bot5  && ask <= fb_top5);
    bool in_bull_zone    = in_ob_bull_m15 || in_fvg_bull_m15 || in_ob_bull_m5 || in_fvg_bull_m5;

    // Cek zona bear
    bool in_ob_bear_m15  = (br_top15  != 0 && bid >= br_bot15  && bid <= br_top15);
    bool in_fvg_bear_m15 = (fbr_top15 != 0 && bid >= fbr_bot15 && bid <= fbr_top15);
    bool in_ob_bear_m5   = (br_top5   != 0 && bid >= br_bot5   && bid <= br_top5);
    bool in_fvg_bear_m5  = (fbr_top5  != 0 && bid >= fbr_bot5  && bid <= fbr_top5);
    bool in_bear_zone    = in_ob_bear_m15 || in_fvg_bear_m15 || in_ob_bear_m5 || in_fvg_bear_m5;

    // Zone source (M15 atau M5 fallback)
    string zone_src = "M15";
    if(regime == "BULL" && !(in_ob_bull_m15 || in_fvg_bull_m15)) zone_src = "M5_FALLBACK";
    if(regime == "BEAR" && !(in_ob_bear_m15 || in_fvg_bear_m15)) zone_src = "M5_FALLBACK";

    if(regime == "BULL" && !in_bull_zone) { res.reason = "NOT_IN_BULL_ZONE"; return res; }
    if(regime == "BEAR" && !in_bear_zone) { res.reason = "NOT_IN_BEAR_ZONE"; return res; }

    // LAYER 5: MICRO REJECTION WICK — pakai iloc[-2] = m1[nm1-2]
    double atr_arr[];
    CalcATR(m1, 14, atr_arr);
    double atr_m1  = atr_arr[nm1-2];
    double min_wick = atr_m1 * 0.1;

    double close_p = m1[nm1-2].close;
    double open_p  = m1[nm1-2].open;
    double wick_down = (close_p > open_p) ? (open_p  - m1[nm1-2].low)  : (close_p - m1[nm1-2].low);
    double wick_up   = (close_p > open_p) ? (m1[nm1-2].high - close_p) : (m1[nm1-2].high - open_p);

    if(regime == "BULL" && wick_down < min_wick) { res.reason = "NO_BULL_REJECTION_WICK"; return res; }
    if(regime == "BEAR" && wick_up   < min_wick) { res.reason = "NO_BEAR_REJECTION_WICK"; return res; }

    // SEMUA LAYER LULUS
    res.status    = "VALID_SETUP";
    res.direction = (regime == "BULL") ? "BUY" : "SELL";
    res.regime    = regime;
    res.bias_h4   = bias_h4;
    res.zone_src  = zone_src;
    res.ask       = ask;
    res.bid       = bid;
    res.atr       = atr_m1;
    res.buy_sl    = ask - (atr_m1 * InpSLMult);
    res.sell_sl   = bid + (atr_m1 * InpSLMult);
    return res;
}

// ==========================================
// 8. RUTHLESS RISK MANAGER
// Identik Python strict_lot_calculator()
// ==========================================
double StrictLotCalculator(string sym, double sl_dist)
{
    double min_sl = SymbolInfoDouble(sym, SYMBOL_POINT) * 50.0;
    if(sl_dist < min_sl) sl_dist = min_sl;

    double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
    double risk_money  = equity * (InpRiskPercent / 100.0);
    double tick_size   = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
    double tick_value  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
    double sl_ticks    = sl_dist / tick_size;
    double loss_per_lot= sl_ticks * tick_value;

    if(loss_per_lot <= 0) return 0;

    double raw_lot  = risk_money / loss_per_lot;
    double min_vol  = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
    if(raw_lot < min_vol) return 0;  // ATURAN BESI

    double final_lot = MathMin(raw_lot, SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX));
    double step      = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
    return MathRound(final_lot / step) * step;
}

// ==========================================
// 9. ACTIVE DEFENSE — BREAKEVEN + TRAILING
// Identik Python manage_defenses()
// ==========================================
void ManageDefenses(string sym)
{
    MqlRates m1[];
    // CopyRates tanpa ArraySetAsSeries → index 0=lama, n-1=baru
    if(CopyRates(sym, PERIOD_M1, 0, 50, m1) <= 0) return;
    // JANGAN ArraySetAsSeries — biarkan default (0=lama)

    int n = ArraySize(m1);
    if(n < 16) return;

    double atr_arr[];
    CalcATR(m1, 14, atr_arr);
    double atr   = atr_arr[n-2];  // iloc[-2]
    double trail = atr * 2.0;

    for(int i = PositionsTotal()-1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(!PositionSelectByTicket(ticket)) continue;
        if(PositionGetString(POSITION_SYMBOL)       != sym)              continue;
        if(PositionGetInteger(POSITION_MAGIC)        != (long)InpMagicNumber) continue;

        double sl    = PositionGetDouble(POSITION_SL);
        if(sl == 0) continue;  // FIX-2: skip posisi tanpa SL

        double entry = PositionGetDouble(POSITION_PRICE_OPEN);
        double price = PositionGetDouble(POSITION_PRICE_CURRENT);
        double tp    = PositionGetDouble(POSITION_TP);

        if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
        {
            // Breakeven: price >= entry + (entry-sl)*1.5 AND sl != entry
            if(price >= entry + (entry - sl) * 1.5 && sl != entry)
            {
                double new_sl = NormalizePrice(sym, entry);
                if(trade.PositionModify(ticket, new_sl, tp))
                    WriteLog("🔒 BREAKEVEN BUY " + sym + " Tiket:" + (string)ticket + " SL→" + DoubleToString(new_sl,5));
            }
            // Trailing: new_sl > sl AND new_sl > entry  (FIX-4)
            else if(price - trail > sl && price > entry)
            {
                double new_sl = NormalizePrice(sym, price - trail);
                if(new_sl > sl && new_sl > entry)
                    trade.PositionModify(ticket, new_sl, tp);
            }
        }
        else if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
        {
            // Breakeven: price <= entry - (sl-entry)*1.5 AND sl != entry
            if(price <= entry - (sl - entry) * 1.5 && sl != entry)
            {
                double new_sl = NormalizePrice(sym, entry);
                if(trade.PositionModify(ticket, new_sl, tp))
                    WriteLog("🔒 BREAKEVEN SELL " + sym + " Tiket:" + (string)ticket + " SL→" + DoubleToString(new_sl,5));
            }
            // Trailing: new_sl < sl AND new_sl < entry  (FIX-5)
            else if(price + trail < sl && price < entry)
            {
                double new_sl = NormalizePrice(sym, price + trail);
                if(new_sl < sl && new_sl < entry)
                    trade.PositionModify(ticket, new_sl, tp);
            }
        }
    }
}

// ==========================================
// 10. EXECUTION ENGINE
// Identik Python execute_trade()
// ==========================================
void ExecuteTrade(string sym, Decision &dec, int sym_idx)
{
    // Cooldown anti-overtrading (identik Python last_trade_time)
    if((int)(TimeCurrent() - LastTradeTime[sym_idx]) < InpCooldownSeconds) return;

    // Cek posisi terbuka (identik Python: positions_get check)
    for(int i = 0; i < PositionsTotal(); i++)
    {
        if(PositionGetSymbol(i) == sym &&
           PositionGetInteger(POSITION_MAGIC) == (long)InpMagicNumber) return;
    }

    // Spread filter (identik Python: sym_info.spread > get_spread_limit)
    int spread = (int)SymbolInfoInteger(sym, SYMBOL_SPREAD);
    if(spread > GetSpreadLimit(sym))
    {
        WriteLog("⚠️ Spread " + sym + " (" + (string)spread + ") > limit " + (string)GetSpreadLimit(sym) + ". Skip.");
        return;
    }

    double tick_size = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
    double price     = (dec.direction == "BUY") ? dec.ask : dec.bid;
    double sl        = (dec.direction == "BUY") ? dec.buy_sl : dec.sell_sl;

    // FIX-6: Normalisasi ke tick_size (identik Python normalize_price)
    price = NormalizePrice(sym, price);
    sl    = NormalizePrice(sym, sl);

    double sl_dist = MathAbs(price - sl);
    double min_sl  = SymbolInfoDouble(sym, SYMBOL_POINT) * 50.0;
    if(sl_dist < min_sl)
    {
        sl_dist = min_sl;
        sl = NormalizePrice(sym, (dec.direction == "BUY") ? (price - sl_dist) : (price + sl_dist));
    }

    double total_lot = StrictLotCalculator(sym, sl_dist);
    if(total_lot == 0)
    {
        WriteLog("⛔ SKIPPED: Equity $" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2) +
                 " tidak kuat risk " + DoubleToString(InpRiskPercent,1) + "% untuk " + sym);
        return;
    }

    double min_vol    = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
    double step       = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
    double layer_lot  = MathRound((total_lot / 3.0) / step) * step;
    int    num_layers = (layer_lot >= min_vol) ? 3 : 1;
    if(layer_lot < min_vol) layer_lot = total_lot;

    // TP identik Python: sl_dist*2, sl_dist*3, sl_dist*5
    double tps[3];
    if(dec.direction == "BUY")
    {
        tps[0] = NormalizePrice(sym, price + sl_dist * 2);
        tps[1] = NormalizePrice(sym, price + sl_dist * 3);
        tps[2] = NormalizePrice(sym, price + sl_dist * 5);
    }
    else
    {
        tps[0] = NormalizePrice(sym, price - sl_dist * 2);
        tps[1] = NormalizePrice(sym, price - sl_dist * 3);
        tps[2] = NormalizePrice(sym, price - sl_dist * 5);
    }

    WriteLog("⚡ V17 ULTIMATE MQL5 NATIVE! " + dec.direction + " " + sym +
             " | H4:" + dec.bias_h4 + " H1:" + dec.regime +
             " | Zone:" + dec.zone_src +
             " | Layers:" + (string)num_layers +
             " | Lot/Layer:" + DoubleToString(layer_lot,2));

    trade.SetExpertMagicNumber(InpMagicNumber);
    trade.SetDeviationInPoints(InpDeviation);
    // CTrade MQL5 otomatis mencoba semua filling mode → identik Python IOC→FOK→RETURN loop

    int success = 0;
    for(int i = 0; i < num_layers; i++)
    {
        double tp_target = (num_layers > 1) ? tps[i] : tps[0];
        bool   res       = false;

        if(dec.direction == "BUY")
            res = trade.Buy(layer_lot, sym, price, sl, tp_target, "V17_B_L" + (string)(i+1));
        else
            res = trade.Sell(layer_lot, sym, price, sl, tp_target, "V17_S_L" + (string)(i+1));

        if(res && trade.ResultRetcode() == TRADE_RETCODE_DONE)
        {
            int rr_arr[3] = {2, 3, 5};
            WriteLog("   ✅ L" + (string)(i+1) + " MASUK! Tiket:" + (string)trade.ResultOrder() +
                     " | TP:" + DoubleToString(tp_target,5) + " | RR 1:" + (string)rr_arr[i]);
            success++;
        }
        else
        {
            WriteLog("   ❌ L" + (string)(i+1) + " GAGAL! Code:" + (string)trade.ResultRetcode() +
                     " | " + trade.ResultComment());
        }
    }

    if(success > 0) LastTradeTime[sym_idx] = TimeCurrent();
}

// ==========================================
// 11. INIT
// ==========================================
int OnInit()
{
    trade.SetExpertMagicNumber(InpMagicNumber);
    trade.SetDeviationInPoints(InpDeviation);

    // Parse symbol list
    ushort sep = StringGetCharacter(",", 0);
    StringSplit(InpSymbols, sep, TargetSymbols);
    SymbolCount = ArraySize(TargetSymbols);

    int valid = 0;
    for(int i = 0; i < SymbolCount; i++)
    {
        StringTrimLeft(TargetSymbols[i]);
        StringTrimRight(TargetSymbols[i]);
        if(SymbolSelect(TargetSymbols[i], true)) valid++;
        else WriteLog("⚠️ Symbol tidak ditemukan di broker: " + TargetSymbols[i]);
    }
    if(valid == 0) { WriteLog("❌ Tidak ada pair valid."); return INIT_FAILED; }

    ArrayResize(LastStatusPrint, SymbolCount); ArrayInitialize(LastStatusPrint, 0);
    ArrayResize(LastTradeTime,   SymbolCount); ArrayInitialize(LastTradeTime, 0);

    // FIX-1: Null-safety equity_at_start
    double eq = AccountInfoDouble(ACCOUNT_EQUITY);
    EquityAtStart = (eq > 0) ? eq : 0.0;
    CurrentDay    = (int)TimeDay(TimeCurrent());

    WriteLog("✅ Active Symbols: " + InpSymbols);
    WriteLog("🤖 QUANTUM V17 ULTIMATE (NATIVE MQL5) LIVE.");
    WriteLog("Mode: 6-Layer | H4+H1 Bias | M15+M5 SMC | CB " +
             DoubleToString(InpMaxDailyLoss,1) + "% | Cooldown " +
             (string)InpCooldownSeconds + "s");

    EventSetMillisecondTimer(200);  // 0.2s loop identik Python time.sleep(0.2)
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    EventKillTimer();
    WriteLog("🛑 V17 Ultimate Aegis MQL5 dimatikan. Reason: " + (string)reason);
}

// ==========================================
// 12. SUPER-LOOP — OnTimer() @ 200ms
// Identik Python while True + time.sleep(0.2)
// ==========================================
void OnTimer()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);

    // ── Reset Circuit Breaker setiap ganti hari ──────────────────────────
    if(dt.day != CurrentDay)
    {
        double eq     = AccountInfoDouble(ACCOUNT_EQUITY);
        EquityAtStart = (eq > 0) ? eq : EquityAtStart;
        CurrentDay    = dt.day;
        WriteLog("🌅 Hari baru. Circuit Breaker direset. Equity awal: $" +
                 DoubleToString(EquityAtStart,2));
    }

    // ── Circuit Breaker ───────────────────────────────────────────────────
    if(EquityAtStart > 0)
    {
        double current_eq = AccountInfoDouble(ACCOUNT_EQUITY);
        double daily_dd   = ((EquityAtStart - current_eq) / EquityAtStart) * 100.0;

        if(daily_dd >= InpMaxDailyLoss)
        {
            if(TimeCurrent() - LastCircuitPrint > 300)
            {
                WriteLog("🛑 CIRCUIT BREAKER: Drawdown " + DoubleToString(daily_dd,2) +
                         "% >= " + DoubleToString(InpMaxDailyLoss,1) + "%. Bot dikunci hari ini.");
                LastCircuitPrint = TimeCurrent();
            }
            // Defense tetap jalan meski circuit breaker aktif
            for(int i = 0; i < SymbolCount; i++)
                ManageDefenses(TargetSymbols[i]);
            return;
        }
    }

    // ── Active Defense (selalu jalan) ─────────────────────────────────────
    for(int i = 0; i < SymbolCount; i++)
        ManageDefenses(TargetSymbols[i]);

    // ── Jam Trading ───────────────────────────────────────────────────────
    if(dt.hour < InpStartHour || dt.hour > InpEndHour) return;

    // ── Scan Semua Symbol (MQL5 C++ loop ~0.001s, tidak perlu threading) ──
    for(int i = 0; i < SymbolCount; i++)
    {
        string sym = TargetSymbols[i];

        // Ambil data tanpa ArraySetAsSeries → index 0=lama, n-1=baru
        MqlRates m1[], m5[], m15[], h1[], h4[];
        if(CopyRates(sym, PERIOD_M1,  0, 300, m1)  <= 0) continue;
        if(CopyRates(sym, PERIOD_M5,  0, 300, m5)  <= 0) continue;
        if(CopyRates(sym, PERIOD_M15, 0, 300, m15) <= 0) continue;
        if(CopyRates(sym, PERIOD_H1,  0, 300, h1)  <= 0) continue;
        if(CopyRates(sym, PERIOD_H4,  0, 300, h4)  <= 0) continue;
        // TIDAK ada ArraySetAsSeries di sini — ini kunci identik dengan Python

        Decision dec = CalculateUltimateLogic(sym, m1, m5, m15, h1, h4);

        if(dec.status == "BLOCKED")
        {
            if(TimeCurrent() - LastStatusPrint[i] > 60)
            {
                WriteLog("   [" + TimeToString(TimeCurrent(), TIME_SECONDS) + "] " +
                         sym + ": Memantau... (" + dec.reason + ")");
                LastStatusPrint[i] = TimeCurrent();
            }
        }
        else if(dec.status == "VALID_SETUP")
        {
            ExecuteTrade(sym, dec, i);
        }
    }
}
//+------------------------------------------------------------------+
