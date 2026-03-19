import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import time
from datetime import datetime

# ==========================================
# 1. KONFIGURASI MASTER QUANTUM NOVA
# ==========================================
TARGET_SYMBOLS = ["BTCUSDm", "XAUUSDm"] # Wajib sesuai penulisan broker
LOT_SIZE = 0.01
MAGIC_NUMBER = 999111
DEVIATION = 20

# Parameter Indikator
RSI_LEN = 14
UT_PERIOD = 10
ST_FACTOR = 3.0
ST_PERIOD = 10
TP_MULT = 3.0
SL_MULT = 1.0

# ==========================================
# 2. NATIVE MATH ENGINE (PENGGANTI PANDAS-TA)
# ==========================================
def calc_ema(series, length):
    return series.ewm(span=length, adjust=False).mean()

def calc_rsi(series, length=14):
    delta = series.diff()
    gain = (delta.where(delta > 0, 0)).rolling(window=length).mean()
    loss = (-delta.where(delta < 0, 0)).rolling(window=length).mean()
    rs = gain / loss
    return 100 - (100 / (1 + rs))

def calc_atr(df, length=10):
    high_low = df['high'] - df['low']
    high_close = np.abs(df['high'] - df['close'].shift())
    low_close = np.abs(df['low'] - df['close'].shift())
    tr = pd.concat([high_low, high_close, low_close], axis=1).max(axis=1)
    return tr.rolling(window=length).mean()

def calc_supertrend(df, period=10, multiplier=3.0):
    atr = calc_atr(df, period)
    hl2 = (df['high'] + df['low']) / 2
    final_upperband = hl2 + (multiplier * atr)
    final_lowerband = hl2 - (multiplier * atr)
    
    supertrend = [True] * len(df) # True = Bullish, False = Bearish
    
    for i in range(1, len(df)):
        curr_close = df['close'].iloc[i]
        
        if curr_close > final_upperband.iloc[i-1]:
            supertrend[i] = True
        elif curr_close < final_lowerband.iloc[i-1]:
            supertrend[i] = False
        else:
            supertrend[i] = supertrend[i-1]
            if supertrend[i] == True and final_lowerband.iloc[i] < final_lowerband.iloc[i-1]:
                final_lowerband.iloc[i] = final_lowerband.iloc[i-1]
            if supertrend[i] == False and final_upperband.iloc[i] > final_upperband.iloc[i-1]:
                final_upperband.iloc[i] = final_upperband.iloc[i-1]
    return supertrend

# ==========================================
# 3. MODUL KONEKSI & DATA FEED
# ==========================================
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

# ==========================================
# 4. QUANTUM AI ENGINE (SCORING & TP/SL)
# ==========================================
def calculate_quantum_logic(df_main, df_h1, df_h4):
    if df_main is None or df_h1 is None or df_h4 is None: return None

    # Trend Score (Native)
    st_list = calc_supertrend(df_main, period=ST_PERIOD, multiplier=ST_FACTOR)
    is_st_bull = st_list[-1] == True
    
    ema50_h1, ema200_h1 = calc_ema(df_h1['close'], 50).iloc[-1], calc_ema(df_h1['close'], 200).iloc[-1]
    t_h1 = 1 if (df_h1['close'].iloc[-1] > ema50_h1 and ema50_h1 > ema200_h1) else -1 if (df_h1['close'].iloc[-1] < ema50_h1 and ema50_h1 < ema200_h1) else 0

    ema50_h4, ema200_h4 = calc_ema(df_h4['close'], 50).iloc[-1], calc_ema(df_h4['close'], 200).iloc[-1]
    t_h4 = 1 if (df_h4['close'].iloc[-1] > ema50_h4 and ema50_h4 > ema200_h4) else -1 if (df_h4['close'].iloc[-1] < ema50_h4 and ema50_h4 < ema200_h4) else 0

    score_trend = 20 if is_st_bull else -20
    score_trend += (10 * t_h1) + (10 * t_h4)

    # Momentum Score (Native)
    rsi_val = calc_rsi(df_main['close'], length=RSI_LEN).iloc[-1]
    atr_ut = calc_atr(df_main, length=UT_PERIOD).iloc[-1]
    close_now, close_prev = df_main['close'].iloc[-1], df_main['close'].iloc[-2]
    ut_pos = 1 if close_now > (close_prev + (atr_ut * 0.1)) else -1 

    score_mom = (10 if rsi_val > 50 else -10) + (20 if ut_pos == 1 else -20)

    # SMC Structure Proxy (Native)
    highest_20 = df_main['high'].rolling(20).max().iloc[-2]
    lowest_20 = df_main['low'].rolling(20).min().iloc[-2]
    score_smc = 20 if close_now > highest_20 else -20 if close_now < lowest_20 else 0

    # Final Math
    q_score = max(0, min(100, 50.0 + score_trend + score_mom + score_smc))

    # Dynamic TP/SL (ATR-based Native)
    atr_14 = calc_atr(df_main, length=14).iloc[-1]
    
    return {
        "score": q_score,
        "close": close_now,
        "buy_tp": close_now + (atr_14 * TP_MULT),
        "buy_sl": close_now - (atr_14 * SL_MULT),
        "sell_tp": close_now - (atr_14 * TP_MULT),
        "sell_sl": close_now + (atr_14 * SL_MULT)
    }

