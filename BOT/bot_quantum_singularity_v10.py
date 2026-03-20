import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import time
from datetime import datetime

# ==========================================
# 1. KONFIGURASI MASTER (V10 QUANTUM SINGULARITY)
# ==========================================
POSSIBLE_SYMBOLS = ["BTCUSDm", "XAUUSDm", "BTCUSDr", "XAUUSDr", "BTCUSD", "XAUUSD", "#BTCUSD", "XAUUSDc", "BTCUSDc"]
TARGET_SYMBOLS = [] 

RISK_PERCENT = 1.0 
MAGIC_NUMBER = 101010
DEVIATION = 5 # Ekstra ketat untuk Tick-Level Execution

START_HOUR = 8
END_HOUR = 23

# INSTITUTIONAL CIRCUIT BREAKER
MAX_DAILY_LOSS = 3 # Maksimal 3 kali SL per hari, lalu bot tidur sampai besok
daily_loss_counter = {}

# ==========================================
# 2. VOLUMETRIC SMC ENGINE (FLUXCHART LOGIC ADAPTATION)
# ==========================================
def calc_atr(df, length=14):
    high_low = df['high'] - df['low']
    high_close = np.abs(df['high'] - df['close'].shift())
    low_close = np.abs(df['low'] - df['close'].shift())
    tr = pd.concat([high_low, high_close, low_close], axis=1).max(axis=1)
    return tr.rolling(window=length).mean()

def detect_volumetric_ob(df):
    """
    SMC Pro dengan Filter Volume Ekstrem.
    Hanya menandai Order Block jika disertai anomali Tick Volume.
    """
    bull_ob, bear_ob = None, None
    atr = calc_atr(df, 14)
    vol_sma = df['tick_volume'].rolling(window=20).mean() # Rata-rata volume

    for i in range(len(df)-2, 10, -1):
        body = abs(df['close'].iloc[i] - df['open'].iloc[i])
        
        # Syarat 1: Imbalance (Body besar)
        # Syarat 2: Volume Anomali (Volume di atas rata-rata 20 candle terakhir)
        is_imbalance = body > (atr.iloc[i] * 2.0) 
        is_high_volume = df['tick_volume'].iloc[i] > (vol_sma.iloc[i] * 1.5)

        if is_imbalance and is_high_volume:
            # Bullish Volumetric OB
            if df['close'].iloc[i] > df['open'].iloc[i] and bull_ob is None: 
                for j in range(i-1, max(0, i-8), -1):
                    if df['close'].iloc[j] < df['open'].iloc[j]: 
                        top = max(df['open'].iloc[j], df['close'].iloc[j])
                        btm = df['low'].iloc[j]
                        if df['low'].iloc[i:].min() > top: # Unmitigated
                            bull_ob = {'top': top, 'bottom': btm}
                            break

            # Bearish Volumetric OB
            if df['close'].iloc[i] < df['open'].iloc[i] and bear_ob is None: 
                for j in range(i-1, max(0, i-8), -1):
                    if df['close'].iloc[j] > df['open'].iloc[j]: 
                        top = df['high'].iloc[j]
                        btm = min(df['open'].iloc[j], df['close'].iloc[j])
                        if df['high'].iloc[i:].max() < btm: # Unmitigated
                            bear_ob = {'top': top, 'bottom': btm}
                            break
                            
        if bull_ob and bear_ob: break
            
    return bull_ob, bear_ob

