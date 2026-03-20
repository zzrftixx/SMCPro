import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import time
from datetime import datetime

# ==========================================
# 1. KONFIGURASI MASTER (V9 APEX HYBRID)
# ==========================================
# Pastikan akhiran Cent (c) atau Micro sudah dimasukkan
POSSIBLE_SYMBOLS = ["BTCUSDm", "XAUUSDm", "BTCUSDr", "XAUUSDr", "BTCUSD", "XAUUSD", "#BTCUSD", "XAUUSDc", "BTCUSDc"]
TARGET_SYMBOLS = [] 

RISK_PERCENT = 1.0 
MAGIC_NUMBER = 999000
DEVIATION = 10 

START_HOUR = 8
END_HOUR = 23

# Parameter Hybrid (SMC + Fast Trend + Momentum Trigger)
FAST_EMA_1 = 21
FAST_EMA_2 = 34
RSI_LEN = 14

# ==========================================
# 2. NATIVE MATH & SMC ENGINE
# ==========================================
def calc_ema(series, length):
    return series.ewm(span=length, adjust=False).mean()

def calc_rsi(series, length=14):
    delta = series.diff()
    gain = (delta.where(delta > 0, 0)).rolling(window=length).mean()
    loss = (-delta.where(delta < 0, 0)).rolling(window=length).mean()
    rs = gain / loss
    return 100 - (100 / (1 + rs))

def calc_atr(df, length=14):
    high_low = df['high'] - df['low']
    high_close = np.abs(df['high'] - df['close'].shift())
    low_close = np.abs(df['low'] - df['close'].shift())
    tr = pd.concat([high_low, high_close, low_close], axis=1).max(axis=1)
    return tr.rolling(window=length).mean()

def detect_unmitigated_ob(df):
    bull_ob, bear_ob = None, None
    atr = calc_atr(df, 14)

    for i in range(len(df)-2, 10, -1):
        body = abs(df['close'].iloc[i] - df['open'].iloc[i])
        is_imbalance = body > (atr.iloc[i] * 1.8) 

        if is_imbalance and bull_ob is None:
            if df['close'].iloc[i] > df['open'].iloc[i]: 
                for j in range(i-1, max(0, i-8), -1):
                    if df['close'].iloc[j] < df['open'].iloc[j]: 
                        top = max(df['open'].iloc[j], df['close'].iloc[j])
                        btm = df['low'].iloc[j]
                        if df['low'].iloc[i:].min() > top: 
                            bull_ob = {'top': top, 'bottom': btm}
                            break

        if is_imbalance and bear_ob is None:
            if df['close'].iloc[i] < df['open'].iloc[i]: 
                for j in range(i-1, max(0, i-8), -1):
                    if df['close'].iloc[j] > df['open'].iloc[j]: 
                        top = df['high'].iloc[j]
                        btm = min(df['open'].iloc[j], df['close'].iloc[j])
                        if df['high'].iloc[i:].max() < btm: 
                            bear_ob = {'top': top, 'bottom': btm}
                            break
                            
        if bull_ob and bear_ob: break
            
    return bull_ob, bear_ob

# ==========================================
# 3. MODUL KONEKSI & DATA FEED
# ==========================================
def init_broker():
    if not mt5.initialize(): return False
    return True

def get_data(symbol, timeframe, num_bars=300):
    rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, num_bars)
    if rates is None: return None
    df = pd.DataFrame(rates)
    df['time'] = pd.to_datetime(df['time'], unit='s')
    df.set_index('time', inplace=True)
    return df

