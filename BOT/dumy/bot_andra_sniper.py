import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import time
from datetime import datetime

# ==========================================
# 1. KONFIGURASI MANAJEMEN RISIKO SPESIFIK PAIR
# ==========================================
# Atur Lot, SL (dalam poin), dan TP (dalam poin) untuk masing-masing pair.
# WAJIB DISESUAIKAN DENGAN KONTRAK EXNESS-MU!
PAIR_CONFIG = {
    "BTCUSDm": {"lot": 0.01, "sl_points": 10000, "tp_points": 30000}, # Contoh SL $100, TP $300
    "XAUUSDm": {"lot": 0.01, "sl_points": 500, "tp_points": 1500}     # Contoh SL 50 pips, TP 150 pips
}

TARGET_SYMBOLS = list(PAIR_CONFIG.keys())
MAGIC_NUMBER = 777888
DEVIATION = 20 # Toleransi slippage M1 (poin)

# ==========================================
# 2. MODUL GATEWAY & INTELIJEN
# ==========================================
def init_broker():
    if not mt5.initialize():
        print(f"❌ Gagal inisialisasi MT5! Error: {mt5.last_error()}")
        return False
    return True

def get_data(symbol, timeframe, num_bars):
    rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, num_bars)
    if rates is None: return None
    df = pd.DataFrame(rates)
    df['time'] = pd.to_datetime(df['time'], unit='s')
    df.set_index('time', inplace=True)
    return df

# ==========================================
# 3. MODUL ANALISIS (H1 + M1)
# ==========================================
def analyze_htf(df_h1):
    if df_h1 is None or len(df_h1) < 200: return "NEUTRAL"
    df_h1['ema_50'] = df_h1['close'].ewm(span=50, adjust=False).mean()
    df_h1['ema_200'] = df_h1['close'].ewm(span=200, adjust=False).mean()
    
    close, ema50, ema200 = df_h1['close'].iloc[-1], df_h1['ema_50'].iloc[-1], df_h1['ema_200'].iloc[-1]
    
    if close > ema50 and ema50 > ema200: return "BULLISH"
    elif close < ema50 and ema50 < ema200: return "BEARISH"
    return "CHOPPY"

def analyze_ltf(df_m1, htf_trend):
    if df_m1 is None or len(df_m1) < 20: return "WAIT"
    
    delta = df_m1['close'].diff()
    gain = (delta.where(delta > 0, 0)).rolling(window=14).mean()
    loss = (-delta.where(delta < 0, 0)).rolling(window=14).mean()
    rs = gain / loss
    df_m1['rsi'] = 100 - (100 / (1 + rs))
    
    current_rsi = df_m1['rsi'].iloc[-1]
    

    if htf_trend == "BULLISH" and current_rsi < 35: # Oversold tajam
        return "SIGNAL_BUY"
    elif htf_trend == "BEARISH" and current_rsi > 65: # Overbought tajam
        return "SIGNAL_SELL"
    # PERCOBAAN
    # if htf_trend == "BULLISH" and current_rsi < 99: # ASAL NEMBAK BUY
    #     return "SIGNAL_BUY"
    # elif htf_trend == "BEARISH" and current_rsi > 1: # ASAL NEMBAK SELL
    #     return "SIGNAL_SELL"        
    return "WAIT"

# ==========================================
# 4. MODUL EKSEKUSI (BRUTE-FORCE FILLING)
# ==========================================
def execute_trade(symbol, signal):
    config = PAIR_CONFIG[symbol]
    point = mt5.symbol_info(symbol).point
    price = mt5.symbol_info_tick(symbol).ask if signal == "SIGNAL_BUY" else mt5.symbol_info_tick(symbol).bid
    
    sl_dist = config["sl_points"] * point
    tp_dist = config["tp_points"] * point
    
    if signal == "SIGNAL_BUY":
        order_type = mt5.ORDER_TYPE_BUY
        sl, tp = price - sl_dist, price + tp_dist
        print(f"   🔫 SNIPER TRIGGER: BUY {symbol} di {price}")
    else:
        order_type = mt5.ORDER_TYPE_SELL
        sl, tp = price + sl_dist, price - tp_dist
        print(f"   🔫 SNIPER TRIGGER: SELL {symbol} di {price}")

    request = {
        "action": mt5.TRADE_ACTION_DEAL,
        "symbol": symbol,
        "volume": config["lot"],
        "type": order_type,
        "price": price,
        "sl": sl,
        "tp": tp,
        "deviation": DEVIATION,
        "magic": MAGIC_NUMBER,
        "comment": "Sniper_M1_Andra",
        "type_time": mt5.ORDER_TIME_GTC,
    }

    # Anti-Error 10030 Logic
    for filling in [mt5.ORDER_FILLING_FOK, mt5.ORDER_FILLING_IOC, mt5.ORDER_FILLING_RETURN]:
        request["type_filling"] = filling
        result = mt5.order_send(request)
        if result.retcode == mt5.TRADE_RETCODE_DONE:
            print(f"   ✅ EKSEKUSI SUKSES! Tiket: {result.order} | SL: {sl:.4f} | TP: {tp:.4f}")
            return
        elif result.retcode != 10030:
            print(f"   ❌ Gagal Eksekusi. Error: {result.retcode} - {result.comment}")
            return
    print("   ❌ Gagal total. Semua mode filling ditolak.")

# ==========================================
# 5. MAIN LOOP
# ==========================================
if __name__ == "__main__":
    if not init_broker(): quit()
    
    print("🤖 MESIN SNIPER M1 AKTIF. Mengawasi market...")
    
    try:
        while True:
            print(f"\n[{datetime.now().strftime('%H:%M:%S')}] Pemindaian M1 dimulai...")
            for sym in TARGET_SYMBOLS:
                info = mt5.symbol_info(sym)
                if info is None or not info.visible: continue
                
                # Cek apakah kita sudah punya posisi terbuka di pair ini?
                # Jika sudah ada, jangan BUKA LAYER BARU dulu (Risk Management M1)
                open_positions = mt5.positions_get(symbol=sym, magic=MAGIC_NUMBER)
                if open_positions is not None and len(open_positions) > 0:
                    print(f"   🛡️ {sym}: Posisi sudah terbuka. Menunggu trade selesai.")
                    continue
                
                df_h1 = get_data(sym, mt5.TIMEFRAME_H1, 250)
                df_m1 = get_data(sym, mt5.TIMEFRAME_M1, 50)
                
                trend = analyze_htf(df_h1)
                signal = analyze_ltf(df_m1, trend)
                
                if signal != "WAIT":
                    execute_trade(sym, signal)
                else:
                    print(f"   ⏳ {sym}: Trend {trend} | Menunggu Momentum Sniper M1...")
            
            # Tidur 60 detik (1 Menit) karena kita berburu di candle M1
            time.sleep(60)
            
    except KeyboardInterrupt:
        print("\n🛑 Mesin Sniper dimatikan oleh Andra.")
        mt5.shutdown()