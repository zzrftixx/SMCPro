import MetaTrader5 as mt5
import pandas as pd
import pandas_ta as ta
import numpy as np
import time

# Konfigurasi dari Master Settings Pine Script-mu
TARGET_SYMBOLS = ["BTCUSDm", "XAUUSDm"] # Sesuaikan pair
RSI_LEN = 14
UT_KEY = 1
UT_PERIOD = 10
ST_FACTOR = 3.0
ST_PERIOD = 10
TP_MULT = 3.0
SL_MULT = 1.0

def init_broker():
    if not mt5.initialize():
        print(f"❌ Gagal inisialisasi MT5! Error: {mt5.last_error()}")
        return False
    return True

def get_data(symbol, timeframe, num_bars=500):
    rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, num_bars)
    if rates is None: return None
    df = pd.DataFrame(rates)
    df['time'] = pd.to_datetime(df['time'], unit='s')
    df.set_index('time', inplace=True)
    return df

def calculate_quantum_logic(df_main, df_h1, df_h4):
    """
    REPLIKASI 100% LOGIKA "QUANTUM NOVA PLATINUM V2" (BAGIAN 4 & 5).
    Menghitung Trend, Momentum, Proxy SMC, Final Score, dan TP/SL.
    """
    if df_main is None or df_h1 is None or df_h4 is None:
        return None

    # --- 1. TREND SCORE (Supertrend & MTF 3 EMA) ---
    # Kalkulasi SuperTrend
    st = ta.supertrend(df_main['high'], df_main['low'], df_main['close'], length=ST_PERIOD, multiplier=ST_FACTOR)
    is_st_bull = st[f'SUPERTd_{ST_PERIOD}_{ST_FACTOR}'].iloc[-1] == 1
    
    # Kalkulasi Trend H1 & H4 (EMA 50 & 200)
    ema50_h1, ema200_h1 = ta.ema(df_h1['close'], 50).iloc[-1], ta.ema(df_h1['close'], 200).iloc[-1]
    t_h1 = 1 if (df_h1['close'].iloc[-1] > ema50_h1 and ema50_h1 > ema200_h1) else -1 if (df_h1['close'].iloc[-1] < ema50_h1 and ema50_h1 < ema200_h1) else 0

    ema50_h4, ema200_h4 = ta.ema(df_h4['close'], 50).iloc[-1], ta.ema(df_h4['close'], 200).iloc[-1]
    t_h4 = 1 if (df_h4['close'].iloc[-1] > ema50_h4 and ema50_h4 > ema200_h4) else -1 if (df_h4['close'].iloc[-1] < ema50_h4 and ema50_h4 < ema200_h4) else 0

    score_trend = 0
    if is_st_bull: score_trend += 20
    if t_h1 == 1: score_trend += 10
    if t_h4 == 1: score_trend += 10
    if not is_st_bull: score_trend -= 20
    if t_h1 == -1: score_trend -= 10
    if t_h4 == -1: score_trend -= 10

    # --- 2. MOMENTUM SCORE (RSI & UT Bot Proxy) ---
    rsi_val = ta.rsi(df_main['close'], length=RSI_LEN).iloc[-1]
    
    # Proxy UT Bot menggunakan perhitungan volatilitas dasar
    atr_ut = ta.atr(df_main['high'], df_main['low'], df_main['close'], length=UT_PERIOD).iloc[-1]
    close_now = df_main['close'].iloc[-1]
    close_prev = df_main['close'].iloc[-2]
    ut_pos = 1 if close_now > (close_prev + (atr_ut * 0.1)) else -1 

    score_mom = 0
    if rsi_val > 50: score_mom += 10
    if ut_pos == 1: score_mom += 20
    if rsi_val < 50: score_mom -= 10
    if ut_pos == -1: score_mom -= 20

    # --- 3. SMC SCORE PROXY (Market Structure Bias) ---
    # Karena LuxAlgo di TradingView bergantung pada loop visual zigzag, 
    # kita gunakan Donchian Channel Breakout sebagai representasi matematika dari "Struktur"
    highest_20 = df_main['high'].rolling(20).max().iloc[-2]
    lowest_20 = df_main['low'].rolling(20).min().iloc[-2]
    
    lux_swing_bias = 1 if close_now > highest_20 else -1 if close_now < lowest_20 else 0
    
    score_smc = 0
    if lux_swing_bias == 1: score_smc += 20
    elif lux_swing_bias == -1: score_smc -= 20

    # --- 4. FINAL SCORE CALCULATION ---
    q_score = 50.0 + score_trend + score_mom + score_smc
    q_score = max(0, min(100, q_score)) 

    # --- 5. TP/SL CALCULATOR (Dynamic ATR) ---
    atr_14 = ta.atr(df_main['high'], df_main['low'], df_main['close'], length=14).iloc[-1]
    pred_stop_buy  = close_now - (atr_14 * SL_MULT)
    pred_target_buy = close_now + (atr_14 * TP_MULT)
    pred_stop_sell = close_now + (atr_14 * SL_MULT)
    pred_target_sell = close_now - (atr_14 * TP_MULT)

    est_profit_buy = ((pred_target_buy - close_now) / close_now) * 100
    est_profit_sell = ((close_now - pred_target_sell) / close_now) * 100

    # Decision Matrix
    if q_score >= 80: 
        action = "🔥 ZONA BUY (LONG)"
        tp, sl, est_prof = pred_target_buy, pred_stop_buy, est_profit_buy
    elif q_score <= 20: 
        action = "🩸 ZONA SELL (SHORT)"
        tp, sl, est_prof = pred_target_sell, pred_stop_sell, est_profit_sell
    else: 
        action = "⏳ WAITING (CHOPPY)"
        tp, sl, est_prof = 0, 0, 0

    return {
        "score": q_score, "action": action, "rsi": rsi_val, "trend_h1": t_h1,
        "tp": tp, "sl": sl, "est_prof": est_prof, "close": close_now
    }

if __name__ == "__main__":
    if not init_broker(): quit()
    
    print("🧠 QUANTUM NOVA PLATINUM ENGINE INITIALIZED...\n")
    
    for sym in TARGET_SYMBOLS:
        print(f"🔍 Mengumpulkan Data M15, H1, dan H4 untuk {sym}...")
        df_m15 = get_data(sym, mt5.TIMEFRAME_M15, 300) 
        df_h1 = get_data(sym, mt5.TIMEFRAME_H1, 300)   
        df_h4 = get_data(sym, mt5.TIMEFRAME_H4, 300)   
        
        result = calculate_quantum_logic(df_m15, df_h1, df_h4)
        
        if result:
            print("-" * 50)
            print(f"[{sym}] BLOOMBERG TERMINAL DASHBOARD")
            print("-" * 50)
            print(f"-> RSI (14)       : {result['rsi']:.2f}")
            print(f"-> Trend H1       : {'BULLISH 🟢' if result['trend_h1'] == 1 else 'BEARISH 🔴' if result['trend_h1'] == -1 else 'NEUTRAL ⚫'}")
            print(f"-> QUANTUM SCORE  : {result['score']}/100")
            print(f"-> AI PREDICTION  : {result['action']}")
            
            if result['score'] >= 80 or result['score'] <= 20:
                print(f"-> TARGET ENTRY   : {result['close']}")
                print(f"-> TAKE PROFIT    : {result['tp']:.5f} (+{result['est_prof']:.2f}%)")
                print(f"-> STOP LOSS      : {result['sl']:.5f}")
            print("-" * 50 + "\n")
        
    mt5.shutdown()