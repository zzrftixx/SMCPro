import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import time
from datetime import datetime

# ==========================================
# 1. KONFIGURASI MASTER (V11 REGIME-ADAPTIVE)
# ==========================================
POSSIBLE_SYMBOLS = ["XAUUSDc", "BTCUSDc", "BTCUSDm", "XAUUSDm", "BTCUSD", "XAUUSD"]
TARGET_SYMBOLS = [] 

RISK_PERCENT = 1.0 
MAGIC_NUMBER = 111111
DEVIATION = 10 

START_HOUR = 0
END_HOUR = 23

# ==========================================
# 2. DATA CACHE & STATE ENGINE (SPEED OPTIMIZATION)
# ==========================================
# Untuk menghindari request data berat setiap 1 detik
data_cache = {}

def get_cached_data(symbol, timeframe, num_bars, cache_key):
    now = time.time()
    # Cache duration: H1 = 1 menit, M15 = 30 detik, M1 = real-time
    cache_ttl = 60 if timeframe == mt5.TIMEFRAME_H1 else 30 if timeframe == mt5.TIMEFRAME_M15 else 0
    
    if cache_key in data_cache:
        last_update, df = data_cache[cache_key]
        if now - last_update < cache_ttl:
            return df

    rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, num_bars)
    if rates is None: return None
    df = pd.DataFrame(rates)
    
    if cache_ttl > 0:
        data_cache[cache_key] = (now, df)
        
    return df

# ==========================================
# 3. NATIVE MATH & SMC ENGINE
# ==========================================
def calc_ema(series, length):
    return series.ewm(span=length, adjust=False).mean()

def calc_atr(df, length=14):
    high_low = df['high'] - df['low']
    high_close = np.abs(df['high'] - df['close'].shift())
    low_close = np.abs(df['low'] - df['close'].shift())
    tr = pd.concat([high_low, high_close, low_close], axis=1).max(axis=1)
    return tr.rolling(window=length).mean()

def detect_regime(df_h1):
    """
    Market Regime Classifier (Trend vs Ranging)
    Mencegah bot hancur di pasar yang sedang tidak berarah.
    """
    if df_h1 is None or len(df_h1) < 50: return "UNKNOWN"
    
    ema20 = calc_ema(df_h1['close'], 20).iloc[-1]
    ema50 = calc_ema(df_h1['close'], 50).iloc[-1]
    atr = calc_atr(df_h1, 14).iloc[-1]
    
    # Jika jarak EMA sempit, pasar sedang Choppy/Ranging
    if abs(ema20 - ema50) < (atr * 0.3):
        return "CHOPPY"
    
    if ema20 > ema50: return "TREND_BULL"
    if ema20 < ema50: return "TREND_BEAR"
    
    return "UNKNOWN"

def detect_volumetric_ob(df):
    """SMC Pro - FIX BUG Mitigasi berdasarkan analisis Claude"""
    bull_ob, bear_ob = None, None
    atr = calc_atr(df, 14)
    vol_sma = df['tick_volume'].rolling(window=20).mean() 

    for i in range(len(df)-2, 10, -1):
        body = abs(df['close'].iloc[i] - df['open'].iloc[i])
        is_imbalance = body > (atr.iloc[i] * 2.0) 
        is_high_volume = df['tick_volume'].iloc[i] > (vol_sma.iloc[i] * 1.5)

        if is_imbalance and is_high_volume:
            if df['close'].iloc[i] > df['open'].iloc[i] and bull_ob is None: 
                for j in range(i-1, max(0, i-8), -1):
                    if df['close'].iloc[j] < df['open'].iloc[j]: 
                        top = max(df['open'].iloc[j], df['close'].iloc[j])
                        btm = df['low'].iloc[j]
                        # FIX BUG: Cek mulai dari i+1 agar tidak salah baca shadow sendiri
                        if len(df) > i+1 and df['low'].iloc[i+1:].min() > top: 
                            bull_ob = {'top': top, 'bottom': btm}
                            break

            if df['close'].iloc[i] < df['open'].iloc[i] and bear_ob is None: 
                for j in range(i-1, max(0, i-8), -1):
                    if df['close'].iloc[j] > df['open'].iloc[j]: 
                        top = df['high'].iloc[j]
                        btm = min(df['open'].iloc[j], df['close'].iloc[j])
                        # FIX BUG: Cek mulai dari i+1
                        if len(df) > i+1 and df['high'].iloc[i+1:].max() < btm: 
                            bear_ob = {'top': top, 'bottom': btm}
                            break
                            
        if bull_ob and bear_ob: break
            
    return bull_ob, bear_ob

