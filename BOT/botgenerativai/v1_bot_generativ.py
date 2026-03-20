import MetaTrader5 as mt5
import pandas as pd
import numpy as np
import time
from datetime import datetime
import google.generativeai as genai # API Gemini milikmu

# ==========================================
# 1. KONFIGURASI GOD MODE
# ==========================================
TARGET_SYMBOLS = ["BTCUSDm", "XAUUSDm"]
RISK_PERCENT = 1.0 
MAGIC_NUMBER = 999111
DEVIATION = 20

# KONFIGURASI GEMINI API (FUNDAMENTAL AI)
# Masukkan API Key kamu di sini. Ingat, Gemini gratisan punya limit 15 Request Per Menit.
GEMINI_API_KEY = "" 
genai.configure(api_key=GEMINI_API_KEY)
ai_model = genai.GenerativeModel('gemini-pro')

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

# ==========================================
# 3. KONEKSI & DATA PULLER
# ==========================================
def init_broker():
    if not mt5.initialize(): return False
    return True

def get_data(symbol, timeframe, num_bars=100):
    rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, num_bars)
    if rates is None: return None
    df = pd.DataFrame(rates)
    df['close'] = df['close'].astype(float)
    return df

# ==========================================
# 4. MACRO-MICRO MATRIX ALIGNMENT (W1 TO M1)
# ==========================================
def check_macro_alignment(symbol):
    """
    Hedge Fund Macro Filter: Mengecek W1, D1, H4, H1.
    Syarat: Harga harus berada di sisi yang sama dari EMA 50 di SEMUA timeframe.
    """
    tfs = [mt5.TIMEFRAME_W1, mt5.TIMEFRAME_D1, mt5.TIMEFRAME_H4, mt5.TIMEFRAME_H1]
    bias_list = []
    
    for tf in tfs:
        df = get_data(symbol, tf, 100)
        if df is None: return "ERROR"
        ema50 = calc_ema(df['close'], 50).iloc[-1]
        close = df['close'].iloc[-1]
        bias_list.append(1 if close > ema50 else -1)
        
    if sum(bias_list) == 4: return "STRONG_BULL"
    if sum(bias_list) == -4: return "STRONG_BEAR"
    return "DISSONANCE" # Trend W1 sampai H1 tidak sejajar. Berantakan.

def check_micro_sniper(symbol, macro_bias):
    """
    Sniper M1 Filter: Hanya mencari entry di M1 jika kondisinya ekstrem 
    dan searah dengan Macro Alignment.
    """
    df_m1 = get_data(symbol, mt5.TIMEFRAME_M1, 50)
    if df_m1 is None: return "WAIT"
    
    rsi_m1 = calc_rsi(df_m1['close'], 14).iloc[-1]
    
    if macro_bias == "STRONG_BULL" and rsi_m1 < 30: # Trend makro naik, tapi M1 lagi diskon (oversold)
        return "TRIGGER_BUY"
    if macro_bias == "STRONG_BEAR" and rsi_m1 > 70: # Trend makro turun, tapi M1 lagi di pucuk (overbought)
        return "TRIGGER_SELL"
        
    return "WAIT"

# ==========================================
# 5. AI FUNDAMENTAL SENTIMENT (GEMINI)
# ==========================================
def ask_gemini_fundamental(symbol, direction):
    """
    Meminta Gemini menganalisis sentimen fundamental real-time.
    WARNING: Jangan panggil fungsi ini tiap detik, API-mu akan diblokir Google.
    Hanya dipanggil SAAT M1 SNIPER MENYALA.
    """
    asset = "Bitcoin/Crypto" if "BTC" in symbol else "Gold/XAU" if "XAU" in symbol else "Forex"
    prompt = f"Sebagai analis finansial institusi, jawab HANYA dengan kata 'AMAN' atau 'BAHAYA'. Saya ingin membuka posisi {direction} untuk aset {asset} sekarang. Apakah ada berita makroekonomi (seperti NFP, CPI, pidato The Fed) atau sentimen fundamental ekstrem hari ini yang berisiko tinggi menghancurkan posisi teknikal {direction} saya?"
    
    try:
        response = ai_model.generate_content(prompt)
        answer = response.text.strip().upper()
        if "BAHAYA" in answer: return False
        return True
    except Exception as e:
        print(f"   ⚠️ Gemini API Error (Rate Limit/Connection): {e}. Fallback: Menganggap AMAN secara teknikal.")
        return True # Fallback jika API limit

# ==========================================
# 6. MAIN HYPER-LOOP
# ==========================================
if __name__ == "__main__":
    if not init_broker(): quit()
    
    print("🧠 THE GOD MODE MATRIX (W1-M1 + GEMINI AI) LIVE.")
    print("Menunggu Konjungsi 7 Timeframe. Ini akan memakan waktu berjam-jam...\n")
    
    try:
        while True:
            current_time = datetime.now().strftime("%H:%M:%S")
            print(f"[{current_time}] Memindai Macro Matrix W1-H1...")
            
            for sym in TARGET_SYMBOLS:
                # 1. CEK MACRO (W1 - H1)
                macro_bias = check_macro_alignment(sym)
                
                if macro_bias == "DISSONANCE":
                    print(f"   ✖️ {sym}: Macro Berantakan. H1 melawan D1/W1. Tiarap.")
                    continue
                    
                print(f"   🔥 {sym}: MACRO ALIGNED ({macro_bias})! Mengaktifkan Radar M1...")
                
                # 2. CEK MICRO (M1)
                trigger = check_micro_sniper(sym, macro_bias)
                
                if trigger != "WAIT":
                    direction = "BUY" if trigger == "TRIGGER_BUY" else "SELL"
                    print(f"   🎯 {sym}: SNIPER M1 TERKUNCI ({direction})! Meminta izin Gemini API...")
                    
                    # 3. CEK FUNDAMENTAL AI (GEMINI)
                    is_safe = ask_gemini_fundamental(sym, direction)
                    
                    if is_safe:
                        print(f"   ✅ GEMINI MEMBERI IZIN. EKSEKUSI {direction} {sym} SEKARANG! (Masukkan fungsi Order di sini)")
                        # panggil execute_trade() mu di sini
                        time.sleep(300) # Tidur 5 menit agar tidak double entry
                    else:
                        print(f"   🛑 GEMINI MEMVETO ENTRY! Ada berita fundamental berbahaya. Batal tembak.")
            
            # Tidur 1 menit untuk cek M1 candle berikutnya
            time.sleep(60)
            
    except KeyboardInterrupt:
        print("\n🛑 God Mode dimatikan.")
        mt5.shutdown()