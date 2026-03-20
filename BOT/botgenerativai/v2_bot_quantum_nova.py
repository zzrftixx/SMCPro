import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import time
from datetime import datetime
import google.generativeai as genai

# ==========================================
# 1. KONFIGURASI MASTER (V6 PURE + AUTO-BROKER)
# ==========================================
# Masukkan semua variasi nama pair Exness dan HFM di sini
POSSIBLE_SYMBOLS = ["BTCUSDm", "XAUUSDm", "BTCUSDr", "XAUUSDr", "BTCUSD", "XAUUSD", "#BTCUSD", "#BTCUSDr", "XAUUSDb", "XAUUSDc", "BTCUSDc"] 
TARGET_SYMBOLS = [] # Akan diisi otomatis oleh bot saat menyala

RISK_PERCENT = 1.0 
MAGIC_NUMBER = 999111
DEVIATION = 20

START_HOUR = 10
END_HOUR = 23
MAX_SPREAD_POINTS = 500 

# KONEKSI GEMINI AI (FUNDAMENTAL VETO)
GEMINI_API_KEY = "AIzaSyBeN2m9pdxR68BU4Uj3Vl-ce-0aapXB8B4" 
genai.configure(api_key=GEMINI_API_KEY)
ai_model = genai.GenerativeModel('gemini-pro')

# Parameter Indikator Teknis
RSI_LEN = 14
UT_PERIOD = 10
ST_FACTOR = 3.0
ST_PERIOD = 10
SL_MULT = 1.5 

# ==========================================
# 2. NATIVE MATH ENGINE
# ==========================================
def calc_ema(series, length): return series.ewm(span=length, adjust=False).mean()
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
# 4. DIVISI FUNDAMENTAL (GEMINI AI VETO)
# ==========================================
def ask_gemini_veto(symbol, direction):
    asset_name = "Bitcoin/Cryptocurrency" if "BTC" in symbol else "Gold/XAUUSD" if "XAU" in symbol else "Forex"
    prompt = f"Sebagai Chief Risk Officer institusi finansial, jawab HANYA dengan SATU KATA: 'AMAN' atau 'BAHAYA'. Saya sistem algoritma yang akan membuka posisi {direction} (Scalping) untuk aset {asset_name} saat ini. Berdasarkan kalender ekonomi makro atau sentimen pasar global terkini, apakah ada rilis berita berdampak tinggi yang sangat berisiko menghancurkan posisi teknikal saya?"
    
    print(f"   🧠 Menghubungi Gemini AI untuk Analisis Sentimen {asset_name}...")
    try:
        response = ai_model.generate_content(prompt)
        answer = response.text.strip().upper()
        if "BAHAYA" in answer:
            print("   🛑 GEMINI VETO: TERDETEKSI BADAI FUNDAMENTAL! ENTRY DIBATALKAN.")
            return False
        print("   ✅ GEMINI APPROVAL: Sentimen makro mendukung teknikal.")
        return True
    except Exception as e:
        print(f"   ⚠️ Gemini API Error / Timeout. Fallback ke Mode Teknikal Murni.")
        return True 

