import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import time
from datetime import datetime

# ==========================================
# 1. KONFIGURASI MASTER QUANTUM NOVA (V5 DAILY SCALPER)
# ==========================================
POSSIBLE_SYMBOLS = ["BTCUSDm", "XAUUSDm", "BTCUSDr", "XAUUSDr", "BTCUSD", "XAUUSD", "#BTCUSD", "#BTCUSDr", "XAUUSDb", "XAUUSDc", "BTCUSDc"] 
TARGET_SYMBOLS = [] # Biarkan kosong, akan diisi otomatis oleh mesin
RISK_PERCENT = 1.0 
MAGIC_NUMBER = 999111
DEVIATION = 20

# Filter Sesi & Keamanan Broker
START_HOUR = 0
END_HOUR = 23
MAX_SPREAD_POINTS = 500 # Pastikan broker tidak sedang scamming

# Parameter Indikator
RSI_LEN = 14
UT_PERIOD = 10
ST_FACTOR = 3.0
ST_PERIOD = 10
SL_MULT = 1.5 # Diperlebar sedikit ke 1.5 ATR karena noise di M1 lebih liar

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
        if curr_close > final_upperband.iloc[i-1]: supertrend[i] = True
        elif curr_close < final_lowerband.iloc[i-1]: supertrend[i] = False
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
    if not mt5.initialize(): return False
    return True

def get_data(symbol, timeframe, num_bars=500):
    rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, num_bars)
    if rates is None: return None
    df = pd.DataFrame(rates)
    df['time'] = pd.to_datetime(df['time'], unit='s')
    df.set_index('time', inplace=True)
    return df

# ==========================================
# 4. QUANTUM AI ENGINE (SCALPING LOGIC)
# ==========================================
def calculate_quantum_logic(df_main, df_tf2, df_tf3):
    """
    df_main = M1 (Trigger)
    df_tf2 = M15 (Minor Trend)
    df_tf3 = H1 (Mayor Trend)
    """
    if df_main is None or df_tf2 is None or df_tf3 is None: return None

    # Trend Score: Supertrend di M1
    st_list = calc_supertrend(df_main, period=ST_PERIOD, multiplier=ST_FACTOR)
    is_st_bull = st_list[-1] == True
    
    # Trend M15
    ema50_tf2, ema200_tf2 = calc_ema(df_tf2['close'], 50).iloc[-1], calc_ema(df_tf2['close'], 200).iloc[-1]
    t_tf2 = 1 if (df_tf2['close'].iloc[-1] > ema50_tf2 and ema50_tf2 > ema200_tf2) else -1 if (df_tf2['close'].iloc[-1] < ema50_tf2 and ema50_tf2 < ema200_tf2) else 0

    # Trend H1
    ema50_tf3, ema200_tf3 = calc_ema(df_tf3['close'], 50).iloc[-1], calc_ema(df_tf3['close'], 200).iloc[-1]
    t_tf3 = 1 if (df_tf3['close'].iloc[-1] > ema50_tf3 and ema50_tf3 > ema200_tf3) else -1 if (df_tf3['close'].iloc[-1] < ema50_tf3 and ema50_tf3 < ema200_tf3) else 0

    score_trend = 20 if is_st_bull else -20
    score_trend += (10 * t_tf2) + (10 * t_tf3)

    # Momentum Score di M1 (Sangat Sensitif)
    rsi_val = calc_rsi(df_main['close'], length=RSI_LEN).iloc[-1]
    atr_ut = calc_atr(df_main, length=UT_PERIOD).iloc[-1]
    close_now, close_prev = df_main['close'].iloc[-1], df_main['close'].iloc[-2]
    ut_pos = 1 if close_now > (close_prev + (atr_ut * 0.1)) else -1 

    # Area diskon di M1 lebih agresif
    score_mom = (10 if rsi_val > 50 else -10) + (20 if ut_pos == 1 else -20)

    # SMC Structure Proxy di M1
    highest_20 = df_main['high'].rolling(20).max().iloc[-2]
    lowest_20 = df_main['low'].rolling(20).min().iloc[-2]
    score_smc = 20 if close_now > highest_20 else -20 if close_now < lowest_20 else 0

    q_score = max(0, min(100, 50.0 + score_trend + score_mom + score_smc))
    atr_14 = calc_atr(df_main, length=14).iloc[-1]
    
    return {
        "score": q_score,
        "close": close_now,
        "atr": atr_14,
        "buy_sl": close_now - (atr_14 * SL_MULT),
        "sell_sl": close_now + (atr_14 * SL_MULT)
    }