# ==========================================
# 5. MODUL EKSEKUSI TAHAN BANTING
# ==========================================
def execute_trade(symbol, decision_data):
    score = decision_data['score']
    
    open_positions = mt5.positions_get(symbol=symbol, magic=MAGIC_NUMBER)
    if open_positions is not None and len(open_positions) > 0:
        print(f"   🛡️ {symbol}: Menahan pelatuk. Posisi lama masih berjalan.")
        return

    if score >= 80:
        order_type = mt5.ORDER_TYPE_BUY
        price = mt5.symbol_info_tick(symbol).ask
        sl, tp = decision_data['buy_sl'], decision_data['buy_tp']
        print(f"   🚀 SKOR {score}/100: MENGUNGKAP JEJAK BANDAR. EKSEKUSI BUY {symbol}!")
    elif score <= 20:
        order_type = mt5.ORDER_TYPE_SELL
        price = mt5.symbol_info_tick(symbol).bid
        sl, tp = decision_data['sell_sl'], decision_data['sell_tp']
        print(f"   🩸 SKOR {score}/100: MENGUNGKAP JEJAK BANDAR. EKSEKUSI SELL {symbol}!")
    else:
        print(f"   ⏳ {symbol}: Skor {score}/100. Market berisik, tidak ada konfirmasi.")
        return

    request = {
        "action": mt5.TRADE_ACTION_DEAL,
        "symbol": symbol,
        "volume": LOT_SIZE,
        "type": order_type,
        "price": price,
        "sl": sl,
        "tp": tp,
        "deviation": DEVIATION,
        "magic": MAGIC_NUMBER,
        "comment": "Quantum_Native_AI",
        "type_time": mt5.ORDER_TIME_GTC,
    }

    for filling in [mt5.ORDER_FILLING_FOK, mt5.ORDER_FILLING_IOC, mt5.ORDER_FILLING_RETURN]:
        request["type_filling"] = filling
        result = mt5.order_send(request)
        if result.retcode == mt5.TRADE_RETCODE_DONE:
            print(f"   ✅ TIKET TERCETAK! Order: {result.order} | Harga: {price} | SL: {sl:.4f} | TP: {tp:.4f}")
            return
        elif result.retcode != 10030:
            print(f"   ❌ Gagal Eksekusi. Error: {result.retcode} - {result.comment}")
            return
            
    print("   ❌ Order gagal total. Broker menolak eksekusi.")

# ==========================================
# 6. MAIN LOOP OPERASIONAL
# ==========================================
if __name__ == "__main__":
    if not init_broker(): quit()
    
    print("🤖 TERMINAL QUANTUM NOVA PLATINUM LIVE (NATIVE ENGINE). Memburu anomali harga...\n")
    
    try:
        while True:
            current_time = datetime.now().strftime("%H:%M:%S")
            print(f"\n[{current_time}] Memindai matriks pasar...")
            
            for sym in TARGET_SYMBOLS:
                info = mt5.symbol_info(sym)
                if info is None or not info.visible: continue
                
                df_m15 = get_data(sym, mt5.TIMEFRAME_M15, 300)
                df_h1 = get_data(sym, mt5.TIMEFRAME_H1, 300)
                df_h4 = get_data(sym, mt5.TIMEFRAME_H4, 300)
                
                decision = calculate_quantum_logic(df_m15, df_h1, df_h4)
                if decision:
                    execute_trade(sym, decision)
            
            # Bot tidur 5 menit, karena perhitungan base kita ada di timeframe M15/H1. 
            time.sleep(300) 
            
    except KeyboardInterrupt:
        print("\n🛑 Sistem Quantum dimatikan secara manual.")
        mt5.shutdown()