# ==========================================
# 5. DIVISI TEKNIKAL & SCORING
# ==========================================
def calculate_quantum_logic(df_m1, df_m15, df_h4, df_d1):
    if df_m1 is None or df_m15 is None or df_h4 is None or df_d1 is None: return None

    ema50_d1 = calc_ema(df_d1['close'], 50).iloc[-1]
    ema50_h4 = calc_ema(df_h4['close'], 50).iloc[-1]
    close_d1, close_h4 = df_d1['close'].iloc[-1], df_h4['close'].iloc[-1]
    
    macro_bull = close_d1 > ema50_d1 and close_h4 > ema50_h4
    macro_bear = close_d1 < ema50_d1 and close_h4 < ema50_h4
    
    if not macro_bull and not macro_bear: return {"score": 50, "status": "D1/H4 DISSONANCE"} 

    st_list = calc_supertrend(df_m1, period=ST_PERIOD, multiplier=ST_FACTOR)
    is_st_bull = st_list[-1] == True
    
    ema50_m15, ema200_m15 = calc_ema(df_m15['close'], 50).iloc[-1], calc_ema(df_m15['close'], 200).iloc[-1]
    t_m15 = 1 if (df_m15['close'].iloc[-1] > ema50_m15 and ema50_m15 > ema200_m15) else -1 if (df_m15['close'].iloc[-1] < ema50_m15 and ema50_m15 < ema200_m15) else 0

    rsi_val = calc_rsi(df_m1['close'], length=RSI_LEN).iloc[-1]
    highest_20 = df_m1['high'].rolling(20).max().iloc[-2]
    lowest_20 = df_m1['low'].rolling(20).min().iloc[-2]
    close_now = df_m1['close'].iloc[-1]

    q_score = 50
    if macro_bull:
        if is_st_bull: q_score += 15
        if t_m15 == 1: q_score += 15
        if rsi_val < 35: q_score += 20 
        if close_now > highest_20: q_score += 10
    elif macro_bear:
        if not is_st_bull: q_score -= 15
        if t_m15 == -1: q_score -= 15
        if rsi_val > 65: q_score -= 20 
        if close_now < lowest_20: q_score -= 10

    atr_14 = calc_atr(df_m1, length=14).iloc[-1]
    
    return {
        "score": q_score, "close": close_now, "atr": atr_14,
        "buy_sl": close_now - (atr_14 * SL_MULT), "sell_sl": close_now + (atr_14 * SL_MULT),
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
# 6. DEFENSE PROTOCOL (TRAIL & BREAKEVEN)
# ==========================================
def manage_defenses(symbol, current_atr):
    positions = mt5.positions_get(symbol=symbol, magic=MAGIC_NUMBER)
    if positions is None or len(positions) == 0: return

    for pos in positions:
        entry_price = pos.price_open
        current_sl = pos.sl
        current_price = pos.price_current
        trail_distance = current_atr * 2.0 
        
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
# 7. DIVISI EKSEKUSI
# ==========================================
def execute_trade(symbol, decision_data):
    symbol_info = mt5.symbol_info(symbol)
    if symbol_info.spread > MAX_SPREAD_POINTS:
        print(f"   ⚠️ SPREAD ABNORMAL ({symbol_info.spread} pts). Menolak eksekusi.")
        return

    score = decision_data['score']
    open_positions = mt5.positions_get(symbol=symbol, magic=MAGIC_NUMBER)
    if open_positions is not None and len(open_positions) > 0: return

    sl_distance = abs(decision_data['close'] - decision_data['buy_sl']) if score >= 90 else abs(decision_data['close'] - decision_data['sell_sl'])
    total_dynamic_lot = calculate_dynamic_lot(symbol, sl_distance, RISK_PERCENT)
    
    min_lot, step_lot = symbol_info.volume_min, symbol_info.volume_step
    layer_lot = round((total_dynamic_lot / 3) / step_lot) * step_lot
    num_layers = 3 if layer_lot >= min_lot else 1
    if layer_lot < min_lot: layer_lot = min_lot

    atr = decision_data['atr']
    if score >= 90:
        order_type, direction = mt5.ORDER_TYPE_BUY, "BUY"
        price, sl = mt5.symbol_info_tick(symbol).ask, decision_data['buy_sl']
        tps = [price + (atr * 1.5), price + (atr * 3.0), 0.0] 
    elif score <= 10:
        order_type, direction = mt5.ORDER_TYPE_SELL, "SELL"
        price, sl = mt5.symbol_info_tick(symbol).bid, decision_data['sell_sl']
        tps = [price - (atr * 1.5), price - (atr * 3.0), 0.0]
    else: return

    if not ask_gemini_veto(symbol, direction): return

    print(f"\n   🚀 THE QUANTUM NEXUS ALIGNED! EKSEKUSI {direction} {symbol} ({num_layers} LAYER)")
    
    for i in range(num_layers):
        request = {
            "action": mt5.TRADE_ACTION_DEAL, "symbol": symbol, "volume": float(layer_lot),
            "type": order_type, "price": price, "sl": sl, "tp": tps[i],
            "deviation": DEVIATION, "magic": MAGIC_NUMBER,
            "comment": f"QNexus_L{i+1}", "type_time": mt5.ORDER_TIME_GTC,
        }

        for filling in [mt5.ORDER_FILLING_FOK, mt5.ORDER_FILLING_IOC, mt5.ORDER_FILLING_RETURN]:
            request["type_filling"] = filling
            result = mt5.order_send(request)
            if result.retcode == mt5.TRADE_RETCODE_DONE:
                tp_str = f"{tps[i]:.4f}" if tps[i] != 0.0 else "OPEN (Trail)"
                print(f"      ✅ LAYER {i+1} MASUK! Tiket: {result.order} | TP: {tp_str}")
                break

# ==========================================
# 8. SUPER-LOOP OPERASIONAL
# ==========================================
if __name__ == "__main__":
    if not init_broker(): quit()
    
    # ---------------------------------------------------------
    # SENSOR LINGKUNGAN: FILTER PAIR OTOMATIS BERDASARKAN BROKER
    # ---------------------------------------------------------
    print("🔄 Melakukan Scanning Pair Aktif di Broker...")
    for sym in POSSIBLE_SYMBOLS:
        info = mt5.symbol_info(sym)
        if info is not None and info.visible:
            TARGET_SYMBOLS.append(sym)
            
    if not TARGET_SYMBOLS:
        print("❌ ERROR: Tidak ada pair yang valid. Pastikan Market Watch di MT5 sudah terbuka semua (Show All).")
        mt5.shutdown()
        quit()
        
    print(f"✅ Pair Terkunci untuk Broker ini: {TARGET_SYMBOLS}")
    # ---------------------------------------------------------

    print("\n🤖 TERMINAL QUANTUM NEXUS V6 LIVE.")
    print("Radar Makro: D1 & H4 | Radar Mikro: M15 & M1 | Fundamental Veto: Gemini AI\n")
    
    try:
        while True:
            # Ambil waktu server dengan aman tanpa error 'NoneType'
            tick = mt5.symbol_info_tick(TARGET_SYMBOLS[0])
            if tick is None: 
                time.sleep(2) # Tunggu sebentar kalau MT5 belum ngasih data tick
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
                
            print(f"[{datetime.now().strftime('%H:%M:%S')}] ⚡ Analisis Kuadran Matrix (D1 ke M1)...")
            
            for sym in TARGET_SYMBOLS:
                info = mt5.symbol_info(sym)
                if info is None or not info.visible: continue
                
                df_m1 = get_data(sym, mt5.TIMEFRAME_M1, 300)
                df_m15 = get_data(sym, mt5.TIMEFRAME_M15, 300)
                df_h4 = get_data(sym, mt5.TIMEFRAME_H4, 300)
                df_d1 = get_data(sym, mt5.TIMEFRAME_D1, 300)
                
                decision = calculate_quantum_logic(df_m1, df_m15, df_h4, df_d1)
                if decision and decision["status"] == "ANALYZED":
                    if decision['score'] >= 90 or decision['score'] <= 10:
                        execute_trade(sym, decision)
            
            time.sleep(20) 
            
    except KeyboardInterrupt:
        print("\n🛑 Sistem Quantum Nexus dimatikan secara manual.")
        mt5.shutdown()