def calculate_dynamic_lot(symbol, sl_price_distance, risk_percent):
    account_info = mt5.account_info()
    symbol_info = mt5.symbol_info(symbol)
    if account_info is None or symbol_info is None: return 0.01

    equity = account_info.equity
    risk_money = equity * (risk_percent / 100.0) 
    sl_ticks = sl_price_distance / symbol_info.trade_tick_size
    if sl_ticks <= 0: return symbol_info.volume_min
        
    loss_per_lot = sl_ticks * symbol_info.trade_tick_value
    if loss_per_lot <= 0: return symbol_info.volume_min
        
    return risk_money / loss_per_lot

# ==========================================
# 5. DEFENSE PROTOCOL (SCALPING ADJUSTED)
# ==========================================
def manage_defenses(symbol, current_atr):
    positions = mt5.positions_get(symbol=symbol, magic=MAGIC_NUMBER)
    if positions is None or len(positions) == 0: return

    for pos in positions:
        entry_price = pos.price_open
        current_sl = pos.sl
        current_price = pos.price_current
        
        trail_distance = current_atr * 2.0 # Agak dijauhkan agar tidak tersapu noise M1
        
        if pos.type == mt5.ORDER_TYPE_BUY:
            if current_price >= entry_price + (entry_price - current_sl):
                if current_sl < entry_price: 
                    request = {"action": mt5.TRADE_ACTION_SLTP, "position": pos.ticket, "symbol": symbol, "sl": entry_price, "tp": pos.tp}
                    mt5.order_send(request)
            
            if current_price - trail_distance > current_sl and current_price > entry_price:
                new_sl = current_price - trail_distance
                if new_sl > entry_price: 
                    request = {"action": mt5.TRADE_ACTION_SLTP, "position": pos.ticket, "symbol": symbol, "sl": new_sl, "tp": pos.tp}
                    mt5.order_send(request)

        elif pos.type == mt5.ORDER_TYPE_SELL:
            if current_price <= entry_price - (current_sl - entry_price):
                if current_sl > entry_price or current_sl == 0:
                    request = {"action": mt5.TRADE_ACTION_SLTP, "position": pos.ticket, "symbol": symbol, "sl": entry_price, "tp": pos.tp}
                    mt5.order_send(request)
            
            if current_price + trail_distance < current_sl and current_price < entry_price:
                new_sl = current_price + trail_distance
                if new_sl < entry_price:
                    request = {"action": mt5.TRADE_ACTION_SLTP, "position": pos.ticket, "symbol": symbol, "sl": new_sl, "tp": pos.tp}
                    mt5.order_send(request)

# ==========================================
# 6. MODUL EKSEKUSI (DENGAN SPREAD FILTER)
# ==========================================
def execute_trade(symbol, decision_data):
    symbol_info = mt5.symbol_info(symbol)
    if symbol_info.spread > MAX_SPREAD_POINTS:
        print(f"   ⚠️ SPREAD {symbol} TERLALU LEBAR ({symbol_info.spread} pts). Bahaya Scalping!")
        return

    score = decision_data['score']
    
    open_positions = mt5.positions_get(symbol=symbol, magic=MAGIC_NUMBER)
    if open_positions is not None and len(open_positions) > 0:
        return

    sl_distance = abs(decision_data['close'] - decision_data['buy_sl']) if score >= 80 else abs(decision_data['close'] - decision_data['sell_sl'])
    total_dynamic_lot = calculate_dynamic_lot(symbol, sl_distance, RISK_PERCENT)
    
    min_lot = symbol_info.volume_min
    step_lot = symbol_info.volume_step

    layer_lot = round((total_dynamic_lot / 3) / step_lot) * step_lot
    if layer_lot < min_lot:
        layer_lot = min_lot
        num_layers = 1
    else:
        num_layers = 3

    atr = decision_data['atr']

    if score >= 80:
        order_type = mt5.ORDER_TYPE_BUY
        price = mt5.symbol_info_tick(symbol).ask
        sl = decision_data['buy_sl']
        tps = [price + (atr * 1.5), price + (atr * 3.0), 0.0] 
        direction = "BUY"
    elif score <= 20:
        order_type = mt5.ORDER_TYPE_SELL
        price = mt5.symbol_info_tick(symbol).bid
        sl = decision_data['sell_sl']
        tps = [price - (atr * 1.5), price - (atr * 3.0), 0.0]
        direction = "SELL"
    else:
        return

    print(f"\n   🚀 MENGUNGKAP JEJAK BANDAR (M1 SNIPER)! EKSEKUSI {direction} {symbol} ({num_layers} LAYER)")
    
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
            "comment": f"QNova_L{i+1}",
            "type_time": mt5.ORDER_TIME_GTC,
        }

        for filling in [mt5.ORDER_FILLING_FOK, mt5.ORDER_FILLING_IOC, mt5.ORDER_FILLING_RETURN]:
            request["type_filling"] = filling
            result = mt5.order_send(request)
            if result.retcode == mt5.TRADE_RETCODE_DONE:
                tp_str = f"{tps[i]:.4f}" if tps[i] != 0.0 else "OPEN (Trailing Active)"
                print(f"      ✅ LAYER {i+1} MASUK! Tiket: {result.order} | TP: {tp_str}")
                break