# ==========================================
# 3. KONEKSI & DATA FEED
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
# 4. TICK-LEVEL SNIPER LOGIC
# ==========================================
def calculate_singularity_logic(symbol, df_m15):
    if df_m15 is None: return None

    # Deteksi Volumetric Order Block di M15
    bull_ob, bear_ob = detect_volumetric_ob(df_m15)
    
    # Ambil harga detik ini (Tick Data) bukan candle close!
    tick = mt5.symbol_info_tick(symbol)
    if tick is None: return None
    
    current_bid = tick.bid
    current_ask = tick.ask
    
    q_score, buy_sl, sell_sl = 50, 0, 0
    atr_val = calc_atr(df_m15, 14).iloc[-1] / 3.0 # Penyesuaian ATR untuk SL

    # TICK-LEVEL TRIGGER
    if bull_ob:
        # Jika Ask price masuk ke zona Bullish OB, tembak seketika!
        if bull_ob['bottom'] <= current_ask <= bull_ob['top']: 
            q_score = 99
            buy_sl = bull_ob['bottom'] - atr_val 

    if bear_ob:
        # Jika Bid price masuk ke zona Bearish OB, tembak seketika!
        if bear_ob['bottom'] <= current_bid <= bear_ob['top']: 
            q_score = 1
            sell_sl = bear_ob['top'] + atr_val 

    return {
        "score": q_score, "ask": current_ask, "bid": current_bid, 
        "buy_sl": buy_sl, "sell_sl": sell_sl, "atr": atr_val,
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
        trail_distance = current_atr * 1.5 
        
        if pos.type == mt5.ORDER_TYPE_BUY:
            if current_price >= entry_price + (entry_price - current_sl): 
                if current_sl < entry_price: 
                    mt5.order_send({"action": mt5.TRADE_ACTION_SLTP, "position": pos.ticket, "symbol": symbol, "sl": entry_price, "tp": pos.tp})
            
            if current_price - trail_distance > current_sl and current_price > entry_price:
                new_sl = current_price - trail_distance
                if new_sl > entry_price: 
                    mt5.order_send({"action": mt5.TRADE_ACTION_SLTP, "position": pos.ticket, "symbol": symbol, "sl": new_sl, "tp": pos.tp})

        elif pos.type == mt5.ORDER_TYPE_SELL:
            if current_price <= entry_price - (current_sl - entry_price):
                if current_sl > entry_price or current_sl == 0:
                    mt5.order_send({"action": mt5.TRADE_ACTION_SLTP, "position": pos.ticket, "symbol": symbol, "sl": entry_price, "tp": pos.tp})
            
            if current_price + trail_distance < current_sl and current_price < entry_price:
                new_sl = current_price + trail_distance
                if new_sl < entry_price:
                    mt5.order_send({"action": mt5.TRADE_ACTION_SLTP, "position": pos.ticket, "symbol": symbol, "sl": new_sl, "tp": pos.tp})

# ==========================================
# 6. DIVISI EKSEKUSI & CIRCUIT BREAKER
# ==========================================
def execute_trade(symbol, decision_data):
    # Cek Circuit Breaker harian
    if daily_loss_counter.get(symbol, 0) >= MAX_DAILY_LOSS:
        print(f"   🛑 CIRCUIT BREAKER AKTIF: {symbol} sudah rugi {MAX_DAILY_LOSS}x hari ini. Mesin dikunci sampai besok.")
        return

    score = decision_data['score']
    open_positions = mt5.positions_get(symbol=symbol, magic=MAGIC_NUMBER)
    if open_positions is not None and len(open_positions) > 0: return

    sl_distance = abs(decision_data['ask'] - decision_data['buy_sl']) if score >= 99 else abs(decision_data['bid'] - decision_data['sell_sl'])
    total_dynamic_lot = calculate_dynamic_lot(symbol, sl_distance, RISK_PERCENT)
    
    symbol_info = mt5.symbol_info(symbol)
    min_lot, step_lot = symbol_info.volume_min, symbol_info.volume_step
    layer_lot = round((total_dynamic_lot / 3) / step_lot) * step_lot
    num_layers = 3 if layer_lot >= min_lot else 1
    if layer_lot < min_lot: layer_lot = min_lot

    sl_dist_raw = sl_distance
    
    if score >= 99:
        order_type, direction = mt5.ORDER_TYPE_BUY, "BUY"
        price, sl = decision_data['ask'], decision_data['buy_sl']
        tps = [price + (sl_dist_raw * 2.0), price + (sl_dist_raw * 3.0), price + (sl_dist_raw * 5.0)] 
    elif score <= 1:
        order_type, direction = mt5.ORDER_TYPE_SELL, "SELL"
        price, sl = decision_data['bid'], decision_data['sell_sl']
        tps = [price - (sl_dist_raw * 2.0), price - (sl_dist_raw * 3.0), price - (sl_dist_raw * 5.0)]
    else: return

    print(f"\n   ⚡ QUANTUM SINGULARITY TRIGGER! EKSEKUSI {direction} TICK-LEVEL {symbol} ({num_layers} LAYER)")
    
    for i in range(num_layers):
        request = {
            "action": mt5.TRADE_ACTION_DEAL, "symbol": symbol, "volume": float(layer_lot),
            "type": order_type, "price": price, "sl": sl, "tp": tps[i],
            "deviation": DEVIATION, "magic": MAGIC_NUMBER,
            "comment": f"V10_Sing_L{i+1}", "type_time": mt5.ORDER_TIME_GTC,
        }

        for filling in [mt5.ORDER_FILLING_FOK, mt5.ORDER_FILLING_IOC, mt5.ORDER_FILLING_RETURN]:
            request["type_filling"] = filling
            result = mt5.order_send(request)
            if result.retcode == mt5.TRADE_RETCODE_DONE:
                print(f"      ✅ LAYER {i+1} MASUK! Tiket: {result.order} | Target RR 1:{[2,3,5][i]}")
                break

# ==========================================
# 7. SUPER-LOOP OPERASIONAL (ULTRA-SPEED)
# ==========================================
def update_daily_loss(symbol):
    """Mengecek history hari ini, apakah ada posisi yang ditutup kena SL (rugi)"""
    today_start = datetime(datetime.now().year, datetime.now().month, datetime.now().day)
    deals = mt5.history_deals_get(today_start, datetime.now(), group=f"*{symbol}*")
    
    loss_count = 0
    if deals is not None:
        for deal in deals:
            if deal.magic == MAGIC_NUMBER and deal.profit < 0:
                loss_count += 1
    
    # Karena kita pakai 3 layer, 1 setup = 3 deal. Kita bagi 3 agar dihitung 1 setup rugi.
    actual_setups_lost = loss_count // 3
    daily_loss_counter[symbol] = actual_setups_lost

if __name__ == "__main__":
    if not init_broker(): quit()
    
    print("🔄 Melakukan Scanning Pair Aktif di Broker...")
    for sym in POSSIBLE_SYMBOLS:
        info = mt5.symbol_info(sym)
        if info is not None and info.visible:
            TARGET_SYMBOLS.append(sym)
            daily_loss_counter[sym] = 0
            
    if not TARGET_SYMBOLS:
        print("❌ ERROR: Tidak ada pair yang valid.")
        mt5.shutdown()
        quit()
        
    print(f"✅ Broker dikenali. Pair Aktif: {TARGET_SYMBOLS}")
    print("\n🤖 TERMINAL QUANTUM V10 (THE SINGULARITY) LIVE.")
    print("Mode: Volumetric Order Blocks + Tick-Level Execution + Circuit Breaker.\n")
    
    try:
        while True:
            current_hour = datetime.now().hour
            
            for sym in TARGET_SYMBOLS:
                rates = mt5.copy_rates_from_pos(sym, mt5.TIMEFRAME_M15, 0, 5)
                if rates is not None:
                    manage_defenses(sym, calc_atr(pd.DataFrame(rates), 14).iloc[-1])
                # Update status rugi harian
                update_daily_loss(sym)
                
            if current_hour < START_HOUR or current_hour > END_HOUR:
                print(f"[{datetime.now().strftime('%H:%M:%S')}] 💤 Di luar Killzone. Menolak berburu.")
                time.sleep(60)
                continue
                
            print(f"[{datetime.now().strftime('%H:%M:%S')}] ⚡ Memindai Volumetric OB (M15) dengan Trigger Tick Harga...")
            
            for sym in TARGET_SYMBOLS:
                df_m15 = get_data(sym, mt5.TIMEFRAME_M15, 300)
                
                decision = calculate_singularity_logic(sym, df_m15)
                if decision and decision.get("status") == "ANALYZED":
                    if decision['score'] >= 99 or decision['score'] <= 1:
                        execute_trade(sym, decision)
            
            # Waktu istirahat HANYA 1 DETIK! Ultra-speed untuk menangkap jarum harga
            time.sleep(1) 
            
    except KeyboardInterrupt:
        print("\n🛑 Sistem Quantum V10 dimatikan secara manual.")
        mt5.shutdown()