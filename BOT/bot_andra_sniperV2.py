import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import time
from datetime import datetime

# ==========================================
# 1. KONFIGURASI MANAJEMEN RISIKO (AGGRESSIVE)
# ==========================================
PAIR_CONFIG = {
    "BTCUSDm": {"lot": 0.01, "sl_points": 10000, "tp_points": 30000},
    "XAUUSDm": {"lot": 0.01, "sl_points": 500, "tp_points": 1500}
}

TARGET_SYMBOLS = list(PAIR_CONFIG.keys())
MAGIC_NUMBER = 777888
DEVIATION = 30 # Diperlebar sedikit karena mode agresif lebih rentan slippage

# ==========================================
# 2. MODUL GATEWAY
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
# 3. MODUL ANALISIS EKSTREM (M15 + M1)
# ==========================================
def analyze_htf_extreme(df_m15):
    """
    Menggunakan M15 dengan EMA 20 & 50 agar jauh lebih sensitif terhadap perubahan arah.
    """
    if df_m15 is None or len(df_m15) < 100: return "NEUTRAL"
    df_m15['ema_20'] = df_m15['close'].ewm(span=20, adjust=False).mean()
    df_m15['ema_50'] = df_m15['close'].ewm(span=50, adjust=False).mean()
    
    close, ema20, ema50 = df_m15['close'].iloc[-1], df_m15['ema_20'].iloc[-1], df_m15['ema_50'].iloc[-1]
    
    if close > ema20 and ema20 > ema50: return "BULLISH"
    elif close < ema20 and ema20 < ema50: return "BEARISH"
    return "CHOPPY"

def analyze_ltf_extreme(df_m1, htf_trend):
    """
    Batas RSI dilonggarkan (42 & 58), tapi wajib dibarengi lonjakan volatilitas (Momentum Breakout).
    """
    if df_m1 is None or len(df_m1) < 20: return "WAIT"
    
    # 1. Kalkulasi RSI
    delta = df_m1['close'].diff()
    gain = (delta.where(delta > 0, 0)).rolling(window=14).mean()
    loss = (-delta.where(delta < 0, 0)).rolling(window=14).mean()
    rs = gain / loss
    df_m1['rsi'] = 100 - (100 / (1 + rs))
    current_rsi = df_m1['rsi'].iloc[-1]
    
    # 2. Kalkulasi Volatilitas (Body Candle)
    df_m1['body_size'] = abs(df_m1['close'] - df_m1['open'])
    avg_body = df_m1['body_size'].rolling(window=10).mean().iloc[-2] # Rata-rata 10 candle sebelumnya
    current_body = df_m1['body_size'].iloc[-1]
    
    # Syarat: Candle saat ini ukurannya harus minimal 1.5x lebih besar dari rata-rata (Ledakan Volume/Momentum)
    is_volatile = current_body > (avg_body * 1.5)
    
    # LOGIKA TRIGGER EKSTREM
    if htf_trend == "BULLISH" and current_rsi < 42 and is_volatile:
        return "SIGNAL_BUY"
    elif htf_trend == "BEARISH" and current_rsi > 58 and is_volatile:
        return "SIGNAL_SELL"
        
    return "WAIT"

# ==========================================
# 4. MODUL EKSEKUSI
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
        print(f"   💥 AGGRESSIVE TRIGGER: BUY {symbol} di {price}")
    else:
        order_type = mt5.ORDER_TYPE_SELL
        sl, tp = price + sl_dist, price - tp_dist
        print(f"   💥 AGGRESSIVE TRIGGER: SELL {symbol} di {price}")

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
        "comment": "Extreme_M1_Andra",
        "type_time": mt5.ORDER_TIME_GTC,
    }

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
    
    print("🤖 MESIN AGGRESSIVE SNIPER AKTIF. Memburu volatilitas...")
    
    try:
        while True:
            print(f"\n[{datetime.now().strftime('%H:%M:%S')}] Memindai M15 & M1...")
            for sym in TARGET_SYMBOLS:
                info = mt5.symbol_info(sym)
                if info is None or not info.visible: continue
                
                open_positions = mt5.positions_get(symbol=sym, magic=MAGIC_NUMBER)
                if open_positions is not None and len(open_positions) > 0:
                    print(f"   🛡️ {sym}: Posisi sudah terbuka. Tahan tembakan.")
                    continue
                
                # Menggunakan M15 (Bukan H1 lagi) untuk kelincahan tren
                df_m15 = get_data(sym, mt5.TIMEFRAME_M15, 200)
                df_m1 = get_data(sym, mt5.TIMEFRAME_M1, 50)
                
                trend = analyze_htf_extreme(df_m15)
                signal = analyze_ltf_extreme(df_m1, trend)
                
                if signal != "WAIT":
                    execute_trade(sym, signal)
                else:
                    print(f"   ⏳ {sym}: Trend M15 [{trend}] | Menunggu Lonjakan M1...")
            
            time.sleep(60)
            
    except KeyboardInterrupt:
        print("\n🛑 Mesin Aggressive Sniper dimatikan.")
        mt5.shutdown()  