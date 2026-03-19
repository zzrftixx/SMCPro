import MetaTrader5 as mt5
import pandas as pd
import numpy as np
from datetime import datetime

# ==========================================
# KONFIGURASI TARGET PAIR DARI GAMBARMU
# ==========================================
# Kita masukkan semua, bot akan otomatis skip yang tidak aktif di akun yang sedang login
TARGET_SYMBOLS = ["XAUUSDm", "BTCUSDm", "#BTCUSDr", "XAUUSDb", "#BTCUSD", "XAUUSD"]

def init_broker():
    if not mt5.initialize():
        print(f"❌ Gagal inisialisasi MT5! Error: {mt5.last_error()}")
        return False
    return True

def get_data(symbol, timeframe, num_bars=200):
    """Fungsi universal untuk menarik data M1 atau H1"""
    rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, num_bars)
    if rates is None:
        return None
    df = pd.DataFrame(rates)
    df['time'] = pd.to_datetime(df['time'], unit='s')
    df.set_index('time', inplace=True)
    return df

def analyze_htf(df_h1):
    """
    ANALISIS HIGHER TIMEFRAME (H1) - Mencari Arah Angin (Trend Utama)
    Menggunakan EMA 50 dan EMA 200 sebagai penunjuk arah makro.
    """
    if df_h1 is None or len(df_h1) < 200:
        return "NEUTRAL"
        
    df_h1['ema_50'] = df_h1['close'].ewm(span=50, adjust=False).mean()
    df_h1['ema_200'] = df_h1['close'].ewm(span=200, adjust=False).mean()
    
    current_close = df_h1['close'].iloc[-1]
    ema_50 = df_h1['ema_50'].iloc[-1]
    ema_200 = df_h1['ema_200'].iloc[-1]
    
    # Syarat Trend Bullish: Harga di atas EMA50, dan EMA50 di atas EMA200
    if current_close > ema_50 and ema_50 > ema_200:
        return "BULLISH"
    # Syarat Trend Bearish: Harga di bawah EMA50, dan EMA50 di bawah EMA200
    elif current_close < ema_50 and ema_50 < ema_200:
        return "BEARISH"
    else:
        return "CHOPPY" # Market sedang sideways/konsolidasi

def analyze_ltf(df_m1, htf_trend):
    """
    ANALISIS LOWER TIMEFRAME (M1) - Sniper Entry
    Hanya mencari entry yang searah dengan H1. Menggunakan RSI momentum M1.
    """
    if df_m1 is None or len(df_m1) < 20:
        return "WAIT"
        
    # Kalkulasi RSI manual sederhana untuk momentum
    delta = df_m1['close'].diff()
    gain = (delta.where(delta > 0, 0)).rolling(window=14).mean()
    loss = (-delta.where(delta < 0, 0)).rolling(window=14).mean()
    rs = gain / loss
    df_m1['rsi'] = 100 - (100 / (1 + rs))
    
    current_rsi = df_m1['rsi'].iloc[-1]
    
    # LOGIKA SNIPER ENTRY:
    # Jika H1 Bullish, kita tunggu M1 oversold (RSI < 40) lalu mulai menanjak
    if htf_trend == "BULLISH" and current_rsi < 40:
        return "SIGNAL_BUY"
        
    # Jika H1 Bearish, kita tunggu M1 overbought (RSI > 60) lalu mulai menukik
    elif htf_trend == "BEARISH" and current_rsi > 60:
        return "SIGNAL_SELL"
        
    return "WAIT"

if __name__ == "__main__":
    if not init_broker():
        quit()
        
    print(f"🤖 Memulai Analisis Multi-Timeframe (H1 + M1)...\n")
    
    for sym in TARGET_SYMBOLS:
        # Pengecekan apakah pair aktif di akun ini
        info = mt5.symbol_info(sym)
        if info is None or not info.visible:
            continue # Skip pair yang tidak aktif/tidak ada
            
        print(f"🔍 Menganalisis {sym}...")
        
        # Tarik data H1 dan M1
        data_h1 = get_data(sym, mt5.TIMEFRAME_H1, 250)
        data_m1 = get_data(sym, mt5.TIMEFRAME_M1, 50)
        
        # Analisis
        trend_h1 = analyze_htf(data_h1)
        signal_m1 = analyze_ltf(data_m1, trend_h1)
        
        # Output Logika
        print(f"   -> Trend H1 : {trend_h1}")
        print(f"   -> Sinyal M1: {signal_m1}")
        if signal_m1 != "WAIT":
            print(f"   🔥 SETUP DITEMUKAN PADA {sym}! Siap untuk eksekusi.")
        print("-" * 40)
        
    mt5.shutdown()