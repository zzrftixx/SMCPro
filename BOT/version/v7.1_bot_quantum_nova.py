import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import time
from datetime import datetime

# ==========================================
# 1. KONFIGURASI MASTER (V7 SMC SNIPER EDITION)
# ==========================================
POSSIBLE_SYMBOLS = ["BTCUSDm", "XAUUSDm", "BTCUSDr", "XAUUSDr", "BTCUSD", "XAUUSD", "#BTCUSD", "XAUUSDc", "BTCUSDc"]
TARGET_SYMBOLS = [] 

RISK_PERCENT = 1.0 
MAGIC_NUMBER = 777999
DEVIATION = 10 # Diperketat untuk sniper

START_HOUR = 8
END_HOUR = 23

# ==========================================
# 2. NATIVE MATH & SMC ENGINE
# ==========================================
def calc_atr(df, length=14):
    high_low = df['high'] - df['low']
    high_close = np.abs(df['high'] - df['close'].shift())
    low_close = np.abs(df['low'] - df['close'].shift())
    tr = pd.concat([high_low, high_close, low_close], axis=1).max(axis=1)
    return tr.rolling(window=length).mean()

def detect_unmitigated_ob(df):
    """
    Logika Python untuk Volumized Order Blocks.
    Mencari Imbalance (Pergerakan impulsif) dan menandai Base Candle sebelumnya.
    """
    bull_ob = None
    bear_ob = None
    atr = calc_atr(df, 14)

    # Mundur dari candle terbaru ke belakang
    for i in range(len(df)-2, 10, -1):
        body = abs(df['close'].iloc[i] - df['open'].iloc[i])
        is_imbalance = body > (atr.iloc[i] * 1.8) # Syarat ledakan volume institusi

        # Mencari Bullish Order Block
        if is_imbalance and bull_ob is None:
            if df['close'].iloc[i] > df['open'].iloc[i]: # Harga meledak NAIK
                # Cari candle turun terakhir (Bearish) sebelum ledakan
                for j in range(i-1, max(0, i-8), -1):
                    if df['close'].iloc[j] < df['open'].iloc[j]: 
                        top = max(df['open'].iloc[j], df['close'].iloc[j])
                        btm = df['low'].iloc[j]
                        # Cek apakah OB ini sudah dites (Mitigated) oleh harga setelahnya
                        min_since = df['low'].iloc[i:].min()
                        if min_since > top: 
                            bull_ob = {'top': top, 'bottom': btm}
                            break

        # Mencari Bearish Order Block
        if is_imbalance and bear_ob is None:
            if df['close'].iloc[i] < df['open'].iloc[i]: # Harga meledak TURUN
                # Cari candle naik terakhir (Bullish) sebelum ledakan
                for j in range(i-1, max(0, i-8), -1):
                    if df['close'].iloc[j] > df['open'].iloc[j]: 
                        top = df['high'].iloc[j]
                        btm = min(df['open'].iloc[j], df['close'].iloc[j])
                        max_since = df['high'].iloc[i:].max()
                        if max_since < btm: 
                            bear_ob = {'top': top, 'bottom': btm}
                            break
                            
        if bull_ob and bear_ob:
            break
            
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
# 4. DIVISI TEKNIKAL & SCORING (SMC LOGIC)
# ==========================================
def calculate_smc_logic(df_m1, df_m15):
    if df_m1 is None or df_m15 is None: return None

    # Deteksi Zona Order Block di M15 (Peta Perang)
    bull_ob, bear_ob = detect_unmitigated_ob(df_m15)
    close_m1 = df_m1['close'].iloc[-1]
    
    q_score = 50
    buy_sl = 0
    sell_sl = 0

    # Logika Entry: Harga M1 masuk ke dalam Kotak OB M15
    if bull_ob:
        if bull_ob['bottom'] <= close_m1 <= bull_ob['top']: # Harga di area diskon bandar
            q_score = 95
            buy_sl = bull_ob['bottom'] - (calc_atr(df_m1, 14).iloc[-1] * 0.5) # SL super ketat di bawah OB

    if bear_ob:
        if bear_ob['bottom'] <= close_m1 <= bear_ob['top']: # Harga di area premium bandar
            q_score = 5
            sell_sl = bear_ob['top'] + (calc_atr(df_m1, 14).iloc[-1] * 0.5) # SL super ketat di atas OB

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
        trail_distance = current_atr * 2.5 # Trail lebih jauh agar nafas SMC tidak gampang tersapu
        
        if pos.type == mt5.ORDER_TYPE_BUY:
            if current_price >= entry_price + ((entry_price - current_sl) * 1.5): # Breakeven setelah profit 1.5x Risiko
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

    # SMC TARGETING: RR 1:2, RR 1:3, RR 1:5
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

    print(f"\n   🎯 ZONA INSTITUSI DITEMBUS! EKSEKUSI {direction} SMC {symbol} ({num_layers} LAYER)")
    
    for i in range(num_layers):
        request = {
            "action": mt5.TRADE_ACTION_DEAL, "symbol": symbol, "volume": float(layer_lot),
            "type": order_type, "price": price, "sl": sl, "tp": tps[i],
            "deviation": DEVIATION, "magic": MAGIC_NUMBER,
            "comment": f"SMC_V7_L{i+1}", "type_time": mt5.ORDER_TIME_GTC,
        }

        for filling in [mt5.ORDER_FILLING_FOK, mt5.ORDER_FILLING_IOC, mt5.ORDER_FILLING_RETURN]:
            request["type_filling"] = filling
            result = mt5.order_send(request)
            if result.retcode == mt5.TRADE_RETCODE_DONE:
                print(f"      ✅ LAYER {i+1} MASUK! Tiket: {result.order} | Target RR 1:{[2,3,5][i]}")
                break

# ==========================================
# 7. SUPER-LOOP OPERASIONAL
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
    print("\n🤖 TERMINAL QUANTUM V7 (SMC SNIPER EDITION) LIVE.")
    print("Mendeteksi Volumized Order Blocks M15. Menunggu sentuhan harga M1...\n")
    
    try:
        while True:
            tick = mt5.symbol_info_tick(TARGET_SYMBOLS[0])
            if tick is None: 
                time.sleep(2) 
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
                
            print(f"[{datetime.now().strftime('%H:%M:%S')}] ⚡ Memindai Imbalance & Order Blocks (M15)...")
            
            for sym in TARGET_SYMBOLS:
                df_m1 = get_data(sym, mt5.TIMEFRAME_M1, 300)
                df_m15 = get_data(sym, mt5.TIMEFRAME_M15, 300)
                
                decision = calculate_smc_logic(df_m1, df_m15)
                if decision and decision["status"] == "ANALYZED":
                    if decision['score'] >= 90 or decision['score'] <= 10:
                        execute_trade(sym, decision)
            
            time.sleep(10) # Lebih cepat agar sentuhan zona OB M15 langsung tereksekusi
            
    except KeyboardInterrupt:
        print("\n🛑 Sistem Quantum V7 dimatikan secara manual.")
        mt5.shutdown()