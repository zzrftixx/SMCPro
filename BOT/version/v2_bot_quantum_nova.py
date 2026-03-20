import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import time
from datetime import datetime

# ==========================================
# 1. KONFIGURASI MASTER QUANTUM NOVA
# ==========================================
POSSIBLE_SYMBOLS = ["BTCUSDm", "XAUUSDm", "BTCUSDr", "XAUUSDr", "BTCUSD", "XAUUSD", "#BTCUSD", "#BTCUSDr", "XAUUSDb", "XAUUSDc", "BTCUSDc"] # Sesuaikan dengan broker
RISK_PERCENT = 1.0 # Total risiko maksimal 1% dari Equity per setup
MAGIC_NUMBER = 999111
DEVIATION = 20

# Parameter Indikator
RSI_LEN = 14
UT_PERIOD = 10
ST_FACTOR = 3.0
ST_PERIOD = 10
SL_MULT = 1.0 # Jarak Stop Loss (1x ATR)

# ==========================================
# 2. NATIVE MATH ENGINE
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
    
    supertrend = [True] * len(df)
    
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
# 4. QUANTUM AI ENGINE (SCORING)
# ==========================================
def calculate_quantum_logic(df_main, df_h1, df_h4):
    if df_main is None or df_h1 is None or df_h4 is None: return None

    # Trend Score
    st_list = calc_supertrend(df_main, period=ST_PERIOD, multiplier=ST_FACTOR)
    is_st_bull = st_list[-1] == True
    
    ema50_h1, ema200_h1 = calc_ema(df_h1['close'], 50).iloc[-1], calc_ema(df_h1['close'], 200).iloc[-1]
    t_h1 = 1 if (df_h1['close'].iloc[-1] > ema50_h1 and ema50_h1 > ema200_h1) else -1 if (df_h1['close'].iloc[-1] < ema50_h1 and ema50_h1 < ema200_h1) else 0

    ema50_h4, ema200_h4 = calc_ema(df_h4['close'], 50).iloc[-1], calc_ema(df_h4['close'], 200).iloc[-1]
    t_h4 = 1 if (df_h4['close'].iloc[-1] > ema50_h4 and ema50_h4 > ema200_h4) else -1 if (df_h4['close'].iloc[-1] < ema50_h4 and ema50_h4 < ema200_h4) else 0

    score_trend = 20 if is_st_bull else -20
    score_trend += (10 * t_h1) + (10 * t_h4)

    # Momentum Score
    rsi_val = calc_rsi(df_main['close'], length=RSI_LEN).iloc[-1]
    atr_ut = calc_atr(df_main, length=UT_PERIOD).iloc[-1]
    close_now, close_prev = df_main['close'].iloc[-1], df_main['close'].iloc[-2]
    ut_pos = 1 if close_now > (close_prev + (atr_ut * 0.1)) else -1 

    score_mom = (10 if rsi_val > 50 else -10) + (20 if ut_pos == 1 else -20)

    # SMC Structure Proxy
    highest_20 = df_main['high'].rolling(20).max().iloc[-2]
    lowest_20 = df_main['low'].rolling(20).min().iloc[-2]
    score_smc = 20 if close_now > highest_20 else -20 if close_now < lowest_20 else 0

    # Final Math
    q_score = max(0, min(100, 50.0 + score_trend + score_mom + score_smc))

    # Dynamic SL Base (Mengembalikan ATR mentah untuk kebutuhan Layering)
    atr_14 = calc_atr(df_main, length=14).iloc[-1]
    
    return {
        "score": q_score,
        "close": close_now,
        "atr": atr_14,
        "buy_sl": close_now - (atr_14 * SL_MULT),
        "sell_sl": close_now + (atr_14 * SL_MULT)
    }

# ==========================================
# 5. KALKULATOR LOT DINAMIS
# ==========================================
def calculate_dynamic_lot(symbol, sl_price_distance, risk_percent):
    account_info = mt5.account_info()
    symbol_info = mt5.symbol_info(symbol)
    
    if account_info is None or symbol_info is None:
        print(f"   ⚠️ Gagal menarik data akun. Fallback ke Lot minimum.")
        return symbol_info.volume_min if symbol_info else 0.01

    equity = account_info.equity
    risk_money = equity * (risk_percent / 100.0) 
    
    tick_size = symbol_info.trade_tick_size
    tick_value = symbol_info.trade_tick_value
    
    sl_ticks = sl_price_distance / tick_size
    if sl_ticks <= 0: return symbol_info.volume_min
        
    loss_per_lot = sl_ticks * tick_value
    if loss_per_lot <= 0: return symbol_info.volume_min
        
    raw_lot = risk_money / loss_per_lot
    return raw_lot