# ==========================================
# 4. KONEKSI & EKSEKUSI
# ==========================================
def init_broker():
    if not mt5.initialize(): return False
    return True

def calculate_v11_logic(symbol, df_m1, df_m15, df_h1):
    regime = detect_regime(df_h1)
    
    # FILTER 1: REGIME GATEKEEPER
    if regime in ["CHOPPY", "UNKNOWN"]:
        return {"status": "BLOCKED_BY_REGIME", "regime": regime}

    # FILTER 2: SMC ZONE
    bull_ob, bear_ob = detect_volumetric_ob(df_m15)
    
    # FILTER 3: TICK TRIGGER
    tick = mt5.symbol_info_tick(symbol)
    if tick is None: return None
    
    q_score, buy_sl, sell_sl = 50, 0, 0
    atr_val = calc_atr(df_m15, 14).iloc[-1] / 3.0

    if bull_ob and regime == "TREND_BULL":
        if bull_ob['bottom'] <= tick.ask <= bull_ob['top']: 
            q_score = 99
            buy_sl = bull_ob['bottom'] - atr_val 

    if bear_ob and regime == "TREND_BEAR":
        if bear_ob['bottom'] <= tick.bid <= bear_ob['top']: 
            q_score = 1
            sell_sl = bear_ob['top'] + atr_val 

    return {
        "score": q_score, "ask": tick.ask, "bid": tick.bid, 
        "buy_sl": buy_sl, "sell_sl": sell_sl, "atr": atr_val,
        "status": "VALID_SETUP", "regime": regime
    }

def calculate_dynamic_lot(symbol, sl_distance, risk_percent):
    info = mt5.account_info()
    sym_info = mt5.symbol_info(symbol)
    if info is None or sym_info is None: return 0.01

    risk_money = info.equity * (risk_percent / 100.0) 
    sl_ticks = sl_distance / sym_info.trade_tick_size
    if sl_ticks <= 0: return sym_info.volume_min
    
    loss_per_lot = sl_ticks * sym_info.trade_tick_value
    if loss_per_lot <= 0: return sym_info.volume_min
    return risk_money / loss_per_lot

def manage_defenses(symbol, current_atr):
    positions = mt5.positions_get(symbol=symbol, magic=MAGIC_NUMBER)
    if not positions: return

    for pos in positions:
        entry_price, current_sl, current_price = pos.price_open, pos.sl, pos.price_current
        trail_dist = current_atr * 2.0 
        
        if pos.type == mt5.ORDER_TYPE_BUY:
            if current_price >= entry_price + ((entry_price - current_sl) * 1.5) and current_sl < entry_price: 
                mt5.order_send({"action": mt5.TRADE_ACTION_SLTP, "position": pos.ticket, "symbol": symbol, "sl": entry_price, "tp": pos.tp})
            if current_price - trail_dist > current_sl and current_price > entry_price:
                new_sl = current_price - trail_dist
                if new_sl > entry_price: 
                    mt5.order_send({"action": mt5.TRADE_ACTION_SLTP, "position": pos.ticket, "symbol": symbol, "sl": new_sl, "tp": pos.tp})

        elif pos.type == mt5.ORDER_TYPE_SELL:
            if current_price <= entry_price - ((current_sl - entry_price) * 1.5) and (current_sl > entry_price or current_sl == 0):
                mt5.order_send({"action": mt5.TRADE_ACTION_SLTP, "position": pos.ticket, "symbol": symbol, "sl": entry_price, "tp": pos.tp})
            if current_price + trail_dist < current_sl and current_price < entry_price:
                new_sl = current_price + trail_dist
                if new_sl < entry_price:
                    mt5.order_send({"action": mt5.TRADE_ACTION_SLTP, "position": pos.ticket, "symbol": symbol, "sl": new_sl, "tp": pos.tp})