# ==========================================
# 4. DIVISI TEKNIKAL & SCORING (THE APEX LOGIC)
# ==========================================
def calculate_apex_logic(df_m1, df_m15, df_h1):
    if df_m1 is None or df_m15 is None or df_h1 is None: return None

    # 1. DAY TREND FILTER (H1)
    ema_fast = calc_ema(df_h1['close'], FAST_EMA_1).iloc[-1]
    ema_slow = calc_ema(df_h1['close'], FAST_EMA_2).iloc[-1]
    close_h1 = df_h1['close'].iloc[-1]

    day_bullish = close_h1 > ema_fast > ema_slow
    day_bearish = close_h1 < ema_fast < ema_slow

    if not day_bullish and not day_bearish: return {"status": "NO_TREND"}

    # 2. INSTITUTIONAL ZONE (M15)
    bull_ob, bear_ob = detect_unmitigated_ob(df_m15)
    
    # 3. SNIPER TRIGGER (M1)
    close_m1 = df_m1['close'].iloc[-1]
    rsi_m1 = calc_rsi(df_m1['close'], RSI_LEN).iloc[-1]
    
    q_score, buy_sl, sell_sl = 50, 0, 0

    # APEX BULLISH ENTRY: Searah H1 + Masuk Kotak OB M15 + M1 Sedang Oversold (Diskon Maksimal)
    if bull_ob and day_bullish:
        if bull_ob['bottom'] <= close_m1 <= bull_ob['top']: 
            if rsi_m1 < 35: # Trigger kelelahan seller
                q_score = 95
                buy_sl = bull_ob['bottom'] - (calc_atr(df_m1, 14).iloc[-1] * 0.5) 

    # APEX BEARISH ENTRY: Searah H1 + Masuk Kotak OB M15 + M1 Sedang Overbought (Premium Maksimal)
    if bear_ob and day_bearish:
        if bear_ob['bottom'] <= close_m1 <= bear_ob['top']: 
            if rsi_m1 > 65: # Trigger kelelahan buyer
                q_score = 5
                sell_sl = bear_ob['top'] + (calc_atr(df_m1, 14).iloc[-1] * 0.5) 

    return {
        "score": q_score, "close": close_m1, 
        "buy_sl": buy_sl, "sell_sl": sell_sl,
        "atr": calc_atr(df_m1, 14).iloc[-1],
        "status": "ANALYZED"
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
# 5. DEFENSE PROTOCOL (TRAIL & BREAKEVEN)
# ==========================================
def manage_defenses(symbol, current_atr):
    positions = mt5.positions_get(symbol=symbol, magic=MAGIC_NUMBER)
    if positions is None or len(positions) == 0: return

    for pos in positions:
        entry_price = pos.price_open
        current_sl = pos.sl
        current_price = pos.price_current
        trail_distance = current_atr * 2.5 
        
        if pos.type == mt5.ORDER_TYPE_BUY:
            if current_price >= entry_price + ((entry_price - current_sl) * 1.5): 
                if current_sl < entry_price: 
                    mt5.order_send({"action": mt5.TRADE_ACTION_SLTP, "position": pos.ticket, "symbol": symbol, "sl": entry_price, "tp": pos.tp})
            
            if current_price - trail_distance > current_sl and current_price > entry_price:
                new_sl = current_price - trail_distance
                if new_sl > entry_price: 
                    mt5.order_send({"action": mt5.TRADE_ACTION_SLTP, "position": pos.ticket, "symbol": symbol, "sl": new_sl, "tp": pos.tp})

        elif pos.type == mt5.ORDER_TYPE_SELL:
            if current_price <= entry_price - ((current_sl - entry_price) * 1.5):
                if current_sl > entry_price or current_sl == 0:
                    mt5.order_send({"action": mt5.TRADE_ACTION_SLTP, "position": pos.ticket, "symbol": symbol, "sl": entry_price, "tp": pos.tp})
            
            if current_price + trail_distance < current_sl and current_price < entry_price:
                new_sl = current_price + trail_distance
                if new_sl < entry_price:
                    mt5.order_send({"action": mt5.TRADE_ACTION_SLTP, "position": pos.ticket, "symbol": symbol, "sl": new_sl, "tp": pos.tp})

# ==========================================
# 6. DIVISI EKSEKUSI
# ==========================================
def execute_trade(symbol, decision_data):
    score = decision_data['score']
    open_positions = mt5.positions_get(symbol=symbol, magic=MAGIC_NUMBER)
    if open_positions is not None and len(open_positions) > 0: return

    sl_distance = abs(decision_data['close'] - decision_data['buy_sl']) if score >= 90 else abs(decision_data['close'] - decision_data['sell_sl'])
    total_dynamic_lot = calculate_dynamic_lot(symbol, sl_distance, RISK_PERCENT)
    
    symbol_info = mt5.symbol_info(symbol)
    min_lot, step_lot = symbol_info.volume_min, symbol_info.volume_step
    layer_lot = round((total_dynamic_lot / 3) / step_lot) * step_lot
    num_layers = 3 if layer_lot >= min_lot else 1
    if layer_lot < min_lot: layer_lot = min_lot

    sl_dist_raw = sl_distance
    
    if score >= 90:
        order_type, direction = mt5.ORDER_TYPE_BUY, "BUY"
        price, sl = mt5.symbol_info_tick(symbol).ask, decision_data['buy_sl']
        tps = [price + (sl_dist_raw * 2.0), price + (sl_dist_raw * 3.0), price + (sl_dist_raw * 5.0)] 
    elif score <= 10:
        order_type, direction = mt5.ORDER_TYPE_SELL, "SELL"
        price, sl = mt5.symbol_info_tick(symbol).bid, decision_data['sell_sl']
        tps = [price - (sl_dist_raw * 2.0), price - (sl_dist_raw * 3.0), price - (sl_dist_raw * 5.0)]
    else: return

    print(f"\n   🎯 THE APEX CONFLUENCE! EKSEKUSI {direction} {symbol} ({num_layers} LAYER)")
    
    for i in range(num_layers):
        request = {
            "action": mt5.TRADE_ACTION_DEAL, "symbol": symbol, "volume": float(layer_lot),
            "type": order_type, "price": price, "sl": sl, "tp": tps[i],
            "deviation": DEVIATION, "magic": MAGIC_NUMBER,
            "comment": f"V9_Apex_L{i+1}", "type_time": mt5.ORDER_TIME_GTC,
        }

        for filling in [mt5.ORDER_FILLING_FOK, mt5.ORDER_FILLING_IOC, mt5.ORDER_FILLING_RETURN]:
            request["type_filling"] = filling
            result = mt5.order_send(request)
            if result.retcode == mt5.TRADE_RETCODE_DONE:
                print(f"      ✅ LAYER {i+1} MASUK! Tiket: {result.order} | Target RR 1:{[2,3,5][i]}")
                break

# ==========================================
# 7. SUPER-LOOP OPERASIONAL (HYPER-SPEED)
# ==========================================
if __name__ == "__main__":
    if not init_broker(): quit()
    
    print("🔄 Melakukan Scanning Pair Aktif di Broker...")
    for sym in POSSIBLE_SYMBOLS:
        info = mt5.symbol_info(sym)
        if info is not None and info.visible:
            TARGET_SYMBOLS.append(sym)
            
    if not TARGET_SYMBOLS:
        print("❌ ERROR: Tidak ada pair yang valid.")
        mt5.shutdown()
        quit()
        
    print(f"✅ Broker dikenali. Pair Aktif: {TARGET_SYMBOLS}")
    print("\n🤖 TERMINAL QUANTUM V9 (THE APEX HYBRID) LIVE.")
    print("Kecepatan Radar: 5 Detik. Memburu presisi SMC + RSI M1...\n")
    
    try:
        while True:
            tick = mt5.symbol_info_tick(TARGET_SYMBOLS[0])
            if tick is None: 
                time.sleep(1) 
                continue
                
            server_time = tick.time
            current_hour = datetime.fromtimestamp(server_time).hour
            
            for sym in TARGET_SYMBOLS:
                rates = mt5.copy_rates_from_pos(sym, mt5.TIMEFRAME_M1, 0, 20)
                if rates is not None:
                    manage_defenses(sym, calc_atr(pd.DataFrame(rates), 14).iloc[-1])
                
            if current_hour < START_HOUR or current_hour > END_HOUR:
                print(f"[{datetime.now().strftime('%H:%M:%S')}] 💤 Di luar Killzone. Menolak berburu.")
                time.sleep(60)
                continue
                
            print(f"[{datetime.now().strftime('%H:%M:%S')}] ⚡ Memindai H1 (Tren) -> M15 (SMC Zone) -> M1 (Sniper RSI)...")
            
            for sym in TARGET_SYMBOLS:
                df_m1 = get_data(sym, mt5.TIMEFRAME_M1, 300)
                df_m15 = get_data(sym, mt5.TIMEFRAME_M15, 300)
                df_h1 = get_data(sym, mt5.TIMEFRAME_H1, 300)
                
                decision = calculate_apex_logic(df_m1, df_m15, df_h1)
                if decision and decision.get("status") == "ANALYZED":
                    if decision['score'] >= 90 or decision['score'] <= 10:
                        execute_trade(sym, decision)
            
            # Waktu istirahat diturunkan jadi 5 detik untuk eksekusi ultra-cepat di M1
            time.sleep(5) 
            
    except KeyboardInterrupt:
        print("\n🛑 Sistem Quantum V9 dimatikan secara manual.")
        mt5.shutdown()