# ==========================================
# 6. MODUL EKSEKUSI (SCALE-OUT LAYERING)
# ==========================================
def execute_trade(symbol, decision_data):
    score = decision_data['score']
    
    open_positions = mt5.positions_get(symbol=symbol, magic=MAGIC_NUMBER)
    if open_positions is not None and len(open_positions) > 0:
        print(f"   🛡️ {symbol}: Menahan pelatuk. Eksekusi Layer sebelumnya masih berjalan.")
        return

    # Kalkulasi Jarak SL untuk menghitung Total Lot 1% Risiko
    sl_distance = abs(decision_data['close'] - decision_data['buy_sl']) if score >= 80 else abs(decision_data['close'] - decision_data['sell_sl'])
    
    total_dynamic_lot = calculate_dynamic_lot(symbol, sl_distance, RISK_PERCENT)
    
    symbol_info = mt5.symbol_info(symbol)
    min_lot = symbol_info.volume_min
    step_lot = symbol_info.volume_step

    # Pecah Lot menjadi 3 peluru
    layer_lot = round((total_dynamic_lot / 3) / step_lot) * step_lot
    
    if layer_lot < min_lot:
        print(f"   ⚠️ Margin/Ekuitas belum cukup untuk Layering. Beralih ke Single Entry {min_lot} Lot.")
        layer_lot = min_lot
        num_layers = 1
    else:
        num_layers = 3

    atr = decision_data['atr']

    if score >= 80:
        order_type = mt5.ORDER_TYPE_BUY
        price = mt5.symbol_info_tick(symbol).ask
        sl = decision_data['buy_sl']
        tps = [price + (atr * 1.0), price + (atr * 2.0), price + (atr * 3.0)]
        direction = "BUY"
    elif score <= 20:
        order_type = mt5.ORDER_TYPE_SELL
        price = mt5.symbol_info_tick(symbol).bid
        sl = decision_data['sell_sl']
        tps = [price - (atr * 1.0), price - (atr * 2.0), price - (atr * 3.0)]
        direction = "SELL"
    else:
        print(f"   ⏳ {symbol}: Skor {score}/100. Market berisik, tidak ada konfirmasi.")
        return

    print(f"   🚀 SKOR {score}/100: EKSEKUSI {direction} {symbol} DENGAN {num_layers} LAYER!")
    print(f"   ⚖️ Target Risiko: {RISK_PERCENT}% Equity. Lot per Layer: {layer_lot:.2f}")

    # Tembak semua layer
    for i in range(num_layers):
        request = {
            "action": mt5.TRADE_ACTION_DEAL,
            "symbol": symbol,
            "volume": float(layer_lot),
            "type": order_type,
            "price": price,
            "sl": sl,
            "tp": tps[i],
            "deviation": DEVIATION,
            "magic": MAGIC_NUMBER,
            "comment": f"QNova_Layer_{i+1}",
            "type_time": mt5.ORDER_TIME_GTC,
        }

        success = False
        for filling in [mt5.ORDER_FILLING_FOK, mt5.ORDER_FILLING_IOC, mt5.ORDER_FILLING_RETURN]:
            request["type_filling"] = filling
            result = mt5.order_send(request)
            if result.retcode == mt5.TRADE_RETCODE_DONE:
                print(f"   ✅ LAYER {i+1} MASUK! Tiket: {result.order} | SL: {sl:.4f} | TP: {tps[i]:.4f}")
                success = True
                break
                
        if not success:
            print(f"   ❌ Gagal mengeksekusi Layer {i+1}. Error Code: {result.retcode}")

# ==========================================
# 7. MAIN LOOP OPERASIONAL
# ==========================================
if __name__ == "__main__":
    if not init_broker(): quit()
    
    print("🤖 TERMINAL QUANTUM NOVA PLATINUM LIVE (NATIVE + LAYER SCALE-OUT). Memburu target...\n")
    
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
            
            # Tidur 5 menit
            time.sleep(300) 
            
    except KeyboardInterrupt:
        print("\n🛑 Sistem Quantum dimatikan secara manual.")
        mt5.shutdown()