import MetaTrader5 as mt5
import pandas as pd
import time

# ==========================================
# KONFIGURASI TARGET PAIR
# ==========================================
# Masukkan pair forex dan crypto incaranmu. 
# Sesuaikan penulisan dengan yang ada di Market Watch Exness/HFM kamu (misal: BTCUSDm, BTCUSDmc, dll)
TARGET_SYMBOLS = ["BTCUSDm", "XAUUSDm", "#BTCUSDr", "#BTCUSD", "XAUUSD"]

# Batas maksimal spread (dalam satuan point) agar aman untuk scalping M1
# Jika spread broker di atas angka ini, bot menolak entry untuk menghindari "manipulasi/kerugian instan"
MAX_SPREAD_POINTS = {
    "BTCUSDm": 1800,  # Misal 2 pips
    "XAUUSDm": 300,  
    "BTCUSDr": 5000,
    "#BTCUSD": 5000,
    "XAUUSD": 25
}

def init_broker():
    """Inisialisasi koneksi ke MT5 Terminal"""
    print("🔄 Mencoba terhubung ke MT5...")
    if not mt5.initialize():
        print(f"❌ Gagal inisialisasi MT5! Error Code: {mt5.last_error()}")
        return False
        
    term_info = mt5.terminal_info()
    if term_info is None:
        print("❌ Gagal mendapatkan info terminal.")
        return False
        
    print(f"✅ Terhubung ke Broker: {term_info.company}")
    print(f"✅ Mode Auto-Trading MT5: {'AKTIF' if term_info.trade_allowed else 'DIMATIKAN (Nyalakan tombol Algo Trading!)'}")
    return True

def check_symbols(symbols):
    """Memastikan pair ada di broker dan mengecek spread/kelayakan trading"""
    print("\n🔍 Memeriksa Intelijen Broker untuk Target Pair...")
    valid_symbols = []
    
    for sym in symbols:
        sym_info = mt5.symbol_info(sym)
        if sym_info is None:
            print(f"   ❌ {sym}: TIDAK DITEMUKAN di broker ini. (Cek penulisan suffix-nya, misal BTCUSDm)")
            continue
            
        if not sym_info.visible:
            mt5.symbol_select(sym, True) # Paksa tampilkan di Market Watch
            
        # Cek apakah broker mengizinkan trading di pair ini
        trade_mode = sym_info.trade_mode
        if trade_mode == mt5.SYMBOL_TRADE_MODE_DISABLED:
            print(f"   ❌ {sym}: Broker MENONAKTIFKAN trading untuk pair ini.")
            continue
            
        # Sistem Intelijen Spread
        current_spread = sym_info.spread
        max_allowed = MAX_SPREAD_POINTS.get(sym, 99999)
        
        status_spread = "🟢 AMAN"
        if current_spread > max_allowed:
            status_spread = f"🔴 BAHAYA (Spread terlalu lebar untuk M1: {current_spread} pts)"
            
        print(f"   ✅ {sym}: Tersedia | Spread: {current_spread} pts | Status: {status_spread}")
        valid_symbols.append(sym)
        
    return valid_symbols

if __name__ == "__main__":
    if init_broker():
        active_pairs = check_symbols(TARGET_SYMBOLS)
        print(f"\n🎯 Total Pair Siap Tempur: {len(active_pairs)}")
        mt5.shutdown()