def execute_trade(symbol, decision):
    score = decision['score']
    if mt5.positions_get(symbol=symbol, magic=MAGIC_NUMBER): return

    sl_dist = abs(decision['ask'] - decision['buy_sl']) if score >= 99 else abs(decision['bid'] - decision['sell_sl'])
    total_lot = calculate_dynamic_lot(symbol, sl_dist, RISK_PERCENT)
    
    sym_info = mt5.symbol_info(symbol)
    min_lot, step = sym_info.volume_min, sym_info.volume_step
    layer_lot = round((total_lot / 3) / step) * step
    num_layers = 3 if layer_lot >= min_lot else 1
    if layer_lot < min_lot: layer_lot = min_lot

    if score >= 99:
        order_type, direction, price, sl = mt5.ORDER_TYPE_BUY, "BUY", decision['ask'], decision['buy_sl']
        tps = [price + (sl_dist * 2.0), price + (sl_dist * 3.0), price + (sl_dist * 5.0)] 
    elif score <= 1:
        order_type, direction, price, sl = mt5.ORDER_TYPE_SELL, "SELL", decision['bid'], decision['sell_sl']
        tps = [price - (sl_dist * 2.0), price - (sl_dist * 3.0), price - (sl_dist * 5.0)]
    else: return

    print(f"\n   ⚡ V11 REGIME ALIGNED! EKSEKUSI {direction} {symbol} ({decision['regime']})")
    
    for i in range(num_layers):
        request = {
            "action": mt5.TRADE_ACTION_DEAL, "symbol": symbol, "volume": float(layer_lot),
            "type": order_type, "price": price, "sl": sl, "tp": tps[i],
            "deviation": DEVIATION, "magic": MAGIC_NUMBER,
            "comment": f"V11_L{i+1}", "type_time": mt5.ORDER_TIME_GTC, "type_filling": mt5.ORDER_FILLING_IOC
        }
        res = mt5.order_send(request)
        if res and res.retcode == mt5.TRADE_RETCODE_DONE:
            print(f"      ✅ LAYER {i+1} MASUK! Tiket: {res.order}")

# ==========================================
# 5. SUPER-LOOP (CACHED ULTRA-SPEED)
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
    print("\n🤖 TERMINAL QUANTUM V11 (REGIME-ADAPTIVE) LIVE.")
    print("Membawa arsitektur caching, regime filter, dan OB Bug-fix.\n")
    
    try:
        while True:
            current_hour = datetime.now().hour
            
            for sym in TARGET_SYMBOLS:
                df_m1 = get_cached_data(sym, mt5.TIMEFRAME_M1, 20, f"{sym}_m1_defense")
                if df_m1 is not None:
                    manage_defenses(sym, calc_atr(df_m1, 14).iloc[-1])
                
            if current_hour < START_HOUR or current_hour > END_HOUR:
                time.sleep(60)
                continue
                
            for sym in TARGET_SYMBOLS:
                # Mengambil data menggunakan sistem Cache agar loop secepat kilat
                df_m1 = get_cached_data(sym, mt5.TIMEFRAME_M1, 300, f"{sym}_m1")
                df_m15 = get_cached_data(sym, mt5.TIMEFRAME_M15, 300, f"{sym}_m15")
                df_h1 = get_cached_data(sym, mt5.TIMEFRAME_H1, 300, f"{sym}_h1")
                
                decision = calculate_v11_logic(sym, df_m1, df_m15, df_h1)
                
                if decision:
                    if decision.get("status") == "BLOCKED_BY_REGIME":
                        # Print hanya di detik ke-0 setiap menit agar terminal tidak berisik
                        if int(time.time()) % 60 == 0: 
                            print(f"   [{datetime.now().strftime('%H:%M:%S')}] {sym}: Pasar sedang {decision['regime']}. Tiarap.")
                    elif decision.get("status") == "VALID_SETUP":
                        if decision['score'] >= 99 or decision['score'] <= 1:
                            execute_trade(sym, decision)
            
            # Istirahat 0.5 detik. Karena data berat di-cache, CPU tidak akan terbakar.
            time.sleep(0.5) 
            
    except KeyboardInterrupt:
        print("\n🛑 Sistem Quantum V11 dimatikan.")
        mt5.shutdown()