# ==========================================
# 7. MAIN LOOP OPERASIONAL (HYPER-ACTIVE)
# ==========================================
if __name__ == "__main__":
    if not init_broker(): quit()
    
    # =========================================================
    # SUNTIKAN SENSOR BROKER (HANYA DIEKSEKUSI 1X SAAT START)
    # =========================================================
    print("🔄 Melakukan Scanning Pair Aktif di Broker...")
    for sym in POSSIBLE_SYMBOLS: # Pastikan kamu sudah ubah TARGET_SYMBOLS jadi POSSIBLE_SYMBOLS di atas ya!
        info = mt5.symbol_info(sym)
        if info is not None and info.visible:
            TARGET_SYMBOLS.append(sym)
            
    if not TARGET_SYMBOLS:
        print("❌ ERROR: Tidak ada pair yang valid di broker ini.")
        mt5.shutdown()
        quit()
        
    print(f"✅ Broker dikenali. Pair Aktif Siap Tempur: {TARGET_SYMBOLS}")
    # =========================================================

    print("\n🤖 TERMINAL QUANTUM NOVA V5 (DAILY SCALPER EDITION).")
    print("Radar disetel ke M1, M15, dan H1. Scan rate: 20 detik.\n")
    
    try:
        while True:
            # PERBAIKAN PENGAMBILAN WAKTU AGAR TIDAK ERROR NONETYPE
            tick = mt5.symbol_info_tick(TARGET_SYMBOLS[0])
            if tick is None: 
                time.sleep(2) # Kasih napas 2 detik kalau MT5 belum siap
                continue
                
            server_time = tick.time
            current_hour = datetime.fromtimestamp(server_time).hour
            
            for sym in TARGET_SYMBOLS:
                rates = mt5.copy_rates_from_pos(sym, mt5.TIMEFRAME_M1, 0, 20)
                if rates is not None:
                    df_temp = pd.DataFrame(rates)
                    current_atr = calc_atr(df_temp, 14).iloc[-1]
                    manage_defenses(sym, current_atr)
                
            if current_hour < START_HOUR or current_hour > END_HOUR:
                print(f"[{datetime.now().strftime('%H:%M:%S')}] 💤 Di luar Killzone. Menolak berburu.")
                time.sleep(60)
                continue
                
            print(f"[{datetime.now().strftime('%H:%M:%S')}] ⚡ Memindai matriks pasar (M1/M15/H1)...")
            
            for sym in TARGET_SYMBOLS:
                info = mt5.symbol_info(sym)
                if info is None or not info.visible: continue
                
                # TARIK DATA TIMEFRAME CEPAT
                df_m1 = get_data(sym, mt5.TIMEFRAME_M1, 300)
                df_m15 = get_data(sym, mt5.TIMEFRAME_M15, 300)
                df_h1 = get_data(sym, mt5.TIMEFRAME_H1, 300)
                
                decision = calculate_quantum_logic(df_m1, df_m15, df_h1)
                if decision:
                    if decision['score'] >= 80 or decision['score'] <= 20:
                        execute_trade(sym, decision)
            
            # Waktu scan dipercepat menjadi 20 detik agar presisi di M1
            time.sleep(20) 
            
    except KeyboardInterrupt:
        print("\n🛑 Sistem Quantum dimatikan secara manual.")
        mt5.shutdown()